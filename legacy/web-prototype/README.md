# Legacy Web 原型（已凍結）

這裡是 InduSpect 最早的 **React + Vite + TypeScript 網頁原型**（原為 Google AI Studio 匯出），用來驗證核心 AI 流程（拍照 → Gemini 分析 → 顯示結構化資料）。

> ⚠️ **已凍結，不再維護。** 現役產品為根目錄的 `flutter_app/`（行動 App）+ `backend/`（FastAPI）。
> 保留此原型僅供參考。若確定不再需要，可整個刪除 `legacy/` 目錄（git history 仍可還原）。

## 原本的執行方式（僅供參考）

```bash
npm install
npm run dev
```

需要 `GEMINI_API_KEY` 環境變數。對應的完整重建規格見根目錄 [`AISTUDIO_REBUILD_SPEC.md`](../../AISTUDIO_REBUILD_SPEC.md)。
