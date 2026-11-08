# dsh-clamawake（ClamAwake 的 DSH 插件）

把 ClamAwake 的合盖保活配方绑到 DSH 宿主生命周期上：**DSH 启动 = 保活在跑，DSH 停止 = 保活停**。没有 web 面板（无 UI 需求），纯宿主半边的后台插件。

保活配方两件套（与仓 README「快速上手」一致）：

1. **虚拟屏**：spawn `vd-engine create 1800 1169 --hidpi --hold` 子进程持有屏——虚拟屏活在持有进程的生命周期内（CGVirtualDisplay 没有跨进程销毁 API，见 `src/vd-engine.swift` 的结论注释）；对子进程 SIGTERM → 引擎的 signal handler `exit(0)` → 屏随之消失。
2. **`caffeinate -d` 显示断言**：独立子进程，停止时一并 SIGTERM。

## 生命周期语义

| 阶段 | 动作 |
|---|---|
| 插件 start（`apply` → `ctx.effect` setup） | 解析引擎二进制 → 核对 `/usr/bin/caffeinate` 存在 → 跑一次只读 `vd-engine list` → **已有 `kya=yes` 的屏则复用不重建**（判据与 `vd-engine doctor` 的 `keepalive_running` 同源：KYA vendor 标记 `0x4B5941`）→ 否则 spawn 建屏子进程 + caffeinate 子进程，异步尾段读回屏 id 并再 list 一遍交叉核验（执行后验证，不信子进程一面之词） |
| 插件 dispose（`ctx.effect` 的 disposer） | **只 SIGTERM 自己 spawn 的子进程**（引擎建屏子进程 + caffeinate），3s 未退升级 SIGKILL 兜底；屏随引擎子进程退出消失 |

**所有权边界（安全红线）**：复用的外部屏（别的 vd-engine 进程 / 菜单栏壳 / 其他虚拟屏工具持有）**绝不动**——本插件 dispose 不碰任何不是自己 spawn 的进程。引擎子进程意外退出时打显著日志（保活失效），不做自动重启（重启策略属后续切片）。

**日志**：`console.log` 前缀 `[clamawake]`，进宿主控制台输出（启动/复用/建屏/核验/停止各一行，失败带原因）。

## 环境变量

| 变量 | 语义 | 默认 |
|---|---|---|
| `CLAMAWAKE_ENGINE` | vd-engine 可执行文件的绝对路径（解析链第 1 级） | 未设 |
| `CLAMAWAKE_REUSE` | 设 `0`/`false`/`no` 强制走建屏路径（测试逃生阀；生产不要设） | 复用开启 |

## 引擎二进制怎么来

插件不编译 Swift，只调用 `vd-engine` 可执行文件。编译（仓根执行）：

```sh
swiftc -O src/vd-engine.swift -o vd-engine
```

解析链（第一个存在且可执行的生效，全落空则插件装载报明确错误——列尝试过的路径 + 上述构建命令）：

1. 环境变量 `CLAMAWAKE_ENGINE`（绝对路径）；
2. `<插件目录>/bin/vd-engine` —— **自包含安装的约定路径**（推荐生产用：把编译产物拷进插件包，见下）；
3. `<插件目录>/../vd-engine` —— 仓根（上面 swiftc 命令的落点，开发形态）；
4. `<插件目录>/../dist/ClamAwake.app/Contents/Resources/vd-engine` —— `scripts/build-app.sh` 的落点；
5. `/Applications/ClamAwake.app/Contents/Resources/vd-engine` —— 装好的 .app。

**生产装载注意**：插件安装后是 profile 目录下的实体拷贝（`~/.dsh/profiles/<profile>/node_modules/dsh-clamawake/`），相对定位 3/4 会失效；DSH 是 GUI 应用，从 launchd/Finder 启动不继承 shell 的环境变量。所以生产环境二选一：

- **推荐**：把 `vd-engine` 拷到 `<插件目录>/bin/vd-engine` 后再装（自包含，无环境依赖）；或
- `launchctl setenv CLAMAWAKE_ENGINE <绝对路径>`（重启机器后失效，需重设）。

## 装载步骤（插件管理器路径已实测，见「已知边界」）

