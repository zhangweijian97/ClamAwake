// ClamAwake 菜单栏壳 — 主界面（NSStatusItem + NSMenu）
// GPL-3.0，见仓库 LICENSE
//
// 为什么不用 SwiftUI MenuBarExtra：MenuBarExtra 把左键和右键都接到「开菜单」，
// 没有挂右键行为的入口；右键直连开关需要自己分流鼠标事件的 NSStatusItem。
//
// 鼠标语义（0.3.4）：左键单击 = 打开菜单（内容与原 SwiftUI 菜单一致）；
// 右键单击 = 直接切换保活（隐藏快捷键，不进菜单）。
//
// 菜单结构：状态段（含电源护栏）→ 保活开关 → 档位（插电/电池）→ 开机自启 → 退出。
// 状态持久化：保活开着时退出 app（例如合盖前误退），下次启动自动恢复保活（resumeKeepAliveOnLaunch）。
// 托盘图标四态：护栏警示 = exclamationmark.triangle（保活中+电池+插电档），保活中 = bolt.circle.fill（实心），
// 启动中 = bolt.circle（空心），未保活 = zzz（一眼可辨状态）。

import AppKit
import Combine
import IOKit.ps

/// 保活档位：插电档=保活只靠虚拟屏+断言（零密码）；电池档=保活时加 pmset 禁睡（进入 running 补闸、
/// 保活停/失败撤闸，各弹一次授权；闸已在=免弹）。电池合盖走硬件事件路径，断言与虚拟屏均挡不住
/// （2026-11-21 实测），唯 pmset 全覆盖。
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
        // 启动恢复先于控制通道：命令端口一开就能读到 phase=starting，不会把「恢复还没起跑」误读成「没恢复」
        statusBar.resumeKeepAliveIfNeeded()
        _ = control.start()   // 命令行控制通道（app 未运行时的 CLI 会先用 open 拉起本 app）
    }

    /// 退出前收尾：停引擎 + 撤闸（若在）。撤闸要弹授权窗，不能在同步返回里做完——
    /// 挂起退出（terminateLater），授权落定后再回话（用户取消也照退，残留走下次启动的菜单出口）。
    private var isTerminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        statusBar.prepareForTermination {
            // 回话排到下一拍：即使收尾同步完成（闸不在），reply 也必须发生在 return terminateLater 之后
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
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

        // 闸的生灭跟着保活的 phase 变化沿走（0.3.6 语义，2026-11-22 goal-088256 恢复；0.3.7 档位重构
        // 把这条链当「闸常驻」的实现细节删掉了）：活侧沿 → running 补闸；关侧沿 → 停/失败撤闸。
        // 关侧沿兜底两路：引擎意外死、启动失败（启动失败时没拉过闸，撤 = 清历史残留）。
        // 用户主动关走 stopKeepAlive 的原子序（先撤闸后停引擎），到这条沿时闸已撤=幂等空操作。
        // 只看变化沿，app 启动时的初始 .stopped 不触发（存量残留只走菜单出口，避免开机自动弹授权窗）。
        var lastPhase: EngineController.Phase = .stopped
        engine.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let self else { return }
                let wasRunning: Bool
                switch lastPhase {
                case .running: wasRunning = true
                default: wasRunning = false
                }
                let wasActive: Bool
                switch lastPhase {
                case .starting, .running: wasActive = true
                default: wasActive = false
                }
                let nowRunning: Bool
                switch phase {
                case .running: nowRunning = true
                default: nowRunning = false
                }
                let nowInactive: Bool
                switch phase {
                case .stopped, .failed: nowInactive = true
                default: nowInactive = false
                }
                lastPhase = phase
                if nowRunning, !wasRunning {
                    // 进入 running 才补闸：建屏失败不弹（开保活＝此时才真正兑现「合盖不睡」）
                    self.pullGuardIfNeeded()
                } else if wasActive, nowInactive {
                    self.releaseGuardIfNeeded()
                }
            }
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
            startKeepAlive()
        } else {
            stopKeepAlive()
        }
        refreshIcon()
    }

    /// 开保活的唯一入口（菜单/右键/CLI/启动恢复共用）：只动引擎与持久化；
    /// 闸由 phase 变化沿补（进入 running 时，见 install()），建屏失败就不弹授权。
    private func startKeepAlive() {
        engine.start()
        UserDefaults.standard.set(true, forKey: "resumeKeepAliveOnLaunch")
    }

    /// 关保活（原子）：电池档且闸在 = 先撤闸、后停引擎——撤闸被取消 → 整个关闭回滚
    /// （保活照跑、图标仍是开启态、resume 键不动）；闸不在（插电档或闸已撤）= 直接停，无弹窗路径。
    /// 撤闸弹窗期间引擎还在跑，图标保持开启态；授权落定（whenDone）才决定是否真的关。
    /// 其余两路（引擎意外死/启动失败）不在这里：引擎已死无法回滚，由 phase 变化沿兜底。
    private func stopKeepAlive() {
        sleepGuard.refresh()
        // isApplying 也算「闸在途」：写入飞行中（如刚开就关）排进 pendingTarget 接续链——
        // 否则刷新读数还是旧值（未落闸）时直接停引擎，写入完成后闸落下，就是半关闭态。
        guard keepAliveMode == .battery, sleepGuard.isEnabled || sleepGuard.isApplying else {
            finishStop()
            return
        }
        sleepGuard.setEnabled(false, whenDone: { [weak self] in
            guard let self else { return }
            self.sleepGuard.refresh()
            // 用户取消 / 撤销失败：闸还在 → 关闭整体未发生，什么都不做
            guard !self.sleepGuard.isEnabled else { return }
            self.finishStop()
        })
    }

    /// 落回关闭态的唯一动作：停引擎 + 清恢复键 + 图标落回关闭态。
    /// 两个调用者：stopKeepAlive 撤闸成立后的关闭、pullGuardIfNeeded 补闸被拒后的开启回滚。
    /// 到达这里时闸一定不在（撤闸已成立 / 本次没拉上）——停引擎后 phase 沿上的撤闸是幂等空操作。
    private func finishStop() {
        engine.stop()
        UserDefaults.standard.set(false, forKey: "resumeKeepAliveOnLaunch")
        refreshIcon()
    }

    /// 电池档完整性：保活承诺「合盖必不睡」，闸缺失时兑现不了——补拉（弹一次授权；闸已在=免弹）
    /// 开启原子化（对称 stopKeepAlive 的关闭原子化）：补闸被拒 / pmset 写入失败 → 整个开启回滚，
    /// 不留「图标亮着、合盖却会睡」的半开启态。允许（闸已落）→ 保活继续，无事发生。
    private func pullGuardIfNeeded() {
        guard keepAliveMode == .battery else { return }
        sleepGuard.refresh()
        guard !sleepGuard.isEnabled else { return }
        sleepGuard.setEnabled(true, whenDone: { [weak self] in
            guard let self else { return }
            self.sleepGuard.refresh()
            // 闸已落 = 开启成立，什么都不做；闸没落（用户不允许 / 写入失败）= 回滚整个开启
            guard !self.sleepGuard.isEnabled else { return }
            // 授权飞行期间用户切到了插电档：该档不依赖闸，回滚会误杀刚切过去的保活——不滚
            guard self.keepAliveMode == .battery else { return }
            self.finishStop()
        })
    }

    private func releaseGuardIfNeeded() {
        sleepGuard.refresh()
        if sleepGuard.isEnabled {
            sleepGuard.setEnabled(false)
        }
    }

    /// 启动恢复（resumeKeepAliveOnLaunch）：走与手动开保活同一条路径（同一状态机、同一持久化、同一补闸链）。
    /// 建屏是瞬态动作，失败重试 2 次——只重试引擎启动，不重试授权窗（用户取消就不反复弹）。
    func resumeKeepAliveIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "resumeKeepAliveOnLaunch") else { return }
        startKeepAlive()
        refreshIcon()
        scheduleResumeRetry(remaining: 2)
    }

    private func scheduleResumeRetry(remaining: Int) {
        guard remaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            guard case .failed = self.engine.phase else { return }
            self.startKeepAlive()
            self.scheduleResumeRetry(remaining: remaining - 1)
        }
    }

    /// 退出前收尾：停引擎 + 撤闸（若在），授权结果落定后回调（quit 路径用它挂起退出）。
    func prepareForTermination(_ completion: @escaping () -> Void) {
        engine.stop()
        if sleepGuard.isApplying {
            // 有写入在飞（刚开保活弹的授权窗）：等它落定再按结果撤——授权成立就撤，用户取消则本就无闸
            sleepGuard.setEnabled(false, whenDone: completion)
            return
        }
        sleepGuard.refresh()
        guard sleepGuard.isEnabled else {
            completion()
            return
        }
        sleepGuard.setEnabled(false, whenDone: completion)
    }

    // MARK: - 命令行控制（CFMessagePort 回调，主线程）

    /// 两拍授权预告（goal-1e0095，CLI 专用）：这条命令会不会弹管理员授权窗？
    /// 会 → 第一拍只回预告、不执行（写标记）；5 分钟内重跑同一条命令（第二拍）才放行原逻辑去弹窗。
    /// 免弹路径（闸已是目标值）不在两拍内：直接照常执行。
    private func authPreviewReply(for request: String) -> String? {
        guard let prompt = guardPrompt(for: request) else { return nil }
        if ControlAuth.announced(for: request) {
            ControlAuth.consume()
            return nil
        }
        ControlAuth.announce(for: request)
        return ControlAuth.preview(prompt: prompt)
    }

    /// 「这条命令将弹授权窗」的判定——与实际弹窗条件对齐：只有电池档需要系统级禁睡；
    /// 闸已是目标值 = 免弹（setEnabled 的 no-op 分支），不进两拍。
    private func guardPrompt(for request: String) -> String? {
        let wantsStart: Bool
        switch request {
        case "start": wantsStart = true
        case "stop": wantsStart = false
        case "toggle": wantsStart = !keepAliveOn
        default: return nil
        }
        guard keepAliveMode == .battery else { return nil }
        sleepGuard.refresh()
        if wantsStart {
            // 已开/启动中 = 空操作（引擎 start 幂等，无 phase 沿就不补闸）
            guard !keepAliveOn, !sleepGuard.isEnabled else { return nil }
            return "即将弹出管理员授权窗：请先告知用户「输密码以允许合盖不睡眠」，用户准备好后重新执行本命令"
        }
        // 关：闸在（或写入在途）才要授权撤闸；闸不在 = 直接停，无弹窗
        guard sleepGuard.isEnabled || sleepGuard.isApplying else { return nil }
        return "即将弹出管理员授权窗：请先告知用户「输密码以恢复系统默认睡眠」，用户准备好后重新执行本命令"
    }

    /// 命令行命令 → 与菜单/右键完全相同的功能路径（返回状态文本）
    func handle(controlCommand request: String) -> String {
        if let preview = authPreviewReply(for: request) { return preview }
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
            menu.addItem(caption("系统级禁睡：开"))
            // 两种异常残留给恢复出口：插电档本不该有闸；保活没在跑时闸该随保活已经撤掉
            if keepAliveMode == .plugged || !keepAliveOn {
                menu.addItem(caption("⚠ 系统级禁睡仍开着（合盖不睡但屏幕会亮着）"))
                let restore = NSMenuItem(title: "恢复系统睡眠默认", action: #selector(disableSleepGuard), keyEquivalent: "")
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
        let batteryItem = NSMenuItem(title: "任何情况都不睡（开关时需授权）",
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
        menu.addItem(caption("ClamAwake v0.3.8"))
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

    /// 切换档位（菜单/CLI 同路径）。闸跟着保活走（0.3.6 语义恢复）：
    /// 切电池档且保活开着 → 补闸（弹一次授权；闸已在则免弹）；切插电档 → 撤闸（弹一次授权；闸已撤则免弹）。
    /// 切电池档而保活关着 → 不弹：闸的存在服务保活承诺，开保活时由 phase 变化沿补。
    private func setKeepAliveMode(_ mode: KeepAliveMode) {
        keepAliveMode = mode
        sleepGuard.refresh()
        if mode == .battery {
            if engine.isProtecting && !sleepGuard.isEnabled {
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

    /// 残留出口：单独关闭系统级防睡（插电档而闸仍开、或保活已停而闸仍开时出现在菜单里——撤闸被取消/异常遗留）
    @objc private func disableSleepGuard() {
        sleepGuard.setEnabled(false)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
