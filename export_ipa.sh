#!/bin/bash
# FreeRouteAI IPA Export 脚本
# 用途：在 macOS 上完成 Xcode 构建 + Archive + IPA 导出

set -e
cd "$(dirname "$0")"

echo "=== FreeRouteAI IPA Export 脚本 ==="
echo "当前目录: $(pwd)"

# 1. 环境检查
command -v xcodebuild >/dev/null 2>&1 || { echo "❌ 请在 macOS 上安装 Xcode 后运行"; exit 1; }
echo "✅ Xcode: $(xcodebuild -version | head -1)"

# 2. 清理旧产物
rm -rf ~/Library/Developer/Xcode/Archives/$(date +%Y)/*.xcarchive 2>/dev/null || true
rm -rf build/Products 2>/dev/null || true

# 3. 下载依赖（如果有 Package）
if [ -f Package.swift ]; then
    echo "🔄 更新 Swift Package 依赖..."
    swift package resolve || true
fi

# 4. 选择 Xcode 版本（如果有多个）
XCODE_VERSION=${XCODE_VERSION:-$(xcodebuild -version | head -1 | awk '{print $2}')}
echo "📦 使用 Xcode $XCODE_VERSION"

# 5. 编译（无签名 Release）
SCHEME="FreeRouteAI"
CONFIGURATION="Release"
DESTINATION="platform=iOS Simulator,name=iPhone SE (3rd generation),OS=latest"

echo "🏗️ 编译中..."
xcodebuild clean build \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    -derivedDataPath build/DerivedData \
    -archivePath build/Products/FreeRouteAI.xcarchive \
    CLIPPED_BUILD_DIR=build/Products 2>&1 | tail -20

# 6. Archive 为 IPA 准备
xcodebuild -exportArchive \
    -archivePath build/Products/FreeRouteAI.xcarchive \
    -exportPath build/Products \
    -exportOptionsPlist ExportOptions.plist \
    -allowProvisioningUpdates 2>&1 | tail -20

# 7. 查找 IPA
IPA_PATH=$(find build/Products -name "*.ipa" -type f | head -1)
if [ -n "$IPA_PATH" ]; then
    echo "✅ IPA 导出成功: $IPA_PATH"
    echo "📱 安装前请确保使用正确证书签名"
    ls -la "$IPA_PATH"
else
    echo "⚠️ IPA 未生成，可能需要签名"
    echo "请检查 build/Products/ 目录"
fi

echo "=== 完成 ==="
