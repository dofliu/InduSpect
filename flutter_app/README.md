# InduSpect AI - Flutter 移動應用

> 這是 InduSpect AI 智慧巡檢系統的 Flutter 移動應用版本，支援 iOS 和 Android 雙平台。

## 📱 專案狀態

**當前版本**: v1.0.0
**開發階段**: Phase 1 - 基礎架構完成
**分支**: `claude/convert-to-mobile-app-*`

⚠️ **注意**: 這是一個獨立的 Flutter 項目，與 Web 版本（位於根目錄）並行開發。

## 🎯 功能特性

### ✅ 已實現功能

- **4 步驟智慧巡檢流程**
  - 步驟 1: 上傳定檢表，AI 自動提取檢查項目
  - 步驟 2: 引導式照片拍攝
  - 步驟 3: AI 分析結果審核與編輯
  - 步驟 4: 檢測記錄查看與報告生成

- **核心服務層**
  - Gemini AI 圖像分析服務
  - 本地持久化存儲（SharedPreferences + SQLite 預備）
  - 圖片壓縮和處理服務
  - 離線優先架構

- **狀態管理**
  - Provider 模式
  - 應用狀態和巡檢數據分離管理

- **用戶界面**
  - Material Design 3
  - 響應式佈局
  - 步驟指示器
  - 載入狀態反饋

### 🚧 待實現功能

- 圖片測量工具（CustomPaint 實現）
- 相機權限管理
- 網路狀態檢測
- 錯誤處理和重試機制
- 單元測試和整合測試
- iOS/Android 平台特定配置

## 🛠️ 技術棧

- **框架**: Flutter 3.x
- **語言**: Dart 3.2+
- **狀態管理**: Provider 6.1.0
- **AI 服務**: Google Generative AI (Gemini)
- **本地存儲**: SharedPreferences, SQLite (sqflite)
- **圖片處理**: image_picker, camera, image

完整依賴列表請查看 [`pubspec.yaml`](pubspec.yaml)

## 📋 環境要求

### 開發環境

- Flutter SDK >= 3.2.0
- Dart SDK >= 3.2.0
- Android Studio / Xcode（用於模擬器）
- VS Code + Flutter 擴展（推薦）

### API 密鑰

