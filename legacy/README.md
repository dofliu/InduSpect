# Legacy — React 網頁原型（已凍結）

此目錄是專案第一階段（可行性驗證）的 Google AI Studio React + Vite 原型，
**已由 `flutter_app/` 取代，不再維護、不部署、不在 CI 範圍**。

保留原因：提示工程與 2D 測量工具的原始實作留作參考（相關邏輯已移植至
`flutter_app/lib/models/measurement.dart` 與 `aimodel.md`）。

注意：`vite.config.ts` 會從**專案根目錄**的 `.env` 讀取 `GEMINI_API_KEY`
並內嵌到前端 bundle——這是原型時代的做法，不可用於任何對外部署。
（根目錄 `.gitignore` 已排除 `.env` 防止誤 commit。）
