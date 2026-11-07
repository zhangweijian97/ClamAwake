// ClamAwake 菜单栏壳 — 引擎宿主
// GPL-3.0，见仓库 LICENSE
//
// 壳作为宿主调用引擎（src/vd-engine.swift 零改动）：
//   · 启动 = spawn `vd-engine create <W> <H> --hidpi --hold` 子进程 + `caffeinate -d` 显示断言
//     （合盖保活配方，见 README）。虚拟屏活在引擎进程生命周期内，引擎没有跨进程销毁 API，
//     所以「停止」唯一可行的实现 = 结束引擎子进程（--hold 对 SIGTERM 有清理 handler，exit(0)）。
//   · 状态确认不用引擎 stdout——stdout 是管道时引擎的 print 走全缓冲，--hold 进程永不 flush
//     （2026-11-07 复现实验定案）。改用 CoreGraphics 在线列表观察：启动前记 baseline，
//     轮询差集里第一个新屏（KYA vendor 优先匹配），这正是引擎内部 waitForNewDisplay 的同一信号源。
//   · 引擎 stderr 管道截留（stderr 无缓冲，即时到达），失败时把诊断带进错误信息。
//   · 退出路径全覆盖：菜单退出走 applicationShouldTerminate，kill/Term 信号走 DispatchSourceSignal，
//     两条路都会先 stop() 再退——不留孤儿虚拟屏（SIGKILL 除外，见实施报告遗留问题）。
//
// 线程约定（Swift 5 模式，未加 actor 隔离）：公开方法与 @Published 变更只发生在主线程；
// 子进程回调经 DispatchQueue.main.async 跳回主线程；stderr 缓冲用锁保护（后台队列写入）。

import Combine
import CoreGraphics
import Darwin
import Foundation

final class EngineController: ObservableObject {
    static let shared = EngineController()

    /// 保活档位：README 合盖保活配方的 1800x1169 HiDPI（16 寸 MBP 内屏逻辑分辨率）
    static let logicalWidth = 1800
    static let logicalHeight = 1169

    /// 引擎自定义 vendor 标记（与 src/vd-engine.swift 的 kyaVendorID 一致，用于读数核对）
    static let kyaVendorID: UInt32 = 0x4B5941

    enum Phase: Equatable {
        case stopped
        case starting
        case running(displayID: CGDirectDisplayID)
        case failed(message: String)
    }

    @Published private(set) var phase: Phase = .stopped

    private var engineProcess: Process?
    private var caffeinateProcess: Process?
    private var stopRequested = false

    /// 启动前的在线屏基线（差集观察用）
    private var baselineDisplayIDs: Set<CGDirectDisplayID> = []
    private var pollTimer: Timer?

    /// 引擎 stderr 截留（有锁保护；失败时取尾部做诊断）
    private let stderrLock = NSLock()
    private var stderrBuffer = Data()

    var isProtecting: Bool {
        if case .running = phase { return true }
        return false
    }

    /// 引擎二进制解析：.app 内 Resources 优先（产品形态）；
    /// 裸二进制跑 --selftest 时经 CLAMAWAKE_ENGINE_PATH 环境变量指到产物里的引擎。
    static func engineURL() -> URL {
        if let bundled = Bundle.main.url(forResource: "vd-engine", withExtension: nil) {
            return bundled
        }
        if let env = ProcessInfo.processInfo.environment["CLAMAWAKE_ENGINE_PATH"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: "/usr/bin/false")
    }

    // MARK: - 开 / 关

    func start() {
        switch phase {
        case .starting, .running:
            return
        case .stopped, .failed:
            break
        }
        let enginePath = Self.engineURL().path
        guard FileManager.default.isExecutableFile(atPath: enginePath) else {
            phase = .failed(message: "找不到可执行的引擎 vd-engine（路径 \(enginePath)）")
            return
        }
        phase = .starting
        stopRequested = false
        baselineDisplayIDs = Set(Self.onlineDisplayIDs())
        stderrLock.lock(); stderrBuffer = Data(); stderrLock.unlock()
        startPollTimer()
        do {
            caffeinateProcess = try spawnCaffeinate()
            engineProcess = try spawnEngine()
        } catch {
            // 半启动回滚：先起来的 caffeinate 不能留下
            for p in [engineProcess, caffeinateProcess].compactMap({ $0 }) where p.isRunning {
                p.terminate()
            }
            engineProcess = nil
            caffeinateProcess = nil
            stopPollTimer()
            phase = .failed(message: "启动失败：\(error.localizedDescription)")
        }
    }

    func stop() {
        stopRequested = true
        stopPollTimer()
        if let p = engineProcess { gracefulTerminate(p) }
        if let p = caffeinateProcess { gracefulTerminate(p) }
        phase = .stopped
    }

    // MARK: - 新屏观察（baseline 差集轮询）

