"""
SQLAlchemy ORM 模型定義
"""

from sqlalchemy import Column, String, Text, DateTime, JSON, Index
from sqlalchemy.dialects.postgresql import UUID
from pgvector.sqlalchemy import Vector
from datetime import datetime
import uuid

from app.db.database import Base
from app.config import settings


class RAGItem(Base):
    """RAG 知識庫項目"""
    __tablename__ = "rag_items"
    
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    content = Column(Text, nullable=False)
    equipment_type = Column(String(255), nullable=False, index=True)
    source_type = Column(String(50), nullable=False, index=True)  # inspection/history/document
    source_id = Column(String(255), nullable=True)
    embedding = Column(Vector(settings.embedding_dimension), nullable=False)
    item_metadata = Column("metadata", JSON, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    created_by = Column(String(255), nullable=True)
    
    # 向量索引 (IVFFlat for approximate nearest neighbor search)
    __table_args__ = (
        Index(
            'ix_rag_items_embedding',
            embedding,
            postgresql_using='ivfflat',
            postgresql_with={'lists': 100},
            postgresql_ops={'embedding': 'vector_cosine_ops'}
        ),
    )


class Template(Base):
    """廠商報告模板"""
    __tablename__ = "templates"
    
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name = Column(String(255), nullable=False)
    vendor_name = Column(String(255), nullable=False, index=True)
    file_type = Column(String(10), nullable=False)  # xlsx/docx/pdf
    description = Column(Text, nullable=True)
    fields = Column(JSON, nullable=False, default=list)
    file_content = Column(Text, nullable=True)  # Base64 encoded
    created_at = Column(DateTime, default=datetime.utcnow)


class Report(Base):
    """產生的報告記錄"""
    __tablename__ = "reports"
    
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    template_id = Column(UUID(as_uuid=True), nullable=False, index=True)
    status = Column(String(20), nullable=False, default='pending')  # pending/processing/completed/failed
    output_path = Column(String(512), nullable=True)
    error_message = Column(Text, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)
