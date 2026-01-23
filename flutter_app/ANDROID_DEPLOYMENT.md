# InduSpect AI - Android 部署指南

## 目前狀態

Flutter 應用已完成 Web 平台測試，所有核心功能正常運作：
- ✅ 相機拍照與圖片上傳
- ✅ AI 設備檢測（快速分析 & 詳細步驟）
- ✅ 繁體中文 AI 回應
- ✅ 跨平台圖片顯示
- ✅ 檢測報告生成

## Android 配置完成項目

### 1. 權限配置 (AndroidManifest.xml)
已配置以下權限：
- `CAMERA` - 相機拍照
- `READ_EXTERNAL_STORAGE` - 讀取圖片
- `WRITE_EXTERNAL_STORAGE` - 儲存圖片（Android 9 以下）
- `INTERNET` - Gemini API 呼叫
- `ACCESS_NETWORK_STATE` - 網路狀態檢查

### 2. Gradle 配置
- `minSdkVersion: 21` (Android 5.0+)
- `targetSdkVersion: 34` (Android 14)
- `compileSdkVersion: 34`
- 支援 multiDex

### 3. Kotlin Activity
已創建 MainActivity.kt，使用 Flutter 嵌入式 Activity

## Android 部署步驟

### 前置需求
1. **安裝 Flutter SDK**
   ```bash
   # 下載 Flutter SDK
   git clone https://github.com/flutter/flutter.git -b stable
   export PATH="$PATH:`pwd`/flutter/bin"

   # 驗證安裝
   flutter doctor
   ```

2. **安裝 Android Studio**
   - 下載：https://developer.android.com/studio
   - 安裝 Android SDK (API 34)
   - 安裝 Android SDK Command-line Tools

3. **配置 Flutter**
   ```bash
   flutter doctor --android-licenses  # 接受所有授權
   flutter config --android-sdk /path/to/android/sdk
   ```

### 編譯 Android APK

#### 方法 1: Debug APK (測試用)
```bash
cd flutter_app
flutter build apk --debug
```
- 輸出位置：`build/app/outputs/flutter-apk/app-debug.apk`
- 檔案大小：約 40-50 MB
- 包含除錯資訊

#### 方法 2: Release APK (正式版)
```bash
cd flutter_app
flutter build apk --release
```
- 輸出位置：`build/app/outputs/flutter-apk/app-release.apk`
- 檔案大小：約 20-30 MB
- 已優化和混淆

#### 方法 3: App Bundle (Google Play 上架)
```bash
cd flutter_app
flutter build appbundle --release
```
- 輸出位置：`build/app/outputs/bundle/release/app-release.aab`
- 用於 Google Play 商店上架

### 安裝到實體設備

#### 透過 USB 連接
```bash
# 1. 在手機開啟 USB 偵錯模式
#    設定 → 關於手機 → 點擊版本號碼 7 次 → 開發人員選項 → USB 偵錯

# 2. 連接手機到電腦，確認設備已連接
flutter devices

# 3. 直接安裝並執行
flutter run --release

# 或安裝已編譯的 APK
adb install build/app/outputs/flutter-apk/app-release.apk
```

#### 手動安裝
```bash
# 1. 將 APK 複製到手機
# 2. 在手機上開啟「檔案管理」
# 3. 點擊 APK 檔案進行安裝
# 4. 允許「安裝未知來源的應用程式」
```

### 使用 Android 模擬器

```bash
# 1. 在 Android Studio 創建模擬器
#    Tools → Device Manager → Create Device
#    建議：Pixel 6 with API 34

# 2. 啟動模擬器
flutter emulators --launch <emulator_id>

# 3. 執行應用
flutter run
```

## 測試檢查清單

在 Android 設備上測試以下功能：

- [ ] **應用啟動**：正常開啟無閃退
- [ ] **相機權限**：第一次使用時請求相機權限
- [ ] **快速分析**：
  - [ ] 點擊相機圖標拍照
  - [ ] AI 分析返回繁體中文結果
  - [ ] 結果包含：設備類型、狀況評估、建議
- [ ] **詳細步驟**：
  - [ ] 上傳檢查清單照片
  - [ ] AI 正確識別檢查項目
  - [ ] 為每個項目拍照
  - [ ] 照片正確顯示（無錯誤）
- [ ] **報告生成**：
  - [ ] 完成檢測後生成總結報告
  - [ ] 報告內容完整（所有項目 + 照片）
- [ ] **儲存/讀取**：
  - [ ] 檢測記錄正確保存
  - [ ] 切換到歷史記錄頁面可查看
- [ ] **網路連接**：
  - [ ] Gemini API 正常呼叫
  - [ ] 處理網路錯誤提示

## 常見問題排除

### 1. Gradle 編譯錯誤
```bash
# 清理並重新編譯
cd flutter_app/android
./gradlew clean
cd ..
flutter clean
flutter pub get
flutter build apk
```

### 2. 權限被拒絕
- 檢查手機設定 → 應用程式 → InduSpect AI → 權限
- 確保已授予相機和儲存權限

### 3. 找不到 Flutter SDK
```bash
# 設定環境變數
export FLUTTER_ROOT=/path/to/flutter
export PATH="$FLUTTER_ROOT/bin:$PATH"
```

### 4. Gemini API 呼叫失敗
- 檢查網路連接
- 確認 API Key 配置正確（在 `lib/utils/constants.dart`）
- 查看 logcat：`flutter logs`

### 5. 圖片無法顯示
- 確認使用的是 `CrossPlatformImage` 組件
- 檢查儲存權限是否授予

## App Icon 配置

目前使用預設圖標。如需自訂：

1. 準備 1024x1024 PNG 圖片
2. 使用線上工具生成各尺寸圖標：
   - https://appicon.co/
   - https://easyappicon.com/
3. 將生成的圖標放到對應目錄：
   - `android/app/src/main/res/mipmap-hdpi/ic_launcher.png` (72x72)
   - `android/app/src/main/res/mipmap-mdpi/ic_launcher.png` (48x48)
   - `android/app/src/main/res/mipmap-xhdpi/ic_launcher.png` (96x96)
   - `android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png` (144x144)
   - `android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png` (192x192)

## 版本更新

修改版本號：`flutter_app/pubspec.yaml`
```yaml
version: 1.0.0+1
#        ^^^^^ 版本名稱
#             ^ 版本代碼
```

重新編譯：
```bash
flutter build apk --release
```

## 後續功能開發計劃

### 第二階段功能 (未來)
- [ ] 測量尺寸工具（互動式畫線測量）
- [ ] 語言切換（中文/英文）
- [ ] 離線模式（本地緩存）
- [ ] PDF 報告匯出
- [ ] 雲端同步

### iOS 部署 (選擇性)
需要：
- macOS 系統
- Xcode
- Apple Developer 帳號

```bash
flutter build ios --release
```

## 支援資訊

- Flutter 文檔：https://flutter.dev/docs
- Android 開發文檔：https://developer.android.com/
- 專案 GitHub：https://github.com/dofliu/InduSpect

---

建立日期：2025-11-03
版本：1.0.0
