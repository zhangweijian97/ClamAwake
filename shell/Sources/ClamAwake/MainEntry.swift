// ClamAwake 菜单栏壳 — 入口
// GPL-3.0，见仓库 LICENSE
//
// 三种入口：
//   · --selftest   无 GUI 的引擎宿主自检（spawn vd-engine → 建屏 → 停止 → 屏消失），构建后机器验证用
//   · 命令参数     命令行控制（status/start/stop/toggle/login/quit），走与菜单同一组方法
//   · 无参数       AppKit 菜单栏分支（NSStatusItem + NSMenu），双击 / open 启动走这里

import AppKit

@main
struct ClamAwakeEntry {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            EngineSelfTest.run()
            return
        }
        if let code = ControlCLI.run(Array(CommandLine.arguments.dropFirst())) {
            exit(code)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
