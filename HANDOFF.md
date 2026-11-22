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

## 2026-11-21 launchd 常驻方案判读：已被 app 形态取代（plist 移出运行位）

由来：`launchd-health-check` 自 2026-11-09 起每日报「未注册 2 项」，其中一件是本项目的
`com.clamawake.vd-engine`。当次核实的四条读数：

1. `/Applications/ClamAwake.app` 是登录项且 enabled（System Events 读 `path=/Applications/ClamAwake.app`）；
2. 在跑引擎来自 app 包内 —— `ps` 显示 `/Applications/ClamAwake.app/Contents/Resources/vd-engine create 1800 1169 --hidpi --hold --mirror-main`，`vd-engine version` = **0.3.4**；
3. `~/Library/LaunchAgents/com.clamawake.vd-engine.plist` 指向项目 `构建/vd-engine`（2026-11-08 19:11 构建），该二进制**不支持 `version` 子命令**（实测「未知子命令」）——比包内引擎旧；而 `vd-engine version` 正是应用/插件跨通道对账的机器读数；
4. plist 指定的 `/tmp/vd-prod.out`、`/tmp/vd-prod.err` 不存在 → 该 label 从未实际跑起来。

判读：这是 2026-11-08 那份实施单（`设计/f8e4a9-launchd常驻实施单-20261108.md`）的旧方案遗留，
产品后来走的形态是「app 自带登录项 + `resumeKeepAliveOnLaunch` + 命令行控制通道」（0.3.4），
launchd 那一支没落地也无需落地——同一条用户价值（重启后 AI 画布自动回来）已由登录项 + app 内建恢复承接。

处置：把运行位 plist 移入 `~/个人成长系统/_最近删除/launchd-未注册-plist-20261121/`（同目录 README 记判读与回滚）；
项目内正本副本 `deploy/com.clamawake.vd-engine.plist` 原样保留。实施单顶部已加状态注记，避免后来者照单执行拉起第二个旧引擎。
回滚（若将来要回到纯 launchd 形态）：先关 app 侧保活（避免两个引擎争同一虚拟屏），再把缓冲里的 plist 拷回
`~/Library/LaunchAgents/` 并 `launchctl bootstrap gui/$(id -u) <plist>`；同时把 plist 的 ProgramArguments 指向**当前版本**的引擎。

## 2026-11-21 v0.3.5：保活与系统级防睡合并为单开关（已装机验证）

用户需求：两个功能合并到一个开关——只防睡不镜像会出现「合盖屏幕还亮着」，不可接受。实施单：`设计/2026-11-21-保活与系统防睡合并单开关.md`（goal-141d32）。

- **语义**：开保活 = engine.start()（虚拟屏镜像+caffeinate）+ pmset 禁睡（已是 1 免弹窗）；关保活 = engine.stop() + 防睡自动回收（phase 观察统一触发，覆盖主动关/引擎意外死/启动失败三路，变化沿 starting|running→stopped|failed）。
- **防睡单独入口全删**（菜单项、CLI `sleepguard on|off`）；矛盾态（防睡仍开+保活已停）菜单警告行 +「恢复系统睡眠默认」项（唯一剩余的单独关出口）。`SleepGuard.setEnabled` 加 no-op 与 pendingTarget 接续（堵 osascript 飞行中回收被 isApplying 吞的窗口）。
- **实弹验证（2026-11-21）**：stop → 拆屏即时、授权后 SleepDisabled=0；start --wait → 建屏 display_id=123、授权后 SleepDisabled=1、引擎读数 mirror_of=1。装机位 /Applications 已是 0.3.5。
- 未发版（GitHub Release/DMG 待发）：bump/构建/冒烟/实机验证已过，发版动作见「发布」节动作序第 4 步起。

## 2026-11-21 v0.3.6：双模式——普通（零密码）/强力（pmset 拉闸）（已装机验证）

用户定调：0.3.5 合并单开关后每次开关都弹管理员密码，产品摩擦不可接受——「要从产品的角度考虑」。重构为模式档位（实施单：`设计/2026-11-21-双模式普通与强力.md`，goal-913ef4）：

