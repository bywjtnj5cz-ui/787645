#!/usr/bin/env bash
# =============================================================================
# ARWorld 一键构建脚本 (需要 macOS + Xcode 15+)
# 用法:
#   bash build.sh           # 构建 Release .app (模拟器)
#   bash build.sh device    # 构建并导出 .ipa (真机, 需签名)
#   bash build.sh archive   # xcodebuild archive 生成 xcarchive
# =============================================================================
set -euo pipefail

PROJECT="ARWorld.xcodeproj"
SCHEME="ARWorld"
BUNDLE_ID="com.arworld.app"
BUILD_DIR="./build"
CONFIG="${1:-release}"
MODE="${2:-sim}"

case "$CONFIG" in
  debug|Debug) CFG="Debug" ;;
  *)           CFG="Release" ;;
esac

echo "==> Checking Xcode..."
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "ERROR: xcodebuild not found. 请安装 Xcode 并在首次启动时完成 license 确认。"
  exit 1
fi
XCODE_VER=$(xcodebuild -version | head -1)
echo "    $XCODE_VER"

echo "==> Project 根目录: $(pwd)"

case "$MODE" in
  sim|"")
    echo "==> Building $CFG for iOS Simulator..."
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CFG" \
      -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath "$BUILD_DIR" \
      CODE_SIGNING_ALLOWED=NO build
    echo
    echo "✅ 完成。产物位于:"
    find "$BUILD_DIR/Build/Products" -name "*.app" -maxdepth 3 2>/dev/null | head -1
    ;;
  device)
    echo "==> Building $CFG for iOS Device + Export IPA..."
    DEV_TEAM="${TEAM_ID:-}"
    if [ -z "$DEV_TEAM" ]; then
      echo "ERROR: 请设置环境变量 TEAM_ID (Apple Developer Team ID, 10 位字母数字)."
      echo "       例如: TEAM_ID=ABCDE12345 bash build.sh device"
      exit 1
    fi
    # 导出 plist
    EXP_PLIST="$BUILD_DIR/ExportOptions.plist"
    mkdir -p "$BUILD_DIR"
    cat > "$EXP_PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>development</string>
  <key>teamID</key><string>$DEV_TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>provisioningProfiles</key>
  <dict><key>$BUNDLE_ID</key><string>iOS Team Provisioning Profile: *</string></dict>
</dict>
</plist>
PLIST
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CFG" \
      -destination 'generic/platform=iOS' \
      -derivedDataPath "$BUILD_DIR" \
      CODE_SIGN_IDENTITY="Apple Development" \
      DEVELOPMENT_TEAM="$DEV_TEAM" \
      CODE_SIGN_STYLE=Automatic build
    echo
    echo "==> Archiving..."
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CFG" \
      -archivePath "$BUILD_DIR/ARWorld.xcarchive" \
      -derivedDataPath "$BUILD_DIR" \
      -destination 'generic/platform=iOS' \
      CODE_SIGN_IDENTITY="Apple Development" \
      DEVELOPMENT_TEAM="$DEV_TEAM" \
      CODE_SIGN_STYLE=Automatic archive
    echo
    echo "==> Exporting IPA..."
    xcodebuild -exportArchive \
      -archivePath "$BUILD_DIR/ARWorld.xcarchive" \
      -exportPath "$BUILD_DIR/ipa" \
      -exportOptionsPlist "$EXP_PLIST"
    echo
    echo "✅ 完成。IPA 位于:"
    ls -la "$BUILD_DIR/ipa/"*.ipa 2>/dev/null || echo "(未找到)"
    ;;
  archive)
    echo "==> Archiving..."
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CFG" \
      -archivePath "$BUILD_DIR/ARWorld.xcarchive" \
      -derivedDataPath "$BUILD_DIR" \
      CODE_SIGNING_ALLOWED=NO archive
    echo "✅ 完成。xcarchive 位于 $BUILD_DIR/ARWorld.xcarchive"
    ;;
  *)
    echo "Usage: $0 [debug|release] [sim|device|archive]"
    exit 1
    ;;
esac
