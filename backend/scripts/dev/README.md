# dev/ — 本機維運腳本（不進 Docker image）

RAG 知識庫的本機維運工具，僅供開發環境手動使用：

| 腳本 | 用途 |
|------|------|
| `check_db.py` | 檢查資料庫連線與內容 |
| `dump_rag.py` | 傾印 RAG 知識庫項目 |
| `import_knowledge.py` | 匯入知識範本（`backend/data/knowledge_template.json`） |
| `reset_rag_db.py` | ⚠️ **破壞性**：清空 RAG 資料表，僅限本機開發環境使用 |

`Dockerfile` 只 COPY `app/`，這些腳本不會進入生產映像。
