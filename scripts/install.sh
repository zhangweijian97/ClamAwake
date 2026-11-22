#!/bin/sh
# ClamAwake 单命令安装：curl -fsSL https://github.com/zhangweijian97/ClamAwake/releases/latest/download/install.sh | sh
# 用法：sh install.sh [本地DMG路径]   （传本地路径=离线安装，供测试；curl|sh 管道形态无参数）
# 行为契约：装 → 拉起 → readme（输出智能体版 README）
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

# app 在跑时先优雅退出再覆盖（运行中覆盖会坏；quit 会连同保活一起收掉）
if pgrep -xq "ClamAwake" >/dev/null 2>&1; then
  osascript -e 'quit app "ClamAwake"' >/dev/null 2>&1 || true
  i=0
  while pgrep -xq "ClamAwake" >/dev/null 2>&1 && [ "$i" -lt 10 ]; do
    sleep 0.5
    i=$((i + 1))
  done
fi

hdiutil attach "$DMG" -nobrowse -readonly >/dev/null
cp -R "$VOLUME/ClamAwake.app" /Applications/
hdiutil detach "$VOLUME" >/dev/null || true

"$BIN" status   # 拉起并打印状态（agent 顺带验证）

if ! "$BIN" readme; then
  echo "readme 输出失败；agent 材料见 README「For AI agents」节：https://github.com/zhangweijian97/ClamAwake#for-ai-agents"
fi
