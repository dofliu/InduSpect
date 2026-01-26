"""
InduSpect AI Backend - FastAPI 入口
"""

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import settings
from app.api import rag, templates, reports

from contextlib import asynccontextmanager
from app.db.database import init_db, close_db

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    await init_db()
    yield
    # Shutdown
    await close_db()

app = FastAPI(
    title="InduSpect AI Backend",
    description="智能工業巡檢系統後端 API - RAG 查詢與廠商報告生成",
    version="1.0.0",
    docs_url="/docs",
    redoc_url="/redoc",
    lifespan=lifespan,
)

# CORS 設定 - 允許 Flutter Web/App 存取
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # 生產環境應限制
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# 註冊路由
app.include_router(rag.router, prefix="/api/rag", tags=["RAG 查詢"])
app.include_router(templates.router, prefix="/api/templates", tags=["模板管理"])
app.include_router(reports.router, prefix="/api/reports", tags=["報告生成"])


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
