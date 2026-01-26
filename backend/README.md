# InduSpect AI Backend

智能工業巡檢系統後端服務 API

## 技術棧

- **Framework**: FastAPI
- **Database**: PostgreSQL + pgvector
- **Embedding**: Google Gemini / OpenAI
- **Deployment**: GCP Cloud Run

## 專案結構

```
backend/
├── app/
│   ├── main.py           # FastAPI 入口
│   ├── config.py         # 配置管理
│   ├── api/
│   │   ├── rag.py        # RAG 查詢 API
│   │   ├── templates.py  # 模板管理 API
│   │   └── reports.py    # 報告生成 API
│   ├── services/
│   │   ├── embedding.py  # Embedding 服務
│   │   ├── rag.py        # RAG 檢索邏輯
│   │   └── form_fill.py  # 表單填入邏輯
│   ├── models/
│   │   └── schemas.py    # Pydantic 資料模型
│   └── db/
│       └── database.py   # 資料庫連線
├── Dockerfile
├── requirements.txt
└── cloudbuild.yaml
```

## 快速開始

### 本地開發

```bash
# 建立虛擬環境
python -m venv venv
venv\Scripts\activate  # Windows

# 安裝依賴
pip install -r requirements.txt

# 設定環境變數
cp .env.example .env
# 編輯 .env 填入 API keys

# 啟動開發伺服器
uvicorn app.main:app --reload --port 8000
```

### 環境變數

```
DATABASE_URL=postgresql://user:password@localhost:5432/induspect
GEMINI_API_KEY=your_gemini_api_key
OPENAI_API_KEY=your_openai_api_key (optional)
GCS_BUCKET_NAME=induspect-files
```

## API 文件

啟動後訪問: <http://localhost:8000/docs>

### 新增功能 (2026-01-26)

#### RAG 知識庫管理

- `GET /api/rag/items`: 列出所有知識庫項目
- `DELETE /api/rag/items/{id}`: 刪除指定項目
- `POST /api/rag/upload`: 上傳維修手冊 (PDF/Doc) 並透過 Gemini AI 自動分析入庫
  - 支援 Gemini File API，自動提取維修建議與設備知識
- `GET /api/rag/stats`: 查看知識庫統計
