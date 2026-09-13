# Session Handover — InduSpect Weekly Routine

> Weekly routine agent 與劉老師之間的接力筆記。每次執行末段更新此檔。
> 最新的在最上方。`[NEEDS HUMAN]` 區塊是必須劉老師裁決的事項。

---

## 2026-09-13 — 文件整理與 Mode B B0（接棒重點）

**如果你是下一個 session，只讀這一段就夠開工。**

### 現在在哪裡

| 產品線 | 狀態 |
|---|---|
| 定檢表 pipeline | 程式面完成。**唯一擋路石是實機端到端測試**（Issue #43） |
| 葉片 Mode A（地面整機） | App 端完整實作（表面／幾何／聲音層）。影片抽幀的 Kotlin **從未被編譯過** |
| 葉片 Mode B（近身影像） | 規格 + 分類表 + 語料實測完成，**演算法一行都還沒寫** |

CI 三軌全綠：Flutter 497 / 後端 191 / 葉片原型 115，另有死角查核擋 PR。

### 這一輪做了什麼

1. **[PR #69](https://github.com/dofliu/InduSpect/pull/69)（draft，CI 全綠，等合併）** — Mode B 的 B0：
   - `BLADE_CLOSEUP_TAXONOMY.md`（由 `blade_prototype/data/closeup_taxonomy.json` 渲染，15 條守門測試）
   - `blade_prototype/CLOSEUP_BASELINE_REPORT.md`（語料實測）
2. **文件整理**（本次 commit）：根目錄 markdown 由 22 份降到 8 份。詳見下方「文件在哪裡」。

### 文件在哪裡（整理後）

| 要找什麼 | 去哪裡 |
|---|---|
| 系統做什麼、為什麼 | `README.md` |
| 怎麼操作 | `docs/USER_GUIDE.md`（**新檔**，操作步驟從 README 搬過來） |
| 開發規則、關鍵檔案、已知問題 | `CLAUDE.md` |
| App 架構、DB schema、變更紀錄 | `flutter_app/DEVELOPMENT.md` |
| 功能規劃 / 上線計畫 | `ROADMAP.md` / `LAUNCH_PLAN.md`（§0 有進度更新） |
| 已完成或已被取代的文件 | `docs/archive/`（**不要照著做**，該目錄的 README 說明每一份為什麼被歸檔） |

**刪掉的 7 份**（`arch.md`、`database.md`、`ui.md`、`prj.md`、`todo.md`、
`feature_enhancements.md`、`COMPILE_CHECK_REPORT.md`）描述的是**專案沒有採用的架構**
（Supabase / GCP 無伺服器 / 登入流程），留著會誤導。內容仍在 git 歷史。

### 2026-09-13 追加：健康照與正常結構第一版已做

`blade_prototype/CLOSEUP_HEALTHY_SET.md`。全語料取像判定（839 合格／`crack` 0/177）、192 張正常結構普查
（避雷接點／VG 板／排水孔 **0 張**；標註痕跡 **35%**）、約 1,200 格健康候選（`unreviewed`）、8 張概略框。
**全部單一標註者未複核。** 下一步是人工複核，不是再寫程式。

### 下一步建議（依可行性排序）

1. **合併 PR #69**（draft、CI 全綠，等劉老師決定時機）
2. **Mode B 健康候選的人工複核** — 第一版已挖出約 1,200 格候選與 192 張正常結構標記（見上），但全部未複核。B0 量到現有可商用語料 1065 張**一張健康照都沒有**，
   §6 第 4 條的誤報分項統計執行不了。`BLADE_CLOSEUP_TAXONOMY.md` §2 的 12 項正常結構
   就是拍攝清單。這件事**不需要實機也不需要外業**，是目前唯一能純線上推進的葉片工作
3. **B1 評估協定實作**（葉片級切分、逐類指標、低光照子集）——同樣純線上可做
4. 其餘葉片工作與定檢主線都**卡在實體世界**，見下方 NEEDS HUMAN

### [NEEDS HUMAN] 卡住的四件事

1. **實機端到端測試**（Issue #43）——需要一台 Android 實機。同一趟請確認
   `android/.../BladeVideoFrames.kt` build 得起來、`getFrameAtTime` 在目標機型回得出幀
2. **葉片外業**——一次現場拍攝（停機 + 怠速各一台）即可定葉片拍攝閘門與聲學門檻，
   同一趟收 Phase 4 的語料。目前**真實手機拍的葉片照片是 0 張**
3. **後端 Cloud Run 部署**——需要 GCP 帳號操作
4. **Play 內部測試軌上架**——需要 keystore 與開發者帳號

### 踩過的坑（省下一次重複）

- **Wikimedia Commons 從本環境會 429**（API 與 upload 都會），語料抓取一律走 Openverse
- **Openverse 對查詢字做 AND 比對**：長查詢字結果歸零，短查詢字相關性崩掉，中間沒有地帶
- **`aimodel.md` 已歸檔**，模型 ID 與路由邏輯已汰換；後端一律走 `gemini_client.py`
- `blade_prototype` 全套測試約 130 秒，超過 Bash 工具預設 120 秒逾時，要加 `timeout`

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
