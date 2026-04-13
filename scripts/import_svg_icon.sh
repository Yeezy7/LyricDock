#!/bin/zsh
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "用法: ./scripts/import_svg_icon.sh /path/to/icon.svg" >&2
  exit 1
fi

SVG_PATH="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APPICON_DIR="${APPICON_DIR:-$ROOT_DIR/LyricDock/Assets.xcassets/AppIcon.appiconset}"
RENDER_DIR="${RENDER_DIR:-/tmp/LyricDockIconRender}"
MASTER_PNG="$RENDER_DIR/$(basename "$SVG_PATH").png"

if [[ ! -f "$SVG_PATH" ]]; then
  echo "未找到 SVG 文件: $SVG_PATH" >&2
  exit 1
fi

mkdir -p "$RENDER_DIR"

qlmanage -t -s 1024 -o "$RENDER_DIR" "$SVG_PATH" >/dev/null

if [[ ! -f "$MASTER_PNG" ]]; then
  echo "SVG 渲染失败，未生成母版 PNG: $MASTER_PNG" >&2
  exit 1
fi

generate_icon() {
  local target_file="$1"
  local pixels="$2"
  sips -s format png -z "$pixels" "$pixels" "$MASTER_PNG" --out "$APPICON_DIR/$target_file" >/dev/null
}

generate_icon "icon_16x16.png" 16
generate_icon "icon_16x16@2x.png" 32
generate_icon "icon_32x32.png" 32
generate_icon "icon_32x32@2x.png" 64
generate_icon "icon_128x128.png" 128
generate_icon "icon_128x128@2x.png" 256
generate_icon "icon_256x256.png" 256
generate_icon "icon_256x256@2x.png" 512
generate_icon "icon_512x512.png" 512
generate_icon "icon_512x512@2x.png" 1024

echo "==> 已更新 AppIcon:"
echo "    SVG : $SVG_PATH"
echo "    输出: $APPICON_DIR"
