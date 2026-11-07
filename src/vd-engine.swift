// vd-engine — 虚拟屏引擎（ClamAwake v0.3，新增 doctor 环境自检子命令）
//
// 编译: swiftc -O src/vd-engine.swift -o vd-engine
//
// 风格与 mirror-probe.swift 一致：中文注释、stdout 只放机器可读结果、诊断走 stderr、
// 退出码 2=用法错 / 1=运行错 / 0=成功。
//
// 参考实现（均 MIT；只抄调用形态，未抄业务逻辑）：
//   · pasky/hidpi-mirror（hidpi-mirror.m）
//       - 私有类取法：NSClassFromString("CGVirtualDisplay") 取类，私有 @interface 只作类型说明、不链接符号
//       - descriptor 填法：name / queue / sizeInMillimeters / maxPixelsWide·High / 色度学原点 / vendor·product·serial
//       - settings.hiDPI = 1，modes 里放像素尺寸（2x）
//       - 关键洞察：WindowServer 在虚拟屏上只跑「模式列表第一个」= 首选模式，不认程序化模式切换
//         → 想要哪档分辨率，就把它放列表第一位
//       - 生命周期：虚拟屏活在创建进程的生命周期内（进程退出即消失），没有销毁 API
//   · xtongs/mirrorscreen（Sources/MirrorScreen/VirtualDisplayManager.swift + Sources/CGVirtualDisplayBridge/*）
//       - descriptor / settings / mode 三段式构造；displayID 从对象属性读（display.displayID != 0 才算建成功）
//       - apply(settings) 后给系统约 1.5s 落盘再读状态
//       - 销毁 = 释放实例（stop() 里 virtualDisplay = nil），没有 destroy 调用
//
// 与早期任务说明的一处差异（实测澄清）：
//   任务说明里写的「CGVirtualDisplayCreate / CGVirtualDisplayDestroy 两个 C 符号」实测不存在。
//   macOS 27.0 上的真实形态是 CoreGraphics.framework 运行时注册的 4 个 ObjC 类：
//     CGVirtualDisplay / CGVirtualDisplayDescriptor / CGVirtualDisplaySettings / CGVirtualDisplayMode
//   （用 class_copyMethodList 内省确认：CGVirtualDisplay 有 initWithDescriptor:/applySettings:/displayID 等 21 个方法，
//     没有任何 destroy/remove/terminate 方法）。因此取法不是 dlsym C 符号，而是：
//     NSClassFromString 取类 + dlsym("objc_msgSend") 拿消息派发指针，再按每个方法签名 unsafeBitCast 成
//     @convention(c) 函数——Swift 无法给私有 ObjC 类写 extension，函数指针强转代替参考项目的 @interface 声明。

import CoreGraphics
import Foundation
import Darwin

// MARK: - 用法与退出码

let usage = """
用法:
  vd-engine create <W> <H> [--hidpi] [--hold]   建虚拟屏（逻辑分辨率 WxH），成功后 stdout 打印屏 id
  vd-engine remove <id>                          销毁指定虚拟屏
  vd-engine list                                 列出全部在线显示器（只读）
  vd-engine hi <id>                              打印指定屏的 HiDPI 情况（只读）
  vd-engine doctor                               环境自检+可执行建议（只读；有阻塞问题时退出码 1）

选项:
  --hidpi  逻辑 WxH、像素 2Wx2H（例: 1800 1169 --hidpi → 像素 3600x2338，HiDPI 档进模式列表）
  --hold   建完不退出，前台常驻持有该屏（Ctrl-C / SIGTERM 结束，屏随之销毁）

退出码: 0 成功 / 1 运行错 / 2 用法错
"""

