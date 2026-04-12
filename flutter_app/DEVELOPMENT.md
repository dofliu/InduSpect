# Flutter App 開發指南

> **最後更新**: 2026-04-12

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
  └─ 或批次拍照（GuidedCaptureScreen）
  └─ 或切換手動填寫模式
  └─ 每次 AI 完成自動存 SQLite

Step 3: preview
  └─ 統計摘要（完成/未完成/異常）
  └─ 逐項列表 + verdict

Step 4: exporting
  └─ 嘗試後端回填原始格式
  └─ 失敗時 fallback 為 JSON 摘要
  └─ 更新 status = exported

Step 5: done
  └─ 統計卡片 + AI 摘要報告（可產生/重新產生）
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

## 已知問題（GitHub Issues）

| Issue | 標題 | Label |
|-------|------|-------|
| #14 | 批次拍照並行 AI 分析需加 concurrency limit | performance |
| #15 | 多張 AI 分析失敗時 SnackBar 連續彈出 | ux |
| #16 | 歷史紀錄搜尋應改用 SQL-side search | performance |
| #17 | saveFormRecord 不應直接 mutate 傳入物件 | code-quality |
| #18 | 匯出檔案存於 temp 目錄，分享前應檢查存在性 | robustness |
| #19 | geocoding 在 Web 平台缺少防護 | robustness |

### 既有 error（非本次引入）

- `measurement.dart` 第 46/54 行：`sqrt` 未 import `dart:math`
- `widget_test.dart` 第 16 行：`MyApp` 已不存在（預設模板未更新）

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

1. **實機端到端測試**：完整流程 上傳 Excel → 拍照 → AI → 匯出 → 分享
2. **離線測試**：斷網狀態完成檢測 → 恢復網路 → 確認自動分享
3. **處理 GitHub Issues #14-#19**
4. **修正既有 error**：measurement.dart `sqrt`、widget_test.dart `MyApp`
