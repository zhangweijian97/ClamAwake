#!/bin/sh
# ClamAwake 单命令安装：curl -fsSL https://github.com/zhangweijian97/ClamAwake/releases/latest/download/install.sh | sh
# 用法：sh install.sh [本地DMG路径]   （传本地路径=离线安装，供测试；curl|sh 管道形态无参数）
# 行为契约：装 → 拉起 → readme（输出智能体说明书，动手前先读）
# 授权两拍：本次换装将弹管理员授权窗时，首跑只输出预告（needs_user_auth=yes，退出码 5）不弹窗，
# agent 转达用户后 5 分钟内重跑同命令才真正执行——详见下方「两拍授权预告」段。
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
INSTALL_STATUS=""
if pgrep -xq "ClamAwake" >/dev/null 2>&1 && [ -x "$BIN" ]; then
  INSTALL_STATUS=$("$BIN" status 2>/dev/null || true)
  case "$INSTALL_STATUS" in *protecting=yes*) WAS_PROTECTING=1 ;; esac
fi

# 两拍授权预告（goal-1e0095）：本次装/换装会不会弹管理员授权窗——quit 撤闸（电池档 + 闸在）、
# 换装后恢复补闸（电池档 + 闸不在）。会弹：第一拍只发预告、退出 5，agent 转达用户后重跑；
# 5 分钟内重跑（标记新鲜）= 第二拍，跳过检测直接执行。标记与 app 共用 UserDefaults domain。
auth_announced_recently() {
  at=$(defaults read com.clamawake.app authAnnouncedAt 2>/dev/null || echo 0)
  case "$at" in ''|*[!0-9.]*) return 1 ;; esac
  act=$(defaults read com.clamawake.app authAnnouncedAction 2>/dev/null || true)
  case "$act" in ''|start) ;; *) return 1 ;; esac
  awk -v a="$at" -v n="$(date +%s)" 'BEGIN { d = n - a; exit !(d >= 0 && d <= 300) }'
}

NEEDS_AUTH=0
# quit 撤闸要授权：退出总会撤闸，不分档（插电档而闸仍在=异常残留，quit 一样弹）
case "$INSTALL_STATUS" in *sleep_guard=on*) NEEDS_AUTH=1 ;; esac
# 换装后恢复保活补闸要授权：只有电池档依赖闸
case "$INSTALL_STATUS" in
  *mode=battery*)
    if [ "$WAS_PROTECTING" = "1" ]; then
      case "$INSTALL_STATUS" in *sleep_guard=off*) NEEDS_AUTH=1 ;; esac
    fi
    ;;
esac

if [ "$NEEDS_AUTH" = "1" ] && ! auth_announced_recently; then
  printf '%s\n' "needs_user_auth=yes"
  printf '%s\n' "prompt_text=即将弹出管理员授权窗：请先告知用户「输密码以完成换装（会调整系统级睡眠设置，可能弹一到两次）」，用户准备好后重新执行本命令"
  # -int 而非 -float：defaults read 对 float 返回科学计数法（1.79e+09），下方数字校验拒收，
  # 第二拍永远读不到新鲜标记、无限退回第一拍（2026-11-23 实弹实证）。两侧（shell/CLI）统一写 int。
  defaults write com.clamawake.app authAnnouncedAt -int "$(date +%s)"
  defaults write com.clamawake.app authAnnouncedAction start
  exit 5
fi

# app 在跑时先优雅退出再覆盖（运行中覆盖会坏；quit 会连同保活一起收掉——电池档闸在时退出会弹一次
# 管理员授权，请在弹出的窗口输入密码。最多等 30s：等不到就退回 SIGTERM，不让脚本挂死在授权窗上。
# 这一步的弹窗已在首拍预告里转达过）
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

# 预告标记用毕即清：第二拍的重跑别把「已预告」留给下一个没预告的动作
defaults delete com.clamawake.app authAnnouncedAt 2>/dev/null || true
defaults delete com.clamawake.app authAnnouncedAction 2>/dev/null || true

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
