# 📱 FreeRouteAI IPA Export 指南

## 快速开始（在 macOS 上）

```bash
cd /path/to/FreeRouteAI
./export_ipa.sh
```

---

## 第 1 步：准备环境

1. **安装 Xcode**（至少 15.0+）
   ```bash
   xcode-select -p  # 确认位置
   ```

2. **登录 Apple ID**
   ```bash
   xcrun altool --login
   ```

---

## 第 2 步：选择签名方式

### 方案 A：自动签名（推荐）
- 在 ExportOptions.plist 中 `signingStyle=automatic`
- Xcode 会自动下载开发证书

### 方案 B：手动签名
- 替换 `signingStyle=manual`
- 填写 `teamID`, `signingCertificate`, `provisioningProfilesSpecifier`

---

## 第 3 步：编译 & 导出

```bash
xcodebuild clean build \
  -scheme FreeRouteAI \
  -configuration Release \
  -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation),OS=17.0' \
  -derivedDataPath build/DerivedData

xcodebuild -exportArchive \
  -archivePath build/Products/FreeRouteAI.xcarchive \
  -exportPath build/Products \
  -exportOptionsPlist ExportOptions.plist
```

---

## 第 4 步：获取 IPA

```bash
# 未签名版
build/Products/FreeRouteAI-unsigned.ipa

# 开发证书版
build/Products/FreeRouteAI.ipa
```

---

## 第 5 步：安装到设备（任意方式）

### 方式 1：AltStore（免签名）
1. 打开 AltServer，安装 AltStore
2. 用 USB/WiFi 连接设备
3. 将 IPA 拖到 AltStore 窗口

### 方式 2：Sideloadly（免签名）
1. 下载 Sideloadly
2. 连接设备，拖入 IPA
3. 用 Apple ID 重签名

### 方式 3：TestFlight（需正式签名）
```bash
xcrun altool --upload-app -t ios -f build/Products/FreeRouteAI.ipa -u YOUR_EMAIL
```

---

## 常见问题

| 问题 | 解决方案 |
|------|----------|
| 证书失效 | Xcode → Preferences → Accounts → 下载新证书 |
| 模拟器运行慢 | 换台更好的 Mac，或在 iOS 17.0+ 模拟器 |
| 暴露敏感 API | 只在开发者控制台使用，勿上传公网 |
| 大文件卡住 | 关闭 Build Settings → Slice Native Dictionary |

---

## 产物说明

| 文件 | 用途 |
|------|------|
| FreeRouteAI.xcarchive | 归档中间产物，可恢复 |
| FreeRouteAI.ipa | 开发签名版，可安装到设备 |
| FreeRouteAI-unsigned.ipa | 未签名版，需自行重签名 |

