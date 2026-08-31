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

    # 後端 API 存取控制（LAUNCH_PLAN P0-3）
    # 設定後，所有 /api/* 請求須帶 X-API-Key header；留空 = 開發模式不驗證（啟動時會警告）
    backend_api_key: str = ""
    # CORS 白名單，逗號分隔（例 "https://app.example.com,https://admin.example.com"）
    # "*" 僅供開發；為 "*" 時 allow_credentials 會自動關閉（符合瀏覽器規範）
    cors_allow_origins: str = "*"
    # 生產環境應設 false 關閉 /docs 與 /redoc
    enable_docs: bool = True

    # Gemini 模型設定（可透過環境變數覆蓋，方便模型升級）
    gemini_flash_model: str = "gemini-3-flash-preview"    # 快速分析用
    gemini_pro_model: str = "gemini-3.1-pro-preview"     # 高複雜度推理用
    gemini_doc_model: str = "gemini-3-flash-preview"     # 文件分析用

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
