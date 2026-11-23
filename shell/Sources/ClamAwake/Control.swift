// ClamAwake 菜单栏壳 — 命令行控制通道（CFMessagePort，本机同用户）
// GPL-3.0，见仓库 LICENSE
//
// 目的：让脚本/代理不碰鼠标也能走同一条功能路径——菜单项、右键、命令行最终都落到
// StatusBarController 的同一组方法上（同一个 EngineController 状态机、同一个 resume 持久化）。
//
// 架构：app 进程注册一个本地 CFMessagePort（名字 com.clamawake.app.control），
// 命令行进程发一条命令字符串、同步拿回状态文本。app 不在运行时，CLI 可选先 open 拉起。
//
// 命令：status / start / stop / toggle / login on|off / mode plugged|battery / quit

import Foundation

enum ControlChannel {
    static let portName = "com.clamawake.app.control"
}

/// 两拍授权预告（goal-1e0095）：会弹管理员授权窗的命令，第一拍只回预告、不执行——
/// 「弹窗之前必须先转达用户」由 stdout + 退出码钉进 agent 的必经路径，不再靠记得。
/// 预告时写 UserDefaults 标记；5 分钟内重跑同一条命令（第二拍）才真正执行（弹窗）。
/// 标记键与窗口期被 install.sh 复用（shell 侧 defaults 读写同一 domain）。
enum ControlAuth {
    static let announcedAtKey = "authAnnouncedAt"
    static let announcedActionKey = "authAnnouncedAction"
    static let window: TimeInterval = 300
    static let needsUserAuthPrefix = "needs_user_auth=yes"

    /// 第二拍判定：5 分钟内有预告记录，且记录的命令与本次相同
    /// （无 action 记录 = 通配——install.sh 只写时间戳的形态）
    static func announced(for request: String) -> Bool {
        let at = UserDefaults.standard.double(forKey: announcedAtKey)
        guard at > 0 else { return false }
        let age = Date().timeIntervalSince1970 - at
        guard age >= 0, age <= window else { return false }
        if let action = UserDefaults.standard.string(forKey: announcedActionKey), action != request {
            return false
        }
        return true
    }

    /// 第一拍：记下「已预告」标记（时间戳 + 命令）。Int 而非 Double：shell 侧 defaults read
    /// 对 float 显示科学计数法、数字校验拒收，两侧统一 int（2026-11-23 实弹实证）。
    static func announce(for request: String) {
        UserDefaults.standard.set(Int(Date().timeIntervalSince1970), forKey: announcedAtKey)
        UserDefaults.standard.set(request, forKey: announcedActionKey)
    }

    /// 第二拍消费：用毕即清，别把本次预告留给下一个动作蹭
    static func consume() {
        UserDefaults.standard.removeObject(forKey: announcedAtKey)
        UserDefaults.standard.removeObject(forKey: announcedActionKey)
    }

    /// 第一拍的 stdout（CLI 原样打印 + 退出码 5）
    static func preview(prompt: String) -> String {
        "\(needsUserAuthPrefix)\nprompt_text=\(prompt)"
    }
}

/// app 侧：常驻控制端口（回调跑在主线程 run loop，可直接改 UI 状态）
final class ControlPortServer {
    private var port: CFMessagePort?
    private weak var target: StatusBarController?

    init(target: StatusBarController) {
        self.target = target
    }

