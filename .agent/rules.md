# InduSpect AI 專案開發規範

## 專案概述

InduSpect AI 是一個智慧工業巡檢系統，使用 Flutter 開發行動應用，結合 Google Gemini AI 進行多模態分析。

## 技術棧

- **前端**: Flutter 3.x (Dart 3.2+)
- **AI 模型**: Google Gemini API (gemini-2.0-flash-exp)
- **狀態管理**: Provider
- **本地儲存**: SharedPreferences / SQLite
- **後端規劃**: Supabase / Firebase + GCP

## 開發規範

### 程式碼風格

- 遵循 Dart 官方風格指南
- 使用 `analysis_options.yaml` 中定義的 lint 規則
- 類別、方法需加上文檔註釋
- 變數命名使用 camelCase，類別使用 PascalCase

### 檔案結構

```
lib/
├── models/          # 資料模型
├── services/        # API 和業務邏輯服務
├── screens/         # 頁面 UI
├── widgets/         # 可重用元件
├── providers/       # 狀態管理
└── utils/           # 工具函式
```

### AI Prompt 規範

- 所有 Gemini API 呼叫須使用結構化 JSON 輸出
- 遵循 `aimodel.md` 中定義的 prompt 模板
- 加入思維鏈 (Chain-of-Thought) 引導

### 離線優先架構

- 所有操作先存本地 SQLite
- 網路恢復後背景同步
- UI 需顯示同步狀態

## 文件導覽

| 文件 | 用途 |
|------|------|
| `README.md` | 專案說明與使用手冊 |
| `ROADMAP.md` | 功能規劃藍圖 |
| `todo.md` | 開發路線圖 |
| `aimodel.md` | AI 模型整合規範 |
| `arch.md` | 系統架構設計 |
| `TEMPLATE_SYSTEM_SPEC.md` | 模板系統技術規格 |

## 分支策略

- `main`: 穩定版本
- `claude/*`: AI 輔助開發分支
- 功能開發請建立 feature 分支

## 測試規範

- 單元測試放在 `test/` 目錄
- 執行測試: `flutter test`
- 提交前確保所有測試通過
