# Flutter App 開發指南

> **最後更新**: 2026-09-06

---

## 架構總覽

定檢主線聚焦於 **2 個核心功能**，另有一條**平行的獨立流程**：

1. **完整檢測 Pipeline**：上傳/匯入定檢表 → 引導拍照 → AI 辨識 → 自動回填原始格式文件 → AI 摘要報告 → PDF 申報報告 → 分享/傳送（離線暫存）
2. **歷史紀錄**：含 GPS 定位、可編輯標題、搜尋功能
3. **風機葉片檢測**（2026-09-07 起）：**資產驅動**——主鍵是某台風機而不是某張表單，
   價值在跨次比對。不共用定檢的資料模型與流程，共用 GPS／PDF／DB／連線探測。

```
┌─ DashboardScreen ────────────────────────────────────────────────┐
│  ┌──────────────┐  ┌───────────────────┐  ┌──────────────────┐   │
│  │ 開始檢測      │  │ 歷史紀錄           │  │ 風機葉片檢測      │   │
│  │ (FormInsp.)  │  │ (UnifiedHistory)  │  │ (BladeInsp.)     │   │
│  └──────┬───────┘  └───────┬───────────┘  └────────┬─────────┘   │
│         │                  │                       │            │
│  ┌──────▼──────────────────▼──────────┐            │            │
│  │       最近檢測 (SQLite FutureBuilder) │            │            │
│  └────────────────────────────────────┘            │            │
│         表單驅動 form_inspection_records    資產驅動 wt_assets     │
│                                            / wt_capture_sessions │
│                                            / wt_detections       │
└──────────────────────────────────────────────────────────────────┘
```

### 核心檔案結構

```
lib/
├── models/
│   ├── form_inspection_record.dart   # 表單檢測紀錄（定檢主線）
│   ├── inspection_template.dart      # 表單模板結構
│   ├── template_field.dart           # 模板欄位定義
│   ├── analysis_result.dart          # AI 分析結果
│   ├── wt_asset.dart                 # 葉片：一台風機（含拍攝點 GPS）
│   ├── wt_capture_session.dart       # 葉片：一次到場（含媒體清單與品質判定）
│   └── wt_detection.dart             # 葉片：一筆發現（含人工確認狀態）
├── screens/
│   ├── dashboard_screen.dart         # 主頁（3 入口 + 最近紀錄）
│   ├── form_inspection_screen.dart   # ★ 核心：完整檢測流程（5 步驟）
│   ├── unified_history_screen.dart   # 歷史紀錄（搜尋/編輯/刪除/重新分享）
│   ├── guided_capture_screen.dart    # 批次引導式拍照
│   ├── blade_inspection_screen.dart  # ★ 葉片：五步流程（選資產→拍攝→分析→人工確認→報告）
│   └── blade_capture_guide_screen.dart # 葉片：格位清單式引導拍攝（系統相機、原尺寸）
├── services/
│   ├── database_service.dart         # SQLite CRUD（v5：定檢三表 + 葉片三表）
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
│   ├── backend_api_service.dart      # 後端 API（表單回填）
│   ├── blade_surface_service.dart    # ★ 葉片表面層：前緣粗糙度（surface.py 的 Dart 對照）
│   ├── blade_analysis_service.dart   # ★ 葉片分析編排 + 門檻表單一來源
│   ├── blade_capture_gate.dart       # 葉片照專用拍攝品質判定（天空為主的畫面）
│   ├── blade_ai_service.dart         # 葉片專用 AI prompt（正常結構清單）
│   └── blade_report_builder.dart     # 葉片報告（不輸出「合格」）→ pdf_report_service
└── providers/
    ├── settings_provider.dart        # API Key & 模型設定
    ├── inspection_provider.dart      # 檢測狀態管理
    └── app_state_provider.dart       # 應用狀態
```

---

## 資料庫 Schema (SQLite v5)

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
| standard_judgments | TEXT (JSON) | ★ v4：法規判定結果（合格/不合格/警告 + 法規依據 + 單位換算） |

索引：`status`, `created_at`, `title`

### 葉片模組三張表（v5 新增，`BLADE_INSPECTION_SPEC.md` §7）

葉片檢測是**資產驅動**（跟著一台風機累積歷次紀錄），定檢是**表單驅動**（跟著一張定檢表），
兩者的生命週期不同，所以是三張獨立新表而不是掛在既有表上。既有三張表一欄未動。

| 表 | 主鍵 | 說明 |
|----|------|------|
| `wt_assets` | `asset_id` (TEXT UNIQUE) | 一台風機。現場編號、風場、機型、輪轂高、轉子直徑、拍攝點（JSON array：名稱 + GPS + 相機朝向） |
| `wt_capture_sessions` | `session_id` (TEXT UNIQUE) | 一次到場。`asset_id` 外參、GPS、風機狀態（停機/怠速/運轉）、天氣、媒體清單（JSON array：路徑 + 視角 + 倍率 + 葉片 + 區段 + 前緣側 + 品質判定）、狀態、報告路徑、待分享旗標 |
| `wt_detections` | `detection_id` (TEXT UNIQUE) | 一筆發現。`session_id` 外參、層（surface/geometry/dynamic/periphery）、葉片、區段、缺陷類別、severity 1–5、confidence、演算法數值（JSON）、bbox（JSON）、照片、來源（algorithm/gemini/geminiOfflinePending）、**人工確認狀態**與備註 |

