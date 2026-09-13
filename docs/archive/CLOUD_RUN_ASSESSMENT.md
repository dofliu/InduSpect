# Cloud Run 部署就緒度評估

> 評估日期: 2026-03-05

## 總評

**後端 (backend/) 已具備 Cloud Run 部署的基礎框架**，包括 Dockerfile、cloudbuild.yaml 和 health check endpoint。但有數個需要在部署前解決的問題。

---

## 已就緒項目

| 項目 | 狀態 | 說明 |
|------|------|------|
| Dockerfile | ✅ 已備妥 | python:3.11-slim, port 8080 |
| Health Check Endpoint | ✅ 已備妥 | `GET /health` → `{"status": "ok"}` |
| Cloud Build 配置 | ✅ 已備妥 | cloudbuild.yaml: build → push → deploy |
| 環境變數管理 | ✅ 已備妥 | pydantic-settings 支援環境變數注入 |
| Stateless API | ✅ 已備妥 | FastAPI 無狀態 RESTful 設計 |
| 自動擴縮 | ✅ 已備妥 | min=0, max=10 instances |
| Port 設定 | ✅ 已備妥 | 監聽 8080 (Cloud Run 預設) |

---

## 需要解決的問題

### 1. 資料庫連線 (嚴重)

**問題**: `DATABASE_URL` 預設指向 `localhost:5432`，Cloud Run 無法連到本機 PostgreSQL。

**解決方案**:
- 建立 **Cloud SQL PostgreSQL 實例** (需啟用 pgvector 擴充)
- cloudbuild.yaml deploy 步驟加上 `--add-cloudsql-instances PROJECT:REGION:INSTANCE`
- DATABASE_URL 改為 Unix socket 格式:
  ```
  postgresql+asyncpg://user:pass@/induspect?host=/cloudsql/PROJECT:REGION:INSTANCE
  ```

### 2. 環境變數不完整 (中等)

**問題**: cloudbuild.yaml 只注入 `GEMINI_API_KEY`，但 backend 還需要 `DATABASE_URL`、`GCS_BUCKET_NAME`、`GCP_PROJECT_ID` 等。

**解決方案**:
- 使用 **Secret Manager** 存放敏感資訊 (API keys, DB credentials)
- deploy 命令加上 `--set-secrets` 或完整的 `--set-env-vars`

### 3. Dockerfile HEALTHCHECK 使用 curl (低)

**問題**: HEALTHCHECK 指令使用 curl，但 python:3.11-slim 未預裝 curl。

**影響**: Cloud Run 不使用 Docker HEALTHCHECK (改用 HTTP startup/liveness probe)，不影響部署，但建議移除或修正。

### 4. CORS 過於寬鬆 (低，生產環境需處理)

**問題**: `allow_origins=["*"]` 允許所有來源存取。

**解決方案**: 部署前限制為前端域名。

### 5. Container Registry 已停用 (低)

**問題**: cloudbuild.yaml 使用 `gcr.io`，Google 建議遷移至 Artifact Registry。

**解決方案**: 映像路徑改為 `REGION-docker.pkg.dev/$PROJECT_ID/REPO_NAME/...`

---

## 部署前行動清單

- [ ] 建立 Cloud SQL PostgreSQL 實例 (含 pgvector 擴充)
- [ ] 更新 cloudbuild.yaml: Cloud SQL 連線 + 完整環境變數 + Secret Manager
- [ ] 建立 GCS Bucket `induspect-files`
- [ ] 設定 Secret Manager: GEMINI_API_KEY, DATABASE_URL
- [ ] 設定 IAM: Cloud Run SA 需要 Cloud SQL Client + GCS 存取權限
- [ ] (建議) 遷移至 Artifact Registry

---

## 目標架構

```
Flutter App ──> Cloud Run (Backend API, port 8080)
                    │
                    ├──> Cloud SQL (PostgreSQL + pgvector)
                    ├──> GCS Bucket (圖片/報告儲存)
                    └──> Gemini API (AI 分析)
```
