#!/bin/bash
# ClamAwake 菜单栏壳构建 — 一条命令产出 dist/ClamAwake.app（ad-hoc 免签）
#
# 做四件事：
#   1. SwiftPM release 编译菜单栏壳（shell/）
#   2. swiftc 编译引擎 vd-engine（只编译 src/ 源码，不改源码）
#   3. 组装 .app：主二进制 + Info.plist(LSUIElement) + 引擎二进制入 Resources
#   4. ad-hoc 签名（先签引擎助手，再签 app 整体）并自检
#
# 用法: scripts/build-app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/ClamAwake.app"
APP_VERSION="0.3.0"

echo "==> [1/4] 编译菜单栏壳（SwiftPM release）"
swift build --package-path "$ROOT/shell" -c release

echo "==> [2/4] 组装 .app 骨架"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/shell/.build/release/ClamAwake" "$APP/Contents/MacOS/ClamAwake"

echo "==> [3/4] 编译引擎 vd-engine 入 Resources（只编译 src/ 源码，不改源码）"
swiftc -O "$ROOT/src/vd-engine.swift" -o "$APP/Contents/Resources/vd-engine"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh-Hans</string>
	<key>CFBundleDisplayName</key>
	<string>ClamAwake</string>
	<key>CFBundleExecutable</key>
	<string>ClamAwake</string>
	<key>CFBundleIdentifier</key>
	<string>com.clamawake.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>ClamAwake</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${APP_VERSION}</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> [4/4] ad-hoc 签名并自检"
codesign --force --sign - "$APP/Contents/Resources/vd-engine"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "构建完成: $APP"