索引：`wt_capture_sessions(asset_id)`、`wt_capture_sessions(captured_at)`、`wt_detections(session_id)`

幾個對 Flutter 端有影響的約定：

- **`WtMedia.qualityOk` 未分析時回 `null`，不可當成通過。** 判斷一律用 `!= true`。
- **`human_status` 預設 `pending`。** 演算法與 AI 都只是初判，沒有人簽過的發現不具效力；
  報告每一列都帶「待確認」欄。
- **重新分析只刪該層 `human_status = 'pending'` 的列**（`replaceWtDetections`），
  人工已簽核的與其他層不受影響。
- SQLite 預設不開外鍵，所以 `deleteWtAsset` / `deleteWtSession` 手動串聯刪除。

### Migration 路徑
- v1 → v2：新增 `photo_sync_tasks` 表
- v2 → v3：新增 `form_inspection_records` 表
- v3 → v4：`form_inspection_records` 新增 `standard_judgments` 欄（判定持久化，Issue #44）
- v4 → v5：新增 `wt_assets` / `wt_capture_sessions` / `wt_detections` 三張表 + 索引。
  **只新增、不改既有欄位**，舊使用者升級後這三張表是空的（migration 測試以 v4 歷史
  schema 快照驗證既有定檢紀錄一字未動）。

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

### 測試清單（406 tests）

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
| `image_decode_test.dart` | 5 | ★ `safeDecodeImage`：`decodeImage` **會丟例外不只回 null**（短位元組在格式嗅探階段就 RangeError），驗真影像解得回來、極短/非影像/截斷都回 null 不丟例外 |
| `photo_decode_guard_test.dart` | 4 | ★ 兩個照片服務在無法解碼時交出**自己文件寫的結果**：`compressPhoto` 回原始位元組、`ImageService` 丟「Failed to decode image」而不是漏出 RangeError |
| `blade_geometry_compare_test.dart` | 17 | ★ 幾何層：三片輪廓逐項對照 Python、健康那台四個量都不標記、**單片注入 24 px 偏移要被標記且指對那一片**、離群判準要同時滿足 z 與「大於另兩片彼此差」、閘門拒收時互比一定為空 |
| `blade_geometry_service_test.dart` | 15 | ★ 分割與結構定位逐階段對照 Python：色空間 → 天空模型場 → 距離與遮罩 → 輪轂/塔架/三片葉尖 |
| `blade_trend_service_test.dart` | 15 | ★ 跨次趨勢：一個點不產生趨勢、下降不可被說成好轉、駁回的點留在線上、只比無因次比值 |
| `blade_ai_retry_service_test.dart` | 11 | ★ AI 補跑佇列：不推翻已簽核的、失敗維持待補、同場次不做 N+1、批次上限 |
| `blade_dsp_test.dart` | 19 | ★ DSP 逐項對照 scipy：STFT 的**縮放/邊界補零/padded 三者都要對**、週期性 Hann（窗和恰為 n/2）、自寫 FFT、savgol 係數、medfilt **用零填補不是 REPLICATE**（斜坡是能分辨的最短案例）、numpy 的 `round` 是半數取偶 |
| `blade_audio_decode_test.dart` | 17 | ★ WAV 讀取：夾具逐點對照 Python、四種位元深度（24-bit 走「補低位元組當 int32」與 Python 同尾數）、多聲道取平均、fmt 前插別的區塊、data 長度為 0／超出檔案、**每一種讀不了的情況都有可顯示的原因且不丟例外** |
| `blade_acoustic_service_test.dart` | 23 | ★ 聲音層：兩段夾具**兩個方向都測**（healthy 不誤報／eroded 真的報且報在對的那一片）、ACF 諧波歧義解對（差三倍就是把 3P 當 1P）、三重守門（靜音／白噪／風噪主導）不可用時**不給逐片數字** |
| `blade_dynamics_service_test.dart` | 18 | ★ 動態層：抽幀注入所以整條編排測得到、朝下葉片的 25° 容差邊界、**缺測的幀不占標籤位置**（否則後面全部錯位）、不以內插值充當量測、每片不足 2 幀就不互比 |
| `blade_audio_recorder_test.dart` | 17 | ★ 錄音流程（plugin 收在一處，流程全測得到）：**裝置不支援 WAV 時不開始錄**（不然會靜靜錄成壓縮格式，等分析才發現解不開）、權限／編碼器的檢查順序、plugin 回 null 時退回指定路徑、放棄會刪檔；另有一組**釘住錄音參數**（WAV／單聲道／自動增益與降噪全關）的測試 |
| `metric_direction_test.dart` | 8 | ★ 互比方向性：偏低不標記但 **z 照樣算完**、兩片往相反方向偏時 high 模式要抓最吵的而不是偏離最多的、早退路徑也要帶著 direction |
| `blade_image_ops_test.dart` | 10 | ★ 影像運算逐項對照 OpenCV：網格中值（網格點逐位相同）、REFLECT_101 高斯、5×5 橢圓閉、連通元件、chamfer 距離變換（含最大值位置）、8-bit Lab |
| `blade_analysis_service_test.dart` | 24 | ★ 葉片分析編排：門檻表邊界、未驗過品質的照片不分析、未超門檻不進報告但存進 DB、AI 不得下砍演算法等級、離線不遺失結果、摘要明講未跑的層 |
| `blade_report_builder_test.dart` | 9 | ★ 葉片報告的立場：不輸出「合格」、零檢出明說代表什麼、演算法數值看得到、人工駁回的不列入但照片仍附上 |
| `blade_capture_gate_test.dart` | 9 | ★ 葉片拍攝閘門（影像層）：只擋讀不到檔與整張過暗；模糊/過亮/死白降為提醒（儀表門檻套天空畫面會誤攔）、原始量全存供日後校準 |
| `blade_surface_service_test.dart` | 8 | ★ 表面層 Dart 對照 Python 原型：前後緣比判定一致、凹坑/p95、分 zone 定位侵蝕落在哪一段、cm 換算、失敗要給補救方式 |
| `blade_ai_service_test.dart` | 8 | ★ 葉片 AI：正常結構清單一定在 prompt 裡、演算法數值不被 AI 覆蓋、severity/confidence 值域夾回、失敗往上丟 |
| `database_migration_test.dart` | 6 | SQLite v3→v4 與 v4→v5 真實 onUpgrade 升級路徑（standard_judgments 欄位；葉片三表 + 既有紀錄不動 + round-trip + 壞 JSON 容錯） |
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