func errln(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

// MARK: - 私有 API 取法：NSClassFromString 取类 + objc_msgSend 派发

// 私有类的消息派发。Swift 里不能给运行时注册的私有 ObjC 类声明 extension，
// 所以每个方法按「self + _cmd + 参数」的真实 ABI 强转成 @convention(c) 函数指针。
private typealias MsgSendAlloc = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer?
private typealias MsgSendInitNoArg = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer?
private typealias MsgSendInitWithObject = @convention(c) (AnyObject, Selector, AnyObject) -> UnsafeMutableRawPointer?
private typealias MsgSendInitMode = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> UnsafeMutableRawPointer?
private typealias MsgSendBoolWithObject = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
private typealias MsgSendUInt32NoArg = @convention(c) (AnyObject, Selector) -> UInt32
private typealias MsgSendVoidWithObject = @convention(c) (AnyObject, Selector, AnyObject) -> Void
private typealias MsgSendVoidWithUInt32 = @convention(c) (AnyObject, Selector, UInt32) -> Void
private typealias MsgSendVoidWithSize = @convention(c) (AnyObject, Selector, CGSize) -> Void
private typealias MsgSendVoidWithPoint = @convention(c) (AnyObject, Selector, CGPoint) -> Void

private enum ObjC {
    // RTLD_DEFAULT 在 Swift 里不是导入的宏，用 -2（(void *)-2）显式表达；先用 dlopen 保证 libobjc 已装载。
    static let msgSend: UnsafeMutableRawPointer = {
        _ = dlopen("/usr/lib/libobjc.A.dylib", RTLD_LAZY)
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else {
            errln("致命错误：取不到 objc_msgSend（libobjc 不可用）")
            exit(1)
        }
        return p
    }()

    static let alloc = unsafeBitCast(msgSend, to: MsgSendAlloc.self)
    static let initNoArg = unsafeBitCast(msgSend, to: MsgSendInitNoArg.self)
    static let initWithObject = unsafeBitCast(msgSend, to: MsgSendInitWithObject.self)
    static let initWithMode = unsafeBitCast(msgSend, to: MsgSendInitMode.self)
    static let boolWithObject = unsafeBitCast(msgSend, to: MsgSendBoolWithObject.self)
    static let uint32NoArg = unsafeBitCast(msgSend, to: MsgSendUInt32NoArg.self)
    static let voidWithObject = unsafeBitCast(msgSend, to: MsgSendVoidWithObject.self)
    static let voidWithUInt32 = unsafeBitCast(msgSend, to: MsgSendVoidWithUInt32.self)
    static let voidWithSize = unsafeBitCast(msgSend, to: MsgSendVoidWithSize.self)
    static let voidWithPoint = unsafeBitCast(msgSend, to: MsgSendVoidWithPoint.self)
}

/// 本引擎建的屏的身份标记（descriptor.vendorID/productID）：list 用它标记「疑为本引擎所建」。
/// 依据（强信号、非实测建屏）：本机当前在线的那块第三方虚拟屏读数 vendor=4660(0x1234) / product=22136(0x5678) /
/// serial=1，正是 descriptor 里的占位值，说明 CGDisplayVendorNumber 会透传 descriptor.vendorID。
/// 仍作「提示」不作判据——未实测本引擎自己的 vendor 是否原样落地。
private let kyaVendorID: UInt32 = 0x4B5941  // "KYA"

// MARK: - 私有对象构造

enum VDError: Error, CustomStringConvertible {
    case privateAPIMissing(String)
    case objectCreationFailed(String)
    case applySettingsFailed

    var description: String {
        switch self {
        case .privateAPIMissing(let name):
            return "私有类 \(name) 不存在（本机 \(ProcessInfo.processInfo.operatingSystemVersionString) 上 CGVirtualDisplay 不可用）"
        case .objectCreationFailed(let name):
            return "构造 \(name) 失败"
        case .applySettingsFailed:
            return "applySettings: 返回 NO（WindowServer 拒绝该模式组合）"
        }
    }
}

private func classNamed(_ name: String) throws -> AnyObject {
    guard let cls = NSClassFromString(name) else {
        throw VDError.privateAPIMissing(name)
    }
    return cls as AnyObject
}

/// 等价于 ObjC 的 [[Cls alloc] init]（参考：mirrorscreen 里 CGVirtualDisplaySettings()/Descriptor() 的默认 init）。
/// 这两个类都有 -init（内省确认），所以直接发 alloc + init。
private func newObject(_ className: String) throws -> AnyObject {
    let cls = try classNamed(className)
    guard let allocPtr = ObjC.alloc(cls, NSSelectorFromString("alloc")) else {
        throw VDError.objectCreationFailed(className)
    }
    // alloc 给 +1，init 返回同一个引用并把 +1 转交给我们；takeRetainedValue 消费这份 +1。
    let alloced = Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(allocPtr)).takeUnretainedValue()
    let initPtr = ObjC.initNoArg(alloced, NSSelectorFromString("init"))
    guard let initPtr = initPtr else {
        throw VDError.objectCreationFailed(className)
    }
    return Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(initPtr)).takeRetainedValue()
}

/// 等价于 [[Cls alloc] initWithWidth:height:refreshRate:]（CGVirtualDisplayMode 没有默认 -init，只能走这个）
private func newMode(width: UInt, height: UInt, refreshRate: Double) throws -> AnyObject {
    let cls = try classNamed("CGVirtualDisplayMode")
    guard let allocPtr = ObjC.alloc(cls, NSSelectorFromString("alloc")) else {
        throw VDError.objectCreationFailed("CGVirtualDisplayMode")
    }
    let alloced = Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(allocPtr)).takeUnretainedValue()
    let sel = NSSelectorFromString("initWithWidth:height:refreshRate:")
    guard let modePtr = ObjC.initWithMode(alloced, sel, width, height, refreshRate) else {
        throw VDError.objectCreationFailed("CGVirtualDisplayMode")
    }
    return Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(modePtr)).takeRetainedValue()
}

