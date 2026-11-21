// ClamAwake 菜单栏壳 — 主界面（NSStatusItem + NSMenu）
// GPL-3.0，见仓库 LICENSE
//
// 为什么不用 SwiftUI MenuBarExtra：MenuBarExtra 把左键和右键都接到「开菜单」，
// 没有挂右键行为的入口；右键直连开关需要自己分流鼠标事件的 NSStatusItem。
//
// 鼠标语义（0.3.4）：左键单击 = 打开菜单（内容与原 SwiftUI 菜单一致）；
// 右键单击 = 直接切换保活（隐藏快捷键，不进菜单）。
//
// 菜单结构：状态段 → 保活开关（合并系统防睡：开=虚拟屏镜像+caffeinate+pmset 禁睡一起，关=一起撤）→ 开机自启（SMAppService）→ 退出。
// 状态持久化：保活开着时退出 app（例如合盖前误退），下次启动自动恢复保活（resumeKeepAliveOnLaunch）。
// 托盘图标：保活中 = bolt.circle.fill（实心），未保活 = zzz（一眼可辨状态）。

import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []
    private let statusBar = StatusBarController()
    private lazy var control = ControlPortServer(target: statusBar)

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        statusBar.install()
        _ = control.start()   // 命令行控制通道（app 未运行时的 CLI 会先用 open 拉起本 app）
        if UserDefaults.standard.bool(forKey: "resumeKeepAliveOnLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                EngineController.shared.start()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        EngineController.shared.stop()
        return .terminateNow
    }

    /// SIGINT / SIGTERM（kill、launchd 关停）也走清理路径：先停引擎子进程（屏随进程消失）再退出
    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                EngineController.shared.stop()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

/// 菜单栏图标与菜单的主人：负责左右键分流、菜单快照生成、图标随保活状态切换。
final class StatusBarController: NSObject {
    private let engine = EngineController.shared
    private let login = LoginItemManager()
    private let sleepGuard = SleepGuardManager()
    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // 不常设 item.menu（常设 menu 会把右键也变成开菜单）——左右键都走 action 分流
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = "左键：菜单　右键：快速开启/停止保活"
        statusItem = item