> 葉片模組（獨立功能）的下一步不在此列，見 `BLADE_INSPECTION_SPEC.md` §9 分期與
> `blade_prototype/README.md` 外業流程。本節只列定檢表主線。

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

### 2026-09-07（解碼守門收斂到一處）

`package:image` 的 `decodeImage` **會丟例外，不只回 null**——位元組太短時在格式
嗅探階段就 `RangeError`（GIF 的 `isValidFile` 讀字串讀過界），那時連格式都還沒判斷
出來。所以 `decodeImage(bytes) == null` 只擋得住「格式認得出來但內容壞掉」，
擋不住「檔案根本不完整」，而後者才是現場會遇到的（外接儲存寫一半被拔掉、複製中斷、
從相簿選到非影像檔）。

新增 `lib/utils/image_decode.dart` 的 `safeDecodeImage`，五處呼叫端全部改用它。
放在 `utils/` 而不是任何一個 service 裡是刻意的：定檢與葉片是兩條獨立的功能線，
從其中一條 import 另一條的檔案只為了拿一個 helper 會把兩者黏起來。
`BladeImageOps.safeDecode` 留成轉呼叫，葉片端的呼叫點不必知道它搬去哪了。

**兩處的實際影響比原本記的小，這裡更正**：

| 呼叫端 | 原本會怎樣 | 改了什麼 |
|---|---|---|
| `image_service._processAndSaveImage` | 有 try/catch 但 `rethrow`，所以漏出去的是 `RangeError` 而不是它自己寫的 `Exception('Failed to decode image')` | 呼叫端（`inspection_provider` 的拍照流程）現在看得懂錯在哪 |
| `photo_service.compressPhoto` | **本來就不會崩潰**——整段包在 try/catch 裡，`catch (e)` 連 `Error` 一起接，會回原始位元組 | 紀錄從「Compress failed: RangeError…」變成「Failed to decode」，那才是實際發生的事 |
| `pdf_report_service._downscaleToJpeg` | 外層 `loadPhotoForPdf` 有 try/catch，安全 | 「無法解碼」在 isolate 內就回 null，不必丟例外穿過 isolate 邊界 |
| `image_quality_service` / `blade_surface_service` | 前一批已修 | 改用共用的那份，本地 try/catch 刪掉 |

所以這一筆修的是**診斷性與紀錄準確度**，不是崩潰。測試 286 → 295。

### 2026-09-07（葉片模組 Phase 1 缺口補完 + Phase 2 幾何層）

**Phase 1 的兩個缺口**（同日盤點、同日補完）：

### 2026-09-07 — 聲音層兩個未決事項結案

#### 一、`tonal_exclusive` 修好了（真的驗獨有性）

