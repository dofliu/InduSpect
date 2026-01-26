"""
資料庫連線與 Session 管理
"""

from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine, async_sessionmaker
from sqlalchemy.orm import declarative_base
from sqlalchemy import text
import logging

from app.config import settings

logger = logging.getLogger(__name__)

# 建立非同步引擎
engine = create_async_engine(
    settings.database_url,
    echo=settings.debug,
    pool_pre_ping=True,
    pool_size=5,
    max_overflow=10,
)

# Session 工廠
async_session_maker = async_sessionmaker(
    engine,
    class_=AsyncSession,
    expire_on_commit=False,
)

# 模型基底類別
Base = declarative_base()


async def get_db() -> AsyncSession:
    """取得資料庫 Session (FastAPI Dependency)"""
    async with async_session_maker() as session:
        try:
            yield session
        finally:
            await session.close()


async def init_db():
    """初始化資料庫 (建立表格和擴充功能)"""
    async with engine.begin() as conn:
        # 啟用 pgvector 擴充功能
        await conn.execute(text("CREATE EXTENSION IF NOT EXISTS vector"))
        
        # 建立所有表格
        await conn.run_sync(Base.metadata.create_all)
    
    logger.info("Database initialized successfully")


async def close_db():
    """關閉資料庫連線"""
    await engine.dispose()
    logger.info("Database connection closed")
