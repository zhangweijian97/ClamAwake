# ClamAwake 项目 HANDOFF

> 本文件是项目级长期上下文：定位、结构、构建发布链、关键决策与坑。**进度与当前推进以 goal board 为准**（方向卡 `goal-85105e`，产品化探讨 `goal-645c4e`，项目卡 `proj-b407e1`），这里不复制进度。

## 项目定位

自研独立产品：单机 Mac 的 AI 熄屏保活工具——合盖后机器继续跑、屏幕熄灭。**独立发布链**（GitHub Releases + DMG、GPL-3.0 开源），不进个人成长系统的工具库、不进 tools-registry 部署链（制品管理系统口径：自研独立项目，部署属性只是维度）。

同一产品的另一仓：`项目库/研发项目/dsh-clamawake`（DSH 插件，随包分发同一引擎，发布到 npm）。

## 仓库结构

- `src/vd-engine.swift` — 虚拟屏引擎（建屏 / 护档 / 镜像 / doctor / version）
- `src/mirror-probe.swift` — 镜像工具
- `shell/` — SwiftPM 菜单栏壳（保活开关、登录项、睡眠授权）
- `scripts/build-app.sh` — 一条命令产 `dist/ClamAwake.app`（壳 + 引擎 + Info.plist + ad-hoc 签名）
- `scripts/make-dmg.sh` — 产 `dist/ClamAwake.dmg`（内部先跑 build-app.sh）
- `设计/` — 实施单等过程材料

`dist/`、`构建/`、根目录的 `vd-engine`/`mirror-probe` 均已 gitignore，不入库。

## 构建

```sh
swiftc -O src/vd-engine.swift -o vd-engine
swiftc -O src/mirror-probe.swift -o mirror-probe
scripts/build-app.sh      # → dist/ClamAwake.app
scripts/make-dmg.sh       # → dist/ClamAwake.dmg
```

两条命令都无输出（或构建脚本最后打印完成）= 成功。

## 发布（对外承诺）

**版本号三处同步**：`src/vd-engine.swift` 的 `engineVersion`、`scripts/build-app.sh` 的 `APP_VERSION` 与 `CFBundleVersion`、`shell/Sources/ClamAwake/ClamAwakeApp.swift` 的菜单文字。

动作序：

1. bump 三处 → commit
2. `scripts/make-dmg.sh`（**bump 之后再构建**，产物不早于源码）
3. 冒烟：`dist/ClamAwake.app/Contents/Resources/vd-engine version`、Info.plist 版本、DMG 内 app 版本
4. `git push` → `git tag -a vX.Y.Z` → push tag
5. `gh release create vX.Y.Z dist/ClamAwake.dmg --title "vX.Y.Z" --notes-file <notes>`（稳定版不勾 pre-release）
6. 安装位换装：替换 `/Applications/ClamAwake.app` → 重启应用（`resumeKeepAliveOnLaunch=1` 自动恢复保活）→ 读 `vd-engine version` 与日志核对
7. 存量版缺陷按发版惯例在旧 Release 页补 Known Issues（现象 / 影响面 / 缓解 / 修复版指向）

## 版本对齐

- 应用与引擎版本一致（0.3.x）。
- DSH 插件包内引擎必须跟随同一版本；插件自身版本（0.1.x）独立递增，见 `dsh-clamawake/HANDOFF.md`。
- `vd-engine version` 是跨通道对账的机器读数：应用与插件都靠它发现「引擎不同步」。

## 关键坑（都踩过）