原本的「只有這片有」複查是在 ±3% 的窄頻帶上**再跑一次** 9 點中值濾波。那是錯的：
手機常見取樣率下那個頻帶只有 4–5 個 bin（48 kHz / nperseg 2048 → bin 間距 23 Hz，
1800 Hz 的 ±3% 是 108 Hz），達不到中值濾波要求的 13 個，於是一律回 NaN 而被呼叫端
當成「另兩片在這個頻率沒有東西」。結果它退化成「突出量 ≥ 6 dB」，
**完全沒有驗過獨有性**——鋸齒尾緣等設計特徵、路過的車輛、地面的發電機會在每一片的
視窗裡留下同一根峰，然後被報成單片缺陷，於是有人去拆錯的葉片。

改成讀各片**全頻帶**突出量頻譜（`med_bins=25`，本來就為了找自己的峰算過一次）
在該頻率上的值。Python 與 Dart 同步改，新增 `_tonal_excess` / `_excess_at`
（Dart：`tonalExcess` / `excessAtFrequency`，**公開**所以測得到）。

合成音軌實測：

| 案例 | 舊做法判為獨有 | 新做法 | 正確答案 |
|---|---|---|---|
| 健康（無哨音） | 0 | 0 | 0 |
| 單片哨音 | 1 | 1 | 1 |
| **兩片同頻哨音** | **2** | **0** | 0 |
| **三片同頻哨音** | **3** | **0** | 0 |

共消掉 5 個誤報，單片哨音仍然抓得到。門檻沒有重新校準：修的是複查那一步，
峰本身的判準（6 dB）沒動。severity 維持 2，但理由換了——不再是「複查形同虛設」，
而是手機地面錄音本身就是 Level 1 篩檢。

既有兩段夾具的參考值**完全不變**（它們沒有多片同頻的情況），所以原有的交叉驗證
仍然有效；改動的那條路另外用轉寫對照補驗（三片／兩片同頻，Python 與 Dart 一致）。

#### 二、加入 `record` 做 App 內錄音

`record: ^6.2.1`，專案 SDK 下限 `>=3.2.0` → `>=3.5.0`，並宣告 `flutter: >=3.24.0`。
**刻意不用 7.x**：它要 Dart `^3.12.0` / Flutter 3.44，那個下限會把還沒升級的開發
環境擋在外面，而 6.x 已經有需要的 `AudioEncoder.wav`（已下載 package 逐項確認 API，
沒有靠記憶）。

錄音參數是**量測要求不是偏好**，寫在 `BladeRecordingSpec` 並有測試釘住：

- **未壓縮 WAV**：裝置上沒有純 Dart 的 AAC 解碼器，錄成 m4a 就離線分析不了。
  而且**開始錄之前先問 `isEncoderSupported`**——不問的話裝置可能靜靜錄成壓縮格式，
  等到分析才發現解不開，那時人已經離開現場了。
- **44.1 kHz 而不是 16 kHz**：分析頻帶上限 8 kHz，16 kHz 取樣的 Nyquist **剛好**是
  8 kHz，抗鋸齒濾波器在那裡就開始滾降，會把 2–8 kHz 的高頻占比量偏。
- **自動增益／降噪／回音消除全部關掉**：自動增益會在錄音過程中改變增益，把「同一段
  錄音裡三片互比」的基準拆掉；降噪削掉的正是要量的寬頻噪音（前緣侵蝕的徵兆）；
  回音消除為語音設計會扭曲頻譜。
- **歷次錄音要用同一個取樣率**：`nperSegFor` 由「32 ms 視窗」推出分析窗長，
  取樣率變了 bin 間距就變、窄頻峰的基線估計跟著變。取樣率已存進 `qualityJson`。

plugin 的 API 只出現在 `RecordPluginAudioRecorder` 一處，流程（權限、編碼器支援、
長度提示、收尾、放棄時刪檔）全部用假的錄音器測到底——這個環境沒有實機，
plugin 本身驗不了，但萬一 API 對不上，要改的也只有那一個檔案裡的那幾行。

錄音與「附加音軌」共用**同一條**驗證與存檔路徑（`_ingestAudio`）：錄音只是換一個
來源，不該長出第二套判定。`file_picker` 那條路保留為備援（裝置不支援 WAV、
或用專業錄音機時）。

Android 已加 `RECORD_AUDIO`。**iOS 的 `NSMicrophoneUsageDescription` 待 `ios/`
目錄建立時補**——目前 repo 只有 android/web/windows。

---

### 2026-09-07 — 葉片模組 Phase 3：動態層（聲音層完整、影片留接縫）

`acoustics.py`（484 行）的 Dart 對照實作。測試 295 → 384。

**先講一個範圍判斷：`dynamics.py` 沒有整套搬過來。** 原型那 424 行的三個輸出，
兩個現在有更好的來源：

| 原型的輸出 | App 端誰負責 |
|---|---|
| 轉速（逐幀角度追蹤 + 回歸） | **聲音層**。包絡自相關量到的 rpm 在夾具上與真值差 0.1%，而且不必解一張幀 |
| 三片半徑一致性 | **幾何層**（Phase 2）。單張整機照就是三片剪影互比 |
| 六點鐘取幀、轉向 | 只有這個真的需要解幀 |