// MARK: - 建屏

struct VirtualDisplayHandle {
    let display: AnyObject      // 必须由调用方持有：实例一释放，WindowServer 就收屏
    let displayID: CGDirectDisplayID
}

/// 建一块虚拟屏。参数是逻辑分辨率（点），hidpi=true 时像素 = 2x 逻辑。
func createVirtualDisplay(logicalWidth: Int, logicalHeight: Int, hidpi: Bool) throws -> VirtualDisplayHandle {
    let pixelWidth = hidpi ? logicalWidth * 2 : logicalWidth
    let pixelHeight = hidpi ? logicalHeight * 2 : logicalHeight

    let descriptor = try newObject("CGVirtualDisplayDescriptor")

    // descriptor 字段：照 hidpi-mirror 的填法（缺省不填的字段保持 0 也能建，但色度学/物理尺寸影响上报 DPI）
    ObjC.voidWithObject(descriptor, NSSelectorFromString("setName:"), "ClamAwake 画布" as NSString)
    ObjC.voidWithObject(descriptor, NSSelectorFromString("setQueue:"), DispatchQueue.main)
    // 物理尺寸只影响上报 DPI，不影响渲染：按「逻辑分辨率约 110 DPI」反推，落在常见笔电/外接屏区间
    let mmWidth = Double(logicalWidth) / 110.0 * 25.4
    let mmHeight = Double(logicalHeight) / 110.0 * 25.4
    ObjC.voidWithSize(descriptor, NSSelectorFromString("setSizeInMillimeters:"),
                      CGSize(width: mmWidth, height: mmHeight))
    // maxPixels=模式列表最大值（HiDPI 合成的必要条件之一，hidpi-mirror 同法）
    ObjC.voidWithUInt32(descriptor, NSSelectorFromString("setMaxPixelsWide:"), UInt32(max(pixelWidth, hidpi ? 5120 : pixelWidth)))
    ObjC.voidWithUInt32(descriptor, NSSelectorFromString("setMaxPixelsHigh:"), UInt32(max(pixelHeight, hidpi ? 2880 : pixelHeight)))
    // sRGB 色度学原点（与 hidpi-mirror 同值）
    ObjC.voidWithPoint(descriptor, NSSelectorFromString("setRedPrimary:"), CGPoint(x: 0.680, y: 0.320))
    ObjC.voidWithPoint(descriptor, NSSelectorFromString("setGreenPrimary:"), CGPoint(x: 0.265, y: 0.690))
    ObjC.voidWithPoint(descriptor, NSSelectorFromString("setBluePrimary:"), CGPoint(x: 0.150, y: 0.060))
    ObjC.voidWithPoint(descriptor, NSSelectorFromString("setWhitePoint:"), CGPoint(x: 0.3127, y: 0.3290))
    // 身份：vendor 打本引擎标记；product 里编进逻辑尺寸，让不同尺寸各有一份模式偏好
    // （hidpi-mirror 同法：macOS 按 vendor+product 存模式偏好，同一身份换尺寸会吃到旧偏好）
    ObjC.voidWithUInt32(descriptor, NSSelectorFromString("setVendorID:"), kyaVendorID)
    let productID = (UInt32(2) << 24) | (UInt32(logicalWidth & 0xFFF) << 12) | UInt32(logicalHeight & 0xFFF)
    ObjC.voidWithUInt32(descriptor, NSSelectorFromString("setProductID:"), productID)
    ObjC.voidWithUInt32(descriptor, NSSelectorFromString("setSerialNum:"), UInt32.random(in: 1...0xFFFF))

    // 建实例：[[CGVirtualDisplay alloc] initWithDescriptor:descriptor]
    let vdClass = try classNamed("CGVirtualDisplay")
    guard let allocPtr = ObjC.alloc(vdClass, NSSelectorFromString("alloc")) else {
        throw VDError.objectCreationFailed("CGVirtualDisplay")
    }
    let alloced = Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(allocPtr)).takeUnretainedValue()
    guard let displayPtr = ObjC.initWithObject(alloced, NSSelectorFromString("initWithDescriptor:"), descriptor) else {
        throw VDError.objectCreationFailed("CGVirtualDisplay")
    }
    let display = Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(displayPtr)).takeRetainedValue()

    let displayID = ObjC.uint32NoArg(display, NSSelectorFromString("displayID"))
    if displayID == 0 {
        throw VDError.objectCreationFailed("CGVirtualDisplay（displayID=0）")
    }

    // 模式 + 设置：HI-DPI 时列表里放像素模式（2x），非 HiDPI 时放 1x。
    // 首选模式=目标档（WindowServer 只跑列表第一个，虚拟屏不认程序化模式切换）；
    // 但 HiDPI 必须跟一组 extra 2x 档且 maxPixels=列表最大——hidpi-mirror 实证：
    // 「丰富的模式列表且最大值等于 maxPixels」是 macOS 合成真正 HiDPI 变体的必要条件，
    // 单模式列表系统不认 HiDPI（1107 实测：points=pixels 全塌 1x）。
    let primaryMode = try newMode(width: UInt(pixelWidth), height: UInt(pixelHeight), refreshRate: 60.0)
    var modeList: [AnyObject] = [primaryMode]
    if hidpi {
        let extra2x: [(UInt, UInt)] = [(5120, 2880), (4608, 2592), (4096, 2304), (3840, 2160),
                                       (3360, 1890), (3200, 1800), (2560, 1440), (1920, 1080)]
        for (w, h) in extra2x where w != UInt(pixelWidth) || h != UInt(pixelHeight) {
            if let m = try? newMode(width: w, height: h, refreshRate: 60.0) { modeList.append(m) }
        }
    }
    let settings = try newObject("CGVirtualDisplaySettings")
    ObjC.voidWithUInt32(settings, NSSelectorFromString("setHiDPI:"), hidpi ? 1 : 0)
    ObjC.voidWithObject(settings, NSSelectorFromString("setModes:"), modeList as NSArray)

    guard ObjC.boolWithObject(display, NSSelectorFromString("applySettings:"), settings) else {
        throw VDError.applySettingsFailed
    }

    return VirtualDisplayHandle(display: display, displayID: displayID)
}

