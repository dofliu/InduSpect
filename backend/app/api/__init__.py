"""
API 路由模組
"""

from app.api.rag import router as rag_router
from app.api.templates import router as templates_router
from app.api.reports import router as reports_router

__all__ = ["rag_router", "templates_router", "reports_router"]