- **普通模式（默认）**：虚拟屏镜像 + `caffeinate -d -s`（显示+系统断言，0.3.6 起加固）。零密码、随开关生灭、结构上无残留。
- **强力模式**：普通 + pmset disablesleep（电池合盖等「断言挡不住」场景兜底）。开保活弹一次授权、关保活再弹一次（已是目标值免弹）；SIGKILL 残留由矛盾态警告行+恢复出口兜底（0.3.5 机制保留）。
- 模式=UserDefaults `keepAliveMode`，菜单项切换（菜单/CLI `mode normal|power` 同路径）；切换时 pmset 对齐新模式（切强力+保活开→补闸；切普通→撤闸）。
- 实弹验证：普通模式开关各约 0.6s 零弹窗（pmset 全程不动）；强力模式开 8s 拉闸/关 4s 回闸（SleepDisabled 1→0 系统读数确认）；切回普通零弹窗。装机位已是 0.3.6。
- **机制对比沉淀（用户问答确立）**：pmset=拉闸（策略层全局禁令，覆盖合盖硬件事件路径，故强、持久、要 root）；断言=投票（请求层声明，随进程生灭，故弱、零成本、零残留）。强度=持久性=管理成本，三者同源。
- 未发版：0.3.5 与 0.3.6 均待 GitHub Release（用户点头即发）。

## 机制认知底座（2026-11-21 深夜定稿：合盖场景矩阵与四层分析框架）

当晚实测+考古+用户一手记忆确立的机制图景，是此后排障/文档/issue 响应的共同底座。

**分工模型**：防睡件管「机器跑不跑」，虚拟屏管「屏幕灭不灭」——虚拟屏在产品里的真实角色是**熄屏件**（承接显示让内屏熄灭），不是防睡件。用户原始痛点「合盖屏幕还亮着」= 有防睡、无熄屏件的形态。

**合盖结果矩阵**（无物理外接屏前提；「断言」指 caffeinate 三类断言，实测均挡不住合盖路径）：

| 电源 | 防睡件 | 虚拟屏 | 机器 | 屏幕 | 证据 |
|---|---|---|---|---|---|
| 插电 | 无 | 无 | 睡 | — | 常识 |
| 插电 | 断言 | 无 | 未观测 | 未观测 | **空格子**（只跑 caffeinate 的用户；只影响定位论述措辞，两种可能答案都指向需要本产品） |
| 插电 | 闸 | 无 | 不睡 | 亮 | 用户记忆（0.3.4 痛点形态） |
| 插电 | 断言 | ✓ | 不睡 | 熄灭 | 本机多日实测（=插电档） |
| 电池 | 无/断言 | 无/✓ | 睡 | — | 20:37 实测（Clamshell Sleep，断言+虚拟屏在场仍睡） |
| 电池 | 闸 | 无 | 不睡（推断） | 亮（推断） | 未观测 |
| 电池 | 闸 | ✓ | 不睡（推断） | 熄灭 | **留观察**（=电池档·日常使用自然验证） |

**四层分析框架**：层一机制层（macOS 电源管理规则：睡眠触发路径×各路径有效件——回答为什么）；层二配置层（上表——回答这台机器会怎样，产品设计在此完成）；层三轨迹层（合盖后的时间函数：醒着→电池掉电→耗尽；睡着→维护睡眠→深度休眠——用户报「挂一夜死了」先在此归因）；层四外推层（单机样本→用户群承诺分级：机制保证的/本机实测的/留余量收反馈的——README 措辞按此分级）。

**定位（用户定调）**：首要用户=携带电脑移动的人（默认电池档）；第二类=电脑不挪窝的插电用户（插电档，虚拟屏是他们的刚需熄屏件——插电+断言+无虚拟屏时即使不睡也屏幕亮着）。分工：本线以伙伴为主推进，用户只做用户侧动作（密码/物理合盖/观察/收货信号）。

## 2026-11-22 v0.3.7 发版（GitHub Release + DMG；对外词汇改效果语言）