把逐幀追蹤搬過來會是「跑不動（Python 就 190–320 ms/幀）又跟已有的兩層重複」。
所以動態層做的是影片**唯一多給的東西**：多幀取中位，抵消風吹擺動。

**抽幀留成注入點。** Flutter 沒有純 Dart 的 H.264／HEVC 解碼器，抽幀一定要走原生
（Android MediaCodec、iOS AVAssetImageGenerator）——那是沒有實機就驗不了的
platform channel，所以不押一個猜的實作。編排與判定用注入的抽幀器測到底（18 條）。
未接上時報告寫「裝置端抽幀尚未接上」而不是「未實作」：「沒拍」與「拍了但解不了」
對現場是兩件不同的事。

**新增四支**（`blade_dsp` / `blade_audio_decode` / `blade_acoustic_service` /
`blade_dynamics_service`），三個不可退化的約定：

1. **三重守門**（週期信賴度／包絡訊噪比／低頻占比）任一不過就 `usable = false`，
   而**不可用時 `blades` 與 `comparisons` 是空的**，不是「全部正常」。
2. **聲學量互比一律 `MetricDirection.high`**。不限方向的話最安靜的那片會被標成
   前緣侵蝕——結論剛好反過來。
3. **兩層的葉片標籤同一個規則**（依通過六點鐘的先後循環），且都明寫不是實際葉片編號。

**驗證方式：先在 Python 端把慣例釘死，再轉寫。** STFT 的縮放、savgol 的邊緣處理、
medfilt 的邊界填補各有好幾種說得通的慣例，猜錯不會報錯，只會讓最後一個數字對不上。
所以先寫一份「打算在 Dart 裡怎麼實作」的 Python 版（顯式迴圈、顯式正規化）對照 scipy：

    STFT |Z| 3.5e-16 / band energy 1.5e-17 / savgol 3.5e-17
    medfilt 0（逐位相同）/ ACF 1.1e-15 / mod_depth 逐位相同

再把整條 `analyzeSamples` 轉寫回 Python 對照 `acoustics.py`，兩段夾具音軌上
**每個輸出都到機器精度一致**。夾具參考值**從寫出去的 WAV 讀回來之後才算**
（含 int16 量化），與 Dart 端輸入同源。改 `acoustics.py` 後要重跑
`blade_prototype/scripts/make_acoustic_fixture.py`——該產生器會**自我對帳**
（它為了掏出中間量重寫了一次前處理，那份重複本來就是漂移來源），
與 `acoustics.py` 漂開時直接爆掉不寫檔。

**移植期間發現的兩件事**：

1. **`compareMetric` 少了 `direction`**（真缺口，已補）。幾何層只用 `both` 所以
   之前沒露出來。有方向時「離群者」也改成最高（最低）那片而不是離中位數最遠那片，
   兩片往相反方向偏時這兩者不同。
2. **`tonal_exclusive` 沒有真的驗過獨有性**（Python 既有缺陷，**照原樣移植**）。
   ±3% 的窄頻帶在手機取樣率下只有 4–5 個 bin，達不到 9 點中值濾波要的 13 個，
   複查回 NaN 被當成「另兩片沒有」。實際等同「突出量 ≥ 6 dB」。因此哨音只給
   severity 2 不越級主張。修法與取捨記在 SPEC §13 第 6 項。

**順手修一個既有的 bug**：`replaceWtDetections` 原本只清傳進來那一層的 `pending`，
但 `analyzeSession` 回傳的是整個場次三層的完整結果——上一輪標記過、這一輪不再標記
的發現會留在報告上，那是憑空多出來的「異常」。改為清整個場次的 `pending`，
`confirmed`/`rejected` 不動（那等於推翻簽核）。Phase 2 就有這個問題，動態層讓它
變成三層。

**音軌的取用**：用既有的 `file_picker`（只收 WAV），沒有加新相依——`record` plugin
的 App 內錄音 UX 更好，但要 Dart SDK `^3.3.0` 而本專案宣告 `>=3.2.0`，
在無法實機驗證的批次裡賭相依解析不划算（SPEC §13 第 7 項）。附加時**當場就驗一次**：
解不開、太短、風噪主導都要在人還站在風機旁、還能重錄的時候講。

分析步驟那張卡片原本寫死「本次只跑表面層；幾何層與動態層還沒實作」——幾何層
Phase 2 就做完了，那句話已經是**假的**。改成依場次素材照實列出會跑哪幾層。

---

### 2026-09-07 — 葉片模組 Phase 1 缺口補完

- **AI 補跑佇列** `blade_ai_retry_service.dart`：離線時偵測標成 `geminiOfflinePending`，
  原本沒有任何東西在連線後把 AI 那一段補完。三條不可退化的規則：只補
  `human_status = pending` 的（在 SQL 層就擋掉，不靠呼叫端記得）、合併走
  `BladeAnalysisService.mergeAlgorithmAndAi`（與線上分析同一條，各寫一份會漂移）、
  失敗一律維持待補不寫半套。
