#!/bin/bash
# ClamAwake DMG 打包 — 产出 dist/ClamAwake.dmg（先跑 build-app.sh，免签 ad-hoc）
#
# 布局：暂存目录里放 ClamAwake.app + /Applications 符号链接，hdiutil 打成压缩 UDZO，
# 最后 hdiutil verify 校验。分发注意：ad-hoc 未经公证，对方 Mac 首次打开需绕过 Gatekeeper
# （右键打开，或系统设置里允许），见 README 与实施报告。
#
# 用法: scripts/make-dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/ClamAwake.app"
STAGE="$DIST/dmg-stage"
DMG="$DIST/ClamAwake.dmg"

"$ROOT/scripts/build-app.sh"

echo "==> 组装 DMG 暂存目录（App + Applications 快捷方式）"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> 生成 DMG"
rm -f "$DMG"
hdiutil create -volname "ClamAwake" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo "==> 校验 DMG"
hdiutil verify "$DMG"
echo "打包完成: $DMG"
