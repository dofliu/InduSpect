"""
InduSpect AI Backend - FastAPI 入口
"""

import logging
import math

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.config import settings
from app.api import rag, templates, reports, auto_fill

from contextlib import asynccontextmanager
from app.db.database import init_db, close_db

logger = logging.getLogger("induspect")


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    if not settings.backend_api_key:
        logger.warning(
            "BACKEND_API_KEY 未設定 — /api/* 端點不驗證請求（僅限開發環境）。"
            "生產環境請透過 Secret Manager 注入 BACKEND_API_KEY。"
        )
    await init_db()
    yield
    # Shutdown
    await close_db()


app = FastAPI(
    title="InduSpect AI Backend",
    description="智能工業巡檢系統後端 API - RAG 查詢與廠商報告生成",
    version="1.0.0",
    # 生產環境設 ENABLE_DOCS=false 關閉互動式文件（LAUNCH_PLAN P0-3）
    docs_url="/docs" if settings.enable_docs else None,
    redoc_url="/redoc" if settings.enable_docs else None,
    lifespan=lifespan,
)

# CORS 白名單：由 CORS_ALLOW_ORIGINS 環境變數控制（逗號分隔）。
# 依瀏覽器規範，wildcard origin 不可與 credentials 並用。
_cors_origins = [o.strip() for o in settings.cors_allow_origins.split(",") if o.strip()]
_cors_wildcard = _cors_origins == ["*"]
app.add_middleware(
    CORSMiddleware,
    allow_origins=_cors_origins or ["*"],
    allow_credentials=not _cors_wildcard,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.middleware("http")
async def api_key_guard(request: Request, call_next):
    """API Key 驗證：BACKEND_API_KEY 設定時，/api/* 須帶相符的 X-API-Key。

    - `/`、`/health` 保持開放（Cloud Run 探針）
    - OPTIONS 放行（CORS preflight 不帶自訂 header）
    - 未設定 key 時不驗證（開發模式，啟動時已警告）
    """
    expected = settings.backend_api_key
    if (
        expected
        and request.url.path.startswith("/api/")
        and request.method != "OPTIONS"
        and request.headers.get("X-API-Key") != expected
    ):
        return JSONResponse(status_code=401, content={"detail": "無效或缺少 API Key"})
    return await call_next(request)


def _json_safe(obj):
    """遞迴淨化為可 JSON 序列化的結構（NaN/inf/例外物件 → 字串）。"""
    if obj is None or isinstance(obj, (str, int, bool)):
        return obj
    if isinstance(obj, float):
        return obj if math.isfinite(obj) else str(obj)
    if isinstance(obj, dict):
        return {str(k): _json_safe(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [_json_safe(v) for v in obj]
    return str(obj)


@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    """422 回應淨化（Issue #47）

    FastAPI 預設 handler 會把違規的原始輸入 echo 回 errors[].input；
    當輸入含 NaN/inf 時該 422 本身無法 JSON 序列化 → 反而變成 500。
    此處遞迴淨化後回傳，確保任何異常輸入都得到結構一致的 422。
    """
    return JSONResponse(status_code=422, content={"detail": _json_safe(exc.errors())})


# 註冊路由
app.include_router(rag.router, prefix="/api/rag", tags=["RAG 查詢"])
app.include_router(templates.router, prefix="/api/templates", tags=["模板管理"])
app.include_router(reports.router, prefix="/api/reports", tags=["報告生成"])
app.include_router(auto_fill.router, prefix="/api/auto-fill", tags=["自動回填"])


@app.get("/")
async def root():
    """健康檢查端點"""
    return {
        "service": "InduSpect AI Backend",
        "version": "1.0.0",
        "status": "healthy",
    }


@app.get("/health")
async def health_check():
    """GCP Cloud Run 健康檢查"""
    return {"status": "ok"}
