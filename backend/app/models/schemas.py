"""
資料模型定義
"""

from pydantic import BaseModel
from typing import Optional
from datetime import datetime


class RAGItem(BaseModel):
    """RAG 知識庫項目"""
    id: str
    content: str
    equipment_type: str
    source_type: str
    source_id: Optional[str] = None
    metadata: Optional[dict] = None
    created_at: datetime


class Template(BaseModel):
    """廠商報告模板"""
    id: str
    name: str
    vendor_name: str
    file_type: str
    description: Optional[str] = None
    fields: list[dict]
    created_at: datetime


class Report(BaseModel):
    """產生的報告"""
    id: str
    template_id: str
    status: str
    output_path: Optional[str] = None
    created_at: datetime
