# Flutter App 開發指南

> **最後更新**: 2026-09-02

---

## 架構總覽

InduSpect 聚焦於 **2 個核心功能**：

1. **完整檢測 Pipeline**：上傳/匯入定檢表 → 引導拍照 → AI 辨識 → 自動回填原始格式文件 → AI 摘要報告 → PDF 申報報告 → 分享/傳送（離線暫存）
2. **歷史紀錄**：含 GPS 定位、可編輯標題、搜尋功能

```
┌─ DashboardScreen ──────────────────────────┐
│  ┌──────────────┐  ┌───────────────────┐   │
│  │ 開始檢測      │  │ 歷史紀錄           │   │
│  │ (FormInsp.)  │  │ (UnifiedHistory)  │   │
│  └──────┬───────┘  └───────┬───────────┘   │
│         │                  │               │
│  ┌──────▼──────────────────▼───────────┐   │
│  │       最近檢測 (SQLite FutureBuilder) │   │
│  └─────────────────────────────────────┘   │
└────────────────────────────────────────────┘
```

### 核心檔案結構

```
lib/
├── models/
│   ├── form_inspection_record.dart   # 表單檢測紀錄 (SQLite v3)
│   ├── inspection_template.dart      # 表單模板結構
│   ├── template_field.dart           # 模板欄位定義
│   └── analysis_result.dart          # AI 分析結果
├── screens/
│   ├── dashboard_screen.dart         # 主頁（2 入口 + 最近紀錄）
│   ├── form_inspection_screen.dart   # ★ 核心：完整檢測流程（5 步驟）
│   ├── unified_history_screen.dart   # 歷史紀錄（搜尋/編輯/刪除/重新分享）
│   └── guided_capture_screen.dart    # 批次引導式拍照
├── services/
│   ├── database_service.dart         # SQLite CRUD（v3：含 form_inspection_records）
│   ├── gemini_service.dart           # Gemini AI 分析 + 摘要報告
│   ├── location_service.dart         # GPS 一次性定位 + 反向地理編碼
│   ├── standards_engine.dart         # ★ Tier 0 離線法規判定引擎（56 條標準內嵌）
│   ├── ocr_reading_parser.dart       # Tier 1a 離線 OCR 讀值解析
│   ├── meter_ocr_service.dart        # ML Kit OCR adapter（條件導入）
│   ├── image_quality_service.dart    # ★ 拍照品質閘門（模糊/曝光/反光，純本機）
│   ├── pdf_report_service.dart       # ★ 申報用 PDF 報告（純 Dart 離線、內嵌繁中字型）
│   ├── share_queue_service.dart      # 離線分享佇列（上線自動處理）
│   ├── connectivity_service.dart     # 連線監聽 + /health 可達性探測
│   ├── file_save_service.dart        # 平台適應的檔案分享
│   ├── photo_service.dart            # 照片命名與管理
│   └── backend_api_service.dart      # 後端 API（表單回填）
└── providers/
    ├── settings_provider.dart        # API Key & 模型設定
    ├── inspection_provider.dart      # 檢測狀態管理
    └── app_state_provider.dart       # 應用狀態
```

---

## 資料庫 Schema (SQLite v3)

### form_inspection_records（核心表）

| 欄位 | 型別 | 說明 |
|------|------|------|
| id | INTEGER PK | 自增 |
| record_id | TEXT UNIQUE | UUID |
| title | TEXT | 可編輯標題 |
| source_file_name | TEXT | 來源檔名 |
| template_json | TEXT | 模板 JSON |
| filled_data | TEXT (JSON) | 已填入資料 |
| ai_results | TEXT (JSON) | AI 分析結果 |
| summary_report | TEXT | AI 摘要報告 |
| filled_document_path | TEXT | 匯出文件路徑 |
| status | TEXT | draft/completed/exported/shared |
| latitude | REAL | GPS 緯度 |
| longitude | REAL | GPS 經度 |
| location_name | TEXT | 反向地理編碼地名 |
| photo_paths | TEXT (JSON array) | 照片路徑列表 |
| created_at | TEXT (ISO8601) | 建立時間 |
| updated_at | TEXT (ISO8601) | 更新時間 |
| pending_share | INTEGER | 0/1 離線待分享 |

索引：`status`, `created_at`, `title`

