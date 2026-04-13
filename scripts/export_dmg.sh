#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/build/release}"
APP_PATH="${APP_PATH:-$OUTPUT_DIR/LyricDock.app}"
DMG_ROOT="$OUTPUT_DIR/dmg-root"

build_settings="$(
  xcodebuild \
    -project "$ROOT_DIR/LyricDock.xcodeproj" \
    -scheme "${SCHEME:-LyricDock}" \
    -configuration "${CONFIGURATION:-Release}" \
    -showBuildSettings 2>/dev/null
)"

marketing_version="${MARKETING_VERSION:-$(printf '%s\n' "$build_settings" | awk -F' = ' '/MARKETING_VERSION/ { print $2; exit }')}"
build_number="${BUILD_NUMBER:-$(printf '%s\n' "$build_settings" | awk -F' = ' '/CURRENT_PROJECT_VERSION/ { print $2; exit }')}"
artifact_name="LyricDock-${marketing_version:-1.0}-${build_number:-1}"
dmg_path="$OUTPUT_DIR/${artifact_name}.dmg"

if [[ ! -d "$APP_PATH" ]]; then
  echo "==> 未找到 Release 应用，先执行 release_build.sh"
  "$ROOT_DIR/scripts/release_build.sh"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "未找到应用产物: $APP_PATH" >&2
  exit 1
fi

rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"
rm -f "$dmg_path"

ditto "$APP_PATH" "$DMG_ROOT/LyricDock.app"
ln -s /Applications "$DMG_ROOT/Applications"

hdiutil create \
  -volname "LyricDock" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$dmg_path"

rm -rf "$DMG_ROOT"

echo "==> DMG 已生成:"
echo "    $dmg_path"
