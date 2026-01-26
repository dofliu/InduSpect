"""
應用程式配置管理
"""

from pydantic_settings import BaseSettings
from functools import lru_cache


class Settings(BaseSettings):
    """應用程式設定"""
    
    # 應用程式
    app_name: str = "InduSpect AI Backend"
    debug: bool = False
    
    # 資料庫
    database_url: str = "postgresql+asyncpg://localhost:5432/induspect"
    
    # AI API Keys
    gemini_api_key: str = ""
    openai_api_key: str = ""
    
    # Embedding 設定
    embedding_provider: str = "gemini"  # "gemini" or "openai"
    embedding_model: str = "embedding-001"  # "text-embedding-004" may have issues
    embedding_dimension: int = 768  # embedding-001 is also 768
    
    # GCP
    gcs_bucket_name: str = "induspect-files"
    gcp_project_id: str = ""
    
    # RAG 設定
    rag_top_k: int = 5
    rag_similarity_threshold: float = 0.7
    
    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"


@lru_cache()
def get_settings() -> Settings:
    """取得快取的設定實例"""
    return Settings()


settings = get_settings()
