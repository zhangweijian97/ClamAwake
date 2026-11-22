// ClamAwake 菜单栏壳 — 系统级防睡（pmset SleepDisabled，管理员授权）
// GPL-3.0，见仓库 LICENSE
//
// 选型：pmset 是「一次性系统设置写入」，设完长期生效（跨重启持久），不是反复需要 root 的操作——
// 用 osascript `with administrator privileges` 在用户开启该功能的当刻弹系统授权窗，全程无终端。
// 不引入常驻 root 助手（SMAppService daemon 需要独立 XPC 目标 + 签名配套，对一次性设置写入过重）。
//
// 读数：`pmset -g` 无需权限，字段名 SleepDisabled（本机实测格式 " SleepDisabled\t\t1"）。
// 写入：`pmset -a disablesleep 1`（开）/ `0`（关）。

import Foundation

final class SleepGuardManager: ObservableObject {
    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var isApplying: Bool = false
    @Published var lastError: String?

    func refresh() {
        isEnabled = Self.readSleepDisabled()
    }

    /// 读当前系统状态（pmset -g 无需权限；读不到字段按未启用处理）
    static func readSleepDisabled() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return false }
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.split(separator: "\n") {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if tokens.count >= 2, tokens[0].lowercased() == "sleepdisabled" {
                return tokens[1] == "1"
            }
        }
        return false
    }

    /// 开/关系统级防睡（会弹管理员授权窗；用户取消 → 报错、状态不变）。
    /// 已是目标值 → no-op（pmset 是持久设置，值没变就不弹窗）；
    /// isApplying 中收到新请求 → 记入 pendingTarget，当前写入完成后紧接着执行
    /// （堵「开保活的 osascript 飞行中引擎失败，回收调用被 isApplying 吞掉」的窗口）。
    /// whenDone：本次写入（含接续的 pending 写入）落定后回调——退出前撤闸要等授权结果再退，靠它。
    private var pendingTarget: Bool?
    private var pendingWhenDone: (() -> Void)?

    func setEnabled(_ on: Bool, whenDone: (() -> Void)? = nil) {
        if isApplying {
            pendingTarget = on
            if let whenDone { pendingWhenDone = whenDone }
            return
        }
        refresh()
        if isEnabled == on {
            whenDone?()
            return
        }
        isApplying = true
        lastError = nil
        let cmd = on ? "pmset -a disablesleep 1" : "pmset -a disablesleep 0"
        let action = on ? "禁用" : "恢复"
        let script = "do shell script \"\(cmd)\" with administrator privileges"
            + " with prompt \"ClamAwake 需要管理员权限来\(action)系统睡眠设置（pmset）\""
        DispatchQueue.global().async { [weak self] in
            let result = runOSascript(script)
            DispatchQueue.main.async {
                guard let self else {
                    whenDone?()   // app 正在退出：回调照发，别把退出流程挂住
                    return
                }
                self.isApplying = false
                if let message = result.1 { self.lastError = message }
                self.refresh()
                // 主路径（非接续）也要触发本次传入的 whenDone——原实现只读 pendingWhenDone，
                // 直接调用时回调被丢弃（2026-11-22 实测：撤闸成功但 finishStop 不执行，半关闭态）
                let done = self.pendingWhenDone ?? whenDone
                self.pendingWhenDone = nil
                if let pending = self.pendingTarget {
                    self.pendingTarget = nil
                    if self.isEnabled != pending {
                        self.setEnabled(pending, whenDone: done)
                    } else {
                        done?()
                    }
                } else {
                    done?()
                }
            }
        }
    }
}

/// 返回 (是否成功, 失败时的用户可读信息)
private func runOSascript(_ script: String) -> (Bool, String?) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    p.standardOutput = FileHandle.nullDevice
    let errPipe = Pipe()
    p.standardError = errPipe
    do { try p.run() } catch {
        return (false, "无法启动 osascript：\(error.localizedDescription)")
    }
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if p.terminationStatus == 0 { return (true, nil) }
    let errText = String(data: errData, encoding: .utf8) ?? ""
    if errText.contains("用户已取消") || errText.contains("User canceled")
        || errText.contains("execution error: (-128)") {
        return (false, "已取消：未修改系统睡眠设置")
    }
    return (false, "pmset 修改失败：\(errText.trimmingCharacters(in: .whitespacesAndNewlines))")
}
