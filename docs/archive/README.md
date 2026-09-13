# 歸檔文件

這裡的文件**已完成任務或已被取代，不再維護**。保留是為了留下決策紀錄，
不是為了給人照著做。任何與現況衝突的地方，以下列現行文件為準：

| 現況看這裡 | |
|---|---|
| [`../../README.md`](../../README.md) | 專案總覽 |
| [`../USER_GUIDE.md`](../USER_GUIDE.md) | 使用手冊 |
| [`../../CLAUDE.md`](../../CLAUDE.md) | 開發規則與已知問題 |
| [`../../flutter_app/DEVELOPMENT.md`](../../flutter_app/DEVELOPMENT.md) | App 架構、DB schema、變更紀錄 |
| [`../../ROADMAP.md`](../../ROADMAP.md) | 功能規劃 |
| [`../../LAUNCH_PLAN.md`](../../LAUNCH_PLAN.md) | 上線計畫 |

---

## 已完成的計畫

| 文件 | 內容 | 為什麼歸檔 |
|---|---|---|
| [`FLUTTER_MIGRATION_PLAN.md`](FLUTTER_MIGRATION_PLAN.md) | React Web → Flutter 遷移計畫（2026-03） | 遷移已完成，Web 原型凍結在 [`legacy/`](../../legacy/) |
| [`REFACTORING_PLAN.md`](REFACTORING_PLAN.md) | 後端重構計畫（2026-03） | 已完成，`form_fill.py` 由 3,053 行拆到現在的 405 行；成果表在文件末 |
| [`DEVELOPMENT_PLAN.md`](DEVELOPMENT_PLAN.md) | Sprint 1–6 定檢系統改善計畫（2026-03） | 六個 Sprint 皆已完成。**注意：文件內的 checkbox 從未被勾選**，完成狀態看每個 Sprint 的「完成時 ✅」標題 |
| [`CLOUD_RUN_ASSESSMENT.md`](CLOUD_RUN_ASSESSMENT.md) | Cloud Run 部署就緒度評估（2026-03） | 五項問題已在產品化 P0 批次處理（Artifact Registry、Secret Manager、後端認證、CORS 收緊）。部署現況看 `LAUNCH_PLAN.md` |

## 凍結的規格

| 文件 | 內容 | 為什麼歸檔 |
|---|---|---|
| [`AISTUDIO_REBUILD_SPEC.md`](AISTUDIO_REBUILD_SPEC.md) | 供 Google AI Studio 從零重建的完整規格 | **2026-05-28 的凍結快照**，之後主線新增的都沒有（Tier 0 判定引擎、離線 OCR、拍照品質閘門、PDF 報告、SQLite v4/v5、整個葉片模組）。照它重建等於重建 5 月的版本 |
| [`TEMPLATE_SYSTEM_SPEC.md`](TEMPLATE_SYSTEM_SPEC.md) | 定檢表範本系統技術規格（2025-11） | 範本系統目前是**隱藏功能**，有實作但未連到主頁 |
| [`aimodel.md`](aimodel.md) | AI 模型整合與 prompt 工程規範（2026-03） | **模型 ID 與路由邏輯已汰換**：後端改走 `backend/app/services/gemini_client.py`（`google-genai` SDK），模型 ID 可在 App 設定頁覆寫。prompt 策略的原始設計仍有參考價值 |

## 時點測試報告

[`test-reports/`](test-reports/) 下的七份 Sprint 報告、重構報告、動態範本報告與後端 walkthrough，
都是當時那個 commit 的快照。**現行測試狀態看 CI**，不看這些數字。

---

## 已刪除的文件

下列文件描述的是**專案沒有採用的架構**，留著會誤導，已於 2026-09-13 刪除（內容仍在 git 歷史）：

| 文件 | 它說的 | 實際上 |
|---|---|---|
| `arch.md` | GCP 無伺服器三層架構 + Supabase Auth | FastAPI 單體後端，App 端無登入 |
| `database.md` | Supabase PostgreSQL 關聯式 schema | 裝置端 SQLite（目前 v5），後端無資料庫 |
| `ui.md` | 登入 → 選巡檢工作 → 提交 → 登出 | 無登入；主頁三個入口（檢測／歷史／葉片） |
| `prj.md` | 早期專案願景與範圍 | 已併入 `README.md` |
| `todo.md` | 四階段開發路線圖（2025-10） | 已由 `ROADMAP.md` 與 `LAUNCH_PLAN.md` 取代 |
| `feature_enhancements.md` | 準確度優化策略（2025-10） | 已由 `ROADMAP.md` 取代 |
| `COMPILE_CHECK_REPORT.md` | 2025-11-04 的 Flutter 編譯檢查 | 時點報告，現行狀態看 CI 的 `flutter analyze` |