- **跨次趨勢** `blade_trend_service.dart` + `blade_history_screen.dart`：
  **只比無因次的前緣/後緣 rms 比**。`rms_px` 受距離與焦段影響，站遠一點同一片葉片的
  px 值就變小，那個變化與侵蝕無關；比值是同一張照片內互比出來的，是唯一跨次可比的
  數字。一個點不產生趨勢（`delta` 回 null 而不是 0）、比值下降不可被說成好轉、
  人工駁回的點留在線上並標記。
- 葉片報告接進離線分享佇列（`getWtSessionsPendingShare()` 原本零呼叫端）。

**Phase 2 幾何層 Dart 移植**（`segmentation.py` + `geometry.py` + `quality.py`）：

整機照現在會真的被量測（三片剪影互比），不再只是「保存下來」。

- **中值改成網格模式**是這批唯一的行為改變。逐像素大核中值在手機上跑不動——即使用
  Perreault 的雙層直方圖，1024×820×3 仍約 1.4G 次 bin 運算。改成只在 step=16 的網格點
  上算**真**中值 + 雙線性內插（約 64M 次）。這不是近似中值：網格點算的是真正的中值。
  真實照片代價：設計範圍內輪轂命中 23/30 → 22/30。
  **降工作尺度是更糟的選擇**（1024 → 512/384/256 掉到 20/19/18，而且時間幾乎沒省，
  瓶頸在結構定位不在中值）。`segmentation.py` 因此新增 `grid_step` 參數當對照基準。
- **色空間必須是 OpenCV 的 8-bit Lab**（L×2.55、a/b+128），不能用表面層那個未縮放的
  CIE Lab：局部模型的 `minScale = 1.2` 是那個空間裡的絕對下限，而大核中值必須跑在
  uint8 上。換空間等於悄悄改門檻。
- **距離變換用 OpenCV 的 5×5 chamfer 近似而非精確 EDT**：chamfer 有約 2% 各向異性
  誤差、精確版沒有，但 Python 用的是 chamfer，而輪轂靠 DT 最大值定位——兩邊用不同的
  距離就對照不起來。要換的話兩邊一起換並重跑真實語料。
- **高斯的邊界是 REFLECT_101**（OpenCV 濾波預設）而不是 clamp；`medianBlur` 例外，
  那個用 REPLICATE。這是逐項對照時抓到的：clamp 在外圈幾個像素會與 Python 差開，
  而那正是遮罩邊界所在。
- **拍攝閘門在三片互比之前，且拒收時不算互比。** 定位錯誤時 `findStructure` 一樣回傳
  三葉結構、互比一樣吐出一組自洽但完全錯的數字。閘門的門檻與 Python 相同，而哪些
  條件拒收、哪些只警告是量出來的（三片半徑離散是唯一真正有鑑別力的拒收條件）。
- 互比標記的發現一律 **severity 2（警告）**，不給不合格：它指出「這片與另兩片不一樣」，
  原因可能是變形也可能是那片剛好被雲遮住一段，要升級得靠近距離複檢。

**跨語言耦合（新增，會咬人）**：改 `surface.py` / `segmentation.py` / `geometry.py` /
`quality.py` 之後必須重跑 `blade_prototype/scripts/make_*_fixture.py`，
否則 Flutter 的交叉驗證測試會紅。三支產生器：`make_image_ops_fixture.py`（逐項對照
OpenCV）、`make_geometry_fixture.py`（逐階段 + 健康/偏移兩組情境）、
`subset_pdf_font.py`（既有）。

測試 211 → 286（葉片相關 +75），blade_prototype 76 → 78。

### 2026-09-07（葉片模組 Phase 1 — App 化，表面層）

規格 §9 的 Phase 1 落地。**表面層排在幾何層之前**是刻意的：表面層走的是原本的逐列
天空模型（長焦分區段照），不需要幾何層那顆大核中值，Dart 移植可行；局部天空模型
留在 Phase 2。

- **SQLite v4 → v5**：`wt_assets` / `wt_capture_sessions` / `wt_detections` 三張新表 +
  三個索引（詳見上方 Schema 章節）。既有三張定檢表一欄未動。
- **`blade_surface_service.dart`**：`surface.py` 的 Dart 對照實作，跑在 `compute()`
  isolate 裡。與 Python 逐 zone 對照到小數第三位一致（`test/assets/blade_segment_reference.json`
  存原型量到的數值）。兩個移植期間抓到的坑：
  - **OpenCV 的 8-bit Lab 與真 CIE Lab 差約 2.55×**。比值型的 5.5σ 門檻轉移得過來，
    但 MAD 的絕對下限要換算（0.75 → 0.3），否則門檻會被悄悄收緊。
  - **旋轉的反向映射符號**：寫錯會把 +20° 的線轉成 40°（傾角加倍）而不是 0°。
    degree-3 基線會把傾角吸收掉，所以這個錯誤自己不會浮出來——加了
    `residualAxisAngleDeg` 與斷言把它釘住。
