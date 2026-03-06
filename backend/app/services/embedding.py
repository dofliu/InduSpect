"""
Embedding 服務 - 文字向量化
支援 Google Gemini (使用新版 google-genai SDK) 和 OpenAI Embedding Models

注意：Gemini Embedding API 對純中文文字有問題，會返回相同的向量。
解決方案：在中文內容前加入英文關鍵字來幫助模型正確理解。
"""

import logging
import re
from typing import Optional

from app.config import settings

logger = logging.getLogger(__name__)

# 常用中文設備類型對應的英文翻譯
EQUIPMENT_TRANSLATIONS = {
    "風力發電機": "wind turbine",
    "塔架": "tower",
    "葉片": "blade",
    "齒輪箱": "gearbox",
    "發電機": "generator",
    "轉向齒輪": "steering gear",
    "控制櫃": "control cabinet",
    "電氣系統": "electrical system",
    "液壓系統": "hydraulic system",
    "軸承": "bearing",
    "油封": "oil seal",
    "密封": "seal",
    "腐蝕": "corrosion",
    "裂縫": "crack",
    "磨損": "wear",
    "油污": "oil contamination",
    "接合處": "joint",
    "螺栓": "bolt",
    "焊接": "weld",
    "塗層": "coating",
    "維修": "repair",
    "異常": "anomaly",
    "檢測": "inspection",
    "設備": "equipment",
}


def _add_english_keywords(chinese_text: str) -> str:
    """
    為中文文字添加英文關鍵字前綴。
    這是為了解決 Gemini Embedding 對純中文返回相同向量的問題。
    """
    english_keywords = []
    
    for zh, en in EQUIPMENT_TRANSLATIONS.items():
        if zh in chinese_text:
            english_keywords.append(en)
    
    if english_keywords:
        # 將英文關鍵字放在前面，後面接中文內容
        prefix = " ".join(english_keywords[:5])  # 最多取5個關鍵字
        return f"{prefix} | {chinese_text}"
    
    return chinese_text


class EmbeddingService:
    """Embedding 服務，將文字轉換為向量"""
    
    def __init__(self, provider: Optional[str] = None):
        self.provider = provider or settings.embedding_provider
        self.model = settings.embedding_model
        self.dimension = settings.embedding_dimension
        
        # 初始化 Gemini 客戶端 (使用新版 SDK)
        if self.provider == "gemini":
            try:
                from google import genai
                self._genai_client = genai.Client(api_key=settings.gemini_api_key)
                logger.info(f"Gemini client initialized with model: {self.model}")
            except ImportError:
                logger.warning("google-genai not installed, falling back to google-generativeai")
                import google.generativeai as genai_old
                genai_old.configure(api_key=settings.gemini_api_key)
                self._genai_client = None
    
    async def embed_text(self, text: str) -> list[float]:
        """
        將文字轉換為向量
        
        Args:
            text: 要向量化的文字
            
        Returns:
            向量 (list of floats)
        """
        if self.provider == "gemini":
            return await self._embed_with_gemini(text)
        elif self.provider == "openai":
            return await self._embed_with_openai(text)
        else:
            raise ValueError(f"Unknown embedding provider: {self.provider}")
    
    async def embed_batch(self, texts: list[str]) -> list[list[float]]:
        """批次向量化多個文字"""
        embeddings = []
        for text in texts:
            emb = await self.embed_text(text)
            embeddings.append(emb)
        return embeddings
    
    async def _embed_with_gemini(self, text: str) -> list[float]:
        """使用 Google Gemini Embedding API (新版 SDK)"""
        try:
            # 為中文內容添加英文關鍵字以解決 Embedding 問題
            enhanced_text = _add_english_keywords(text)
            logger.debug(f"Enhanced text for embedding: {enhanced_text[:100]}...")
            
            if self._genai_client:
                # 使用新版 google-genai SDK
                result = self._genai_client.models.embed_content(
                    model=self.model,
                    contents=enhanced_text,
                )
                return list(result.embeddings[0].values)
            else:
                # 回退到舊版 SDK
                import google.generativeai as genai_old
                result = genai_old.embed_content(
                    model=f"models/{self.model}",
                    content=enhanced_text,
                    task_type="retrieval_document"
                )
                return result['embedding']
                
        except Exception as e:
            logger.error(f"Gemini embedding failed: {e}")
            raise
    
    async def _embed_with_openai(self, text: str) -> list[float]:
        """使用 OpenAI Embedding API"""
        try:
            import openai
            
            client = openai.OpenAI(api_key=settings.openai_api_key)
            response = client.embeddings.create(
                model=self.model or "text-embedding-3-small",
                input=text
            )
            return response.data[0].embedding
        except Exception as e:
            logger.error(f"OpenAI embedding failed: {e}")
            raise
    
    def format_inspection_for_embedding(self, inspection_data: dict) -> str:
        """
        將巡檢資料格式化為適合 Embedding 的文字
        
        Args:
            inspection_data: 巡檢資料字典
            
        Returns:
            格式化的文字
        """
        parts = []
        
        if inspection_data.get("equipment_type"):
            parts.append(f"設備類型: {inspection_data['equipment_type']}")
        
        if inspection_data.get("equipment_name"):
            parts.append(f"設備名稱: {inspection_data['equipment_name']}")
        
        if inspection_data.get("anomaly_description"):
            parts.append(f"異常描述: {inspection_data['anomaly_description']}")
        
        if inspection_data.get("condition_assessment"):
            parts.append(f"狀況評估: {inspection_data['condition_assessment']}")
        
        if inspection_data.get("extracted_values"):
            values_str = ", ".join(
                f"{k}: {v}" for k, v in inspection_data['extracted_values'].items()
            )
            parts.append(f"數值資料: {values_str}")
        
        return "\n".join(parts)