// MARK: - 显示器读数（公开 API）

func onlineDisplayIDs() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    var count: UInt32 = 0
    let err = CGGetOnlineDisplayList(32, &ids, &count)
    if err != .success {
        errln("CGGetOnlineDisplayList 失败: CGError=\(err.rawValue)")
        return []
    }
    return Array(ids.prefix(Int(count)))
}

struct ModeReading {
    let pointsWidth: Int
    let pointsHeight: Int
    let pixelsWidth: Int
    let pixelsHeight: Int
    let refreshRate: Double
    var isHiDPI: Bool { pixelsWidth >= 2 * pointsWidth && pointsWidth > 0 }
}

func reading(_ mode: CGDisplayMode) -> ModeReading {
    // Swift 里 CGDisplayModeGetWidth/GetPixelWidth 等函数已被 CGDisplayMode 的属性取代（SDK 27）
    ModeReading(pointsWidth: mode.width,
                pointsHeight: mode.height,
                pixelsWidth: mode.pixelWidth,
                pixelsHeight: mode.pixelHeight,
                refreshRate: mode.refreshRate)
}

func currentMode(_ id: CGDirectDisplayID) -> ModeReading? {
    // 注意：虚拟屏成为硬件镜像组的 master 时 CGDisplayCopyDisplayMode 可能返回 NULL（hidpi-mirror 实测），
    // 这里按可空处理，不崩。
    guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
    return reading(mode)
}

func allModes(_ id: CGDirectDisplayID) -> [ModeReading] {
    // kCGDisplayShowDuplicateLowResolutionModes=true：把低分辨率重复档（含 HiDPI 档）一起列出来
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue as Any] as CFDictionary
    guard let array = CGDisplayCopyAllDisplayModes(id, opts) else { return [] }
    var out: [ModeReading] = []
    for index in 0..<CFArrayGetCount(array) {
        let raw = CFArrayGetValueAtIndex(array, index)
        guard let mode = unsafeBitCast(raw, to: CGDisplayMode?.self) else { continue }
        out.append(reading(mode))
    }
    return out
}

func waitForNewDisplay(baseline: [CGDirectDisplayID], expected: CGDirectDisplayID, timeout: Double) -> CGDirectDisplayID? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        let online = onlineDisplayIDs()
        if expected != 0, online.contains(expected) {
            return expected
        }
        if let fresh = online.first(where: { !baseline.contains($0) }) {
            return fresh
        }
        usleep(100_000)
    } while Date() < deadline
    return nil
}

// MARK: - doctor（环境自检，v0.3 增）

