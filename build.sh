#!/bin/bash
# 编译 Tiborom 像素风菜单栏 App（只需要 Xcode Command Line Tools，不需要 Xcode 本体）
# 产物为通用二进制：Apple Silicon（arm64）+ Intel（x86_64）
set -euo pipefail
cd "$(dirname "$0")"

APP="Build/Tiborom.app"
OBJ="Build/obj"
rm -rf Build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OBJ/arm64" "$OBJ/x86_64"

if [ ! -f "Resources/AppIcon.icns" ]; then
  echo "→ 生成 App 图标"
  swift Scripts/make-icon.swift
fi

echo "→ 编译 arm64"
swiftc -O -target arm64-apple-macosx13.0 Sources/*.swift -o "$OBJ/arm64/Tiborom"

echo "→ 编译 x86_64"
swiftc -O -target x86_64-apple-macosx13.0 Sources/*.swift -o "$OBJ/x86_64/Tiborom"

echo "→ 合并通用二进制"
lipo -create -output "$APP/Contents/MacOS/Tiborom" \
  "$OBJ/arm64/Tiborom" "$OBJ/x86_64/Tiborom"

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/pomo-chime.mp3 "$APP/Contents/Resources/pomo-chime.mp3"
cp Resources/click.wav "$APP/Contents/Resources/click.wav"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP" 2>/dev/null || true

echo "✅ 构建完成: $APP ($(lipo -archs "$APP/Contents/MacOS/Tiborom"))"
