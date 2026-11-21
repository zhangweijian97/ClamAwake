// ClamAwake 菜单栏壳 — 命令行控制通道（CFMessagePort，本机同用户）
// GPL-3.0，见仓库 LICENSE
//
// 目的：让脚本/代理不碰鼠标也能走同一条功能路径——菜单项、右键、命令行最终都落到
// StatusBarController 的同一组方法上（同一个 EngineController 状态机、同一个 resume 持久化）。
//
// 架构：app 进程注册一个本地 CFMessagePort（名字 com.clamawake.app.control），
// 命令行进程发一条命令字符串、同步拿回状态文本。app 不在运行时，CLI 可选先 open 拉起。
//
// 命令：status / start / stop / toggle / login on|off / quit

import Foundation

enum ControlChannel {
    static let portName = "com.clamawake.app.control"
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
      status                打印当前状态（phase/protecting/display_id/login/sleep_guard）
      start [--wait]        开启保活（--wait 等到建屏完成或失败再返回）
      stop                  停止保活
      toggle                切换保活（同鼠标右键）
      login on|off          开机自启
      quit                  退出 app
    说明：命令发给正在运行的 ClamAwake.app；未运行时自动先拉起（除 quit 外）。
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
        case "quit":
            command = "quit"
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
