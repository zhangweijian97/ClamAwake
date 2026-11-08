// vd-engine — 虚拟屏引擎（ClamAwake v0.4，--hold 常驻含护档+护镜像；v0.3 新增 doctor 环境自检子命令）
//
// 2026-11-08 回炉 r2（goal-9dcbec：护档重配监听生产实锤未生效，部署两小时零回调）：
//   · 进程形状修复（实证根因，对照实验双确认）：CGS 重配通知只投递给 app 形状进程——
//     纯 CLI（pause/dispatchMain/RunLoop 任一泵）注册成功却零事件，NSApplication 形状即时收到。
//     hold 常驻改为 NSApplication(.accessory) + app.run()（原 `while true { pause() }`）；
//   · App Nap 豁免：beginActivity(.userInitiated)，activity 对象进程常驻期全程持有；
//   · 校验双查扩镜像：镜像基线（部署序列 mirror-probe 建立的「虚拟屏镜像主屏」）确立后，
//     检测到 mirror_of ≠ 主屏自动重挂（护镜像并入，goal-9dcbec 遗留①）。
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
//         （2026-11-08 实测修正适用边界：「不认程序化切换」指拓扑重排时 WindowServer 按自己的
//           默认逻辑选档、无视列表首位；而 CGDisplaySetDisplayMode 在**创建者进程内**对本引擎
//           建的屏有效（护档实测：偏档重设读回通过）。外部进程对本屏 set 无效——虚拟屏的模式
//           配置权属创建者进程（CGError 1001 / displayplacer 静默无效），护档恰住在创建者进程里。）
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

import AppKit
import CoreGraphics
import Foundation
import Darwin

/// 引擎版本：与 ClamAwake 应用版本对齐（build-app.sh 的 APP_VERSION）。
/// DSH 插件装载时读 `vd-engine version` 与包内声明比对，用于发现「应用与插件的引擎不同步」。
let engineVersion = "0.3.0"

// MARK: - 用法与退出码

