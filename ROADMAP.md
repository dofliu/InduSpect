# InduSpect AI — 前瞻路線圖

> **最後更新**：2026-05-29
> **目的**：定義「後續要做什麼」的大方向與近期可執行任務。
> 長期目標：**6 個月內讓 InduSpect 通過一個真實工廠的試用**。
> 本檔只放「未來工作」；已完成的歷史計畫見 [`docs/archive/`](docs/archive/)，每週進度見 [`docs/handover/session-handover.md`](docs/handover/session-handover.md)。

---

## 現況（2026-05-29）

- 兩大核心功能（完整檢測 Pipeline、歷史紀錄）已可運作。
- 自動 AI 定檢已串接**法規標準判定**（量測欄位自動帶出合格/不合格/警告 + 法規依據，含單位換算）。
- 後端 150 pytest 全綠；前端 59 單元測試；CI 每 PR 自動跑。
- **主要缺口**：缺乏實機端到端驗證；CI 仍有 advisory/假陽性的測試紀律問題；判定結果尚未持久化到歷史。

---

## 大目標（依優先序）

### G1. 實機端到端驗證與穩定化 🔴 最高優先
讓核心 Pipeline 在真實 Android 裝置上跑通並穩定。
- 實機完整流程：上傳 Excel → 一鍵自動檢測 → 法規判定回填 → 匯出 → 分享。
- 離線情境：斷網完成檢測 → 恢復網路 → 確認自動分享 + 待判定項目重新判定。
- `flutter analyze` / `flutter test` 在有 SDK 環境跑通並修正 lint。
- 大量歷史紀錄時的列表滾動效能。
> 多數子項需**現場/實機**，非 routine agent 可獨力完成 → 由人類驗證、routine 負責可自動化的修補。

### G2. 工程紀律收緊 🟠
讓 CI 真正能擋住退化。
- 移除 `ci.yml` 中 `flutter analyze` 的 `continue-on-error`（清完 lint 後）。
- 修正 sprint test 的 `TestResults.check` 假陽性（改為 `assert`，否則條件不成立仍 PASS）。
- 把 `__main__`-style 的 sprint test 逐檔改造為 pytest function-style 並納入 CI。

### G3. 法規判定深化 🟠
讓判定結果完整可稽核。
- **判定結果持久化**：`standardJudgment` 存入 `form_inspection_records`（目前僅 session 內，重開草稿會遺失）。
- 擴充 `inspection_standards.py`（56 → 更多條；補齊更多設備類別與單位變體）。
- 判定信心度與多標準衝突的處理策略。

### G4. 可靠性與錯誤處理 🟡
- 邊角案例與錯誤處理（AI 回傳異常 JSON、讀數無法解析、後端逾時降級）。
- 後端輸入驗證與一致的錯誤回應格式。

### G5. 使用者與維運文件 🟡
- 現場操作手冊（給巡檢員的圖文步驟）。
- API 文件（OpenAPI/Swagger 整理）。

### G6. 部署（長期）⚪
- 依 [`docs/archive/CLOUD_RUN_ASSESSMENT.md`](docs/archive/CLOUD_RUN_ASSESSMENT.md) 評估 Cloud Run 上線（Cloud SQL + pgvector、Secret Manager、CORS 收斂）。
- 需架構與成本決策 → **由人類拍板**，非 routine 自動進行。

---

## 近期可執行任務（GitHub Issues）

以下拆成可獨立完成的小任務，開為 GitHub Issues 供每週 routine 取用。
**routine 可自動承接**的任務以標題前綴 `[routine-ok]` 標示（小步、可驗證、可回滾）；
需人類裁決的以 `[needs-human]` 標示。（若日後建立 `weekly-routine-ok` label 亦可改用 label 過濾。）

| 對應大目標 | 任務 | 適合 routine 自動做？ |
|---|---|---|
| G3 | 判定結果持久化到 SQLite（新增欄位 + migration + 測試） | ⚠️ 觸及 schema，需人類確認後再放行 |
| G2 | sprint test `TestResults.check` → `assert` 改造（一次一檔） | ✅ |
| G2 | 將 1-2 個 `__main__`-style 測試改 pytest 並加進 CI | ✅ |
| G3 | `inspection_standards.py` 擴充 5-10 條新標準 | ✅ |
| G4 | 後端 judge-readings 輸入驗證 + 邊角案例測試 | ✅ |
| G5 | 後端 API 文件（OpenAPI 描述補完） | ✅ |
| G1 | 實機端到端驗證腳本與檢查清單 | ❌ 需實機 |

---

## 推進機制：Workflow vs Routine

關於「是否可用 workflow 來進行」：

- **GitHub Actions workflow（`ci.yml`）**：負責**自動化驗證**（每 PR 跑 backend pytest + Flutter analyze/test），**不**做自主開發。它是「守門員」，不是「開發者」。
- **每週 routine（推進開發）**：由 **Claude Code on the web** 搭配 `/loop` 定時執行 [`docs/routines/weekly-progress.md`](docs/routines/weekly-progress.md) 的 SOP，**從 GitHub Issues（label `weekly-routine-ok`）取一條小任務**→ 開分支 → 做 → 測 → 開 PR（不自動 merge）。
- **分工**：大目標寫在本檔 → 拆成 Issues → routine 逐週消化可自動化的 → 需現場/架構決策的留給人類。

> 簡言之：**Actions 驗證、Routine 推進、Issues 當任務佇列、人類做關鍵裁決**。
