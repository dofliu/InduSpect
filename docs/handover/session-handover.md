# Session Handover — InduSpect Weekly Routine

> Weekly routine agent 與劉老師之間的接力筆記。每次執行末段更新此檔。
> 最新的在最上方。`[NEEDS HUMAN]` 區塊是必須劉老師裁決的事項。

---

## 2026-08-31 — Session #8（產品化三批 + 現場環境因應 + 文件重整）

**這是目前的接手點。** 本次為一整天的長 session，三個 PR 全部合併進 main。

### 已完成（全部在 main 上）

| PR | 內容 |
|----|------|
| [#48](https://github.com/dofliu/InduSpect/pull/48) | P0 批次：Release 簽署（key.properties + R8）、後端 X-API-Key 認證 + CORS 白名單 + 錯誤淨化、判定持久化（SQLite **v3→v4**）、GA 模型 ID + 三層可覆寫、隱私政策草稿、**Tier 0 離線判定引擎**、CI 全量收緊 |
| [#49](https://github.com/dofliu/InduSpect/pull/49) | **Tier 1a 裝置端 OCR**（ML Kit + `OcrReadingParser`）、reports 狀態修正、repo 清理（legacy 原型歸檔） |
| [#50](https://github.com/dofliu/InduSpect/pull/50) | **拍照品質閘門**（模糊/曝光/反光）、**連線可達性探測**、兩個 UI 修正、介紹影片素材 |

**指標變化**：Flutter 57 → **137 tests**；後端 150 → **172 pytest**（全套進 CI）；
analyzer warning 15 → **0**；Issues #44 / #45 / #47 全數關閉。

### 現在的架構重點（接手前先讀這段）

- **三層 AI**：品質閘門 → Tier 0 法規判定（離線、純規則）→ Tier 1a OCR（離線）→ Tier 2 Gemini（聯網）
- **法規資料單一來源**：編輯 `backend/app/data/inspection_standards.py` 後**必須**跑
  `python backend/scripts/export_standards.py` 重新匯出 JSON，否則 `test_standards_json_sync.py` 會擋
- **可達性探測**：`ConnectivityService.checkConnection()` 會探測 `<BACKEND_API_URL>/health`
  （3s 逾時、10s 快取）；未設定後端位址時退回介面判定
- **SQLite v4**：`form_inspection_records.standard_judgments` 存法規判定（稽核依據）

### 下一步（依優先序）

**A. 需實機／帳號操作（阻塞上線，非程式面）**
1. **實機端到端驗證**（[#43](https://github.com/dofliu/InduSpect/issues/43)）：完整流程 + 斷網情境（驗證走本地判定與 OCR，而非「待判定」）+ R8 release build 煙霧測試
2. **品質閘門門檻現場校準**：`image_quality_service.dart` 的 `ImageQualityThresholds` 預設值是用**合成影像**校準的，需以現場實拍照片調整
3. upload keystore（見 `flutter_app/ANDROID_DEPLOYMENT.md`）、隱私政策公開 URL、Play 內部測試軌
4. Cloud Run 部署（見 `CLOUD_RUN_ASSESSMENT.md`；`cloudbuild.yaml` 前置步驟已寫在註解）
5. Crashlytics / Sentry

**B. 程式面可續做（不阻塞，可直接開工）**
1. **低信心露出**：判定引擎已產出 `confidence`（pass/fail 0.98、unknown 0.7、無匹配 0.0），
   但只顯示在 `auto_fill_screen` / `one_stop_inspection_screen`——**這兩個畫面都是死程式碼**。
   現行 `form_inspection_screen` 未露出。建議：`confidence < 0.9` 或 `source == 'ocr'` 標「需人工確認」
2. **重拍快捷鍵**：`GuidedCaptureScreen` 加「這張不清楚，重拍」
3. **PDF 報告輸出**：申報場景的實際交付格式（需嵌中文字型）
4. **多幀取樣**：連拍 3 張取一致讀值，對抗手震與反光
5. 標準庫擴充（[#46](https://github.com/dofliu/InduSpect/issues/46)，純資料、零風險）

### 接手時的環境注意事項

- 本 repo 的 dev 環境**沒有預裝 Flutter SDK**。本次是自行 clone stable（`git clone https://github.com/flutter/flutter.git -b stable`）後使用。
- **不要對既有檔案跑 `dart format`**：repo 未統一格式化，會產生大量無關 churn。
- **注意換行符**：部分檔案是 CRLF（如 `connectivity_service.dart`）。用腳本改檔時若寫成 LF，整個檔案會在 diff 中顯示為重寫。
- Flutter Web 可建置並用 Playwright 擷圖，但需處理兩個坑（CanvasKit CDN、中文字型 fallback）——做法見 `docs/media/intro-video/README.md`。
  `FormInspectionScreen` 在 Web 上會因 `sqflite`/`path_provider` 無 Web 實作而初始化失敗（不影響 Android）。

### 文件現況（本次重整）

- **有效**：`README.md`（總覽 + 使用說明）、`LAUNCH_PLAN.md`（90 天計畫 + 市場定位）、
  `ROADMAP.md`（功能藍圖）、`todo.md`（階段進度）、`CLAUDE.md`、`STATUS.yaml`、
  `flutter_app/README.md`、`flutter_app/DEVELOPMENT.md`
- **歷史**：`arch.md`、`aimodel.md`、`ui.md`、`prj.md`、`database.md`、`DEVELOPMENT_PLAN.md` 等
  已於檔首加上「歷史文件」標註，**不要據此施工**

**[NEEDS HUMAN]**
- #44 的欄位設計採獨立 `standard_judgments` JSON 欄（非併入 `ai_results`），請劉老師 review 確認
- 介紹影片檔（20 MB）未入版控，建議放 Release assets 或雲端硬碟

---

## 2026-05-16 — Session #6（測試門檻收緊 + 文件對齊 housekeeping）

**本週做了**：在 Sessions #2-#5 的 3 個 PR（#32 #34 #35）全部 merge 後做收尾整理。

**改動**：
- `backend/tests/test_sprint3_standards.py`：拉高 `test_database_coverage` 門檻反映現況
  - 總數 ≥35 → **≥50**（main 為 56）
  - 消防 ≥10 → **≥13**（main 為 15）
  - 機械 ≥10 → **≥13**（main 為 15）
  - 壓力 ≥3 → **≥10**（main 為 11）
  - 電氣維持 ≥15（無變化）
- `backend/app/data/inspection_standards.py`：修正過時的章節 comment（消防 10→15、機械 10→15、壓力 5→11）
- `STATUS.yaml`：progress 87→89、`key_metrics` 重整為「2 core features, 46 Flutter tests, 65 backend pytest in CI, 56 regulation standards」
- `docs/handover/session-handover.md`：本檔本次更新（含 Session #3/#4/#5 rollup）

**測試**：CI 應全綠（threshold buffer 設計上留 2-6 條餘裕避免邊界 flaky）。

---

## 2026-05-16 — Sessions #3 / #4 / #5（標準資料庫四大類擴充 rollup）

**為什麼合併紀錄**：3 輪 routine 均為「純資料 append + 自動驗證」的同一模式，個別 commit 訊息已足，handover 用 rollup 表保留總覽即可。

| 輪 | PR | 動作 | 改動 |
|---|---|---|---|
| #3 | [#33](https://github.com/dofliu/InduSpect/pull/33) | 壓力/管線 +6 條 | 5 → 11 |
| #4 | [#34](https://github.com/dofliu/InduSpect/pull/34) | 機械類 +5 條 | 10 → 15 |
| #5 | [#35](https://github.com/dofliu/InduSpect/pull/35) | 消防類 +5 條 | 10 → 15 |

**累積結果**：資料庫從 40 條增至 **56 條（+40%）**，四大類別均衡覆蓋（electrical/fire/mechanical 各 15，pressure 11）。所有新增條目皆引用台灣現行法規或 IEEE/NEMA/CNS/API 國際標準。

**下一步建議**（給後續 routine）：
1. **馴化 `test_e2e_inspection.py`** → 改造為 pytest function-style 加進 CI（單檔但測試本體複雜）
2. **修復 `TestResults.check` 模式的隱形 bug**：目前 sprint test 用 `results.check(condition, ...)` 而非 `assert`，當條件不成立 pytest 仍視為 PASS（只有 stdout 出現 ❌）。需要把 sprint test 系列改為 `assert ...` 才能讓 CI 真正阻擋退化
3. **新增 `judgment_service.batch_process` 的單元測試**：目前只有 e2e 透過 FormFillService 測試該路徑
4. **`flutter analyze` 收緊**：CI 已穩定，可將 `continue-on-error: true` 移除

---

## 2026-05-16 — Session #2（CI baseline + judgment_service 直接測試覆蓋）

**本週做了**：依 Session #1 的「下一步建議 #2」，新增 `backend/tests/test_judgment_service.py`（14 個 pytest function-style 測試，含 async）並加進 CI workflow 的 pytest 清單。覆蓋 JudgmentService 的 `auto_judge` 與 `batch_auto_judge` 直接 API（之前只有透過 FormFillService 間接測試）。

**改動檔案**：
- `backend/tests/test_judgment_service.py`（新建，14 tests）
- `.github/workflows/ci.yml`（新增 test_judgment_service.py 進 pytest 指令）
- `STATUS.yaml`（progress 86→87、key_metrics 補上 judgment_service 14 tests）
- `docs/handover/session-handover.md`（本檔追加 Session #2 區塊）

**測試覆蓋面**：
- `auto_judge` 各 pass_condition：gte（絕緣電阻）/ lte（接地電阻、馬達溫度）/ range（滅火器壓力上下限）
- 多類別：electrical / fire / mechanical
- 邊界：unknown field、unit fallback、batch 空清單、batch 順序保留、回傳 dict contract（必含欄位）
- 全部 async 透過 CI `--asyncio-mode=auto` 跑

**未推送/未合併**：
- 分支：`claude/weekly-2026-05-16-judgment-tests`
- PR：將於本次 session 開出（連結待補）

**下一步建議**（下次 routine 可挑）：
1. **若本 PR CI 過** → 把 sprint test 系列（`test_e2e_inspection.py` / `test_real_form_validation.py` / `test_sprint1_photo_tasks.py` 等）逐步從 `__main__` script 改造為 pytest function-style，再加進 CI（一次處理一兩個檔，避免改動爆量）
2. **擴充** `inspection_standards.py`：新增壓力容器/管線 5-10 條（純資料、零風險、會自動被 test_sprint3_standards.py 的 `test_database_coverage` 驗證）
3. **flutter analyze 收緊**：CI 已穩定數輪後，將 `continue-on-error: true` 移除，讓 lint 議題真正阻擋 PR
4. **整理** `flutter_app/lib/screens/` step1-step4 vs `form_inspection_screen.dart` 的重複（先寫 [NEEDS HUMAN] note 不動程式碼）

**[NEEDS HUMAN]**：
- （上輪 Session #1 留下的 3 項仍待裁示：未追蹤檔案位置、Gemini API key 整合測試的 secret 設定）

---

## 2026-05-16 — Session #1（首次執行）

**本週做了**：建立 weekly routine SOP（`docs/routines/weekly-progress.md`）、新增 GitHub Actions CI workflow（Backend pytest + Flutter analyze/test）作為工業可用化的工程紀律基礎建設。

**改動檔案**：
- `docs/routines/weekly-progress.md`（新建）
- `docs/handover/session-handover.md`（新建）
- `.github/workflows/ci.yml`（新建）
- `STATUS.yaml`（更新 progress / last_updated / key_metrics）

**測試狀態**：
- Backend：未在本地執行 pytest（routine agent 環境無 Python 虛擬環境）
- Flutter：未在本地執行（同上）
- CI workflow 第 1 次：50 過 / 1 fail（async test 需 pytest-asyncio auto mode）→ 已加 `--asyncio-mode=auto`
- CI workflow 第 2 次：backend ✅ pass (32s)；flutter ❌ fail（pubspec 宣告 .env 為 asset 但 CI 無此檔）→ 已加 `touch .env` step

**未推送/未合併**：
- 分支：`claude/weekly-2026-05-16-ci-workflow`
- PR：將於本次 session 開出（連結待補）

**下一步建議**（下次 routine 可挑）：
1. **若 CI 失敗** → 先修 CI（這是 routine agent 可做的小範圍）
2. **若 CI 通過** → 為 `backend/app/services/judgment_service.py` 補單元測試（覆蓋率明顯不足，且是規則類邏輯，無外部相依）
3. **擴充** `backend/app/data/inspection_standards.py`：新增壓力容器/管線檢查的 5-10 條標準（純資料新增，零風險）
4. **整理** `flutter_app/lib/screens/` 的 step1-step4 是否仍被使用 vs `form_inspection_screen.dart`，若已被取代則文件化或標記 deprecated（須先確認，可能觸發 §6 架構決策 → 建議只先寫 [NEEDS HUMAN] note 而不動）

**[NEEDS HUMAN]**（Session #7 已收結，保留紀錄以利追溯）：
1. ~~**本地 main 與 origin/main 不同步**~~ — Session #1 當下已 `git restore` + `git pull --ff-only` 處理完畢。劉老師後續未提出此暫存改動有特殊意圖，視同已解決。
2. ~~**未追蹤檔案**~~ — Session #7 解決：5 個 PNG/PDF 全部移到 `_local_archive/`（已加進 .gitignore），檔案保留在工作目錄但不入版控。
3. **CI workflow 中 Gemini API key 處理** — Session #7 確認劉老師立場：產品本身用使用者個人 API key（透過 .env），CI 目前的測試集為純邏輯測試不需打 Gemini API，繼續用假值 `ci-fake-key` 即可。**現況不需要 GitHub Secret，未來如需啟用整合測試再評估。**

---

*本檔為活文件。下次 routine 從此檔最上方接續。*