需要 Google Gemini API Key，獲取方式：
1. 訪問 [Google AI Studio](https://ai.google.dev/)
2. 創建 API Key
3. 添加到 `.env` 文件

## 🚀 快速開始

### 1. 安裝 Flutter

如果尚未安裝 Flutter，請訪問 [Flutter 官網](https://flutter.dev/docs/get-started/install) 按照您的操作系統安裝。

```bash
# 驗證安裝
flutter doctor
```

### 2. 克隆項目

```bash
git clone https://github.com/dofliu/InduSpect.git
cd InduSpect
git checkout claude/convert-to-mobile-app-*
cd flutter_app
```

### 3. 安裝依賴

```bash
flutter pub get
```

### 4. 配置環境變量

```bash
# 複製環境變量範例文件
cp .env.example .env

# 編輯 .env 文件，添加您的 Gemini API Key
# GEMINI_API_KEY=your_api_key_here
```

### 5. 運行應用

```bash
# 連接設備或啟動模擬器後

# Android
flutter run

# iOS (僅限 macOS)
flutter run -d ios

# 指定設備
flutter devices
flutter run -d <device_id>
```

### 6. 構建發布版本

```bash
# Android APK
flutter build apk --release

# Android App Bundle (推薦用於 Google Play)
flutter build appbundle --release

# iOS (需要 macOS 和 Xcode)
flutter build ios --release
```

## 📁 項目結構

```
flutter_app/
├── lib/
│   ├── main.dart                    # 應用入口
│   ├── config/                      # 配置文件
│   ├── models/                      # 數據模型
│   │   ├── inspection_item.dart
│   │   ├── analysis_result.dart
│   │   ├── inspection_record.dart
│   │   └── measurement.dart
│   ├── services/                    # 業務邏輯服務
│   │   ├── gemini_service.dart     # AI 分析
│   │   ├── storage_service.dart    # 本地存儲
│   │   └── image_service.dart      # 圖片處理
│   ├── providers/                   # 狀態管理
│   │   ├── app_state_provider.dart
│   │   └── inspection_provider.dart
│   ├── screens/                     # 頁面
│   │   ├── home_screen.dart
│   │   ├── step1_upload_checklist.dart
│   │   ├── step2_capture_photos.dart
│   │   ├── step3_review_results.dart
│   │   ├── step4_records_report.dart
│   │   └── quick_analysis_screen.dart
│   ├── widgets/                     # 可複用組件
│   │   ├── stepper_widget.dart
│   │   └── common/
│   └── utils/                       # 工具和常量
│       └── constants.dart
├── assets/                          # 資源文件
├── test/                            # 單元測試
├── pubspec.yaml                     # 依賴配置
└── README.md                        # 本文件
```

## 🔑 關鍵實現說明

### AI 分析服務

使用 Google Gemini API 進行圖像分析，遵循 `aimodel.md` 中定義的 Prompt 工程策略：

- **gemini-2.0-flash-exp**: 用於快速圖像分析
- **gemini-2.5-pro**: 用於高質量報告生成

示例：
```dart
final result = await GeminiService().analyzeInspectionPhoto(
  itemId: item.id,
  itemDescription: item.description,
  imageBytes: imageBytes,
  photoPath: photoPath,
);
```

### 本地存儲

- **SharedPreferences**: 用於輕量級鍵值對存儲
- **SQLite (計劃中)**: 用於結構化數據和大容量存儲

```dart
await StorageService().saveInspectionItems(items);
final items = StorageService().getInspectionItems();
```

### 狀態管理

使用 Provider 模式進行狀態管理：

```dart
// 讀取狀態
final inspection = context.watch<InspectionProvider>();

// 調用方法
context.read<InspectionProvider>().analyzeAllPhotos();
```

## 🧪 測試

```bash
# 運行所有測試
flutter test

# 運行特定測試文件
flutter test test/services/gemini_service_test.dart

# 生成覆蓋率報告
flutter test --coverage
```

## 📱 平台配置

### Android 配置

編輯 `android/app/src/main/AndroidManifest.xml` 添加權限：

```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />
```

### iOS 配置

編輯 `ios/Runner/Info.plist` 添加相機權限描述：

```xml
<key>NSCameraUsageDescription</key>
<string>需要相機權限以拍攝巡檢照片</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>需要相冊權限以選擇照片</string>
```

## 🐛 故障排除

### 常見問題

1. **Gemini API 調用失敗**
   - 檢查 `.env` 文件中的 API Key 是否正確
   - 確認網路連接正常
   - 查看 API 使用配額

2. **相機無法啟動**
   - 確認已授予相機權限
   - 檢查設備是否支持相機
   - 查看平台配置文件

3. **圖片無法保存**
   - 檢查存儲權限
   - 確認應用目錄可寫

4. **依賴安裝失敗**
   ```bash
   flutter clean
   flutter pub get
   ```

## 📚 相關文檔

- [Flutter Migration Plan](../FLUTTER_MIGRATION_PLAN.md) - 完整遷移計劃
- [AI Model Integration](../aimodel.md) - AI 模型整合規範
- [Architecture Design](../arch.md) - 系統架構設計
- [Web Version README](../README.md) - Web 版本文檔

## 🤝 與 Web 版本的關係

- **獨立開發**: Flutter 版本獨立於 Web 版本
- **功能同步**: 盡可能保持功能一致
- **共享文檔**: 共享 `aimodel.md`, `prj.md` 等設計文檔
- **分支管理**: Web 版本在 `main`, Flutter 版本在 `claude/convert-to-mobile-app-*`

## 📝 開發指南

### 添加新功能

1. 在 `models/` 中定義數據模型
2. 在 `services/` 中實現業務邏輯
3. 在 `providers/` 中添加狀態管理
4. 在 `screens/` 中創建 UI
5. 在 `widgets/` 中提取可複用組件

### 代碼風格

遵循 Flutter 官方代碼風格，使用 `flutter_lints` 進行檢查：

```bash
flutter analyze
```

### Git 工作流

```bash
# 確保在正確的分支
git checkout claude/convert-to-mobile-app-*

# 提交更改
git add .
git commit -m "feat: description"
git push origin claude/convert-to-mobile-app-*
```

## 📄 授權

本專案使用與主專案相同的授權協議。

## 👥 貢獻

歡迎提交 Issue 和 Pull Request！

---

**開發者**: Claude (Anthropic AI)
**專案負責人**: dofliu
**最後更新**: 2025-11-03
