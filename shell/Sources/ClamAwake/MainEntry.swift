// ClamAwake 菜单栏壳 — 入口
// GPL-3.0，见仓库 LICENSE
//
// --selftest：无 GUI 的引擎宿主自检（spawn vd-engine → 建屏 → 停止 → 屏消失），
// 供构建后机器验证用；正常双击 / open 启动走 SwiftUI 菜单栏分支。

import SwiftUI

@main
struct ClamAwakeEntry {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            EngineSelfTest.run()
            return
        }
        ClamAwakeApp.main()
    }
}
