# InduSpect AI — 智慧工業巡檢系統

> 工業設備智慧巡檢系統：**Flutter 行動 App + FastAPI 後端 + Google Gemini AI**。
> 由 doflab 劉瑞弘老師研究團隊（NCUT 智慧自動化工程系）開發。

利用多模態 AI 將傳統工業巡檢流程自動化——「除了拍照，其餘全自動」：上傳定檢表後，App 引導拍照、AI 批次辨識、依法規標準自動判定合格/不合格、回填原始格式表單並產生 AI 摘要報告。

---

## 核心功能（聚焦兩項）

1. **完整檢測 Pipeline**
   上傳/匯入定檢表（Excel/Word）→ 一鍵自動檢測（引導拍照 → AI 批次分析 → **法規標準判定** → 自動回填原始格式文件 → 自動 AI 摘要報告）→ 分享/傳送（離線自動暫存，連線後自動送出）。

2. **歷史紀錄**
   GPS 定位、可編輯標題、SQL 端搜尋、重新分享。

> 其餘功能（快速分析、範本系統、設備管理、雲端同步等）目前為**隱藏狀態**，非核心開發重點。相關規格保存於 [`docs/archive/`](docs/archive/)。

---

## 技術棧

| 層 | 技術 |
|----|------|
| 行動前端 | Flutter 3.x / Dart 3.2+，Provider 狀態管理，SQLite（sqflite）離線優先 |
| 後端 API | FastAPI（Python 3.11），表單結構分析 + AI 語意映射 + 法規標準判定 |
| AI | Google Gemini（圖像分析 + 摘要報告），後端 56 條法規標準自動判定（含單位換算） |
| 定位 | geolocator + geocoding（GPS 一次性定位 + 反向地理編碼） |

---

## 專案結構

```
InduSpect/
├── flutter_app/          ★ 行動 App（主要開發版本）
│   ├── lib/screens/form_inspection_screen.dart   核心：5 步驟檢測流程
│   ├── lib/services/                              gemini / backend_api / database / location ...
│   ├── test/                                      59 個單元測試
│   └── DEVELOPMENT.md                             ★ 完整開發指南 + 變更紀錄
├── backend/              FastAPI 後端
│   ├── app/api/auto_fill.py                       表單回填 + judge-readings 端點
│   ├── app/services/judgment_service.py           法規標準判定
│   ├── app/data/inspection_standards.py           56 條法規標準資料庫
│   └── tests/                                     150 pytest
├── docs/
│   ├── routines/weekly-progress.md                每週維護 routine SOP
│   ├── handover/session-handover.md               接力筆記
│   └── archive/                                    已完成計畫 / 隱藏功能規格 / 部署評估
├── examples/             範例模板
├── test_forms/           自動回填測試表單與報告
├── legacy/web-prototype/ 早期 React/Vite 網頁原型（已凍結，僅供參考）
├── CLAUDE.md             ★ 專案開發紅線與慣例
├── STATUS.yaml           專案狀態快照
├── AUTO_FILL_SYSTEM.md   自動回填系統技術文件
├── AISTUDIO_REBUILD_SPEC.md   供 Google AI Studio 從零重建的完整規格
└── README.md             本文件
```

---

## 快速開始

### 行動 App（Flutter）

```bash
cd flutter_app
flutter pub get
cp .env.example .env          # 填入 GEMINI_API_KEY 與 BACKEND_API_URL
flutter run                   # 或 flutter build apk --release
```

詳見 [`flutter_app/README.md`](flutter_app/README.md)。

### 後端（FastAPI）

```bash
cd backend
pip install -r requirements.txt
cp .env.example .env          # 填入 GEMINI_API_KEY 等
uvicorn app.main:app --reload
```

詳見 [`backend/README.md`](backend/README.md)。

---

## 測試

```bash
# 後端（150 pytest）
cd backend && pytest tests/ --asyncio-mode=auto

# 前端（59 tests）
cd flutter_app && flutter test \
  test/form_inspection_record_test.dart \
  test/database_service_test.dart \
  test/inspection_item_state_test.dart \
  test/photo_service_test.dart
```

每個 PR 由 GitHub Actions（[`.github/workflows/ci.yml`](.github/workflows/ci.yml)）自動跑 backend pytest + Flutter analyze/test。

---

## 文件導覽

| 文件 | 說明 |
|------|------|
| [CLAUDE.md](CLAUDE.md) | **專案紅線、慣例、關鍵檔案**（開發前必讀） |
| [STATUS.yaml](STATUS.yaml) | 專案狀態快照（progress / milestone / metrics） |
| [ROADMAP.md](ROADMAP.md) | **前瞻路線圖**——後續工作大目標 |
| [flutter_app/DEVELOPMENT.md](flutter_app/DEVELOPMENT.md) | Flutter 完整開發指南 + 變更紀錄 |
| [AUTO_FILL_SYSTEM.md](AUTO_FILL_SYSTEM.md) | 表單自動回填系統技術文件 |
| [AISTUDIO_REBUILD_SPEC.md](AISTUDIO_REBUILD_SPEC.md) | 供 Google AI Studio 從零重建的規格 |
| [docs/routines/weekly-progress.md](docs/routines/weekly-progress.md) | 每週維護 routine SOP |
| [docs/handover/session-handover.md](docs/handover/session-handover.md) | Session 接力筆記 |
| [docs/archive/](docs/archive/) | 已完成計畫、隱藏功能規格、Cloud Run 部署評估 |