- **`blade_analysis_service.dart`**（編排層）：門檻表（前後緣 rms 比 5.0 / 2.0 / 1.5
  → severity 5 / 4 / 2）與原型 `report.py` 同一組數值，寫在一個地方。
  - 未過品質閘門的照片不進演算法，判斷用 `qualityOk != true`（`null` 是「還沒驗過」）。
  - 未超門檻的量測值**存進 DB 但不進報告**：那是下次複拍比趨勢的依據，可是把
    「比值 0.93、未超門檻」印成一列「待判定」會讓報告看起來有懸而未決的事項。
  - **演算法的 severity 是下限，AI 只能往上加**；AI 說「這是正常結構」時不刪掉發現，
    把理由寫進描述交給人工。
  - 摘要**明寫幾何層與動態層「本次未進行」**——只寫「未檢出異常」會被讀成
    「整支葉片都查過了」。
- **`blade_capture_gate.dart`**：規格原本計畫「給 `image_quality_service` 加遮罩參數」，
  實作時改為**不動它、另寫一支重新決定哪些條件該擋**。那組門檻是以儀表近拍校準的，
  葉片照大半是天空，三個量都會偏（Laplacian 變異數是整張平均、藍天 180–230、
  陰天白空 240+ 直接踩到 `maxBrightness = 228`）。只擋讀不到檔與整張過暗，其餘降為提醒。
  模糊降為提醒的理由是**失敗方向安全**：邊緣模糊後輪廓變平滑 → 殘差變小 →
  前後緣比變小 → 漏判而不是誤判。四個原始量全存進 `qualityJson`，供日後拿真實照片重新定門檻。
- **`blade_ai_service.dart`**：葉片專用 prompt（正常結構清單、演算法數值標為事實、
  保守判斷、JSON schema）、severity/confidence 值域夾回、失敗往上丟讓呼叫端排佇列。
  `gemini_service.dart` 只加一個 `analyzeImageWithPrompt`，現有定檢 prompt 一字未動。
- **三個畫面**：`blade_inspection_screen.dart`（五步流程，第四步人工確認不可跳過）、
  `blade_capture_guide_screen.dart`（格位清單 + 上次同格位照片對照 + GPS 導回拍攝點）、
  `dashboard_screen.dart` 第三個入口。
- **取像方式修正規格**：原計畫用 `camera` 即時預覽疊剪影，改為**系統相機
  （`image_picker`）**。Flutter `camera` plugin 只拿得到邏輯相機，5x 望遠鏡頭切換與
  最高像素模式都碰不到（`ResolutionPreset.max` 是支援的預設值，不是感光元件全解析度），
  而 §3.1/§5.2 的物理前提正是建立在那兩件事上。取景重複性改由「上次照片對照 + GPS
  導回拍攝點（< 15 m）」達成。**照片一律原尺寸保存**，不走 `PhotoService.compressPhoto`
  （降到 1280×960 等於丟掉 4.8 cm/px 的量測前提）。
- **葉片報告不輸出「合格」**：`blade_report_builder.dart` 的 `allowedVerdicts` 只有
  不合格/警告/待判定；零檢出寫「本次未檢出超出門檻的異常。這不等於葉片沒有問題…」。
  人工駁回的發現不列成項目，但**照片照樣附進報告**——駁回的是「這是缺陷」這個判斷，
  不是「這張照片存在」這件事。
- 測試 155 → 211（葉片相關 +52：表面層 8、報告 9、AI 8、編排 18、拍攝閘門 9，
  migration 2 → 6）。

**Phase 1 的已知缺口**（實作完盤點出來的，不是設計上的取捨）：

1. **`geminiOfflinePending` 沒有補跑機制。** 離線時偵測會標成「AI 解讀待補」並存進 DB，
   畫面上也標示出來了，但**沒有任何東西在連線後把它跑完**。`share_queue_service`
   有現成的佇列模式可沿用（`ConnectivityService` 的 onlineStream + 啟動時掃一次）。
   目前的實際行為：那筆偵測永遠只有演算法的數值，除非使用者手動重新分析整個場次。
2. **沒有葉片歷史紀錄／趨勢畫面。** `getWtSessions()` 目前只被呼叫一次而且是 `limit: 1`
   （拿上次的照片當取景參考）；`getWtSessionsPendingShare()` **零呼叫端**，
   所以葉片報告也還沒接上離線分享佇列。資料模型做成資產驅動的整個理由是跨次比對
   （LAUNCH_PLAN §5.6：「價值在跨次比對出新增的東西」），而那個價值現在沒有 UI 可以看：
   未超門檻的量測值有存下來，但沒有畫面把同一台風機同一格位的歷次 rms 比排在一起。

兩者都不影響單次篩檢的正確性，但第 2 項是「Phase 1 只交付得出單次篩檢」的實際原因。

### 2026-09-06（風力機葉片模組 Phase 0 — 獨立功能）

**追加：聲音層 + 圖文報告**（同日）

