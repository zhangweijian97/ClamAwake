---
name: clamawake
description: 当用户想让 Mac 合盖后继续运行（跑 AI 任务、下载、编译、长时间脚本），或问「合盖后为什么还是睡了 / 怎么让笔记本合盖继续跑」时使用；也用于结束这种保活、把机器恢复到默认睡眠。macOS + Apple Silicon。Use to install and drive ClamAwake (macOS lid-closed keep-awake) for the user.
---

# ClamAwake（macOS 合盖保活）

给智能体的操作手册：把这个工具装上、按用户的意图开启或关闭、知道什么时候可以放心地说「好了」。

## 何时用

- 用户说：合盖继续跑、合上盖子别睡、跑完再关、下载/编译/训练期间别断；
- 用户问：合盖还是睡了、笔记本为什么睡着了；
- 不适用：只想屏幕常亮（`caffeinate -d` 就够）；非 macOS 或非 Apple Silicon。

## 安装（一次，不需要 sudo）

```sh
test -d /Applications/ClamAwake.app && echo installed   # 已装就跳过

# 单命令安装（首选）：
curl -fsSL https://github.com/zhangweijian97/ClamAwake/releases/latest/download/install.sh | sh

# DMG 手动安装（备选，单命令不可用时）：
curl -L -o /tmp/ClamAwake.dmg https://github.com/zhangweijian97/ClamAwake/releases/latest/download/ClamAwake.dmg
hdiutil attach /tmp/ClamAwake.dmg -nobrowse -readonly
cp -R "/Volumes/ClamAwake/ClamAwake.app" /Applications/
hdiutil detach "/Volumes/ClamAwake"
```

若目标机器弹「未验证的开发者」，让用户手动右键打开一次；不要用 `xattr` 去清隔离标记。

下文的 `ClamAwake` 指 `/Applications/ClamAwake.app/Contents/MacOS/ClamAwake`，`vd-engine` 指 `/Applications/ClamAwake.app/Contents/Resources/vd-engine`。

## 上手三步

```sh
/Applications/ClamAwake.app/Contents/MacOS/ClamAwake status      # 应用没在跑会自动拉起
/Applications/ClamAwake.app/Contents/MacOS/ClamAwake start --wait # 等到建屏完成或失败
/Applications/ClamAwake.app/Contents/MacOS/ClamAwake status      # 确认 protecting=yes
```

状态输出是 `key=value` 行：`phase` / `display_id` / `protecting` / `login` / `sleep_guard` / `mode` / `power`。

`start --wait` 只等到建屏完成；电池档随后还会弹授权窗：允许=保活生效（`status` 读 `protecting=yes` 且 `sleep_guard=on`）；不允许=保活不会开启（回到关闭态），想开再 `start` 一次。

**授权两拍**：电池档的 `start`/`stop` 若将弹授权窗，**首跑不执行、不弹窗**——stdout 输出 `needs_user_auth=yes` 与 `prompt_text=`，退出码 5。把 `prompt_text` 的原话转达用户、等他说准备好，再重跑同一条命令（5 分钟内有效）——第二拍才真正弹窗；跳过转达直接重跑=预告失效，用户会被突然的弹窗打断。闸已是目标值（免弹路径）不进两拍，直接执行。

## 模式（名字反直觉，按覆盖范围起名）

| 值 | 真实语义 | 授权 |
|---|---|---|
| `mode battery`（默认） | 任何情况都不睡（用电池也保） | 开/关保活时各需一次人类授权（弹窗出现时请输入密码），你不能代输密码；闸已在时免弹 |
| `mode plugged` | 只在充电时不睡（电池上合盖会睡） | 零授权 |

选档：用户在电池上也要合盖不睡 → `battery`，把授权那一步交回用户；只插电跑任务 → `plugged`。

## 用户意图 → 动作

| 用户说的 | 你做的 |
|---|---|
| 合盖继续跑 | `start --wait` → `status` 确认 `protecting=yes` |
| 跑完就关 | 同上，并由你负责收尾（见下），它不会自己停 |
| 不用了 / 省电 | `stop` |
| 为什么还是睡了 | `vd-engine doctor` 看 `lid_sleep`，再读 `status` 的 `mode`、`power` |
| 开机自启 | `login on` |

## 验证边界（能向用户声称什么）

- L1 组件：`vd-engine doctor` 五项 pass——只说明环境可用；
- L2 应用：`status` 里 `protecting=yes`——只说明保活在跑；
- L3 结果：合盖后机器没睡——只有人合上盖子才能确认，不要替用户宣布。报告给「组件已就绪，请合盖确认」。

## 收尾（不要留残留）

- 你开的保活由你关：任务结束或用户说「可以了」→ `stop`；电池档会弹授权窗：输密码=关干净（`protecting=no` 且 `sleep_guard=off`），点不允许=关闭没有发生、保活还在跑，想关再 stop 一次；
- 收尾判据：`status` 的 `protecting=no` **且** `sleep_guard=off`，且 `vd-engine list` 里没有 `kya=yes` 的屏；
- 退出应用用 `quit`（会连同保活一起收掉）；
- 不要 `kill` 别人的 vd-engine 进程——可能是菜单栏应用或另一个工具建的屏。

## 失败处理

- `start` 后 `phase=failed`：读 `error` 行。常见三种——私有类缺失（本机不支持）、分辨率组合被拒（换 1920x1080 再试）、3 秒未上线（重试一次，仍失败跑 doctor）；
- 退出码 5（授权预告）：不是成功也不是失败——把 `prompt_text` 原话转达用户后重跑；超过 5 分钟重跑=预告过期，会重新出预告；
- 授权飞行中的 `status` 是快照：第二拍返回时弹窗还在等输密码，此刻 status 是飞行前旧值（「进行中」不是「没做」）——落定后重跑 `status`，以 `protecting`/`sleep_guard` 终态行判读；
- 手动 `quit` 命令与 `mode` 切换的授权弹窗不进两拍（弹窗前无预告）——install.sh 换装场景才按协议预告；
- doctor 的 `lid_sleep` 是 warn：需要人类执行 `sudo pmset -a disablesleep 1`，或让用户切到 `battery` 档由应用请求授权——**不要自己尝试 sudo**；
- 已在跑（`keepalive_running` warn 或存在 `kya=yes` 的屏）：复用，不要重复建屏。

## 完整契约

退出码、stdout/stderr 约定、doctor 输出格式，安装、决策表、验证阶梯、收尾，以及 readme 命令（智能体说明书，动手前先读）见仓库 README 的「For AI agents」节：
https://github.com/zhangweijian97/ClamAwake#for-ai-agents
