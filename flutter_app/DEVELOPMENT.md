# Flutter App 開發指南

> **最後更新**: 2026-04-17

---

## 架構總覽

InduSpect 聚焦於 **2 個核心功能**：

1. **完整檢測 Pipeline**：上傳/匯入定檢表 → 引導拍照 → AI 辨識 → 自動回填原始格式文件 → AI 摘要報告 → 分享/傳送（離線暫存）
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
│   ├── share_queue_service.dart      # 離線分享佇列（上線自動處理）
│   ├── connectivity_service.dart     # 網路連線狀態監聽
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
# 全部測試（排除壞掉的 widget_test.dart）
flutter test test/form_inspection_record_test.dart test/database_service_test.dart test/inspection_item_state_test.dart test/photo_service_test.dart

# 單一檔案
flutter test test/form_inspection_record_test.dart
```

### 測試清單（46 tests）

| 檔案 | 數量 | 覆蓋範圍 |
|------|------|---------|
| `form_inspection_record_test.dart` | 17 | Model: toMap/fromMap 往返、null 處理、舊格式向後相容、computed getters、copyWith 深拷貝、日期邊界 |
| `database_service_test.dart` | 12 | DB CRUD: insert/update/delete、排序、limit、搜尋 title/locationName、GPS 持久化、UNIQUE 約束、clearAll |
| `inspection_item_state_test.dart` | 11 | displayValue/verdict 邏輯、TextEditingController 生命週期 |
| `photo_service_test.dart` | 6 | 照片命名格式、序號補零、截斷、特殊字元 |

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

## 下一步

1. **實機端到端測試**：完整流程 上傳 Excel → 一鍵自動檢測 → 匯出 → 分享
2. **離線測試**：斷網狀態完成檢測 → 恢復網路 → 確認自動分享
3. **效能優化**：大量紀錄時的列表滾動效能
4. **UI 微調**：根據實機測試回饋進行調整

---

## 變更紀錄

### 2026-05-25

- **fix(judgment)**: 修正自動定檢「標準判定」單位數量級誤判 — 判定前先把 AI 讀數換算成法規標準單位。
  - 原本 `500 kΩ` 直接拿去與 `≥1.0 MΩ` 比較（`500 ≥ 1.0` → 誤判合格），實際 `0.5 MΩ` 應為**不合格**；`0.05 A`(=50 mA) 對 `≤30 mA` 也曾誤判。屬安全相關 bug。
  - 新增 `normalize_unit()`（℃/°C、Mohm/MΩ、kgf/cm² 等變體正規化）與 `convert_value()`（電阻/電流/電壓/壓力/溫度/時間/長度/速度 同維度換算）於 `backend/app/data/inspection_standards.py`。
  - `auto_judge` 回傳新增 `converted_value` / `converted_unit`，供前端透明顯示「原始讀數 → 換算值」。
- **fix(judgment)**: 修正標準匹配假陽性 — 不相干欄位（如「不存在項目」）只要設備類型相同就被硬湊到某條標準而產生假判定。改為**必須有欄位名稱相關性**（inspection_item 或 keyword 命中）才列為候選，單位/設備類型僅作加分。
- **feat(api)**: 新增輕量端點 `POST /api/auto-fill/judge-readings` — App 在批次 AI 分析後可直接送讀數做標準判定（不需 field_map / 歷史資料），回傳 judgments + warnings + summary。
- **feat(flutter)**: `BackendApiService.judgeReadings()` client 方法，離線時降級回傳 `error=offline`。
- **test**: 新增 `backend/tests/test_unit_conversion_judgment.py`（25 tests），覆蓋單位正規化、同維度換算、換算後判定、維度不相容防呆、匹配相關性。後端全套 **143 pytest 全綠**。

> 待辦（需 Flutter SDK 環境驗證）：將 `judgeReadings()` 串入 `form_inspection_screen.dart` 的 `_mapAIResultToField`／預覽步驟，使量測欄位自動帶出合格/不合格/警告與法規依據；離線時標記「待判定」。本次未動核心畫面（無法在此環境編譯驗證 Flutter）。

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