let usage = """
用法:
  vd-engine create <W> <H> [--hidpi] [--hold] [--mirror-main]
                                                 建虚拟屏（逻辑分辨率 WxH），成功后 stdout 打印屏 id
  vd-engine remove <id>                          销毁指定虚拟屏
  vd-engine list                                 列出全部在线显示器（只读）
  vd-engine hi <id>                              打印指定屏的 HiDPI 情况（只读）
  vd-engine doctor                               环境自检+可执行建议（只读；有阻塞问题时退出码 1）
  vd-engine version                              打印引擎版本与架构（只读，一行机器可读：version=<x.y.z>）

选项:
  --hidpi  逻辑 WxH、像素 2Wx2H（例: 1800 1169 --hidpi → 像素 3600x2338，HiDPI 档进模式列表）
  --hold   建完不退出，前台常驻持有该屏（Ctrl-C / SIGTERM 结束，屏随之销毁）；
           常驻期间开启护档：显示拓扑重排（合盖/开盖/接拔屏）后自动校验本屏模式，
           偏离目标档则重设（goal-9dcbec：合盖触发 WindowServer 默认配置导致塌档）；
           镜像基线（部署序列 mirror-probe 建立的「虚拟屏镜像主屏」）确立后，
           检测到镜像解除自动重挂（2026-11-08 回炉扩查，遗留①护镜像并入）
  --mirror-main  仅 --hold 有意义：建屏后启动即自动挂主屏镜像并确立护档镜像基线
                 （launchd/登录自启形态用——launchd 拉起的新进程=新建屏，镜像基线
                 不会自动回来，须启动即自挂）；失败只记日志不退出（建屏保活主语义
                 不变），需人工 mirror-probe 建基线（f8e4a9，2026-11-08）

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

// MARK: - 护档（--hold 模式的分辨率守卫，goal-9dcbec）

// 背景（2026-11-08 凌晨实测，WindowServer 日志实锤）：
//   合盖瞬间内屏被移除、镜像克隆被系统解除（set_clone_master / remove clone），拓扑重排时
//   WindowServer 对本引擎建的虚拟屏走「持久化偏好校验失败 → Applying default configuration」，
//   模式被改写（日志 setting mode 40 -> 12）——塌档发生在合盖时刻而非开盖，开盖后停塌不自愈。
//   引擎侧唯一的确定性防线：监听显示重配，校验本屏模式，偏离目标档则重设。
//
// 机制要点：
//   · 重配事件的主体常常不是虚拟屏（合盖时事件主体是内屏 removed），所以任何重配事件都触发校验；
//   · 校验动作幂等（模式匹配即不动），连环重排（合盖+开盖）靠 300ms 去抖合并为一次校验；
//   · CGDisplayCopyDisplayMode 返回 NULL ≠ 塌档（镜像组 master 场景会返回 NULL，见 currentMode 注释），
//     NULL 只记日志不重设，避免在镜像场景误动作；
//   · 镜像防护（2026-11-08 回炉，遗留①）：镜像基线确立（任一次校验读到 mirror_of==主屏）后，
//     检测到 mirror_of ≠ 主屏 → 重挂主屏（API 用法照抄 mirror-probe mirror）。
//     基线未确立（fresh start，部署序列稍后由 mirror-probe 建基线）只记日志不动作——
//     避免把「启动时还没有镜像」误判成「镜像被解除」，也避免与部署序列抢拍；
//   · 通知投递（2026-11-08 回炉二修）：重配通知只投递给 app 形状进程（对照实验实证，
//     见文件头与 hold 分支注释）——hold 常驻改 NSApplication(.accessory)+app.run()；
//     另以 beginActivity(.userInitiated) 豁免 App Nap（nohup 后台长跑的交付抑制面）。

/// 护档上下文：C 回调不能捕获 Swift 上下文，经 userInfo 指针传递（Unmanaged 来回）。
final class ModeGuardContext {
    let displayID: CGDirectDisplayID
    let targetPointsW: Int
    let targetPointsH: Int
    let targetPixelsW: Int
    let targetPixelsH: Int
    // 串行队列承载去抖与校验动作；重配回调来自 WindowServer 任意线程，不能在回调里直接干活
    let queue = DispatchQueue(label: "vd-engine.mode-guard")
    var pending: DispatchWorkItem?
    // 镜像基线是否已确立（2026-11-08 回炉）：任一次校验读到 mirror_of==主屏 即置位，
    // 进程常驻期不复位——确立后「mirror_of ≠ 主屏」才判为镜像解除并自动重挂。
    var mirrorBaselineEstablished = false
    // 内屏档位守护（2026-11-08 合盖塌档修复 v2）：合盖→开盖时 WindowServer 重建整套显示配置，
    // 会把内屏重置成默认档（实测 1800x1169 → 1512x982）。恢复目标=内屏离线前最后一轮在线时
    // 读到的档位（用户合盖前手动改的分辨率也保留），只在重新上线后的 5s 窗口内恢复；
    // 窗口外正常在线时只持续记录档位、不干预——用户在线改分辨率不会被锁死。
    var innerDisplayID: CGDirectDisplayID?
    var innerLastSeenMode: ModeReading?
    var innerWasOnline = true
    var innerRestoreDeadline: Date?

    init(displayID: CGDirectDisplayID, pointsW: Int, pointsH: Int, pixelsW: Int, pixelsH: Int) {
        self.displayID = displayID
        self.targetPointsW = pointsW
        self.targetPointsH = pointsH
        self.targetPixelsW = pixelsW
        self.targetPixelsH = pixelsH
    }

    func guardLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        errln("[mode-guard \(formatter.string(from: Date()))] \(message)")
    }
}

private func modeMatchesTarget(_ mode: ModeReading?, ctx: ModeGuardContext) -> Bool {
    guard let mode = mode else { return false }
    return mode.pointsWidth == ctx.targetPointsW
        && mode.pointsHeight == ctx.targetPointsH
        && mode.pixelsWidth == ctx.targetPixelsW
        && mode.pixelsHeight == ctx.targetPixelsH
}

/// 在指定屏的档位列表里找 points/pixels 双匹配的 CGDisplayMode（CGDisplaySetDisplayMode 需要档位对象）。
private func findMode(on displayID: CGDirectDisplayID, pointsW: Int, pointsH: Int, pixelsW: Int, pixelsH: Int) -> CGDisplayMode? {
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue as Any] as CFDictionary
    guard let array = CGDisplayCopyAllDisplayModes(displayID, opts) else { return nil }
    for index in 0..<CFArrayGetCount(array) {
        let raw = CFArrayGetValueAtIndex(array, index)
        guard let mode = unsafeBitCast(raw, to: CGDisplayMode?.self) else { continue }
        if mode.width == pointsW && mode.height == pointsH
            && mode.pixelWidth == pixelsW && mode.pixelHeight == pixelsH {
            return mode
        }
    }
    return nil
}

/// 本引擎虚拟屏的目标档查询（findMode 的既有调用形态）。
private func findTargetMode(ctx: ModeGuardContext) -> CGDisplayMode? {
    findMode(on: ctx.displayID,
             pointsW: ctx.targetPointsW, pointsH: ctx.targetPointsH,
             pixelsW: ctx.targetPixelsW, pixelsH: ctx.targetPixelsH)
}

/// 把本屏重挂回主屏镜像（镜像基线防护动作，2026-11-08 回炉）。
/// API 用法照抄 mirror-probe mirror：CGBegin → CGConfigureDisplayMirrorOfDisplay(slave, master)
/// → CGComplete(.forSession)，方向 slave=本引擎虚拟屏、master=主屏（内屏）。
/// 返回重挂是否读回验证通过（最多 1s，与 mirror-probe 读回同法）。
private func remirrorToMain(ctx: ModeGuardContext, mainID: CGDirectDisplayID) -> Bool {
    var config: CGDisplayConfigRef?
    var result = CGBeginDisplayConfiguration(&config)
    guard result == .success, let config = config else {
        ctx.guardLog("镜像重挂：CGBeginDisplayConfiguration 失败: CGError=\(result.rawValue)")
        return false
    }
    result = CGConfigureDisplayMirrorOfDisplay(config, ctx.displayID, mainID)
    guard result == .success else {
        CGCancelDisplayConfiguration(config)
        ctx.guardLog("镜像重挂：CGConfigureDisplayMirrorOfDisplay(slave=\(ctx.displayID), master=\(mainID)) 失败: CGError=\(result.rawValue)")
        return false
    }
    result = CGCompleteDisplayConfiguration(config, .forSession)
    guard result == .success else {
        ctx.guardLog("镜像重挂：CGCompleteDisplayConfiguration(.forSession) 失败: CGError=\(result.rawValue)")
        return false
    }
    for _ in 0..<5 {
        if CGDisplayMirrorsDisplay(ctx.displayID) == mainID { return true }
        usleep(200_000)
    }
    return false
}

/// 内屏档位守护（2026-11-08 合盖塌档修复 v2）：
/// 合盖→开盖时 WindowServer 重建整套显示配置，会把内屏重置成默认档（实测 1800x1169 → 1512x982）。
/// 恢复目标=内屏离线前最后一轮在线读到的档位；只在重新上线后的 5s 窗口内恢复；窗口外只记录不干预。
private func restoreInnerIfJustReturned(ctx: ModeGuardContext) {
    guard let innerID = ctx.innerDisplayID else { return }
    let online = onlineDisplayIDs().contains(innerID)
    if online && !ctx.innerWasOnline {
        ctx.innerRestoreDeadline = Date().addingTimeInterval(5)
        let target = ctx.innerLastSeenMode.map {
            "\($0.pointsWidth)x\($0.pointsHeight) 像素\($0.pixelsWidth)x\($0.pixelsHeight)"
        } ?? "未记录"
        ctx.guardLog("内屏重新上线（id=\(innerID)），进入 5s 档位恢复窗口（恢复目标=离线前 \(target)）")
    }
    ctx.innerWasOnline = online
    guard online else { return }
    let inWindow = ctx.innerRestoreDeadline.map { Date() <= $0 } ?? false
    if !inWindow {
        ctx.innerLastSeenMode = currentMode(innerID)
        return
    }
    guard let target = ctx.innerLastSeenMode, let reading = currentMode(innerID) else {
        ctx.guardLog("内屏档位恢复窗口内读数缺失（目标或当前模式读不到），本轮跳过")
        return
    }
    if reading.pointsWidth == target.pointsWidth && reading.pointsHeight == target.pointsHeight
        && reading.pixelsWidth == target.pixelsWidth && reading.pixelsHeight == target.pixelsHeight {
        return
    }
    let observed = "\(reading.pointsWidth)x\(reading.pointsHeight) 像素\(reading.pixelsWidth)x\(reading.pixelsHeight)"
    let base = "\(target.pointsWidth)x\(target.pointsHeight) 像素\(target.pixelsWidth)x\(target.pixelsHeight)"
    guard let mode = findMode(on: innerID,
                              pointsW: target.pointsWidth, pointsH: target.pointsHeight,
                              pixelsW: target.pixelsWidth, pixelsH: target.pixelsHeight) else {
        ctx.guardLog("内屏合盖塌档（当前 \(observed)，目标 \(base)），档位列表里找不到目标档，放弃恢复")
        return
    }
    let setError = CGDisplaySetDisplayMode(innerID, mode, nil)
    guard setError == .success else {
        ctx.guardLog("内屏合盖塌档（当前 \(observed)），CGDisplaySetDisplayMode 失败: CGError=\(setError.rawValue)")
        return
    }
    var verified = false
    for _ in 0..<5 {
        if let now = currentMode(innerID),
           now.pointsWidth == target.pointsWidth && now.pointsHeight == target.pointsHeight,
           now.pixelsWidth == target.pixelsWidth && now.pixelsHeight == target.pixelsHeight {
            verified = true
            break
        }
        usleep(200_000)
    }
    if verified {
        ctx.guardLog("内屏合盖塌档（当前 \(observed)），已恢复离线前档位 \(base)，读回验证通过")
    } else {
        ctx.guardLog("内屏合盖塌档（当前 \(observed)），已发恢复但读回未达目标档，需人工核查")
    }
}

/// 校验本屏镜像与模式并按需恢复（在护档串行队列上执行）。成功/失败都打 stderr 日志（重定向到 vd-prod.err 可查）。
///
/// 双查（2026-11-08 回炉，护镜像并入；查序=镜像先于档位）：
///   1. 镜像查：基线确立后 mirror_of ≠ 主屏 → 重挂主屏+读回验证；重挂成功即返回
///      （重挂后档位随主屏=目标档，本轮档位查无需再做）；镜像正常也即返回
///      （镜像态档位随主屏，档位查无意义且有伪判，见分支内注释）；基线未确立只记日志
///      （fresh start 的独立态不是「镜像解除」，部署序列随后建基线）。
///   2. 档位查：四元比对，偏档重设（原逻辑不变；仅独立态到达）。
private func verifyAndRestore(ctx: ModeGuardContext) {
    guard onlineDisplayIDs().contains(ctx.displayID) else {
        ctx.guardLog("目标屏 \(ctx.displayID) 不在线，跳过校验")
        return
    }

    // —— 显示配置是一份（2026-11-08 归并定性）——
    // 合盖/开盖会让 WindowServer 重排整套显示配置：拓扑（哪块屏在线）、镜像关系、各屏档位。
    // 这三类字段此前按入口依次暴露、各自修过一次（虚拟屏档位 → 镜像关系 → 内屏档位）。
    // 这里不再按入口打补丁，而按「期望配置」逐字段核对，每字段独立恢复、幂等：
    //   1. 内屏档位：合盖→开盖塌档，恢复离线前档位（restoreInnerIfJustReturned）
    //   2. 镜像关系：虚拟屏必须镜像内屏，解除则重挂（remirrorToMain）
    //   3. 虚拟屏档位：本引擎屏偏离目标档则重设（findTargetMode + CGDisplaySetDisplayMode）
    // 再接新的显示对象（外接屏、缩放等）时在此追加同一形态的核对，不再另起恢复器。
    restoreInnerIfJustReturned(ctx: ctx)

    // —— 镜像查 ——
    let mainID = CGMainDisplayID()
    if mainID == ctx.displayID {
        // 本屏即主屏（合盖内屏被移除的独立态）：无内屏可镜像；档位查继续（独立态保档）
        ctx.guardLog("本屏即主屏（无内屏可镜像），跳过镜像校验")
    } else {
        let mirrorOf = CGDisplayMirrorsDisplay(ctx.displayID)
        let observed = mirrorOf == kCGNullDirectDisplay ? "none" : String(mirrorOf)
        if mirrorOf == mainID {
            if !ctx.mirrorBaselineEstablished {
                ctx.mirrorBaselineEstablished = true
                ctx.guardLog("镜像基线确立（mirror_of=\(mainID)）：此后检测到镜像解除将自动重挂")
            } else {
                ctx.guardLog("镜像正常（mirror_of=\(mainID)），不动作")
            }
            // 镜像态档位随主屏（读数=主屏档位或 NULL），档位查无意义且有伪判：
            // 实测（2026-11-08 测试屏）镜像建立/重挂后 slave 档位读数=主屏档位，
            // 目标档≠主屏档位时会被误判成偏档并发重设（本屏渲染本就跟随主屏，重设只改偏好+日志噪声）。
            // 跳过本轮档位查；独立态（镜像未确立/本屏即主屏/重挂失败）的档位查不受影响。
            return
        } else if ctx.mirrorBaselineEstablished {
            if remirrorToMain(ctx: ctx, mainID: mainID) {
                ctx.guardLog("检测到镜像解除（mirror_of=\(observed)），已重挂到主屏 \(mainID)，读回验证通过")
                ctx.mirrorBaselineEstablished = true
                return
            }
            // 重挂未生效：不 return，继续档位校验（此时屏处于独立态，保档仍有意义）
            ctx.guardLog("检测到镜像解除（mirror_of=\(observed)），已发重挂但读回仍是 mirror_of=\(CGDisplayMirrorsDisplay(ctx.displayID) == kCGNullDirectDisplay ? "none" : String(CGDisplayMirrorsDisplay(ctx.displayID)))——重挂未生效，需人工核查")
        } else {
            ctx.guardLog("镜像未确立（mirror_of=\(observed)，主屏=\(mainID)）——等待部署序列建立镜像基线，不动作")
        }
    }

    // —— 档位查（原有逻辑） ——
    let current = currentMode(ctx.displayID)
    if current == nil {
        // NULL ≠ 塌档：镜像组 master 场景 CGDisplayCopyDisplayMode 返回 NULL（见 currentMode 注释），不动作
        ctx.guardLog("当前模式读数 NULL（可能处于镜像组），不动作")
        return
    }
    if modeMatchesTarget(current, ctx: ctx) {
        ctx.guardLog("模式正常 \(ctx.targetPointsW)x\(ctx.targetPointsH) HiDPI，不动作")
        return
    }
    let observed = current.map { "\($0.pointsWidth)x\($0.pointsHeight) 像素\($0.pixelsWidth)x\($0.pixelsHeight)" } ?? "?"
    guard let target = findTargetMode(ctx: ctx) else {
        ctx.guardLog("检测到偏档（当前 \(observed)），但档位列表里找不到目标档 \(ctx.targetPointsW)x\(ctx.targetPointsH)/\(ctx.targetPixelsW)x\(ctx.targetPixelsH)，无法重设")
        return
    }
    let setError = CGDisplaySetDisplayMode(ctx.displayID, target, nil)
    guard setError == .success else {
        ctx.guardLog("检测到偏档（当前 \(observed)），CGDisplaySetDisplayMode 失败: CGError=\(setError.rawValue)")
        return
    }
    // 写后读回：给 WindowServer 落盘时间，最多 1s（与 mirror-probe 读回同法）
    var verified = false
    for _ in 0..<5 {
        if modeMatchesTarget(currentMode(ctx.displayID), ctx: ctx) {
            verified = true
            break
        }
        usleep(200_000)
    }
    if verified {
        ctx.guardLog("检测到偏档（当前 \(observed)），已重设回 \(ctx.targetPointsW)x\(ctx.targetPointsH) HiDPI，读回验证通过")
    } else {
        let after = currentMode(ctx.displayID).map { "\($0.pointsWidth)x\($0.pointsHeight)" } ?? "?"
        ctx.guardLog("检测到偏档（当前 \(observed)），已发重设但读回仍是 \(after)——重设未生效，需人工核查")
    }
}

/// 重配回调（C 函数指针，上下文经 userInfo 传递）。只排去抖任务，不在回调线程干活。
private func modeGuardReconfigurationCallback(_ display: CGDirectDisplayID,
                                              _ flags: CGDisplayChangeSummaryFlags,
                                              _ userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo = userInfo else { return }
    let ctx = Unmanaged<ModeGuardContext>.fromOpaque(userInfo).takeUnretainedValue()
    ctx.pending?.cancel()
    let work = DispatchWorkItem {
        verifyAndRestore(ctx: ctx)
        ctx.pending = nil
    }
    ctx.pending = work
    ctx.queue.asyncAfter(deadline: .now() + 0.3, execute: work)
}

/// 注册护档：进入 --hold 前调用。进程常驻期间一直生效（退出随进程清理，无需显式注销）。
/// mirrorMain=true（启动参数 --mirror-main，f8e4a9）：注册成功后启动即自动挂主屏镜像并确立基线——
/// launchd/登录自启拉起的新进程=新建屏，镜像基线不会自动回来，必须启动即自挂。
func startModeGuard(handle: VirtualDisplayHandle, logicalWidth: Int, logicalHeight: Int, hidpi: Bool, mirrorMain: Bool = false) {
    let ctx = ModeGuardContext(
        displayID: handle.displayID,
        pointsW: logicalWidth,
        pointsH: logicalHeight,
        pixelsW: hidpi ? logicalWidth * 2 : logicalWidth,
        pixelsH: hidpi ? logicalHeight * 2 : logicalHeight
    )
    // ctx 需存活整个常驻期：retain 交给回调侧（passRetained），由注册的回调长期持有——
    // 这里用全局集合持有引用更直白：护档上下文与进程同生命周期，无需配对释放。
    modeGuardContexts.append(ctx)
    // 记录内屏（建屏时的主屏）与当前档位：合盖塌档恢复的起点（2026-11-08）。
    let mainAtStart = CGMainDisplayID()
    if mainAtStart != handle.displayID, let mainMode = currentMode(mainAtStart) {
        ctx.innerDisplayID = mainAtStart
        ctx.innerLastSeenMode = mainMode
        errln("内屏档位记录：id=\(mainAtStart) "
            + "\(mainMode.pointsWidth)x\(mainMode.pointsHeight) 像素\(mainMode.pixelsWidth)x\(mainMode.pixelsHeight)")
    }
    let unmanaged = Unmanaged.passRetained(ctx)
    let err = CGDisplayRegisterReconfigurationCallback(modeGuardReconfigurationCallback, unmanaged.toOpaque())
    if err == .success {
        errln("护档已启动：目标档 \(logicalWidth)x\(logicalHeight)\(hidpi ? " HiDPI(像素 \(logicalWidth * 2)x\(logicalHeight * 2))" : "")，拓扑重排后自动校验")
        // 初始校验：注册发生在建屏之后，「屏幕加入」的重配事件已经错过——
        // 新 product 首次上线时 WindowServer 默认配置可能就没落在目标档（2026-11-08 测试屏实测），
        // 启动后延时 1s（等建屏配置落定）先校验一轮，不依赖后续事件。
        let initial = DispatchWorkItem { verifyAndRestore(ctx: ctx) }
        ctx.pending = initial
        ctx.queue.asyncAfter(deadline: .now() + 1.0, execute: initial)
        // --mirror-main（f8e4a9，2026-11-08）：启动即自挂主屏镜像，成功置基线（此后护档才认
        // 「镜像解除」并自动重挂）。失败不退出——建屏保活是主语义，基线缺席时护档不重挂，
        // 日志写明需人工 mirror-probe 建基线（重试入口=下次重配事件前的部署序列）。
        if mirrorMain {
            let mainID = CGMainDisplayID()
            if mainID == ctx.displayID {
                ctx.guardLog("--mirror-main：本屏即主屏（无内屏可镜像），忽略")
            } else if remirrorToMain(ctx: ctx, mainID: mainID) {
                ctx.mirrorBaselineEstablished = true
                ctx.guardLog("镜像基线已建立（启动参数 --mirror-main），mirror_of=\(mainID)")
            } else {
                ctx.guardLog("--mirror-main：镜像基线建立失败（读回 mirror_of 非主屏）——需人工 mirror-probe 建基线，基线确立前护档不会自动重挂")
            }
        }
    } else {
        // passRetained 的引用没有消费方了，手动平衡避免泄漏
        unmanaged.release()
        errln("护档注册失败: CGError=\(err.rawValue)（--hold 退化为纯持有，无护档）")
    }
}

// 护档上下文的全局存活集合（进程常驻期 = 护档期，无需配对释放；见 startModeGuard 注释）
private var modeGuardContexts: [ModeGuardContext] = []

// App Nap 豁免句柄（2026-11-08 回炉，9dcbec 嫌疑②）：进程常驻期全程持有，释放即豁免结束；
// nil = 未启用（list/doctor/remove 等短命调用不断言）。豁免在 --hold 分支进入时启用。
private var napActivity: NSObjectProtocol?

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
    var mirrorMain = false
    var positional: [String] = []
    for arg in args.dropFirst(2) {
        switch arg {
        case "--hidpi": hidpi = true
        case "--hold": hold = true
        case "--mirror-main": mirrorMain = true
        default: positional.append(arg)
        }
    }
    if mirrorMain && !hold {
        errln("注意：--mirror-main 仅在 --hold 常驻模式下有意义，本次忽略")
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
            // App Nap 豁免（2026-11-08 回炉，9dcbec 嫌疑②）：nohup 后台常驻进程默认可被 nap，
            // CGS 通知/timer 交付被抑制（生产「短时自测过、长时生产死」的吻合形态之一）。
            // 只断言 userInitiated，不加 .idleSystemSleepDisabled——合盖入睡边界归 ClamAwake
            // 配方（caffeinate）管理，引擎越权禁睡会改变系统行为。
            napActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "vd-engine mode guard")
            errln("App Nap 豁免已启用（userInitiated，进程常驻期全程持有）")
            // 进程形状修复（2026-11-08 回炉二修，实证根因）：CGS 重配通知只投递给 app 形状进程。
            // 对照实验（2026-11-08 11:3x，macOS 27.0）：同一事件流（displayplacer 偏档 + 镜像建立/解除）
            // 下，纯 CLI 进程注册成功（CGError=0）却零事件——pause()/RunLoop.main.run() 任一泵都收不到；
            // NSApplication 形状进程即时收到（flags=begin/SetMode/Moved/DesktopShapeChanged）。
            // 原首修（RunLoop 泵）与实施单嫌疑①（pause() 睡死无泵）据此被实验否定——泵不是缺口，
            // 进程形状才是。accessory 形状 = 无 Dock 图标无菜单栏的后台应用，重配通知通道随之激活。
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            // 护档注册（goal-9dcbec）：合盖/开盖的拓扑重排会把本屏模式改写，
            // 常驻期间监听重配并校验/重设，见「护档」节。须在 NSApplication 初始化之后注册
            // （通知投递依赖 app 形状的 CGS 连接）。
            startModeGuard(handle: handle, logicalWidth: logicalWidth, logicalHeight: logicalHeight, hidpi: hidpi, mirrorMain: mirrorMain)
            errln("常驻持有中（Ctrl-C / SIGTERM 结束，屏随之销毁）")
            signal(SIGINT) { _ in exit(0) }
            signal(SIGTERM) { _ in exit(0) }
            // NSApplication 主循环：app 形状的常驻泵（泵主 run loop + main queue + app 事件源），
            // 永不返回，handle 由外层闭包持有；退出走上方 signal→exit(0)，语义与 pause() 版一致。
            app.run()
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

case "version":
    guard args.count == 2 else {
        errln("参数错误：version 不接受参数\n\(usage)")
        exit(2)
    }
    #if arch(arm64)
    let arch = "arm64"
    #elseif arch(x86_64)
    let arch = "x86_64"
    #else
    let arch = "unknown"
    #endif
    print("version=\(engineVersion)")
    print("arch=\(arch)")
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