        // 保活状态变了就换图标（引擎在后台线程发通知，切回主线程再动 UI）
        engine.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &cancellables)

        // 合并开关的关侧：保活一旦停了（用户主动关 / 引擎意外死亡 / 启动失败），
        // 系统级防睡必须跟着撤——防睡单独残留 = 合盖不睡且内屏背光保持亮（不可接受状态）。
        // 只看变化沿（starting/running → stopped/failed），app 启动时的初始 .stopped 不触发
        // （存量矛盾态只走菜单警告行，避免开机自动弹管理员授权窗）。
        var lastPhase: EngineController.Phase = .stopped
        engine.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                let wasActive: Bool
                switch lastPhase {
                case .starting, .running: wasActive = true
                default: wasActive = false
                }
                let nowInactive: Bool
                switch phase {
                case .stopped, .failed: nowInactive = true
                default: nowInactive = false
                }
                lastPhase = phase
                if wasActive && nowInactive {
                    self?.sleepGuard.refresh()
                    if self?.sleepGuard.isEnabled == true {
                        self?.sleepGuard.setEnabled(false)
                    }
                }
            }
            .store(in: &cancellables)
        refreshIcon()
    }

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        // 三态：保活中=实心闪电，启动中=空心闪电（建屏那 0.25s 有系统卡顿，先给即时反馈），未保活=zzz
        let symbol: String
        if engine.isProtecting {
            symbol = "bolt.circle.fill"
        } else if case .starting = engine.phase {
            symbol = "bolt.circle"
        } else {
            symbol = "zzz"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ClamAwake")
        image?.isTemplate = true
        button.image = image
    }

    // MARK: - 鼠标分流

    @objc private func statusItemClicked(_ sender: Any?) {
        let type = NSApp.currentEvent?.type
        if type == .rightMouseUp || type == .rightMouseDown {
            toggleKeepAlive()
        } else {
            showMenu()
        }
    }

    /// 在状态栏按钮正下方弹出菜单。
    /// 不用「临时挂 item.menu + performClick」的旧写法：performClick 会给按钮补一次合成点击，
    /// 造成一下点击闪两次；偶发还会因为 menu 挂载与当前事件时序错开而弹不出来。
    /// 也不用 popUpContextMenu（锚点是鼠标）：改用 popUp 指定按钮左边缘，菜单左缘与图标左缘对齐。
    private func showMenu() {
        guard let button = statusItem?.button else { return }
        let menu = buildMenu()
        // 显式指定外观：popUp 会继承状态栏按钮的 vibrancy（深色壁纸下菜单会跟着变暗），
        // 菜单应跟随系统外观（浅色模式=浅色菜单）。
        menu.appearance = NSApp.effectiveAppearance
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: button)
    }

    // MARK: - 保活开关（右键 + 菜单共用一条路径）

    /// 启动中视作「已开」：右键此时按下 = 取消这次启动，而不是叠一次 start
    private var keepAliveOn: Bool {
        engine.isProtecting || engine.phase == .starting
    }

    @objc private func toggleKeepAlive() {
        setKeepAlive(!keepAliveOn)
    }

    private func setKeepAlive(_ on: Bool) {
        if on {
            engine.start()
            sleepGuard.setEnabled(true)   // 合并开关：开保活同时禁系统睡眠（已是 1 则免弹窗）
            UserDefaults.standard.set(true, forKey: "resumeKeepAliveOnLaunch")
        } else {
            engine.stop()   // 防睡回收由 observeEnginePhase 的 phase 观察统一触发
            UserDefaults.standard.set(false, forKey: "resumeKeepAliveOnLaunch")
        }
        refreshIcon()
    }

    // MARK: - 命令行控制（CFMessagePort 回调，主线程）

    /// 命令行命令 → 与菜单/右键完全相同的功能路径（返回状态文本）
    func handle(controlCommand request: String) -> String {
        switch request {
        case "status":
            return statusReport()
        case "start":
            setKeepAlive(true)
            return statusReport()
        case "stop":
            setKeepAlive(false)
            return statusReport()
        case "toggle":
            setKeepAlive(!keepAliveOn)
            return statusReport()
        case "login on":
            login.enable()
            return statusReport()
        case "login off":
            login.disable()
            return statusReport()
        case "quit":
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return "bye"
        default:
            return "error=未知命令 \(request)"
        }
    }

    /// 机器可读状态（CLI status / start --wait 消费）
    private func statusReport() -> String {
        sleepGuard.refresh()   // pmset 读数实时
        login.syncStatus()
        var lines: [String] = []
        switch engine.phase {
        case .stopped:
            lines.append("phase=stopped")
            lines.append("display_id=")
        case .starting:
            lines.append("phase=starting")
            lines.append("display_id=")
        case .running(let id):
            lines.append("phase=running")
            lines.append("display_id=\(id)")
        case .failed(let message):
            lines.append("phase=failed")
            lines.append("display_id=")
            lines.append("error=\(message.replacingOccurrences(of: "\n", with: " "))")
        }
        lines.append("protecting=\(engine.isProtecting ? "yes" : "no")")
        lines.append("login=\(login.isEnabled ? "on" : "off")")
        lines.append("sleep_guard=\(sleepGuard.isEnabled ? "on" : "off")")
        return lines.joined(separator: "\n")
    }

    // MARK: - 菜单（每次打开现算快照）

    private func buildMenu() -> NSMenu {
        sleepGuard.refresh()          // pmset 读数实时刷新（不碰 lastError）
        login.syncStatus()            // 系统设置里改过登录项也能反映出来

        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(plain(phaseText))
        if case .failed(let message) = engine.phase {
            menu.addItem(caption(message))
        }
        menu.addItem(caption("保活档位：\(EngineController.logicalWidth)×\(EngineController.logicalHeight) HiDPI"))
        if let message = login.lastError { menu.addItem(caption(message)) }
        if let message = sleepGuard.lastError { menu.addItem(caption(message)) }
        menu.addItem(.separator())

        let keep = NSMenuItem(title: keepAliveOn ? "停止保活" : "开启保活",
                              action: #selector(toggleKeepAlive), keyEquivalent: "")
        keep.target = self
        menu.addItem(keep)
        menu.addItem(.separator())

        let startAtLogin = NSMenuItem(title: "开机自启", action: #selector(toggleLaunchItem), keyEquivalent: "")
        startAtLogin.target = self
        startAtLogin.state = login.isEnabled ? .on : .off
        menu.addItem(startAtLogin)

        if login.needsApproval {
            let approval = NSMenuItem(title: "登录项待批准：在系统设置中查看…",
                                      action: #selector(openLoginItemsSettings), keyEquivalent: "")
            approval.target = self
            menu.addItem(approval)
        }

        // 矛盾态兜底：防睡仍开而保活已停（关保活时授权被取消/失败）——合盖屏幕会亮，给显眼警告与恢复出口
        if sleepGuard.isEnabled && !keepAliveOn {
            menu.addItem(caption("⚠ 系统防睡仍开着而保活已停：合盖屏幕会亮着"))
            let unstick = NSMenuItem(title: "恢复系统睡眠默认", action: #selector(disableSleepGuard), keyEquivalent: "")
            unstick.target = self
            unstick.isEnabled = !sleepGuard.isApplying
            menu.addItem(unstick)
            if sleepGuard.isApplying { menu.addItem(caption("等待管理员确认…")) }
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 ClamAwake", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.addItem(caption("ClamAwake v0.3.5"))
        return menu
    }

    private var phaseText: String {
        switch engine.phase {
        case .stopped:
            return "当前状态：未保活"
        case .starting:
            return "当前状态：启动中…"
        case .running(let id):
            return "当前状态：保活中（虚拟屏 id=\(id)）"
        case .failed:
            return "当前状态：启动失败"
        }
    }

    /// 灰色说明行（原 SwiftUI 里的小字 caption）
    private func plain(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func caption(_ text: String) -> NSMenuItem {
        let item = plain(text)
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
        )
        return item
    }

    // MARK: - 菜单动作

    @objc private func toggleLaunchItem() {
        if login.isEnabled {
            login.disable()
        } else {
            login.enable()
        }
    }

    @objc private func openLoginItemsSettings() {
        NSWorkspace.shared.open(LoginItemManager.loginItemsSettingsURL)
    }

    /// 矛盾态恢复出口：单独关闭系统级防睡（只在防睡仍开而保活已停时出现在菜单里）
    @objc private func disableSleepGuard() {
        sleepGuard.setEnabled(false)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