1. 编译引擎并按上文放进解析链某一级（推荐 `bin/vd-engine` 自包含）。
2. 把本目录（`dsh-plugin/`）作为插件包装进 DSH，两种等价路径：
   - **界面/插件管理器**：`plugin_manager(action=install_bundle, target=<本目录绝对路径>)`（与 dsh-member 同法；实测装成的是 profile 下指向本目录的 link，改代码后重新启用即可生效，无需拷贝）；
   - **文件级**（DSH 插件接入的硬约束：必须是 profile 下**实体目录** + 双登记）：把本目录拷到 `~/.dsh/profiles/<profile>/node_modules/dsh-clamawake/`，并在该 profile 的 `package.json` 里同时登记 `dependencies` 与 `dsh.profile.bundles`。手工符号链接不要用——宿主 import 会失败且只打一行「entry did not activate」；插件管理器的 link 依赖不同，已实测可用。
3. **重启 DSH**（插件只在应用启动时加载；已装好后改代码，重新启用插件（`set_plugin` 关→开）即可让宿主读到新模块）。
4. 验证：宿主控制台出现 `[clamawake]` 启动日志（复用或建屏 + 核验通过）；`vd-engine list` 里出现 `kya=yes` 屏（若此前没有的话）；退出 DSH 后该屏消失、本插件挂的 caffeinate 断言释放。
5. 移除/更新插件：`remove_bundle`（或文件级删除 + 重启）；更新 `index.js` 后需重装并重启。

`package.json` 的 `dsh` 段只有 `bundle.patch`（指向 `cordis.patch.yml`，往宿主 bundle 插一行 `dsh-clamawake`）——没有 `dsh.client` 段（无 web 面板、无客户端模块）。

## 结构

| 文件 | 作用 |
|---|---|
| `index.js` | 宿主半边：start/dispose 生命周期、引擎解析、复用防护、交叉核验。无 npm 依赖（`node:child_process`，数组参数不经 shell） |
| `cordis.patch.yml` | bundle patch：插入一行 `dsh-clamawake`（仅宿主半边） |
| `locale/zh.json` / `locale/en.json` | Plugin Manager 读的标题/描述 |
| `test-lifecycle.mjs` | 生命周期自测（不经宿主，见下） |

## 自测

```sh
node dsh-plugin/test-lifecycle.mjs
```

模拟 cordis 装载协议（最小 ctx：`effect(setup)` → setup 同步执行、返回值当 disposer），两个阶段：

- **阶段 A 建屏路径**（`CLAMAWAKE_REUSE=0`）：start → `vd-engine list` 出现新的 kya=yes 屏 → dispose → 屏消失；
- **阶段 B 复用路径**（默认）：start → 不建新屏、复用既有 kya=yes 屏 → dispose → 既有屏原样；
- **终态复核**：在线屏集合与测试开始时一致。

首次运行若无引擎二进制会现场 `swiftc` 编译到 `dsh-plugin/.test-engine/`（已 gitignore，src 未变则缓存复用）。**安全边界**：脚本全程只读查询 + 只 SIGTERM 自己 spawn 的子进程，绝不 kill 外部保活引擎、绝不跨进程 remove 任何屏。

## 已知边界

- **无 Config 导出**：配置只走环境变量（与 dsh-member/spacemgr 一致，无 UI 场景够用）。
- **引擎意外退出不自拉起**：只打显著日志；自动重启策略（含退避）属后续切片。
- **真实 DSH 宿主装载已验收（2026-11-08）**：`install_bundle` 装载并在宿主激活（`application: applied`）；复用模式下挂自有 `caffeinate -d`、不动外部 kya=yes 屏；`set_plugin` 关闭只收自有 caffeinate（用户 ClamAwake.app 保活与外部屏原样），重新开启重挂。协议级自测（`node test-lifecycle.mjs`）同一轮通过：建屏 → 核验 → 拆屏 → 屏消失，复用路径不重复建屏、终态与基线一致。
- **宿主被强杀时的孤儿子进程（未验证）**：正常退出走 cordis dispose（SIGTERM 自有子进程）；若宿主进程被 `kill -9` 之类强杀，dispose 不执行，插件 spawn 的 vd-engine / caffeinate 可能成孤儿继续保活，需手动 `kill`（下次宿主启动时插件会按 kya 标记复用该屏）。
- **GUI 宿主的环境变量缺口**：见「引擎二进制怎么来」——推荐 `bin/vd-engine` 自包含规避。