- `blade_prototype/blade_proto/acoustics.py`：逐片聲音異常。音軌 STFT → 包絡自相關求
  葉片通過週期 → 依通過時刻切成三份互比。前緣侵蝕看寬頻位準（只有偏高才算缺陷），
  後緣裂縫看窄頻哨音（只有單片出現才算）。風噪／訊噪比／週期信賴度三重守門，
  不可用就明說不可用。合成資料實測：+3 dB 寬頻差異可指對葉片；風噪過大時是**漏判**不是誤判。
- `report.py` / `charts.py`：單一自帶內容 HTML 圖文報告（零 JS，可列印成 PDF）。
  **Flutter 端的 PDF 葉片章節可直接對照這份版面**（六張圖表、逐片數值表、待人工確認欄）。
- App 端要注意：聲音層需要錄影時的音軌，`image_picker` 錄的影片有音軌，
  但**拍照流程沒有**——葉片模組的影片拍攝要另走 `camera` 套件並確認 `enableAudio: true`。

- **docs**: 新增 `BLADE_INSPECTION_SPEC.md` — 手機地面拍葉片的目視檢測模組規格。
  定位為**獨立功能**（資產驅動：主鍵是某台風機的某片葉片、反覆檢測跨次比對），
  與定檢表 pipeline（表單驅動）平行，**不整合進 `form_inspection_screen.dart`**。
- **feat**: 新增 `blade_prototype/`（Python/OpenCV，23 pytest，已納入 CI）——
  規格 §5.1–5.4 的參考實作，用於外業前量化可偵測門檻、外業後跑真實資料，
  並作為日後 Dart 移植的對照。四層偵測：表面（前緣粗糙度）、幾何（三片中心線互比）、
  動態（影片轉速/六點鐘取幀）、周邊。
- **量化結論**（`blade_prototype/SENSITIVITY.md`，合成影像上限）：
  正視整轉子在 12 MP 橫幅需 ≥ 4.8 cm/px 才塞得進畫面，此時 50 cm 葉尖偏移可分辨、
  25 cm 不行；側視垂掛葉片直幅 2.5–3.5 cm/px 可用；5x 長焦在 50 m 可分辨 1 cm 深的前緣凹坑。
  **整轉子幾何靠主鏡頭高像素模式，不靠長焦**（長焦塞不進整個轉子）。
- **對 Flutter 端的影響**（四項均已於 2026-09-07 Phase 1 處理，做法見該條）：
  - ✅ DB 升 v5，新增三張獨立表
  - ✅ 曝光誤判：**沒有**改 `image_quality_service.dart` 加遮罩，改為另寫
    `blade_capture_gate.dart` 重新決定哪些條件該擋（遮罩要先分割，而分割正是
    要被閘門守的那一步，順序上倒過來了）
  - ✅ 不沿用「無異常即 pass」：`human_status` 預設 `pending`，報告不輸出「合格」
  - ✅ 全解析度原圖不壓縮：拍攝流程不走 `PhotoService.compressPhoto`

### 2026-09-04（後端 SDK 汰換 — LAUNCH_PLAN P1）

- **refactor(backend)**: `google-generativeai`（已停止維護）→ **`google-genai`**。
  新增 `backend/app/services/gemini_client.py` 作為唯一 Gemini 入口：
  - **延遲建立 client**：新版 `Client(api_key="")` 會直接拋 ValueError，若沿用
    「在 `__init__` 建 client」的舊寫法，連不需要 AI 的路徑（Excel/Word 回填、
    結構分析）都會因為沒設 key 而整條掛掉。改為呼叫時才建。
  - **依 key 快取**：`FormFillService` 每請求 new 一次，原本等於每請求建一個 HTTP client。
  - 移除各 service 的 `genai.configure()` 全域狀態；`AutoFillService` 根本沒用到 Gemini，
    其 genai 依賴一併刪除。
- **fix(rag)**: 文件匯入的 `PROCESSING` 輪詢加上 120 秒上限，避免檔案卡住時請求無限等待。
- **deps**: `google-genai` 要求 `httpx>=0.28.1` 與 `pydantic>=2.12.5`，而 httpx 0.28 移除了
  `Client(app=...)` 捷徑、舊 starlette(0.35) 的 TestClient 仍在用它 → 相依鏈強制連帶升版：
  `httpx` 0.26.0→0.28.1、`pydantic` 2.5.3→2.13.5、`fastapi` 0.109.0→0.116.1（starlette 0.47 線）。
- **test**: +19 `backend/tests/test_gemini_client.py`（延遲建立、依 key 快取、`generate_text`
  模型與空回應處理、檔案狀態 enum/物件/字串三形態、embedding task_type 鎖定、
  舊 SDK 不再被 import 的守門）。後端 172 → **191 pytest**。
  `test_judge_readings_endpoint.py` 的 NaN/Infinity 兩測改送原始 body——httpx 0.28 的
  `json=` 會在客戶端就拒絕非標準 JSON，會讓「伺服器必須擋下 NaN」（Issue #47）失去覆蓋。

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
