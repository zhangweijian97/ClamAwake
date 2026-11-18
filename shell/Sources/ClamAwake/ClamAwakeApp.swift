// ClamAwake 菜单栏壳 — 主界面（NSStatusItem + NSMenu）
// GPL-3.0，见仓库 LICENSE
//
// 为什么不用 SwiftUI MenuBarExtra：MenuBarExtra 把左键和右键都接到「开菜单」，
// 没有挂右键行为的入口；右键直连开关需要自己分流鼠标事件的 NSStatusItem。
//
// 鼠标语义（0.3.4）：左键单击 = 打开菜单（内容与原 SwiftUI 菜单一致）；
// 右键单击 = 直接切换保活（隐藏快捷键，不进菜单）。
//
// 菜单结构：状态段 → 保活开关 → 开机自启（SMAppService）→ 系统级防睡（pmset，管理员授权）→ 退出。
// 状态持久化：保活开着时退出 app（例如合盖前误退），下次启动自动恢复保活（resumeKeepAliveOnLaunch）。
// 托盘图标：保活中 = bolt.circle.fill（实心），未保活 = zzz（一眼可辨状态）。

import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []
    private let statusBar = StatusBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        statusBar.install()
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
        refreshIcon()
    }

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let symbol = engine.isProtecting ? "bolt.circle.fill" : "zzz"
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

    /// 临时挂上 menu 再 performClick 弹出（弹完摘掉，保持右键可分流）
    private func showMenu() {
        guard let item = statusItem else { return }
        let menu = buildMenu()
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
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
            UserDefaults.standard.set(true, forKey: "resumeKeepAliveOnLaunch")
        } else {
            engine.stop()
            UserDefaults.standard.set(false, forKey: "resumeKeepAliveOnLaunch")
        }
        refreshIcon()
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

        let sleep = NSMenuItem(title: "系统级防睡（部分机型合盖仍入睡时用）",
                               action: #selector(toggleSleepGuardItem), keyEquivalent: "")
        sleep.target = self
        sleep.state = sleepGuard.isEnabled ? .on : .off
        sleep.isEnabled = !sleepGuard.isApplying
        menu.addItem(sleep)
        if sleepGuard.isApplying { menu.addItem(caption("等待管理员确认…")) }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 ClamAwake", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.addItem(caption("ClamAwake v0.3.3"))
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

    @objc private func toggleSleepGuardItem() {
        sleepGuard.setEnabled(!sleepGuard.isEnabled)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
