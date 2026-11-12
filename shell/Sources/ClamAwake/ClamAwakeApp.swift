// ClamAwake 菜单栏壳 — 主界面（MenuBarExtra）
// GPL-3.0，见仓库 LICENSE
//
// 菜单结构：状态段 → 保活开关 → 开机自启（SMAppService）→ 系统级防睡（pmset，管理员授权）→ 退出。
// 状态持久化：保活开着时退出 app（例如合盖前误退），下次启动自动恢复保活（resumeKeepAliveOnLaunch）。

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
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

struct ClamAwakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = EngineController.shared
    @StateObject private var login = LoginItemManager()
    @StateObject private var sleepGuard = SleepGuardManager()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(engine: engine, login: login, sleepGuard: sleepGuard)
        } label: {
            Label("ClamAwake", systemImage: engine.isProtecting ? "bolt.circle.fill" : "zzz")
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuContent: View {
    @ObservedObject var engine: EngineController
    @ObservedObject var login: LoginItemManager
    @ObservedObject var sleepGuard: SleepGuardManager

    var body: some View {
        statusSection
        Divider()
        keepAliveButton
        Divider()
        Toggle("开机自启", isOn: Binding(
            get: { login.isEnabled },
            set: { on in on ? login.enable() : login.disable() }
        ))
        if login.needsApproval {
            Button("登录项待批准：在系统设置中查看…") {
                NSWorkspace.shared.open(LoginItemManager.loginItemsSettingsURL)
            }
        }
        Toggle("系统级防睡（部分机型合盖仍入睡时用）", isOn: Binding(
            get: { sleepGuard.isEnabled },
            set: { on in sleepGuard.setEnabled(on) }
        ))
        if sleepGuard.isApplying {
            Text("等待管理员确认…").font(.caption2)
        }
        Divider()
        Button("退出 ClamAwake") { NSApp.terminate(nil) }
        Text("ClamAwake v0.3.3").font(.caption2)
    }

    // 保活开着时菜单栏图标换成实心（一眼可辨状态），这里是状态文字段
    @ViewBuilder
    private var statusSection: some View {
        switch engine.phase {
        case .stopped:
            Text("当前状态：未保活")
        case .starting:
            Text("当前状态：启动中…")
        case .running(let id):
            Text("当前状态：保活中（虚拟屏 id=\(id)）")
        case .failed(let message):
            Text("当前状态：启动失败")
            Text(message).font(.caption2)
        }
        Text("保活档位：\(EngineController.logicalWidth)×\(EngineController.logicalHeight) HiDPI")
            .font(.caption2)
        if let message = login.lastError {
            Text(message).font(.caption2)
        }
        if let message = sleepGuard.lastError {
            Text(message).font(.caption2)
        }
    }

    private var keepAliveButton: some View {
        Button {
            setKeepAlive(!engine.isProtecting)
        } label: {
            engine.isProtecting ? Text("停止保活") : Text("开启保活")
        }
    }

    private func setKeepAlive(_ on: Bool) {
        if on {
            engine.start()
            UserDefaults.standard.set(true, forKey: "resumeKeepAliveOnLaunch")
        } else {
            engine.stop()
            UserDefaults.standard.set(false, forKey: "resumeKeepAliveOnLaunch")
        }
    }
}