### Migration 路徑
- v1 → v2：新增 `photo_sync_tasks` 表
- v2 → v3：新增 `form_inspection_records` 表

---

## FormInspectionScreen 流程

```
Step 1: uploadForm
  └─ 使用者選擇 .xlsx/.docx → 後端或本地分析結構
  └─ 產生 InspectionItemState 列表
  └─ 建立 draft 紀錄 + 背景 GPS 定位

Step 2: inspecting
  └─ 逐項拍照/選圖 → AI 分析 → 自動填入
  └─ ★ 一鍵自動檢測（引導拍照 → 批次 AI 分析 → 自動預覽）
  └─ 批次拍照（GuidedCaptureScreen）+ 智慧拍照提示
  └─ 或切換手動填寫模式
  └─ 批次分析時顯示即時進度覆蓋層
  └─ 每次 AI 完成自動存 SQLite

Step 3: preview
  └─ 統計摘要（完成/未完成/異常）
  └─ 逐項列表 + verdict

Step 4: exporting
  └─ 嘗試後端回填原始格式
  └─ 失敗時 fallback 為 JSON 摘要
  └─ 更新 status = exported

Step 5: done
  └─ 統計卡片
  └─ ★ AI 摘要報告自動產生（無需手動觸發）
  └─ ★ 匯出 PDF 報告（PdfReportService，純本機：判定/法規依據/AI 報告/照片附件）
  └─ 分享表單 / 分享報告
  └─ 離線時 → pendingShare=1，上線自動分享
```

---

## 離線分享架構

```
使用者點擊「分享」
  ├─ 有網路 → share_plus 系統分享 → status=shared
  └─ 無網路 → pendingShare=1 存 DB
                │
ShareQueueService (監聽 ConnectivityService)
  └─ 網路恢復 → 查 pendingShare=1 → 逐筆分享 → 標記完成
```

---

## 測試

### 執行測試

```bash
# 全部測試（widget_test.dart 已於 2026-08-31 修復，不再排除）
flutter test

# 單一檔案
flutter test test/form_inspection_record_test.dart
```

### 測試清單（155 tests）

| 檔案 | 數量 | 覆蓋範圍 |
|------|------|---------|
| `standards_engine_test.dart` | 24 | ★ Tier 0 離線判定引擎：單位正規化/換算、標準匹配、autoJudge、批次判定合約 |
| `pdf_report_service_test.dart` | 18 | ★ PDF 報告：合法 PDF/字型內嵌/照片嵌入與容錯/跨頁、fromRecord 重建（模板順序、判定優先序、值格式化、舊紀錄相容）、檔名 |
| `ocr_reading_parser_test.dart` | 21 | ★ Tier 1a OCR 讀值解析：誤讀修正、雜訊過濾、最佳讀值優先序 |
| `image_quality_service_test.dart` | 14 | ★ 拍照品質閘門：模糊/過暗/過曝/反光/無法解碼、門檻可調、跨解析度一致性（合成影像） |
| `connectivity_probe_test.dart` | 14 | ★ 可達性探測：介面×可達性決策矩陣、快取 TTL、forceProbe、逾時與例外 |
| `inspection_item_state_test.dart` | 22 | displayValue/verdict 邏輯（含法規標準判定優先序）、controller 生命週期 |
| `form_inspection_record_test.dart` | 21 | Model: toMap/fromMap 往返、null 處理、舊格式相容、standardJudgments 持久化、copyWith 深拷貝 |
| `database_service_test.dart` | 12 | DB CRUD: insert/update/delete、排序、limit、搜尋、GPS 持久化、UNIQUE 約束 |
| `photo_service_test.dart` | 6 | 照片命名格式、序號補零、截斷、特殊字元 |
| `database_migration_test.dart` | 2 | SQLite v3→v4 真實 onUpgrade 升級路徑（standard_judgments 欄位） |
| `widget_test.dart` | 1 | App smoke test（sqflite ffi + mock prefs + dotenv testLoad） |

### 測試依賴

- `sqflite_common_ffi`：讓 DB 測試在 Desktop/CI 上用 in-memory SQLite 執行

---

## 已關閉的 Issues（2026-04-16 全數修復）