/// 只读外部命令的 stdout（失败/非零退出返回 nil）。doctor 只用它读 pmset / pgrep，不派任何写动作。
private func runReadonlyCommand(_ path: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
}

/// 从 `pmset -g` 输出解析 SleepDisabled（System-wide power settings 段）。
/// true=合盖不入睡 / false=会入睡 / nil=读不到（该项缺失，状态未知）。
private func sleepDisabled(from pmsetOutput: String) -> Bool? {
    for rawLine in pmsetOutput.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("SleepDisabled") else { continue }
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let value = tokens.last else { continue }
        if value == "1" { return true }
        if value == "0" { return false }
    }
    return nil
}

/// 除自己之外还在跑的 vd-engine 进程 pid（pgrep -x vd-engine，排除自身——doctor 本身就叫 vd-engine）。
private func otherVdEnginePids() -> [Int] {
    guard let output = runReadonlyCommand("/usr/bin/pgrep", ["-x", "vd-engine"]) else { return [] }
    let own = Int(getpid())
    return output.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        .filter { $0 != own }
}

private struct DoctorFinding {
    let key: String        // 机器可读检查名（stdout 的 check= 行）
    let result: String     // pass / warn / fail
    let detail: String     // 机器可读细节
    let advice: [String]   // 可执行建议（stderr，人读、agent 可照跑）
}

