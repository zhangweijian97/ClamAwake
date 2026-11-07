// mirror-probe — 显示器镜像探针（ClamAwake v0.1.2）
// 编译: swiftc -O src/mirror-probe.swift -o mirror-probe
//
// 用法:
//   mirror-probe mirror   <internalID> <virtualID>   虚拟屏(virtualID/slave)镜像内屏(internalID/master)
//   mirror-probe unmirror <virtualID>                解除 virtualID 的镜像关系
//   mirror-probe status   <displayID>                打印 CGDisplayMirrorsDisplay 读数（只读无副作用）
//
// 方向依据（调查验证）：
//   CGConfigureDisplayMirrorOfDisplay(config, slave, master) — 第一参数 slave、第二参数 master
//   （照 MirrorScreen：virtualDisplay 为 slave、物理屏为 master）
// 提交用 .forSession：只作用于当前会话，不烘进 windowserver 偏好（kCGConfigurePermanently 会）
// 读回方向：CGDisplayMirrorsDisplay(slave) == master 才算「已镜像」
//   （Apple 文档 + MirrorScreen isDisplayMirrored(virtualDisplayID) + SimpleDisplay DisplayService 同判；
//    早期任务说明写的是读 master==slave，实测前两方向都接受，失败时把两方向读数一起打到 stderr）

import CoreGraphics
import Foundation

let usage = """
用法:
  mirror-probe mirror   <internalID> <virtualID>
  mirror-probe unmirror <virtualID>
  mirror-probe status   <displayID>
"""

func errln(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func parseID(_ s: String) -> CGDirectDisplayID? {
    guard let v = UInt32(s), v != 0 else { return nil }
    return v
}

func isOnline(_ id: CGDirectDisplayID) -> Bool {
    // 注意：CGDisplayIsOnline 对不存在的 id 返回 0xFFFFFFFF（非 0 也非 false），不能直接当布尔用。
    // 用在线列表做成员判断才是可靠口径。
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(32, &ids, &count)
    return ids.prefix(Int(count)).contains(id)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    errln(usage)
    exit(2)
}

switch args[1] {

case "mirror":
    guard args.count == 4,
          let internalID = parseID(args[2]),
          let virtualID = parseID(args[3]) else {
        errln("参数错误：mirror 需要两个非零数字 id（内屏 master、虚拟屏 slave）")
        exit(2)
    }
    guard internalID != virtualID else {
        errln("参数错误：内屏与虚拟屏 id 相同（\(internalID)）")
        exit(2)
    }
    guard isOnline(internalID) else {
        errln("内屏 \(internalID) 不在线（镜像 master 必须在线）")
        exit(1)
    }
    guard isOnline(virtualID) else {
        errln("虚拟屏 \(virtualID) 不在线（镜像 slave 必须在线）")
        exit(1)
    }

    var config: CGDisplayConfigRef?
    var result = CGBeginDisplayConfiguration(&config)
    guard result == .success, let config = config else {
        errln("CGBeginDisplayConfiguration 失败: CGError=\(result.rawValue)")
        exit(1)
    }

    // slave = 虚拟屏（被设为镜像的屏），master = 内屏
    result = CGConfigureDisplayMirrorOfDisplay(config, virtualID, internalID)
    guard result == .success else {
        CGCancelDisplayConfiguration(config)
        errln("CGConfigureDisplayMirrorOfDisplay(slave=\(virtualID), master=\(internalID)) 失败: CGError=\(result.rawValue)")
        exit(1)
    }

    result = CGCompleteDisplayConfiguration(config, .forSession)
    guard result == .success else {
        errln("CGCompleteDisplayConfiguration(.forSession) 失败: CGError=\(result.rawValue)")
        exit(1)
    }

    // 读回验证（给 WindowServer 一点落盘时间，最多 1s）
    var ok = false
    for _ in 0..<5 {
        let fromSlave = CGDisplayMirrorsDisplay(virtualID)
        let fromMaster = CGDisplayMirrorsDisplay(internalID)
        if fromSlave == internalID || fromMaster == virtualID {
            ok = true
            break
        }
        usleep(200_000)
    }
    if ok {
        print("mirrored")
        exit(0)
    }
    errln("镜像未生效：CGDisplayMirrorsDisplay(\(virtualID))=\(CGDisplayMirrorsDisplay(virtualID))（期望 \(internalID)）; CGDisplayMirrorsDisplay(\(internalID))=\(CGDisplayMirrorsDisplay(internalID))（期望 0）")
    exit(1)

case "unmirror":
    guard args.count == 3, let virtualID = parseID(args[2]) else {
        errln("参数错误：unmirror 需要一个非零数字 id（虚拟屏 slave）")
        exit(2)
    }

    var config: CGDisplayConfigRef?
    var result = CGBeginDisplayConfiguration(&config)
    guard result == .success, let config = config else {
        errln("CGBeginDisplayConfiguration 失败: CGError=\(result.rawValue)")
        exit(1)
    }

    result = CGConfigureDisplayMirrorOfDisplay(config, virtualID, kCGNullDirectDisplay)
    guard result == .success else {
        CGCancelDisplayConfiguration(config)
        errln("CGConfigureDisplayMirrorOfDisplay(slave=\(virtualID), master=null) 失败: CGError=\(result.rawValue)")
        exit(1)
    }

    result = CGCompleteDisplayConfiguration(config, .forSession)
    guard result == .success else {
        errln("CGCompleteDisplayConfiguration(.forSession) 失败: CGError=\(result.rawValue)")
        exit(1)
    }

    var ok = false
    for _ in 0..<5 {
        if CGDisplayMirrorsDisplay(virtualID) == kCGNullDirectDisplay {
            ok = true
            break
        }
        usleep(200_000)
    }
    if ok {
        print("unmirrored")
        exit(0)
    }
    errln("镜像未解除：CGDisplayMirrorsDisplay(\(virtualID))=\(CGDisplayMirrorsDisplay(virtualID))（期望 0）")
    exit(1)

case "status":
    guard args.count == 3, let displayID = parseID(args[2]) else {
        errln("参数错误：status 需要一个非零数字 id")
        exit(2)
    }
    // 只读：0 = 无镜像；非 0 = 该屏正在镜像的目标屏 id（master）。
    // 离线/不存在的 id CG 会返回 0xFFFFFFFF（不是 0），这里显式报错，避免读数被误当成真实屏 id。
    guard isOnline(displayID) else {
        errln("显示器 \(displayID) 不在线（CGDisplayMirrorsDisplay 读数 \(CGDisplayMirrorsDisplay(displayID)) 不可信）")
        exit(1)
    }
    print(CGDisplayMirrorsDisplay(displayID))
    exit(0)

default:
    errln("未知子命令：\(args[1])\n\(usage)")
    exit(2)
}
