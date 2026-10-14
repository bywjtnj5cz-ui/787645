#!/bin/bash
# ARWorld IPA 构建脚本 (复用 ZakaFilza 构建管道思路, 适配 ARWorld 工程)
# 用法:
#   bash Scripts/build-ipa.sh sim                          # 编模拟器版（仅验证编译）
#   bash Scripts/build-ipa.sh unsigned                     # 出未签名 IPA（推荐，配合 xsign 签名）
#   bash Scripts/build-ipa.sh unsigned --bundle com.abc.arworld --marketing 1.0.1
#   bash Scripts/build-ipa.sh ipa ABCDE12345               # 出已签名 IPA（需 Team ID）
#   bash Scripts/build-ipa.sh archive                      # 仅出 .xcarchive
#   bash Scripts/build-ipa.sh unsigned --clean             # 先清再编
#
# 签名方式（推荐 xsign）:
#   1. bash Scripts/build-ipa.sh unsigned
#   2. xsign -k cert.p12 -p 密码 -m profile.mobileprovision \
#            -b com.arworld.app -o ARWorld_signed.ipa build/ARWorld.ipa

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="ARWorld"
SCHEME="ARWorld"
BUILD_DIR="$ROOT/build"
IPA_PATH="$BUILD_DIR/${PROJECT}.ipa"
# ARWorld 无 MHA 旁路要求, 默认包名可自由修改
BUNDLE_ID="com.arworld.app"
MARKETING_VERSION="1.0"
CLEAN=0

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[*]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err() { echo -e "${RED}[✗]${NC} $1"; }

# 解析参数
MODE=""
TEAM_ID=""
args=("$@")

for i in "${!args[@]}"; do
    case "${args[$i]}" in
        sim|unsigned|ipa|archive)
            MODE="${args[$i]}"
            if [ "$MODE" == "ipa" ]; then
                TEAM_ID="${args[$((i+1))]}"
                if [ -z "$TEAM_ID" ]; then
                    err "ipa 模式必须提供 TEAM_ID，例如: bash build-ipa.sh ipa ABCDE12345"
                    exit 1
                fi
            fi
            ;;
        --bundle) BUNDLE_ID="${args[$((i+1))]}" ;;
        --marketing) MARKETING_VERSION="${args[$((i+1))]}" ;;
        --clean) CLEAN=1 ;;
    esac
done

if [ -z "$MODE" ]; then
    echo "用法: bash Scripts/build-ipa.sh <sim|unsigned|ipa TEAM_ID|archive> [--bundle ID] [--marketing VER] [--clean]"
    exit 1
fi

cd "$ROOT"

# 确保工程存在
if [ ! -d "$PROJECT.xcodeproj" ]; then
    log "工程文件不存在，正在生成..."
    python3 Scripts/gen_xcodeproj.py
fi

mkdir -p "$BUILD_DIR"

# 清理
if [ $CLEAN -eq 1 ]; then
    log "清理构建缓存..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
fi

# 通用构建参数
BUILD_SETTINGS=(
    -project "$PROJECT.xcodeproj"
    -scheme "$SCHEME"
    -configuration Release
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
    MARKETING_VERSION="$MARKETING_VERSION"
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_IDENTITY=""
)

case "$MODE" in
    sim)
        log "编译模拟器版（验证编译）..."
        xcodebuild "${BUILD_SETTINGS[@]}" \
            -sdk iphonesimulator \
            -destination 'generic/platform=iOS Simulator' \
            build 2>&1 | tee "$BUILD_DIR/build.log"
        log "编译完成（模拟器版，未出 IPA）"
        ;;

    unsigned)
        log "编译未签名 IPA..."
        ARCHIVE_PATH="$BUILD_DIR/${PROJECT}.xcarchive"
        xcodebuild "${BUILD_SETTINGS[@]}" \
            -sdk iphoneos \
            -destination 'generic/platform=iOS' \
            -archivePath "$ARCHIVE_PATH" \
            archive 2>&1 | tee "$BUILD_DIR/archive.log"

        # 从 xcarchive 提取 .app 并打包成 IPA
        APP_PATH="$ARCHIVE_PATH/Products/Applications/${PROJECT}.app"
        if [ ! -d "$APP_PATH" ]; then
            err "编译失败: 找不到 .app"
            tail -30 "$BUILD_DIR/archive.log" > "$BUILD_DIR/编译报错.txt"
            exit 1
        fi

        log "打包 IPA..."
        PAYLOAD_DIR="$BUILD_DIR/Payload"
        rm -rf "$PAYLOAD_DIR"
        mkdir -p "$PAYLOAD_DIR"
        cp -R "$APP_PATH" "$PAYLOAD_DIR/"

        # 移除签名相关（确保未签名）
        rm -rf "$PAYLOAD_DIR/${PROJECT}.app/_CodeSignature"
        rm -f "$PAYLOAD_DIR/${PROJECT}.app/embedded.mobileprovision"

        cd "$BUILD_DIR"
        rm -f "$IPA_PATH"
        zip -qr "$IPA_PATH" Payload
        cd "$ROOT"

        log "未签名 IPA 已生成: $IPA_PATH"
        du -h "$IPA_PATH"
        ;;

    ipa)
        log "编译已签名 IPA (Team ID: $TEAM_ID)..."
        ARCHIVE_PATH="$BUILD_DIR/${PROJECT}.xcarchive"
        xcodebuild \
            -project "$PROJECT.xcodeproj" \
            -scheme "$SCHEME" \
            -configuration Release \
            -sdk iphoneos \
            -destination 'generic/platform=iOS' \
            -archivePath "$ARCHIVE_PATH" \
            archive \
            PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
            MARKETING_VERSION="$MARKETING_VERSION" \
            DEVELOPMENT_TEAM="$TEAM_ID" \
            CODE_SIGN_STYLE=Automatic \
            2>&1 | tee "$BUILD_DIR/archive.log"

        log "导出 IPA..."
        EXPORT_PLIST="$BUILD_DIR/export.plist"
        cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
</dict>
</plist>
PLIST

        xcodebuild \
            -exportArchive \
            -archivePath "$ARCHIVE_PATH" \
            -exportPath "$BUILD_DIR" \
            -exportOptionsPlist "$EXPORT_PLIST" \
            2>&1 | tee "$BUILD_DIR/export.log"

        IPA_FILE=$(ls "$BUILD_DIR"/*.ipa 2>/dev/null | head -1)
        if [ -n "$IPA_FILE" ]; then
            log "已签名 IPA 已生成: $IPA_FILE"
            du -h "$IPA_FILE"
        else
            err "导出失败，查看 $BUILD_DIR/export.log"
        fi
        ;;

    archive)
        log "编译 .xcarchive..."
        ARCHIVE_PATH="$BUILD_DIR/${PROJECT}.xcarchive"
        xcodebuild "${BUILD_SETTINGS[@]}" \
            -sdk iphoneos \
            -destination 'generic/platform=iOS' \
            -archivePath "$ARCHIVE_PATH" \
            archive 2>&1 | tee "$BUILD_DIR/archive.log"
        log "xcarchive 已生成: $ARCHIVE_PATH"
        ;;
esac

if [ $? -eq 0 ]; then
    log "构建成功!"
else
    err "构建失败，错误日志: $BUILD_DIR/编译报错.txt"
fi
