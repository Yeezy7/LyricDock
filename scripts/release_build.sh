#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/LyricDock.xcodeproj"
SCHEME="${SCHEME:-LyricDock}"
CONFIGURATION="${CONFIGURATION:-Release}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/build/release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$OUTPUT_DIR/DerivedData}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$OUTPUT_DIR/LyricDock.xcarchive}"
EXPORT_DIR="${EXPORT_DIR:-$OUTPUT_DIR/export}"
EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-}"
TEAM_ID="${TEAM_ID:-}"

mkdir -p "$OUTPUT_DIR"

build_settings="$(
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -showBuildSettings 2>/dev/null
)"

marketing_version="${MARKETING_VERSION:-$(printf '%s\n' "$build_settings" | awk -F' = ' '/MARKETING_VERSION/ { print $2; exit }')}"
build_number="${BUILD_NUMBER:-$(printf '%s\n' "$build_settings" | awk -F' = ' '/CURRENT_PROJECT_VERSION/ { print $2; exit }')}"
artifact_name="LyricDock-${marketing_version:-1.0}-${build_number:-1}"

echo "==> 输出目录: $OUTPUT_DIR"
echo "==> 版本: ${marketing_version:-1.0} (${build_number:-1})"

if [[ -n "$EXPORT_OPTIONS_PLIST" ]]; then
  echo "==> 执行签名归档导出"

  archive_args=(
    -project "$PROJECT_PATH"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -archivePath "$ARCHIVE_PATH"
    -derivedDataPath "$DERIVED_DATA_PATH"
    archive
  )

  if [[ -n "$TEAM_ID" ]]; then
    archive_args+=("DEVELOPMENT_TEAM=$TEAM_ID")
  fi

  xcodebuild "${archive_args[@]}"

  rm -rf "$EXPORT_DIR"
  mkdir -p "$EXPORT_DIR"

  export_args=(
    -exportArchive
    -archivePath "$ARCHIVE_PATH"
    -exportPath "$EXPORT_DIR"
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"
  )

  if [[ -n "$TEAM_ID" ]]; then
    export_args+=("DEVELOPMENT_TEAM=$TEAM_ID")
  fi

  xcodebuild "${export_args[@]}"

  exported_app="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.app' -print -quit)"
  if [[ -z "$exported_app" ]]; then
    echo "未在 $EXPORT_DIR 找到导出的 .app" >&2
    exit 1
  fi

  zip_path="$OUTPUT_DIR/${artifact_name}.zip"
  rm -f "$zip_path"
  ditto -c -k --keepParent "$exported_app" "$zip_path"

  echo "==> 归档完成:"
  echo "    Archive: $ARCHIVE_PATH"
  echo "    Export : $exported_app"
  echo "    Zip    : $zip_path"
  exit 0
fi

echo "==> 执行本地 Release 构建（不签名）"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build

built_app="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/LyricDock.app"
if [[ ! -d "$built_app" ]]; then
  echo "未找到构建产物: $built_app" >&2
  exit 1
fi

release_app="$OUTPUT_DIR/LyricDock.app"
zip_path="$OUTPUT_DIR/${artifact_name}-unsigned.zip"

rm -rf "$release_app"
rm -f "$zip_path"

ditto "$built_app" "$release_app"
ditto -c -k --keepParent "$release_app" "$zip_path"

echo "==> 本地发布包已生成:"
echo "    App: $release_app"
echo "    Zip: $zip_path"
echo
echo "提示:"
echo "  - 如需正式分发，请配置签名后重新运行。"
echo "  - 示例: TEAM_ID=YOURTEAMID EXPORT_OPTIONS_PLIST=$ROOT_DIR/scripts/ExportOptions-DeveloperID.plist ./scripts/release_build.sh"
