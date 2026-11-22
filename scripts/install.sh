#!/bin/sh
# ClamAwake 单命令安装：curl -fsSL https://github.com/zhangweijian97/ClamAwake/releases/latest/download/install.sh | sh
# 用法：sh install.sh [本地DMG路径]   （传本地路径=离线安装，供测试；curl|sh 管道形态无参数）
# 行为契约：装 → 拉起 → readme（输出智能体说明书，动手前先读）
set -e

DMG_URL="https://github.com/zhangweijian97/ClamAwake/releases/latest/download/ClamAwake.dmg"
APP="/Applications/ClamAwake.app"
BIN="$APP/Contents/MacOS/ClamAwake"
VOLUME="/Volumes/ClamAwake"

if [ $# -ge 1 ]; then
  DMG="$1"
  test -f "$DMG" || { echo "错误：本地 DMG 不存在：$DMG"; exit 1; }
else
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL -o "$TMP/ClamAwake.dmg" "$DMG_URL"
  DMG="$TMP/ClamAwake.dmg"
fi

# 换装恢复：quit 前先记下保活状态（quit 会清 resume 键——用户主动退出的正确语义；
# 换装「退了再装回来接着跑」的恢复职责归本脚本，不压在 app 的 resume 键上）
WAS_PROTECTING=0
if pgrep -xq "ClamAwake" >/dev/null 2>&1; then
  "$BIN" status 2>/dev/null | grep -q "^protecting=yes" && WAS_PROTECTING=1
fi

# app 在跑时先优雅退出再覆盖（运行中覆盖会坏；quit 会连同保活一起收掉——电池档闸在时退出会弹一次
# 管理员授权，请在弹出的窗口输入密码。最多等 30s：等不到就退回 SIGTERM，不让脚本挂死在授权窗上）
if pgrep -xq "ClamAwake" >/dev/null 2>&1; then
  osascript -e 'quit app "ClamAwake"' >/dev/null 2>&1 &
  i=0
  while pgrep -xq "ClamAwake" >/dev/null 2>&1 && [ "$i" -lt 60 ]; do
    sleep 0.5
    i=$((i + 1))
  done
  if pgrep -xq "ClamAwake" >/dev/null 2>&1; then
    echo "ClamAwake 30s 内未退出（撤闸授权未确认？），改发 SIGTERM 继续安装" >&2
    pkill -TERM -x ClamAwake >/dev/null 2>&1 || true
    sleep 1
  fi
fi

hdiutil attach "$DMG" -nobrowse -readonly >/dev/null
cp -R "$VOLUME/ClamAwake.app" /Applications/
hdiutil detach "$VOLUME" >/dev/null || true

# 换装恢复：quit 前保活开着 → 重开拉起后主动恢复保活（电池档会弹一次补闸授权窗，请输密码）
if [ "$WAS_PROTECTING" = "1" ]; then
  "$BIN" start --wait >/dev/null 2>&1 || true
fi

# 拉起并打印状态（agent 顺带验证）。两件事可能还在路上，抢读会把「进行中」误读成「没做」：
#   ① 启动恢复：控制端口先就绪、建屏在后 → phase=starting 时等它落定；
#   ② 电池档补闸：进入 running 后才弹授权（闸已开=免弹）→ 闸缺席时等用户输完密码。
status_settled() {
  case "$1" in *phase=starting*) return 1 ;; esac
  case "$1" in *phase=running*) ;; *) return 0 ;; esac
  case "$1" in *mode=battery*) ;; *) return 0 ;; esac
  case "$1" in *sleep_guard=off*) return 1 ;; esac
  return 0
}

i=0
while :; do
  STATUS=$("$BIN" status) || { printf '%s\n' "$STATUS"; exit 1; }
  if status_settled "$STATUS"; then break; fi
  i=$((i + 1))
  if [ "$i" -ge 20 ]; then break; fi
  sleep 0.5
done
printf '%s\n' "$STATUS"

if ! "$BIN" readme; then
  echo "readme 输出失败；agent 材料见 README「For AI agents」节：https://github.com/zhangweijian97/ClamAwake#for-ai-agents"
fi
