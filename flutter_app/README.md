# InduSpect AI — Flutter 行動應用

工業設備智慧巡檢 App。拍照 → AI 讀值 → 台灣法規自動判定 → 回填原始定檢表。

> **最後更新**：2026-08-31
> 架構細節、DB schema、測試清單與完整變更紀錄見 **[DEVELOPMENT.md](DEVELOPMENT.md)**
> 專案總覽與使用說明見 [../README.md](../README.md)

| 項目 | 現況 |
|------|------|
| 版本 | `1.0.0+1`（`pubspec.yaml`） |
| Flutter / Dart | 3.47 / 3.13 |
| 測試 | **137 tests** 全綠 |
| 靜態分析 | 0 error / 0 warning |
| 平台 | Android（主要）、Web / Windows（開發用）；**iOS 未建置** |

---

## 兩個核心功能

| 功能 | 進入點 |
|------|--------|
| **完整檢測 Pipeline**（5 步驟） | `screens/form_inspection_screen.dart` |
| **歷史紀錄**（GPS / 搜尋 / 重新分享） | `screens/unified_history_screen.dart` |

其餘畫面（快速分析、範本系統、一站式流程等）已停用但仍在 repo 中，**沒有從 `main.dart` 或主流程可達**。

---

## 三層 AI 架構

```
拍照
 ├─ 品質閘門   image_quality_service.dart   模糊/曝光/反光（純本機，離線可用）
 ├─ Tier 1a    meter_ocr_service.dart       ML Kit 離線 OCR
 │             ocr_reading_parser.dart      讀值解析（誤讀修正、雜訊過濾）
 ├─ Tier 0     standards_engine.dart        56 條法規標準離線判定
 └─ Tier 2     gemini_service.dart          雲端精判 + AI 摘要報告
```

呼叫 Gemini 前先經 `connectivity_service.dart` 的**可達性探測**（`/health`，逾時 3 秒、快取 10 秒）；不通直接走 Tier 1a，不空等 60 秒逾時。

---

## 開發環境

```bash
flutter pub get
cp .env.example .env      # GEMINI_API_KEY 必填；BACKEND_API_URL 實機必填
flutter run

flutter analyze --no-pub  # 應為 0 error / 0 warning
flutter test              # 137 tests
```

### `.env` 設定
| 變數 | 說明 |
|------|------|
| `GEMINI_API_KEY` | 必填。使用者亦可在設定頁自行輸入（存 SharedPreferences） |
| `BACKEND_API_URL` | **實機必填**。未設定會退回 `http://localhost:8000`，手機上必然連不到 |
| `BACKEND_API_KEY` | 後端有設 `BACKEND_API_KEY` 時必填，隨請求以 `X-API-Key` 送出 |
| `GEMINI_FLASH_MODEL` / `GEMINI_PRO_MODEL` | 選填，覆寫模型 ID（模型下架時免改版） |

> `.env` 被宣告為 asset 且已 gitignore；CI 會 `touch .env` 讓 asset bundle 建置成功。

### Release 建置
需先建立簽署金鑰（`android/key.properties`），步驟見 **[ANDROID_DEPLOYMENT.md](ANDROID_DEPLOYMENT.md)**。
未設定時會退回 debug 簽署並印出警告——**該 APK 不可發布**。

---

## 目錄結構

```
lib/
├── models/          form_inspection_record.dart（SQLite v4 核心 model）等
├── screens/         dashboard / form_inspection / unified_history / guided_capture / settings / guide
├── services/        standards_engine · ocr_reading_parser · meter_ocr_service
│                    image_quality_service · connectivity_service · database_service
│                    gemini_service · backend_api_service · share_queue_service · location_service
├── providers/       settings / inspection / app_state
├── widgets/         image_quality_dialog 等
└── utils/           constants.dart（模型 ID 預設值、色彩、尺寸）

assets/standards/inspection_standards.json   ← 56 條法規標準（由後端匯出，勿手改）
test/                                        ← 137 tests
```

---

## 常見注意事項

- **標準資料勿手改**：`assets/standards/inspection_standards.json` 由 `backend/scripts/export_standards.py` 產生，後端有同步守門測試。
- **DB migration**：目前 SQLite v4。新增欄位務必處理既有使用者升級路徑，並補 migration 測試（見 `test/database_migration_test.dart`）。
- **Web 平台限制**：`FormInspectionScreen` 在 Web 上會因 `sqflite` / `path_provider` 無 Web 實作而初始化失敗。Web 僅供開發與擷圖，不影響 Android。
- **品質閘門門檻**：`image_quality_service.dart` 的預設門檻以合成影像校準，**上實機後需以現場實拍照片重新校準**。

---

## 相關文件

- [DEVELOPMENT.md](DEVELOPMENT.md) — 架構、DB schema、測試清單、變更紀錄
- [ANDROID_DEPLOYMENT.md](ANDROID_DEPLOYMENT.md) — 建置與 Release 簽署
- [../LAUNCH_PLAN.md](../LAUNCH_PLAN.md) — 產品化評估與 90 天計畫
- [../CLAUDE.md](../CLAUDE.md) — 開發規則
