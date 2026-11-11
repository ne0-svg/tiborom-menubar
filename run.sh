#!/bin/bash
# 构建并启动 Tiborom
set -euo pipefail
cd "$(dirname "$0")"

./build.sh
pkill -x Tiborom 2>/dev/null || true
open "Build/Tiborom.app"
echo "🍅 已在菜单栏启动（看屏幕右上角）"