    private func startPollTimer() {
        stopPollTimer()
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.pollForDisplay()
        }
        RunLoop.main.add(timer, forMode: .default)
        pollTimer = timer
    }

    private func stopPollTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollForDisplay() {
        guard case .starting = phase else {
            stopPollTimer()
            return
        }
        guard engineProcess?.isRunning == true else { return }   // 退出交给 engineDidTerminate
        let fresh = Self.onlineDisplayIDs().filter { !baselineDisplayIDs.contains($0) }
        // KYA vendor 优先（本引擎标记，已实测透传）；匹配不到再退回任意新屏
        let chosen = fresh.first { CGDisplayVendorNumber($0) == Self.kyaVendorID } ?? fresh.first
        guard let displayID = chosen else { return }
        stopPollTimer()
        phase = .running(displayID: displayID)
    }

    // MARK: - 子进程装配

    private func spawnCaffeinate() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-d"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    private func spawnEngine() throws -> Process {
        let p = Process()
        p.executableURL = Self.engineURL()
        p.arguments = ["create", "\(Self.logicalWidth)", "\(Self.logicalHeight)", "--hidpi", "--hold"]
        p.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        p.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.stderrLock.lock()
            self.stderrBuffer.append(data)
            if self.stderrBuffer.count > 4096 {
                self.stderrBuffer.removeFirst(self.stderrBuffer.count - 4096)
            }
            self.stderrLock.unlock()
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.engineDidTerminate(proc) }
        }
        try p.run()
        return p
    }

    private func stderrExcerpt(_ maxBytes: Int) -> String {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        guard let start = stderrBuffer.index(stderrBuffer.endIndex, offsetBy: -min(maxBytes, stderrBuffer.count),
                                            limitedBy: stderrBuffer.startIndex) else { return "" }
        return String(data: stderrBuffer[start...], encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func engineDidTerminate(_ proc: Process) {
        guard proc === engineProcess else { return }
        engineProcess = nil
        stopPollTimer()
        if stopRequested {
            stopRequested = false
            phase = .stopped
            return
        }
        switch phase {
        case .starting:
            let excerpt = stderrExcerpt(600)
            phase = .failed(message: excerpt.isEmpty
                ? "引擎在建屏确认前就退出了（建屏失败；重启 app 可重试）"
                : "引擎退出：\(excerpt)")
        default:
            // 意外退出：屏随引擎进程一起消失，状态回落到已停止
            phase = .stopped
        }
    }

    /// SIGTERM → 等最多 3s → SIGKILL 兜底（引擎 --hold 对 SIGTERM 有清理 handler，正常秒退）
    private func gracefulTerminate(_ p: Process) {
        guard p.isRunning else { return }
        p.terminate()
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(3)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    // MARK: - 公开读数

    static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}

// MARK: - 引擎宿主自检（--selftest）

enum EngineSelfTest {
    /// 主线程直跑（命令行入口即主线程），无 GUI：建屏 → 核对 → 停止 → 核对消失
    static func run() {
        MainActor.assumeIsolated {
            body()
        }
    }

    @MainActor
    private static func body() {
        let enginePath = EngineController.engineURL().path
        print("SELFTEST engine=\(enginePath)")
        guard FileManager.default.isExecutableFile(atPath: enginePath) else {
            print("SELFTEST FAIL: 引擎不可执行（检查 CLAMAWAKE_ENGINE_PATH / .app 组装）")
            exit(1)
        }

        let controller = EngineController()
        controller.start()

        var reportedPhase: EngineController.Phase = .starting
        for _ in 0..<60 {   // 最多 12s（引擎建屏确认最多 3s + 观察轮询 0.4s，留足余量）
            reportedPhase = controller.phase
            if case .running = reportedPhase { break }
            if case .failed(let message) = reportedPhase {
                print("SELFTEST FAIL: \(message)")
                exit(1)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        guard case .running(let id) = reportedPhase else {
            print("SELFTEST FAIL: 12s 内 phase 未进入 running")
            controller.stop()
            exit(1)
        }
        guard EngineController.onlineDisplayIDs().contains(id) else {
            print("SELFTEST FAIL: phase 报 running(displayID=\(id)) 但该屏不在在线列表")
            controller.stop()
            exit(1)
        }
        let vendor = CGDisplayVendorNumber(id)
        print("SELFTEST created display=\(id) vendor=0x\(String(vendor, radix: 16))"
            + "（引擎标记=0x\(String(EngineController.kyaVendorID, radix: 16))）")
        print("SELFTEST phase=running(displayID=\(id))，CG 观察与在线读数一致")

        controller.stop()
        var gone = false
        for _ in 0..<30 {   // 最多 6s
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            if !EngineController.onlineDisplayIDs().contains(id) { gone = true; break }
        }
        print(gone ? "SELFTEST PASS: 停止后虚拟屏已消失" : "SELFTEST FAIL: 停止 6s 后虚拟屏仍在线")
        exit(gone ? 0 : 1)
    }
}