/// doctor 子命令主体。stdout 每行一项 `check=<key> result=<...> detail=<...>`（机器可读），
/// 诊断与建议走 stderr（既有约定）。返回退出码：有 fail → 1；warn 不置 1（注意但可继续）。
private func runDoctor() -> Int32 {
    var findings: [DoctorFinding] = []
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

    // 1. 私有类可用性 —— 整个工具的地基，缺了什么都没法做
    if NSClassFromString("CGVirtualDisplay") != nil {
        findings.append(DoctorFinding(key: "private_class", result: "pass",
                                      detail: "CGVirtualDisplay available", advice: []))
    } else {
        findings.append(DoctorFinding(key: "private_class", result: "fail",
                                      detail: "CGVirtualDisplay missing",
                                      advice: ["本机 macOS（\(osVersion)）没有 CGVirtualDisplay 私有类，ClamAwake 无法工作；无可执行的恢复动作。"]))
    }

    // 2. caffeinate —— 合盖配方的另一半
    if FileManager.default.fileExists(atPath: "/usr/bin/caffeinate") {
        findings.append(DoctorFinding(key: "caffeinate", result: "pass",
                                      detail: "/usr/bin/caffeinate present", advice: []))
    } else {
        findings.append(DoctorFinding(key: "caffeinate", result: "fail",
                                      detail: "/usr/bin/caffeinate missing",
                                      advice: ["系统自带的 /usr/bin/caffeinate 缺失（异常环境）；合盖配方里 caffeinate -d 一步无法执行。"]))
    }

    // 3. 显示器枚举 —— CG 公开 API 的运行时健全性
    let online = onlineDisplayIDs()
    if online.isEmpty {
        findings.append(DoctorFinding(key: "displays", result: "fail", detail: "0 display online",
                                      advice: ["CGGetOnlineDisplayList 返回 0 块在线显示器（异常环境）；连内屏都不可见，后续步骤无从谈起。"]))
    } else {
        let builtinCount = online.filter { CGDisplayIsBuiltin($0) != 0 }.count
        findings.append(DoctorFinding(key: "displays", result: "pass",
                                      detail: "\(online.count) display(s) online, \(builtinCount) builtin", advice: []))
    }

    // 4. 已有保活冲突：别的 vd-engine 进程 / KYA 标记的虚拟屏 / caffeinate 断言是否在跑
    //    caffeinate 断言属于配方的正常组成部分，只进 detail 不触发 warn。
    let pmsetOutput = runReadonlyCommand("/usr/bin/pmset", ["-g"]) ?? ""
    let enginePids = otherVdEnginePids()
    let kyaScreens = online.filter { CGDisplayVendorNumber($0) == kyaVendorID }
    let caffeinateActive = pmsetOutput.contains("caffeinate")
    var conflictParts: [String] = []
    if !enginePids.isEmpty { conflictParts.append("vd-engine pid " + enginePids.map(String.init).joined(separator: ",")) }
    if !kyaScreens.isEmpty { conflictParts.append("kya display id " + kyaScreens.map(String.init).joined(separator: ",")) }
    conflictParts.append(caffeinateActive ? "caffeinate assertion active" : "no caffeinate assertion")
    if enginePids.isEmpty && kyaScreens.isEmpty {
        // pass 行也自包含：三项状态都写进 detail，机器消费时不必对照 warn 行猜字段
        conflictParts.insert("no kya display", at: 0)
        conflictParts.insert("no vd-engine pid", at: 0)
        findings.append(DoctorFinding(key: "keepalive_running", result: "pass",
                                      detail: conflictParts.joined(separator: "; "), advice: []))
    } else {
        var advice: [String] = ["已有一套保活在跑（见上行 detail）。"]
        if let first = enginePids.first {
            advice.append("  · 若这是你有意保留的常驻引擎：直接复用它（vd-engine list 里 kya=yes 的屏），不要重复建屏。")
            advice.append("  · 若不是：先结束再继续—— kill -TERM \(first)（屏随进程消失）。")
        } else {
            advice.append("  · 有 kya 标记的屏但没有 vd-engine 进程：多半是别的虚拟屏工具（如 SimpleDisplay）建的；确认后退出那个工具，或直接用它的屏继续。")
        }
        findings.append(DoctorFinding(key: "keepalive_running", result: "warn",
                                      detail: conflictParts.joined(separator: "; "), advice: advice))
    }

    // 5. 合盖入睡（SleepDisabled）：1=合盖不入睡；0/读不到=合盖大概率入睡（除非外接真屏+电源的 clamshell 条件成立）。
    //    「外接真屏」排除 kya 标记的虚拟屏——虚拟屏是否满足 clamshell 条件未经实测，不作判据。
    let realExternal = online.filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayVendorNumber($0) != kyaVendorID }
    switch sleepDisabled(from: pmsetOutput) {
    case .some(true):
        findings.append(DoctorFinding(key: "lid_sleep", result: "pass",
                                      detail: "SleepDisabled=1 (lid-close sleep disabled)", advice: []))
    case .some(false):
        var advice = ["合盖后机器大概率入睡，保活配方会失效。解除办法（二选一）："]
        if !realExternal.isEmpty {
            advice.append("  · clamshell 模式：外接真屏（id \(realExternal.map(String.init).joined(separator: ","))）+ 接电源时合盖，机器不睡——你的用法若是这样，可不禁睡。")
        }
        advice.append("  · 系统级禁睡（需 sudo，工具不代设）：sudo pmset -a disablesleep 1")
        advice.append("    恢复默认：sudo pmset -a disablesleep 0；设完用 pmset -g 核对 SleepDisabled 是否变 1。")
        findings.append(DoctorFinding(key: "lid_sleep", result: "warn",
                                      detail: "SleepDisabled=0 (lid-close sleep possible)", advice: advice))
    case .none:
        findings.append(DoctorFinding(key: "lid_sleep", result: "warn",
                                      detail: "SleepDisabled unreadable",
                                      advice: ["从 pmset -g 读不到 SleepDisabled（合盖入睡状态未知）。人工核对：pmset -g | grep SleepDisabled；未禁睡则：sudo pmset -a disablesleep 1（需 sudo）。"]))
    }

    // 输出：stdout 一行一项（机器可读）；warn/fail 的建议走 stderr；末尾汇总走 stderr
    for finding in findings {
        print("check=\(finding.key) result=\(finding.result) detail=\(finding.detail)")
    }
    var passCount = 0, warnCount = 0, failCount = 0
    for finding in findings {
        switch finding.result {
        case "pass": passCount += 1
        case "warn": warnCount += 1
        case "fail": failCount += 1
        default: break
        }
        if !finding.advice.isEmpty {
            errln("注意（\(finding.key)）：")
            for line in finding.advice { errln(line) }
        }
    }
    let exitCode: Int32 = failCount > 0 ? 1 : 0
    errln("doctor 完成：\(findings.count) 项检查（pass \(passCount) / warn \(warnCount) / fail \(failCount)），退出码 \(exitCode)")
    return exitCode
}

// MARK: - 子命令

let args = CommandLine.arguments
guard args.count >= 2 else {
    errln(usage)
    exit(2)
}