- **建屏前的模式读数会污染进程缓存**：建屏前任何一次 `CGDisplayCopyDisplayMode` 调用都会初始化本进程的显示模式缓存，随后新建的虚拟屏在该进程里恒读 NULL、`CGDisplayCopyAllDisplayModes` 也拿不到——护档因此失明（v0.3.1 起，v0.3.3 修）。建屏前读数必须走 `screenMode`（NSScreen）。
- **镜像组 slave 的档位不能直接设**：直接 `CGDisplaySetDisplayMode` 返回 `CGError 1001`；要改走整配置（displayplacer 那种），代价是短暂拆镜像，引擎约 0.3s 内自动重挂。
- **两块虚拟屏并存时档位会被重排改写**：另一块虚拟屏的生灭会让 WindowServer 重排显示配置，本屏档位可能变成 800×520 / 800×600；镜像态不自愈（镜像成员改不了），离开镜像态（合盖、本屏升主屏）时护档按目标档恢复。见 README 故障排查。
- **ad-hoc 免签分发**：安装三步必须含「右键 ClamAwake → 打开」，否则用户装不上。

## 当前上下文（2026-11-12）

v0.3.3 已发布（GitHub Release + DMG，tag `v0.3.3`），修复 v0.3.1 起的护档失明回归；本机 `/Applications` 已装 0.3.3（引擎 pid 786），两轮真实合盖验证「模式正常 1800x1169」。v0.3.1 / v0.3.2 的 Release 页已标注 Known Issues。

## 2026-11-18 菜单栏右键切换保活 + 命令行通道（已发版 0.3.4）

用户需求：左键单击保持开菜单，右键单击作隐藏快捷键直接切换保活。实施单：`设计/2026-11-18-菜单栏右键切换保活.md`。

- **架构变化**：菜单栏壳从 SwiftUI `MenuBarExtra` 改为 AppKit `NSStatusItem` + `NSMenu`——MenuBarExtra 把左右键都接到开菜单，挂不了右键行为。菜单内容逐项复刻（状态段/保活开关/开机自启/登录项待批准/系统级防睡/退出/版本号），每次打开现算快照（pmset 读数与登录项状态实时刷新）。
- **行为**：右键＝切换保活；启动中再按＝取消这次启动。与菜单按钮共用 `setKeepAlive`，同样写 `resumeKeepAliveOnLaunch`。图标沿用 bolt.circle.fill / zzz，切换即变。
- **发版**：0.3.4（GitHub Release v0.3.4，含 DMG；应用/引擎/CFBundleVersion 三处同步 bump：0.3.4 / 0.3.4 / 5）。`dsh-clamawake` 插件内引擎仍是 0.3.3，下次插件发版时按 `scripts/build-engine.sh` 重建同步即可（插件只核对自身包内指纹，不影响运行）。
- **实机验证（2026-11-18）**：左键菜单正常弹出且内容完整；右键开 → `vd-engine list` 出 `kya=yes mirror_of=1`（id=99）+ caffeinate/vd-engine 进程齐 + 图标变实心闪电；再右键关 → 虚拟屏消失、进程退出、`resumeKeepAliveOnLaunch=0`。


## 2026-11-18 命令行控制通道（已发版 0.3.4）

用户要求：功能要能命令行调用，不必点菜单栏图标（代理测试不抢鼠标）。设计与实测见 `设计/2026-11-18-菜单栏右键切换保活.md` 的「追加：命令行控制通道」。

- **实现**：`shell/Sources/ClamAwake/Control.swift`——app 内 `ControlPortServer`（CFMessagePort `com.clamawake.app.control`，回调主线程）＋ CLI 侧 `ControlCLI`；命令分派进 `StatusBarController.handle(controlCommand:)`，与菜单/右键共用同一组方法，状态机单份。
- **用法**：`/Applications/ClamAwake.app/Contents/MacOS/ClamAwake status|start [--wait]|stop|toggle|login on|off|sleepguard on|off|quit`；app 未运行时 CLI 自动 `open -a` 拉起（实测 0.43s 就绪）。输出为 `key=value` 行，`phase=failed` 退出码 1。
- **无参数**仍是 GUI 菜单栏分支；`--selftest` 不变。
- **卡顿读数**：命令行开保活 ≈ 0.25s（两段）、关 ≈ 0.06s；建/收显示器是 WindowServer 显示拓扑变更，换单模式/非 HiDPI 同量级，属机制固有成本（README 的中英「应用自带命令行」段已补，发版说明同步）。