| Issue | 標題 | Label | 修復摘要 |
|-------|------|-------|---------|
| #14 | 批次拍照並行 AI 分析需加 concurrency limit | performance | `_maxConcurrentAnalysis = 3`，用 `Future.any()` 控制 |
| #15 | 多張 AI 分析失敗時 SnackBar 連續彈出 | ux | 800ms debounce + 合併錯誤通知 |
| #16 | 歷史紀錄搜尋應改用 SQL-side search | performance | 改用 `searchFormRecords()` SQL LIKE + 300ms debounce |
| #17 | saveFormRecord 不應直接 mutate 傳入物件 | code-quality | 在 Map 上設定 `updated_at`，不 mutate 原物件 |
| #18 | 匯出檔案存於 temp 目錄，分享前應檢查存在性 | robustness | 改用 `getApplicationDocumentsDirectory()` + share_queue fallback |
| #19 | geocoding 在 Web 平台缺少防護 | robustness | 加入 `kIsWeb` 判斷跳過 geocoding |

### 既有 error（已修復）

- ~~`measurement.dart` 第 46/54 行：`sqrt` 未 import `dart:math`~~ → 已加入 `import 'dart:math' show sqrt;` 並改用 `sqrt()` 函式
- `widget_test.dart`：已更新為使用 `InduSpectApp`

---

## 開發環境

```bash
# 安裝依賴
flutter pub get

# 靜態分析
flutter analyze --no-pub

# 執行測試
flutter test test/form_inspection_record_test.dart test/database_service_test.dart test/inspection_item_state_test.dart test/photo_service_test.dart

# Android 建置
flutter build apk --debug
```

