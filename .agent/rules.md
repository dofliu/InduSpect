# InduSpect AI 專案開發規範

## 專案概述

InduSpect AI 是一個智慧工業巡檢系統，使用 Flutter 開發行動應用，結合 Google Gemini AI 進行多模態分析。

## 技術棧

- **前端**: Flutter 3.x (Dart 3.2+)
- **AI 模型**: Google Gemini API (gemini-3-flash-preview / gemini-3.1-pro-preview)
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
- Prompt 模板見各 service（`flutter_app/lib/services/gemini_service.dart`、`blade_ai_service.dart`；
  後端一律走 `backend/app/services/gemini_client.py`）
- 加入思維鏈 (Chain-of-Thought) 引導

### 離線優先架構

- 所有操作先存本地 SQLite
- 網路恢復後背景同步
- UI 需顯示同步狀態

## 文件導覽

| 文件 | 用途 |
|------|------|
| `README.md` | 專案總覽 |
| `docs/USER_GUIDE.md` | 使用手冊（操作步驟） |
| `CLAUDE.md` | 開發規則速查、關鍵檔案表、已知問題 |
| `ROADMAP.md` | 功能規劃藍圖 |
| `LAUNCH_PLAN.md` | 產品化評估與上線計畫 |
| `flutter_app/DEVELOPMENT.md` | App 架構、DB schema、變更紀錄 |
| `docs/archive/` | 已完成或已被取代的文件（不要照著做） |

## 分支策略

- `main`: 穩定版本
- `claude/*`: AI 輔助開發分支
- 功能開發請建立 feature 分支

## 測試規範

- 單元測試放在 `test/` 目錄
- 執行測試: `flutter test`
- 提交前確保所有測試通過