- **验证收口**：测试 A 历史判定 PASS（11-14 以来每晚零入睡）；测试 B 由 11-22 晨隐式证据判 PASS（10:19:32–10:35:31 合盖 15 分 59 秒，pmset 零入睡、引擎进程连续——vd-engine.log 的 mode-guard 内屏离线/回归记录可作盖子开合判读源，后续此类验证无需用户回忆）。T1 格（电池+闸+合盖→不睡）实证落定，合盖结果矩阵不再有留观察格。
- **发版前文案定稿（用户三轮定调）**：对外词汇从机制语言改效果语言——「保活」→「合盖不睡眠」；「电池档/插电档」→「任何情况都不睡 / 只在充电时不睡」（选项缩进挂开关下，不再有档位分组；内部值 battery/plugged 不变）。定调过程实证：普通人对「充电」的语义=插着线（宽泛化），文案按读者语义不按技术定义。菜单/CLI/README 中英同步，commit 173eb74。
- **发布**：tag v0.3.7，Release 页 https://github.com/zhangweijian97/ClamAwake/releases/tag/v0.3.7 （稳定版，DMG 附件，notes 用新词形）。0.3.5/0.3.6 不单独发（其变更全部含于 0.3.7）。
- **换装**：/Applications 已换新构建（quit → ditto → 重开，resumeKeepAliveOnLaunch 自动恢复保活），核对 mode=battery / protecting=yes / 新虚拟屏 id=137。
- **冒烟注意（新增坑）**：`dist/.../MacOS/ClamAwake` 无参数=GUI 分支会拉起第二实例挂住冒烟——usage 冒烟要传假命令参数（`__usage_probe__`，exit 2 分支打印 usage）。strings 对中文字符串常量无效，冒烟以运行时输出为准。

## 2026-11-22 晚 0.3.8：授权语义回退（闸随保活生灭）+ 撤闸链修复

用户体感「开关不需要密码」触发调查：0.3.7 档位重构（0fda577）主动删除 phase 观察 sink（闸常驻，密码只在换档——当时为解决 0.3.5 每次开关弹窗的痛点，实施单有记录）——**有意识设计，不是 bug**；但闸常驻的代价在 agent 面出现后暴露：①关保活后 SleepDisabled=1 残留，用户「关掉=恢复默认睡眠」预期被违背；②agent 收尾判据失效（protecting=no 不等于系统干净）。**决策：回退到闸随保活生灭**（5b92336+7eedbd8）：开关各弹一次授权（闸已在免弹）、换装弹两次；stop/quit/引擎意外死三路撤闸（phase 变化沿统一触发，quit 挂起退出）；quit 清 resume 键（用户主动退出的正确语义），换装恢复职责归 install.sh（quit 前记 protecting，重开后 start 恢复——受弹窗时序影响，agent 兜底句已进说明书安装段「装完确认 protecting=yes」）。文案六处对齐（usage/菜单/SKILL/README 中英/guide 卡收尾判据=protecting=no 且 sleep_guard=off 才算收干净）。实弹验证：stop 撤闸 1→0 过。HANDOFF 0.3.7 段缺档位重构记录（0fda577）——本段补记。

## 2026-11-22 深夜 0.3.8 后续四连修（goal-088256 链+goal-1e0095）
授权语义回退后连续修复：①关闭原子化（50397cc，先撤闸后停引擎，不允许=回滚）②setEnabled 主路径接住 whenDone（0ea6205，撤闸成功但 finishStop 不执行的一行修复）③开启原子化（f6dbecd，对称回滚+切档防御）④**两拍授权预告协议**（ac5d190，goal-1e0095：battery 档 stop/start/toggle 将弹窗时第一拍输出 needs_user_auth=yes+exit 5 不弹窗，agent 转达用户后 5 分钟内同命令重跑才真正弹窗；install.sh 同协议；mode/quit 未覆盖留观察）。三步实弹（关闭侧）全过；两拍第二拍实弹与 mode/quit 覆盖留验。**抽验判例：验两拍分流必须新 app 实例接控制端口——新 CLI 对装着的旧 app 发命令会绕过分流直触弹窗（本次抽验事故：多弹一次窗，已清）**。