### 必要權限 (Android)

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
```

---

## 程式碼慣例

- 檔案名：`snake_case.dart`
- 類名：`PascalCase`
- 變數/方法：`camelCase`
- 私有：前綴 `_`
- 路徑操作：一律使用 `package:path/path.dart` 的 `p.basename()` 等方法，不手動 split
- 日期序列化：ISO8601 字串
- JSON Map 序列化：`jsonEncode/jsonDecode`
- photoPaths 序列化：JSON array（向後相容 `|||` 分隔格式）
- 繁體中文註解，技術術語保留英文

---

## 下一步（詳見 LAUNCH_PLAN.md 90 天計畫）

1. **實機端到端測試**（G1/#43，僅剩實機部分）：上傳 Excel → 一鍵自動檢測 →
   法規判定回填 → 匯出 → 分享；斷網流程改驗證「本地引擎判定」而非「待判定」；
   R8 開啟後的 release build 需實機煙霧測試
2. **上架準備**：產生 upload keystore（見 ANDROID_DEPLOYMENT.md）、隱私政策發布到
   公開 URL（docs/PRIVACY_POLICY.md）、Play 內部測試軌
3. **後端部署**：Cloud Run + Secret Manager（cloudbuild.yaml 已備妥前置步驟註解）
4. **試點計畫**：2-3 場域量測指標（時間節省、AI 讀值免修改率）；
   品質閘門門檻需以現場實拍照片校準（見 `image_quality_service.dart` 註記）
5. **PDF 報告實機驗證**：以現場真實照片與 30+ 項目的定檢表產生 PDF，確認檔案大小
   （照片降採樣 900px/JPEG q75）、中低階機記憶體與產生時間可接受；若出現缺字「□」
   依 `scripts/subset_pdf_font.py` 說明擴充字元範圍

---

## 變更紀錄

### 2026-09-02（PDF 報告輸出 — LAUNCH_PLAN 第 5-8 週）

- **feat(report)**: ★ **申報用 PDF 報告** `pdf_report_service.dart` — 純 Dart（`pdf` 套件）
  裝置端產生、不經後端、離線可用，符合「斷網可完成拍照 → 判定 → 匯出」原則。
  內容：基本資料（標題/日期/來源表單/地點/GPS/紀錄編號）→ 判定統計（總數/已完成/合格/
  不合格/警告/待判定）→ 逐項明細表（檢測值、判定色標、法規依據 + 單位換算說明）→
  異常/不合格清單 → AI 總結報告 → 照片附件（每項照片 + 標籤）→ 產生說明；頁首/頁尾含頁碼。
  - `PdfReportData` 與 UI/SQLite 解耦：完成頁以現場狀態組資料（照片可對應項目）；
    歷史紀錄以 `PdfReportData.fromRecord()` 由 `template_json` + `filled_data` +
    `ai_results` + `standard_judgments` 重建（舊紀錄無模板/模板損毀皆容錯）。
  - 判定優先序與 `InspectionItemState.verdict` 一致（法規判定 > AI 異常 > 手動 > 未檢測）。
  - 照片以 isolate 降採樣（最長邊 900px、JPEG q75）控制檔案大小；讀取失敗的照片略過不中斷。
  - 中文字型：內嵌 Noto Sans TC 子集（`assets/fonts/`，OFL；Big5 全字元 + 單位符號，4.9 MB），
    產生腳本 `scripts/subset_pdf_font.py`；`pdf` 輸出時再依實際用字二次子集。
- **ui**: 完成頁新增「匯出 PDF 報告」按鈕；歷史紀錄卡片新增「PDF 報告」按鈕（任何狀態皆可重建）。
- **test**: +18 測試 `pdf_report_service_test.dart`（合法 PDF/字型與照片嵌入/照片容錯/去重/
  120 項跨頁/空資料、fromRecord 映射與格式化、檔名清理）。Flutter 137 → **155 tests**。
- **deps**: 新增 `pdf: ^3.11.0`（解析 3.12.0）；`assets/fonts/` 加入 asset bundle。

### 2026-08-31（第三批：現場惡劣環境因應）

- **feat(quality)**: ★ **拍照品質閘門** `image_quality_service.dart` — 純本機、零 AI、
  零網路（Tier 0 思路）。Laplacian 響應變異數測模糊、平均亮度與過曝/過暗比例測曝光、
  局部死白比例測錶面反光；分析前統一降採樣到 512px 讓分數可跨機型比較，
  運算跑在 isolate 不卡 UI。不合格時彈出可執行建議（「請對焦後重拍」「開手電筒補光」
  「側身避開反光」）並提供重拍 / 仍要使用；三個拍照入口（單張、相簿、批次引導）皆已接。
  解決的問題：髒污反光導致 AI 讀出錯誤數值，卻被當成正常讀值送進法規判定。
- **feat(offline)**: **連線可達性探測** — `ConnectivityService.checkConnection()` 原本
  只看網路介面，廠區「連上 AP 但沒有 uplink / captive portal」會被誤判為 online，
  導致每張照片空等 Gemini 60 秒逾時。改為探測 `<BACKEND_API_URL>/health`
  （逾時 3 秒、結果快取 10 秒；介面已斷則不浪費時間探測；未設定後端則維持舊行為）。
  `_runAIAnalysis` 在呼叫 Gemini 前先探測，不通直接走 Tier 1a OCR 備援。
- **test**: +28 測試（品質閘門 14：以合成影像涵蓋模糊/過暗/過曝/反光/無法解碼/門檻可調/
  跨解析度一致性；可達性探測 14：介面×可達性決策矩陣、快取 TTL、forceProbe、
  逾時與例外處理）。Flutter 109 → **137 tests**。

### 2026-08-31（第二批：Tier 1a 離線 OCR + 後端狀態修正 + repo 清理）

- **feat(offline)**: ★ **Tier 1a 裝置端 OCR 讀值備援** — AI 不可用（離線）時：
  拍照 → ML Kit 離線 OCR（latin 模型）→ `OcrReadingParser` 解析讀值（全形
  正規化、MQ→MΩ 誤讀修正、年份/型號/日期雜訊過濾、期望單位優先）→
  合成 `source: ocr` 的 aiResult → Tier 0 本地判定 → 持久化。
  數位錶在全斷網環境有端到端流程。OCR 品質需實機驗證（G1 追加項）。
- **fix(backend)**: reports 舊版流程修正 — `FormFillService._templates` 原為
  instance attribute 且 service 每請求 new 一個 → 模板活不過單一請求；
  改 class-level + `/generate` 改同步回傳 + Template not found 回 404
- **chore**: legacy React 原型移入 `legacy/`、後端維運腳本移入
  `backend/scripts/dev/`、刪除 scratch 測試腳本與輸出
- **test**: Flutter 88 → **109 tests**（+21 OCR 解析器）；後端 167 → **172 pytest**（+5 reports 狀態）

### 2026-08-31（產品化 P0 批次 + Tier 0 離線判定，對應 LAUNCH_PLAN.md）

- **feat(offline)**: ★ **Tier 0 法規判定引擎 Dart 化**（`lib/services/standards_engine.dart`）
  - 標準資料單一來源：`backend/scripts/export_standards.py` 將 56 條標準匯出為
    `assets/standards/inspection_standards.json` 內嵌 App；後端
    `test_standards_json_sync.py` 守門兩者一致
  - 完整移植單位正規化/換算（kΩ→MΩ、°C↔°F 仿射）、標準匹配、判定與 confidence
  - 離線或後端失敗 → 本地引擎判定（judgment 帶 `source: local`），
    **「待判定」僅在本地引擎也失敗時出現**；判定結果照常持久化
- **feat(db)**: 判定結果持久化（Issue #44）— SQLite **v3→v4**，
  `form_inspection_records` 新增 `standard_judgments` 欄位（fieldId → judgment JSON），
  `FormInspectionRecord.standardJudgments` + `failCount`/`warningCount` getters，
  `_saveDraft` 隨紀錄儲存；migration 測試以 v3 歷史 schema 快照驗證升級路徑
- **feat(models)**: Gemini 模型 ID 汰換 preview（P0-6）— Flash 預設改 GA 版
  `gemini-3.6-flash`；`GeminiService.init` 支援 `GEMINI_FLASH_MODEL`/`GEMINI_PRO_MODEL`
  env 覆寫與參數注入；設定頁選擇的模型真正生效（原本選了沒作用）；
  已下架模型 ID 自動遷移
- **feat(android)**: Release 簽署改 `key.properties` 模式（P0-2）—
  不再寫死 debug 簽署；開啟 R8 minify + shrinkResources；
  金鑰產生步驟見 `ANDROID_DEPLOYMENT.md`「Release 簽署」
- **fix(app)**: `BACKEND_API_URL` 顯性化（P0-4）— `.env.example` 補實機必填說明；
  兩處無聲降級（表單本機解析、匯出 JSON fallback）改為明確 SnackBar 提示；
  自動帶 `X-API-Key` 對接後端認證；dio LogInterceptor 僅 debug 啟用（P0-8）
- **fix(test)**: 修復長期壞掉的 `widget_test.dart`（sqflite ffi + mock prefs +
  dotenv testLoad；固定幀數 pump 取代會逾時的 pumpAndSettle）；
  清零全部 15 個 analyzer warning（unused imports/fields）
- **後端同步改動**：API Key middleware + CORS 白名單 + 422/500 淨化（P0-3/P0-8）、
  judge-readings 輸入驗證（#47）、sprint 測試假陽性修正（#45）、
  CI 全量收緊（後端 167 pytest / Flutter 88 tests / analyze 硬性）
- **文件**: 新增 `LAUNCH_PLAN.md`（產品化評估與 90 天行動計畫）、
  `docs/PRIVACY_POLICY.md`（隱私政策草稿，Play 上架用）

### 2026-05-28

- **feat(flutter)**: 完成自動 AI 定檢「標準判定」串接 — 將後端 `judge-readings` 接入 `form_inspection_screen.dart`，使量測欄位在 AI 辨識後自動帶出**合格 / 不合格 / 警告**與法規依據。完成里程碑「將標準判定串入自動回填」。
  - `InspectionItemState` 新增 `standardJudgment` / `standardJudgmentPending`，並新增 `judgmentCode`、`standardBasis`、`conversionNote` getters。
  - `verdict` 判定優先序調整：**量測欄位以法規標準判定為準**（pass→合格、fail→不合格、warning→警告），`unknown` 落回 AI 異常判定；離線時顯示「待判定」。
  - 新增 `_runStandardJudgment()`：批次分析後（`_launchGuidedCapture`）一次判定所有含數值讀數的項目；單張拍照分析後（`_captureAndAnalyze` / `_pickFromGallery`）僅判定該項。後端保證 judgments 與輸入 readings 同序，前端以索引回填。
  - 新增 `_extractNumericReading()` / `_toNum()`：從 AI `readings` 中萃取最匹配欄位的數值（容錯解析夾帶單位的字串）。
  - 離線降級：`judgeReadings` 回傳 `error=offline` 時相關項目標記「待判定」，預覽頁出現提示並可由右上角「重新依法規判定」按鈕重試。
  - UI：預覽統計改為「不合格 / 警告」計數；逐項卡、預覽列表、完成頁的圖示與顏色改用統一的 `verdictColor()`（不合格紅、警告橘、待判定灰、合格綠），並顯示「標準 …（法規）」與單位換算說明。
  - 匯出 JSON 摘要與 AI 報告資料新增 `standard_judgment` / `standard_basis` / `verdict` 欄位，使法規判定成為可留存的稽核依據。
- **test(flutter)**: `inspection_item_state_test.dart` 新增 13 個測試（標準判定優先序、unknown 落回、離線待判定、`standardBasis`/`conversionNote`、`verdictColor`）。
- **test(backend)**: 新增 `tests/test_judge_readings_endpoint.py`（7 tests，FastAPI TestClient）鎖定 `judge-readings` 端點合約（頂層鍵、judgments 同序、分類、summary 計數、kΩ→MΩ 換算）。後端全套由 143 → **150 pytest 全綠**。

### 2026-05-25

- **fix(judgment)**: 修正自動定檢「標準判定」單位數量級誤判 — 判定前先把 AI 讀數換算成法規標準單位。
  - 原本 `500 kΩ` 直接拿去與 `≥1.0 MΩ` 比較（`500 ≥ 1.0` → 誤判合格），實際 `0.5 MΩ` 應為**不合格**；`0.05 A`(=50 mA) 對 `≤30 mA` 也曾誤判。屬安全相關 bug。
  - 新增 `normalize_unit()`（℃/°C、Mohm/MΩ、kgf/cm² 等變體正規化）與 `convert_value()`（電阻/電流/電壓/壓力/溫度/時間/長度/速度 同維度換算）於 `backend/app/data/inspection_standards.py`。
  - `auto_judge` 回傳新增 `converted_value` / `converted_unit`，供前端透明顯示「原始讀數 → 換算值」。
- **fix(judgment)**: 修正標準匹配假陽性 — 不相干欄位（如「不存在項目」）只要設備類型相同就被硬湊到某條標準而產生假判定。改為**必須有欄位名稱相關性**（inspection_item 或 keyword 命中）才列為候選，單位/設備類型僅作加分。
- **feat(api)**: 新增輕量端點 `POST /api/auto-fill/judge-readings` — App 在批次 AI 分析後可直接送讀數做標準判定（不需 field_map / 歷史資料），回傳 judgments + warnings + summary。
- **feat(flutter)**: `BackendApiService.judgeReadings()` client 方法，離線時降級回傳 `error=offline`。
- **test**: 新增 `backend/tests/test_unit_conversion_judgment.py`（25 tests），覆蓋單位正規化、同維度換算、換算後判定、維度不相容防呆、匹配相關性。後端全套 **143 pytest 全綠**。

> ~~待辦（需 Flutter SDK 環境驗證）：將 `judgeReadings()` 串入 `form_inspection_screen.dart`，使量測欄位自動帶出合格/不合格/警告與法規依據；離線時標記「待判定」。~~ → **已於 2026-05-28 完成**（見上方變更紀錄）。註：本環境無 Flutter SDK，前端改動以靜態審查 + 既有測試樣式驗證，待實機 `flutter analyze` / `flutter test` 最終確認。

### 2026-04-17

- **feat(#27)**: 新增「一鍵自動檢測」模式 — 引導拍照 → 批次 AI 分析 → 自動進入預覽
- **feat(#27)**: 新增批次分析進度覆蓋層 — 即時顯示分析項目、完成數、錯誤數
- **feat(#27)**: 智慧拍照提示 — 根據欄位類型（溫度/壓力/電氣/外觀等）產生專業拍照指引
- **feat(#28)**: AI 報告自動產生 — 進入完成步驟時自動觸發，無需手動按鈕
- **feat(#28)**: 返回修改時重置報告狀態，確保重新匯出時產生新報告
- **ui**: 更新 Step 1 流程說明反映自動化改進
- **ui**: Step 2 底部新增「自動檢測」按鈕（teal 配色），「批次拍照」按鈕縮短為「批次」

### 2026-04-16

- **fix(#18)**: 匯出檔案改用 `getApplicationDocumentsDirectory()` 持久化目錄
- **fix(#18)**: `share_queue_service.dart` 加入檔案存在性檢查 fallback
- **fix(#16)**: 歷史紀錄搜尋加入 300ms debounce Timer
- **fix**: `measurement.dart` 修正 `sqrt` 未 import `dart:math` 的編譯錯誤
- **chore**: 關閉 GitHub Issues #14-#19，附修復說明留言
