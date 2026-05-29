# InduSpect AI 專案開發規範

> **單一事實來源（SSOT）**：本專案的開發紅線、慣例、關鍵檔案以根目錄
> [`CLAUDE.md`](../CLAUDE.md) 為準；後續工作方向見 [`ROADMAP.md`](../ROADMAP.md)。
> 本檔僅保留快速摘要，避免與 CLAUDE.md 重複/分歧。

## 專案概述

工業設備智慧巡檢系統：**Flutter 行動 App + FastAPI 後端 + Google Gemini AI**。
聚焦兩大核心功能：完整檢測 Pipeline、歷史紀錄（詳見 `CLAUDE.md`）。

## 技術棧

- **前端**：Flutter 3.x（Dart 3.2+）、Provider 狀態管理、SQLite（sqflite）離線優先
- **後端**：FastAPI（Python 3.11）—— 表單回填、法規標準判定（`judge-readings`）
- **AI**：Google Gemini（圖像分析 + 摘要報告）

## 開發規範（摘要）

- 程式碼：Dart 官方風格 + `analysis_options.yaml` lint；camelCase / PascalCase；私有前綴 `_`。
- 路徑操作一律用 `package:path`，不手動 split；日期用 ISO8601；繁體中文註解、技術術語保留英文。
- AI 呼叫使用結構化 JSON 輸出 + 思維鏈引導（實際 prompt 見 `flutter_app/lib/services/gemini_service.dart`）。
- 離線優先：先存本地 SQLite，連線後背景同步，UI 顯示同步狀態。
- DB schema 變更必須附 migration 並處理既有使用者升級路徑。

## 檔案結構

```
flutter_app/lib/{models,services,screens,widgets,providers,utils}/
backend/app/{api,services,data,db}/
```

## 分支與測試

- 分支：`main` 穩定版；`claude/*` AI 輔助開發分支；功能開發開 feature 分支。
- 測試：前端 `flutter test`、後端 `pytest tests/ --asyncio-mode=auto`；提交前確保通過，CI 會自動驗證。

## 文件導覽

詳見根目錄 [`README.md`](../README.md) 的「文件導覽」表。已完成的歷史計畫與隱藏功能規格存於 [`docs/archive/`](../docs/archive/)。
