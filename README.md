# ClamAwake — macOS 合盖保活工具

**简体中文** | [English](README.en.md)

合盖之后，机器照常运行 AI / 长任务，屏幕熄灭。

## 解决什么问题

MacBook 合上盖子，macOS 默认直接进入睡眠——正在跑的 AI 任务、编译、下载全部中断。想让机器继续跑，让显示器睡眠也不行：屏幕一熄，截屏类的视觉采集拿到的就是纯黑画面。

ClamAwake 的做法：给系统接一块自建的虚拟屏，合盖后由虚拟屏接管显示、屏幕熄灭——机器照常跑，视觉采集不受影响。

## 原理

核心是 macOS 的私有 `CGVirtualDisplay` 类族。这些类没有公开头文件，ClamAwake 用 `NSClassFromString` 取类、`objc_msgSend` 做消息派发，按每个方法的真实 ABI 强转函数指针来调用（Swift 无法给运行时注册的私有 ObjC 类写 extension）。私有类族没有 destroy API——虚拟屏的生命周期等于创建它的进程的生命周期，引擎用 `--hold` 前台常驻来持有屏幕。

合盖侧配合 `caffeinate -d` 显示断言（完整配方见下文）。另外，若你的机型合盖后仍会入睡，需要系统级禁睡：`pmset` 的 `SleepDisabled` 项（需 sudo），工具不代用户设置。`vd-engine doctor` 会读这一项，未禁睡时给出确切命令（见[快速上手](#快速上手首次运行)）。

## 当前形态

目前发布的是 CLI 源码形态：

- `vd-engine` — 虚拟屏引擎（创建 / 查询虚拟屏，含 `doctor` 环境自检）
- `mirror-probe` — 显示器镜像工具（虚拟屏与内屏建立 / 解除镜像）

菜单栏常驻壳与 DMG 打包在路线图上，是下一站。

## 快速上手（首次运行）

前提：macOS + [Xcode Command Line Tools](https://developer.apple.com/xcode/features/)（提供 swiftc；没装的话 `xcode-select --install`）。

### 第 1 步：构建

```sh
swiftc -O src/vd-engine.swift -o vd-engine
swiftc -O src/mirror-probe.swift -o mirror-probe
```

两条命令都无输出即构建成功——目录里多出 `vd-engine`、`mirror-probe` 两个可执行文件。

### 第 2 步：环境自检

```sh
./vd-engine doctor
```

stdout 每行一项检查（`check=… result=…`），建议和警告走 stderr。五项全部 pass、退出码 0，环境就绪：

```text
check=private_class result=pass detail=CGVirtualDisplay available
check=caffeinate result=pass detail=/usr/bin/caffeinate present
check=displays result=pass detail=2 display(s) online, 1 builtin
check=keepalive_running result=pass detail=no vd-engine pid; no kya display; no caffeinate assertion
check=lid_sleep result=pass detail=SleepDisabled=1 (lid-close sleep disabled)
```

重点看两行（warn 不阻塞，但要看 stderr 里的建议）：

- `lid_sleep` 为 warn → 合盖会入睡，照 stderr 里的确切命令禁睡：`sudo pmset -a disablesleep 1`（恢复默认 `sudo pmset -a disablesleep 0`）；
- `keepalive_running` 为 warn → 已有一套保活在跑（引擎进程 / kya 标记屏 / caffeinate 断言），照 stderr 处理：复用它，或 `kill -TERM <pid>` 结束后再继续。

### 第 3 步：启动引擎（前台，别关这个终端）

```sh
./vd-engine create 1800 1169 --hidpi --hold
```

发生了什么：一块 1800×1169（像素 3600×2338）的虚拟屏挂进系统；stdout 打印它的屏 id（如 `22`），stderr 打印诊断；随后进程停在前台持有这块屏——**Ctrl-C 或关掉终端，屏就没了**。

（1800 1169 是常见 MacBook 内屏的逻辑分辨率；`--hidpi` 让像素翻倍进 HiDPI 档。想省事可换 `1920 1080`。）

### 第 4 步：合盖

另开一个终端：

```sh
caffeinate -d &
```

然后合盖：屏幕熄灭，机器继续跑，视觉采集拿到的是虚拟屏画面而不是黑屏。

（`lid_sleep` 未禁睡、又没有「外接屏 + 电源」的 clamshell 条件时，合盖会直接入睡——这就是第 2 步要处理的事。）

### （可选）把虚拟屏镜像到内屏

视觉采集要拿到「和当前会话一致的画面」时用：

```sh
./mirror-probe mirror 1 22     # 1=内屏 id（vd-engine list 里 main=yes），22=虚拟屏 id
# stdout: mirrored
./mirror-probe status 22       # 读回验证：打印 1（内屏 id），无镜像时打印 0
./mirror-probe unmirror 22     # 解除：stdout: unmirrored
```

### 解除保活

- 结束引擎：回引擎那个终端按 Ctrl-C（或另开终端 `kill -TERM <引擎pid>`）——虚拟屏随进程消失，会话级镜像关系随之自然失效；
- 想立刻点亮内屏：`caffeinate -u -t 3`。

## 使用

不带参数运行 `vd-engine` 或 `mirror-probe` 会打印 usage；以下说明与之一致，以程序输出为准。

### vd-engine

```text
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
```

`remove` 是有意「不静默失败」的：跨进程没有销毁 API，它面对的必然是别的进程持有的屏，程序会把真正可行的销毁办法讲清楚。

`list` 输出里 `kya=yes` 的屏是本引擎创建的虚拟屏（vendor 标记），`main=yes` 的是系统主屏（通常即内屏）。

### mirror-probe

```text
用法:
  mirror-probe mirror   <internalID> <virtualID>
  mirror-probe unmirror <virtualID>
  mirror-probe status   <displayID>
```

方向约定：`mirror` 让虚拟屏（virtualID/slave）镜像内屏（internalID/master）；`unmirror` 解除 virtualID 的镜像关系；`status` 打印 CGDisplayMirrorsDisplay 读数（只读无副作用）。

### 合盖保活配方

```sh
vd-engine create 1800 1169 --hidpi --hold &
caffeinate -d &
```

之后合盖：屏幕熄灭，机器继续运行，视觉采集不受影响。解除时结束引擎进程（Ctrl-C 或 `kill`），再跑 `caffeinate -u -t 3` 唤醒显示器。

## For AI agents

面向自动化调用的精确契约。两条约定贯穿始终：**stdout 只放机器可读结果**（屏 id / `mirrored` / `unmirrored` / 读数 / doctor 的 `check=` 行）；**诊断与可执行恢复动作走 stderr**。分支判断依据 = 退出码 + stdout，不要解析 stderr 文案（stderr 目前是中文诊断，人读的）。

### 退出码语义（以源码与实测为准）

`vd-engine`：

| 退出码 | 语义 | 触发场景 |
|--------|------|----------|
| 0 | 成功 | `create` / `list` / `hi` / `doctor` 正常完成（doctor 有 warn 仍为 0） |
| 1 | 运行错 | 建屏失败（私有类缺失 / 构造失败 / `applySettings:` 被拒 / 3s 未上线）；`remove` / `hi` 目标屏不在线；`list` 在线列表为空；doctor 发现阻塞问题（fail） |
| 2 | 用法错 | 无参数、未知子命令、参数解析失败（W/H 非正整数、id 非法、分辨率超 8192/16384 上限、doctor 带多余参数） |

`mirror-probe`：

| 退出码 | 语义 | 触发场景 |
|--------|------|----------|
| 0 | 成功 | `mirror` / `unmirror` 生效（读回验证通过，stdout 为 `mirrored` / `unmirrored`）；`status` 打印镜像目标 id |
| 1 | 运行错 | 任一 id 不在线；显示配置 API 失败；`mirror` / `unmirror` 读回验证 1s 未生效 |
| 2 | 用法错 | 无参数、未知子命令、id 非法（非数字 / 0 / 内屏与虚拟屏同 id） |

注意：`vd-engine remove` 对任何在线屏都退出 1——这是设计而非故障（跨进程无销毁 API，stderr 讲清真正可行的销毁路径）。

### 第 0 步：环境自检

```sh
vd-engine doctor    # 退出码 0=无阻塞问题（warn 可继续） / 1=有阻塞问题 / 2=用法错
```

stdout 逐行 `check=<key> result=<pass|warn|fail> detail=<…>`，按 result 路由：

- 全 pass → 继续；
- `keepalive_running` warn → 引擎 pid / kya 屏 id / caffeinate 断言都在 detail 里；不是你有意保留的就 `kill -TERM <pid>`；
- `lid_sleep` warn → 照 stderr 的确切命令禁睡（`sudo pmset -a disablesleep 1`）；
- 任一 fail → stderr 有说明，中止流程。

### 保活会话标准序列（每步预期输出已实测）

```sh
# 1) 建屏并常驻持有。stdout 打印屏 id（已 fflush，重定向到文件可即时读到）；stderr 打印诊断。
vd-engine create 1800 1169 --hidpi --hold >"$TMP/vd-id" 2>"$TMP/vd-err" &
for i in $(seq 1 30); do [ -s "$TMP/vd-id" ] && break; sleep 0.2; done
VIRTUAL_ID=$(cat "$TMP/vd-id")    # 例：22；等待循环兜 WindowServer 挂屏的最多 3s
ENGINE_PID=$!
```

```sh
# 2) 查看在线情况（只读，退出码 0）。kya=yes 的行是 ClamAwake 虚拟屏；main=yes 的是内屏。
vd-engine list
# stdout 首行：# 在线显示器 N 个（main=系统主屏）
# 随后每屏一行：id=<n> main=<yes|no> builtin=<yes|no> active=<yes|no> asleep=<yes|no> mirror_of=<id|none> points=<WxH> pixels=<WxH> hidpi=<yes|no> vendor=… product=… serial=… kya=<yes|no>
```

```sh
# 3)（可选，视觉采集用）虚拟屏镜像内屏：<internalID> = list 里 main=yes 的 id
mirror-probe mirror "$INTERNAL_ID" "$VIRTUAL_ID"
# 退出码 0，stdout 恰好一行：mirrored

# 4) 读回验证（只读无副作用）
mirror-probe status "$VIRTUAL_ID"
# 退出码 0，stdout 为镜像目标 id（已镜像=内屏 id，如 1；未镜像=0）

# 5) 解除镜像
mirror-probe unmirror "$VIRTUAL_ID"
# 退出码 0，stdout 恰好一行：unmirrored
```

```sh
# 6) 收尾：结束引擎，虚拟屏随进程消失，会话级镜像关系自然失效（无需先 unmirror）。
kill -TERM "$ENGINE_PID"
# 验证收屏：vd-engine list 不再有 $VIRTUAL_ID 的行
```

### 错误处理约定

任何非 0 退出码，stderr 都带原因，多数场景带可执行恢复动作（例：`remove` 的完整销毁路径说明；`status` 对离线 id 的「读数不可信」提示；`mirror` 指明哪个 id 不在线）。恢复动作照跑即可；stdout 的 `check=` / `id=` / 读数行才是程序化分支的依据。

## 故障排查

### 引擎启动失败（create 退出 1）

stderr 会写明具体原因，常见三种：

- 「私有类 CGVirtualDisplay 不存在」——本机 macOS 没有这个私有类，ClamAwake 无法工作。跑 `vd-engine doctor`，`private_class` 为 fail 即确认；无恢复动作（取决于系统版本）。
- 「applySettings: 返回 NO」——WindowServer 拒绝该模式组合。换一组常规分辨率再试（如 `1920 1080`、`1512 982`、`1800 1169`）。
- 「applySettings 成功但 3s 内没在 CGGetOnlineDisplayList 里看到新屏」——建了但没挂上。重试一次；仍失败跑 `vd-engine doctor` 看 `displays` 项。

### 镜像探测失败（mirror / unmirror 退出 1）

- 「内屏/虚拟屏 N 不在线」——虚拟屏 id 多半是旧会话留下的：引擎重启后屏是新的一块，id 会变（旧 id 随旧进程消失）。重跑 `vd-engine list` 取当前 id。
- 「镜像未生效：CGDisplayMirrorsDisplay(…)=…」——配置提交了但读回验证 1s 内没通过。重试一次；状态可随时用 `mirror-probe status <id>` 查（只读无副作用）。

### 已存在保活冲突

`vd-engine doctor` 的 `keepalive_running` 为 warn，或 `pgrep -x vd-engine` 有输出时：

- 一个 vd-engine 进程 + 一块 `kya=yes` 屏 + caffeinate 断言 = 一套正在运行的保活。是你（或之前的会话）有意保留的 → 直接复用：`vd-engine list` 取 `kya=yes` 的 id 用，不要重复建屏。
- 要重开一套：`kill -TERM <pid>`（屏随进程消失）→ 重新 `create`。
- 有 `kya=yes` 屏但没有 vd-engine 进程 → 别的虚拟屏工具（如 SimpleDisplay）建的：退出那个工具，或直接用它的屏。
- 多块虚拟屏可并存、也可同时镜像同一内屏（实测可行），屏 id 各自独立。

## 致谢

- [pasky/hidpi-mirror](https://github.com/pasky/hidpi-mirror)
- [xtongs/mirrorscreen](https://github.com/xtongs/mirrorscreen)

两者均为 MIT 许可，是本项目构建虚拟屏的参考实现——只参考了私有 API 的调用形态，未复用代码。

## 许可证

[GPL-3.0](LICENSE)

## 赞赏

如果 ClamAwake 帮到了你，请作者喝杯咖啡：[爱发电](https://afdian.net/a/<待填>)

## 署名

ClamAwake is maintained by @<待填GitHub ID>.