    @discardableResult
    func start() -> Bool {
        guard port == nil, let target else { return false }
        var context = CFMessagePortContext(
            version: 0,
            info: Unmanaged.passUnretained(target).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: CFMessagePortCallBack = { _, _, data, info in
            guard let info else { return nil }
            let controller = Unmanaged<StatusBarController>.fromOpaque(info).takeUnretainedValue()
            let request = data.flatMap { String(data: $0 as Data, encoding: .utf8) } ?? ""
            let reply = controller.handle(controlCommand: request)
            return Unmanaged.passRetained(Data(reply.utf8) as CFData)
        }
        guard let local = CFMessagePortCreateLocal(nil, ControlChannel.portName as CFString, callback, &context, nil) else {
            return false
        }
        let source = CFMessagePortCreateRunLoopSource(nil, local, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        port = local
        return true
    }
}

/// CLI 侧：发命令、拿回复
enum ControlClient {
    static func send(_ command: String, timeout: TimeInterval = 3) -> String? {
        guard let remote = CFMessagePortCreateRemote(nil, ControlChannel.portName as CFString) else { return nil }
        defer { CFMessagePortInvalidate(remote) }
        var reply: Unmanaged<CFData>?
        let payload = Data(command.utf8) as CFData
        let status = CFMessagePortSendRequest(
            remote, 1, payload, timeout, timeout,
            CFRunLoopMode.defaultMode.rawValue as CFString, &reply
        )
        guard status == kCFMessagePortSuccess, let reply else { return nil }
        return String(data: reply.takeRetainedValue() as Data, encoding: .utf8)
    }
}

/// 命令行入口：返回退出码；返回 nil 表示「不是 CLI 调用」，交回 GUI 启动
enum ControlCLI {
    static let usageText = """
    用法: ClamAwake <命令>
    ★ 智能体：动手前先跑 `ClamAwake readme`（智能体说明书）
      status                打印当前状态（phase/protecting/display_id/login/sleep_guard/mode/power）
      start [--wait]        开启合盖不睡眠（--wait 等到建屏完成或失败再返回）
      stop                  停止合盖不睡眠
      toggle                切换合盖不睡眠（同鼠标右键）
      login on|off          开机自启
      mode plugged|battery  合盖不睡眠范围（plugged=只在充电时不睡；battery=任何情况都不睡（开关时各需一次管理员授权，闸已在时免弹））
      quit                  退出 app
      readme                输出智能体说明书（agent 材料与边界；纯本地输出）
    说明：命令发给正在运行的 ClamAwake.app；未运行时自动先拉起（除 quit 外，readme 纯本地输出）。battery 档开关首跑返回退出码 5（授权预告），转达用户后重跑生效。
    """

    static func run(_ args: [String]) -> Int32? {
        guard let first = args.first, !first.isEmpty else { return nil }
        let command: String
        var wait = false
        switch first {
        case "status":
            command = "status"
        case "start", "stop", "toggle":
            command = first
            wait = args.contains("--wait")
        case "login":
            guard args.count >= 2, ["on", "off"].contains(args[1]) else {
                FileHandle.standardError.write(Data((usageText + "\n").utf8))
                return 2
            }
            command = "\(first) \(args[1])"
        case "mode":
            guard args.count >= 2 else {
                FileHandle.standardError.write(Data((usageText + "\n").utf8))
                return 2
            }
            let target: String
            switch args[1] {
            case "plugged", "normal": target = "plugged"   // 0.3.6 旧值迁移
            case "battery", "power": target = "battery"    // 0.3.6 旧值迁移
            default:
                FileHandle.standardError.write(Data((usageText + "\n").utf8))
                return 2
            }
            command = "mode \(target)"
        case "quit":
            command = "quit"
        case "readme":
            // 纯本地输出：不发控制端口、不拉起 app，直接返回
            AgentReadme.print_()
            return 0
        case "help", "-h", "--help":
            print(usageText)
            return 0
        default:
            FileHandle.standardError.write(Data((usageText + "\n").utf8))
            return 2
        }

        var reply = ControlClient.send(command)
        if reply == nil {
            // app 没在跑：先拉起（首次启动到端口就绪通常 < 2s）
            if command != "quit" && launchApp() {
                for _ in 0..<50 {
                    usleep(100_000)
                    if let retry = ControlClient.send(command) { reply = retry; break }
                }
            }
        }
        guard let firstReply = reply else {
            FileHandle.standardError.write(Data("控制端口不可达（ClamAwake.app 未运行且拉起失败）\n".utf8))
            return 3
        }

        // 两拍授权预告的第一拍：app 只回了预告没执行——原样打印（agent 转达用户），退出码 5
        if firstReply.hasPrefix(ControlAuth.needsUserAuthPrefix) {
            print(firstReply)
            return 5
        }

        var output = firstReply
        if wait && command == "start" {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let status = ControlClient.send("status") {
                    output = status
                    if !status.contains("phase=starting") { break }
                }
                usleep(150_000)
            }
        }
        print(output)
        return output.contains("phase=failed") ? 1 : 0
    }

    /// 拉起 app：优先按 bundle id（经 symlink 调用也成立），退回同 bundle 路径
    private static func launchApp() -> Bool {
        if runOpen(["-b", "com.clamawake.app"]) { return true }
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else { return false }
        return runOpen(["-a", appURL.path])
    }

    private static func runOpen(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