switch args[1] {

case "create":
    var hidpi = false
    var hold = false
    var positional: [String] = []
    for arg in args.dropFirst(2) {
        switch arg {
        case "--hidpi": hidpi = true
        case "--hold": hold = true
        default: positional.append(arg)
        }
    }
    guard positional.count == 2,
          let logicalWidth = Int(positional[0]),
          let logicalHeight = Int(positional[1]),
          logicalWidth > 0, logicalHeight > 0 else {
        errln("参数错误：create 需要两个正整数 W H（逻辑分辨率）\n\(usage)")
        exit(2)
    }
    let pixelWidth = hidpi ? logicalWidth * 2 : logicalWidth
    let pixelHeight = hidpi ? logicalHeight * 2 : logicalHeight
    guard logicalWidth <= 8192, logicalHeight <= 8192, pixelWidth <= 16384, pixelHeight <= 16384 else {
        errln("参数错误：逻辑分辨率上限 8192，像素上限 16384（本次 \(logicalWidth)x\(logicalHeight) / 像素 \(pixelWidth)x\(pixelHeight)）")
        exit(2)
    }

    let baseline = onlineDisplayIDs()
    let handle: VirtualDisplayHandle
    do {
        handle = try createVirtualDisplay(logicalWidth: logicalWidth, logicalHeight: logicalHeight, hidpi: hidpi)
    } catch {
        errln("建屏失败：\(error)")
        exit(1)
    }

    // 等 WindowServer 把屏挂进在线列表（mirrorscreen 给 1.5s；这里最多 3s，命中即返回）
    guard let displayID = waitForNewDisplay(baseline: baseline, expected: handle.displayID, timeout: 3.0) else {
        errln("建屏失败：applySettings 成功但 3s 内没在 CGGetOnlineDisplayList 里看到新屏（对象 displayID=\(handle.displayID)）")
        exit(1)
    }

    // stdout 只放机器可读的 id（脚本直接消费）；诊断信息走 stderr。
    // fflush 不能省：--hold 时进程不退出，stdout 重定向到文件/管道时是块缓冲，
    // 不主动刷的话 id 一直不出缓冲（实测 2026-11-07），脚本侧「读 stdout 拿 id」会拿到空。
    print(displayID)
    fflush(stdout)
    errln("已建虚拟屏 id=\(displayID) 逻辑=\(logicalWidth)x\(logicalHeight) 像素=\(pixelWidth)x\(pixelHeight) hidpi=\(hidpi ? "yes" : "no")")

    // 屏活在本进程生命周期内：进程一退出，WindowServer 就收屏（没有跨进程销毁 API，见 remove）。
    withExtendedLifetime(handle) {
        if hold {
            errln("常驻持有中（Ctrl-C / SIGTERM 结束，屏随之销毁）")
            signal(SIGINT) { _ in exit(0) }
            signal(SIGTERM) { _ in exit(0) }
            while true { pause() }
        }
    }
    if !hold {
        errln("注意：create 退出即销毁虚拟屏。要让屏持续存在需 --hold（或由常驻进程持有实例）。")
    }
    exit(0)

case "remove":
    guard args.count == 3, let target = CGDirectDisplayID(args[2]), target != 0 else {
        errln("参数错误：remove 需要一个非零数字 id\n\(usage)")
        exit(2)
    }
    let online = onlineDisplayIDs()
    guard online.contains(target) else {
        errln("显示器 \(target) 不在线（在线列表：\(online.map(String.init).joined(separator: ", "))）")
        exit(1)
    }
    // 跨进程销毁的结论（2026-11-07，参考源码 + 运行时内省 + 实验验证三方吻合）：
    //   · CGVirtualDisplay 的生命周期绑在创建它的进程上——实例释放（ARC 归零）或进程退出，WindowServer 即收屏；
    //     hidpi-mirror 靠 exit() 销毁屏、mirrorscreen 靠 virtualDisplay = nil 销毁屏，两者都没有 destroy 调用。
    //   · CGVirtualDisplay 类的方法表里没有任何 destroy/remove/terminate 方法（class_copyMethodList 内省确认）。
    //   · 公开 API 侧也没有「删除显示器的函数」：CGDisplayConfiguration.h 只有
    //     Origin / WithDisplayMode / StereoOperation / MirrorOfDisplay / Mode，没有 Disabled/Remove。
    //   · 实验验证同向：SIGKILL 建屏进程后，在线列表里的 id 单调升（9→10→11）且
    //     分辨率跳回 1920x1080 默认档——旧屏随进程死、看到的是重启后新建的屏，不是同一块屏活下来。
    // 所以 remove 只能在「同一进程持有实例」时成立，而 vd-engine 是单次调用的 CLI——它建的屏在 create 退出时
    // 就已经消失，remove 面对的必然是别的进程持有的屏。这里不静默失败：讲清楚怎么才能真正销毁它。
    if CGDisplayMirrorsDisplay(target) != kCGNullDirectDisplay {
        errln("提示：显示器 \(target) 正作为镜像成员（CGDisplayMirrorsDisplay=\(CGDisplayMirrorsDisplay(target))），它的持有进程销毁屏前应先解除镜像。")
    }
    errln("""
    无法销毁显示器 \(target)：它由另一个进程创建的 CGVirtualDisplay 实例持有，跨进程没有销毁 API。
    真正销毁它的办法只有一个：让持有该实例的进程释放实例或退出——
      · 若是 `vd-engine create ... --hold` 开的：给它发 SIGTERM（或 Ctrl-C），进程退出即收屏；
      · 若是别的应用开的（如 SimpleDisplay）：退出那个应用。
        （注意它若被 launchd/登录项自动拉起，会另建一块默认屏——那不是旧屏没死，是新屏换了 id。）
    """)
    exit(1)

case "list":
    let online = onlineDisplayIDs()
    guard !online.isEmpty else {
        errln("在线显示器列表为空（CGGetOnlineDisplayList 返回 0 个）")
        exit(1)
    }
    let mainID = CGMainDisplayID()
    print("# 在线显示器 \(online.count) 个（main=系统主屏）")
    for id in online {
        let mode = currentMode(id)
        let points = mode.map { "\($0.pointsWidth)x\($0.pointsHeight)" } ?? "?"
        let pixels = mode.map { "\($0.pixelsWidth)x\($0.pixelsHeight)" } ?? "?"
        let hidpi = mode.map { $0.isHiDPI ? "yes" : "no" } ?? "?"
        let vendor = CGDisplayVendorNumber(id)
        let kya = (vendor == kyaVendorID) ? "yes" : "no"
        let mirrored = CGDisplayMirrorsDisplay(id)
        print("id=\(id)"
            + " main=\(id == mainID ? "yes" : "no")"
            + " builtin=\(CGDisplayIsBuiltin(id) != 0 ? "yes" : "no")"
            + " active=\(CGDisplayIsActive(id) != 0 ? "yes" : "no")"
            + " asleep=\(CGDisplayIsAsleep(id) != 0 ? "yes" : "no")"
            + " mirror_of=\(mirrored == kCGNullDirectDisplay ? "none" : String(mirrored))"
            + " points=\(points) pixels=\(pixels) hidpi=\(hidpi)"
            + " vendor=\(vendor) product=\(CGDisplayModelNumber(id)) serial=\(CGDisplaySerialNumber(id))"
            + " kya=\(kya)")
    }
    // 虚拟屏没有公开标记：CGVirtualDisplay 建的屏在公开 API 里和真屏长一样（CGDisplayIsVirtualDevice 是私有函数）。
    // 可用的弱信号只有「非内建 + 当前模式是 HiDPI 或尺寸异常」+ 本引擎自定义的 vendor 标记（kya 列）。
    exit(0)

case "hi":
    guard args.count == 3, let target = CGDirectDisplayID(args[2]), target != 0 else {
        errln("参数错误：hi 需要一个非零数字 id\n\(usage)")
        exit(2)
    }
    guard onlineDisplayIDs().contains(target) else {
        errln("显示器 \(target) 不在线（只读查询需要一个在线 id）")
        exit(1)
    }
    let modes = allModes(target)
    let current = currentMode(target)
    print("display=\(target)")
    if let current = current {
        print("current_points=\(current.pointsWidth)x\(current.pointsHeight)")
        print("current_pixels=\(current.pixelsWidth)x\(current.pixelsHeight)")
        print("current_refresh=\(String(format: "%.2f", current.refreshRate))")
        print("hidpi=\(current.isHiDPI ? "yes" : "no")")
        let scale = current.pointsWidth > 0 ? Double(current.pixelsWidth) / Double(current.pointsWidth) : 0
        print("backing_scale=\(String(format: "%.2f", scale))")
    } else {
        print("current=none")   // 镜像组 master 场景下 CGDisplayCopyDisplayMode 可能为空
        print("hidpi=unknown")
    }
    let hidpiModes = modes.filter { $0.isHiDPI }
    print("mode_count=\(modes.count)")
    print("hidpi_mode_count=\(hidpiModes.count)")
    // 真屏会列出几十上百个模式（内屏实测 72 个 HiDPI 档），全打出来读不动，截到 40 条并报总数
    let listLimit = 40
    for mode in hidpiModes.prefix(listLimit) {
        print("hidpi_mode points=\(mode.pointsWidth)x\(mode.pointsHeight)"
            + " pixels=\(mode.pixelsWidth)x\(mode.pixelsHeight)"
            + " refresh=\(String(format: "%.2f", mode.refreshRate))")
    }
    if hidpiModes.count > listLimit {
        print("hidpi_mode_omitted=\(hidpiModes.count - listLimit)")
    }
    exit(0)

case "doctor":
    guard args.count == 2 else {
        errln("参数错误：doctor 不接受参数\n\(usage)")
        exit(2)
    }
    exit(runDoctor())

default:
    errln("未知子命令：\(args[1])\n\(usage)")
    exit(2)
}
