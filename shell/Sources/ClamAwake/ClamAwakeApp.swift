// ClamAwake 菜单栏壳 — 主界面（NSStatusItem + NSMenu）
// GPL-3.0，见仓库 LICENSE
//
// 为什么不用 SwiftUI MenuBarExtra：MenuBarExtra 把左键和右键都接到「开菜单」，
// 没有挂右键行为的入口；右键直连开关需要自己分流鼠标事件的 NSStatusItem。
//
// 鼠标语义（0.3.4）：左键单击 = 打开菜单（内容与原 SwiftUI 菜单一致）；
// 右键单击 = 直接切换保活（隐藏快捷键，不进菜单）。
//
// 菜单结构：状态段（含电源护栏）→ 保活开关 → 档位（插电/电池，闸常驻）→ 开机自启 → 退出。
// 状态持久化：保活开着时退出 app（例如合盖前误退），下次启动自动恢复保活（resumeKeepAliveOnLaunch）。
// 托盘图标四态：护栏警示 = exclamationmark.triangle（保活中+电池+插电档），保活中 = bolt.circle.fill（实心），
// 启动中 = bolt.circle（空心），未保活 = zzz（一眼可辨状态）。

import AppKit
import Combine
import IOKit.ps

/// 保活档位（0.3.7 重构）：档位是机器的常驻配置，独立于保活开关——
/// 插电档=保活只靠虚拟屏+断言（零密码）；电池档=系统级禁睡常驻（换档时拉/撤 pmset 闸各授权一次，
/// 保活开关零密码）。电池合盖走硬件事件路径，断言与虚拟屏均挡不住（2026-11-21 实测），唯 pmset 全覆盖。
enum KeepAliveMode: String {
    case plugged
    case battery
}

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

    // MARK: - 电源状态（IOPS）：保活中 + 电池供电 + 插电档 = 插电档挡不住合盖，给护栏
    private var powerSource: CFRunLoopSource?

    /// 当前是否在用电池（无电池设备/读不到按接电处理）
    static var onBattery: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        for ps in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any],
                  let state = desc[kIOPSPowerSourceStateKey] as? String else { continue }
            if state == kIOPSBatteryPowerValue { return true }
        }
        return false
    }

    /// 电源状态护栏：保活开着 + 电池 + 插电档 → 图标警示 + 菜单一键换档
    private var guardTripped: Bool {
        engine.isProtecting && Self.onBattery && keepAliveMode == .plugged
    }

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
        refreshIcon()

        // 电源变化（插/拔电）即时刷新图标（护栏态的进与退）
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let controller = Unmanaged<StatusBarController>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { controller.refreshIcon() }
        }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource(callback, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            powerSource = src
        }
    }

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        // 四态：护栏警示最高优先（保活中+电池+插电档=合盖会睡），
        // 保活中=实心闪电，启动中=空心闪电（建屏那 0.25s 有系统卡顿，先给即时反馈），未保活=zzz
        let symbol: String
        if guardTripped {
            symbol = "exclamationmark.triangle"
        } else if engine.isProtecting {
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

    // 档位持久化（UserDefaults key=keepAliveMode；缺省电池档——首要用户=移动携带；迁移 0.3.6 旧值 normal/power）
    private var keepAliveMode: KeepAliveMode {
        get {
            switch UserDefaults.standard.string(forKey: "keepAliveMode") {
            case "plugged", "normal": return .plugged
            default: return .battery   // battery/power/缺省都归电池档（0.3.7 收尾批：首要用户=移动携带）
            }
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "keepAliveMode") }
    }

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
            // 电池档完整性：保活开着承诺「合盖必不睡」，闸缺失时兑现不了——补拉（新用户首次开保活弹一次授权，
            // 此后闸常驻、开关零密码）。resume 路径不补：pmset 持久，正常场景闸在；异常场景菜单状态行可见。
            if keepAliveMode == .battery {
                sleepGuard.refresh()
                if !sleepGuard.isEnabled {
                    sleepGuard.setEnabled(true)
                }
            }
            UserDefaults.standard.set(true, forKey: "resumeKeepAliveOnLaunch")
        } else {
            engine.stop()
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
        case "mode plugged":
            setKeepAliveMode(.plugged)
            return statusReport()
        case "mode battery":
            setKeepAliveMode(.battery)
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
        lines.append("mode=\(keepAliveMode.rawValue)")
        lines.append("power=\(Self.onBattery ? "battery" : "ac")")
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
        if let message = login.lastError { menu.addItem(caption(message)) }
        if let message = sleepGuard.lastError { menu.addItem(caption(message)) }
        if sleepGuard.isEnabled {
            // 电池档合法态：闸常驻，保活关着也照常显示
            menu.addItem(caption("系统级禁睡：开"))
            if keepAliveMode == .plugged {
                // 插电档残留（切档取消/异常）：给恢复出口
                menu.addItem(caption("⚠ 系统级禁睡仍开着（上次切档未完成）"))
                let restore = NSMenuItem(title: "恢复睡眠默认", action: #selector(disableSleepGuard), keyEquivalent: "")
                restore.target = self
                restore.isEnabled = !sleepGuard.isApplying
                menu.addItem(restore)
                if sleepGuard.isApplying { menu.addItem(caption("等待管理员确认…")) }
            }
        }
        if guardTripped {
            menu.addItem(caption("⚠ 正用电池——当前档只在充电时不睡，合盖会睡"))
            let fix = NSMenuItem(title: "切换到：任何情况都不睡", action: #selector(switchToBatteryMode), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
        }
        menu.addItem(.separator())

        let keep = NSMenuItem(title: keepAliveOn ? "关闭合盖不睡眠" : "开启合盖不睡眠",
                              action: #selector(toggleKeepAlive), keyEquivalent: "")
        keep.target = self
        menu.addItem(keep)
        let batteryItem = NSMenuItem(title: "任何情况都不睡（授权一次）",
                                     action: #selector(chooseBatteryMode), keyEquivalent: "")
        batteryItem.target = self
        batteryItem.indentationLevel = 1
        batteryItem.state = keepAliveMode == .battery ? .on : .off
        menu.addItem(batteryItem)
        let pluggedItem = NSMenuItem(title: "只在充电时不睡",
                                     action: #selector(choosePluggedMode), keyEquivalent: "")
        pluggedItem.target = self
        pluggedItem.indentationLevel = 1
        pluggedItem.state = keepAliveMode == .plugged ? .on : .off
        menu.addItem(pluggedItem)
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

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 ClamAwake", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.addItem(caption("ClamAwake v0.3.7"))
        return menu
    }

    private var phaseText: String {
        switch engine.phase {
        case .stopped:
            return "当前状态：未开启"
        case .starting:
            return "当前状态：启动中…"
        case .running(let id):
            return "当前状态：合盖不睡眠中（虚拟屏 id=\(id)）"
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

    /// 切换档位（菜单/CLI 同路径）。闸的生灭只发生在换档：
    /// 切电池档 → 拉闸（弹一次授权；闸已在则免弹）；切插电档 → 撤闸（弹一次授权；闸已撤则免弹）。
    private func setKeepAliveMode(_ mode: KeepAliveMode) {
        keepAliveMode = mode
        sleepGuard.refresh()
        if mode == .battery {
            if !sleepGuard.isEnabled {
                sleepGuard.setEnabled(true)
            }
        } else if sleepGuard.isEnabled {
            sleepGuard.setEnabled(false)
        }
    }

    @objc private func choosePluggedMode() { setKeepAliveMode(.plugged) }

    @objc private func chooseBatteryMode() { setKeepAliveMode(.battery) }

    @objc private func switchToBatteryMode() {
        setKeepAliveMode(.battery)
    }

    @objc private func openLoginItemsSettings() {
        NSWorkspace.shared.open(LoginItemManager.loginItemsSettingsURL)
    }

    /// 插电档残留出口：单独关闭系统级防睡（只在插电档而闸仍开时出现在菜单里——切档取消/异常残留）
    @objc private func disableSleepGuard() {
        sleepGuard.setEnabled(false)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
