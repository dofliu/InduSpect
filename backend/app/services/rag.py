"""
RAG 服務 - 向量檢索與相似案例查詢
"""

import logging
import uuid
import json
import os
import time
from typing import Optional
from datetime import datetime

import google.generativeai as genai
from sqlalchemy import select, func

from app.config import settings
from app.services.embedding import EmbeddingService
from app.db.database import async_session_maker
from app.db.models import RAGItem

logger = logging.getLogger(__name__)

# 暫存檔案目錄
UPLOAD_DIR = "uploads"
if not os.path.exists(UPLOAD_DIR):
    os.makedirs(UPLOAD_DIR)


class RAGService:
    """RAG 檢索服務 (PostgreSQL + pgvector)"""
    
    def __init__(self):
        self.embedding_service = EmbeddingService()
        self.top_k = settings.rag_top_k
        self.similarity_threshold = settings.rag_similarity_threshold
    
    async def search_similar(
        self, 
        query_text: str, 
        top_k: Optional[int] = None,
        filters: Optional[dict] = None
    ) -> list[dict]:
        """
        搜尋相似案例
        
        :param query_text: 查詢文字
        :param top_k: 回傳數量
        :param filters: Metadata 過濾條件 (例如 {"vendor": "Delta"})
        """
        k = top_k or self.top_k
        
        # 1. 將查詢文字向量化
        query_embedding = await self.embedding_service.embed_text(query_text)
        
        # 2. 在向量資料庫中查詢
        async with async_session_maker() as session:
            # 使用 pgvector 的餘弦距離運算子 (<=>) 排序
            stmt = select(RAGItem)
            
            # 套用過濾條件 (如果有的話)
            if filters:
                # 這裡假設 filters 是簡單的鍵值對匹配
                # 若 item_metadata 是 JSONB，可使用 contains
                stmt = stmt.where(RAGItem.item_metadata.contains(filters))
            
            stmt = stmt.order_by(
                RAGItem.embedding.cosine_distance(query_embedding)
            ).limit(k)
            
            result = await session.execute(stmt)
            items = result.scalars().all()
            
            # 轉換為回傳格式
            results = []
            for item in items:
                # 計算相似度 (1 - distance)
                sim = self._cosine_similarity(query_embedding, item.embedding)
                
                if sim >= self.similarity_threshold:
                    results.append({
                        "id": str(item.id),
                        "similarity": round(sim, 4),
                        "equipment_type": item.equipment_type,
                        "content": item.content,
                        "source_type": item.source_type,
                        "metadata": item.item_metadata,
                    })
            
            return results
    
    def _cosine_similarity(self, a: list[float], b: list[float]) -> float:
        """計算餘弦相似度 (輔助用)"""
        import math
        dot_product = sum(x * y for x, y in zip(a, b))
        norm_a = math.sqrt(sum(x * x for x in a))
        norm_b = math.sqrt(sum(x * x for x in b))
        if norm_a == 0 or norm_b == 0: return 0.0
        return dot_product / (norm_a * norm_b)
    
    async def add_item(
        self,
        content: str,
        equipment_type: str,
        source_type: str,
        source_id: Optional[str] = None,
        metadata: Optional[dict] = None
    ) -> str:
        """新增項目到知識庫"""
        # 向量化
        embedding = await self.embedding_service.embed_text(content)
        
        async with async_session_maker() as session:
            new_item = RAGItem(
                content=content,
                equipment_type=equipment_type,
                source_type=source_type,
                source_id=source_id,
                embedding=embedding,
                item_metadata=metadata or {},
            )
            session.add(new_item)
            await session.commit()
            await session.refresh(new_item)
            
            logger.info(f"Added RAG item: {new_item.id}")
            return str(new_item.id)
    
    async def generate_suggestions(
        self,
        query: dict,
        similar_cases: list[dict]
    ) -> list[str]:
        """根據相似案例生成維修建議 (Gemini)"""
        if not similar_cases:
            return ["暫無相似歷史案例，建議依照標準維修程序處理。"]
        
        try:
            genai.configure(api_key=settings.gemini_api_key)
            model = genai.GenerativeModel('gemini-2.0-flash')
            
            cases_text = "\n\n".join([
                f"案例 {i+1} (相似度: {c['similarity']}):\n{c['content']}"
                for i, c in enumerate(similar_cases[:3])
            ])
            
            prompt = f"""
你是一位專業的工業設備維修顧問。根據以下巡檢結果和歷史相似案例，提供具體的維修建議。

【目前巡檢結果】
設備類型: {query.get('equipment_type', '未知')}
異常描述: {query.get('anomaly_description', '無')}
狀況評估: {query.get('condition_assessment', '無')}

【歷史相似案例】
{cases_text}

請提供 3-5 條具體、可操作的維修建議，每條一行，使用繁體中文。
"""
            response = model.generate_content(prompt)
            
            return [
                line.strip().lstrip("•-123456789.、）)")
                for line in response.text.strip().split("\n")
                if line.strip() and len(line.strip()) > 5
            ][:5]
            
        except Exception as e:
            logger.error(f"Generate suggestions failed: {e}")
            return ["暫時無法生成建議，請稍後再試。"]
    
    async def get_stats(self) -> dict:
        """取得知識庫統計"""
        async with async_session_maker() as session:
            # 總數
            total = await session.scalar(select(func.count()).select_from(RAGItem))
            
            # 來源統計
            src_result = await session.execute(
                select(RAGItem.source_type, func.count(RAGItem.id))
                .group_by(RAGItem.source_type)
            )
            by_source = dict(src_result.all())
            
            # 設備統計
            eq_result = await session.execute(
                select(RAGItem.equipment_type, func.count(RAGItem.id))
                .group_by(RAGItem.equipment_type)
            )
            by_equipment = dict(eq_result.all())
            
            return {
                "total": total,
                "by_source": by_source,
                "by_equipment": by_equipment,
            }

    async def get_all_items(self, skip: int = 0, limit: int = 100) -> list[dict]:
        """取得所有知識庫項目"""
        async with async_session_maker() as session:
            stmt = select(RAGItem).order_by(RAGItem.created_at.desc()).offset(skip).limit(limit)
            result = await session.execute(stmt)
            items = result.scalars().all()
            
            return [{
                "id": str(item.id),
                "equipment_type": item.equipment_type,
                "content": item.content,
                "source_type": item.source_type,
                "source_id": item.source_id,
                "metadata": item.item_metadata,
                "created_at": item.created_at.isoformat() if item.created_at else None,
            } for item in items]

    async def delete_item(self, item_id: str) -> bool:
        """刪除知識庫項目"""
        async with async_session_maker() as session:
            stmt = select(RAGItem).where(RAGItem.id == uuid.UUID(item_id))
            result = await session.execute(stmt)
            item = result.scalar_one_or_none()
            
            if item:
                await session.delete(item)
                await session.commit()
                return True
            return False

    async def import_from_document(self, file_path: str, source_filename: str) -> dict:
        """從文件導入知識 (使用 Gemini File API)"""
        try:
            logger.info(f"Processing document: {source_filename}")
            genai.configure(api_key=settings.gemini_api_key)
            # 使用 1.5 Flash，支援文件分析且速度快
            model = genai.GenerativeModel('gemini-1.5-flash')

            # 1. 上傳檔案到 Gemini
            logger.info(f"Uploading to Gemini...")
            uploaded_file = genai.upload_file(path=file_path, display_name=source_filename)
            
            # 等待檔案處理 (通常很快，但安全起見)
            while uploaded_file.state.name == "PROCESSING":
                time.sleep(1)
                uploaded_file = genai.get_file(uploaded_file.name)
            
            if uploaded_file.state.name == "FAILED":
                raise ValueError("Gemini file processing failed")

            # 2. 發送 Prompt 進行提取
            logger.info("Analyzing document...")
            prompt = """
            請分析這份維修手冊或文件。
            你的任務是提取其中所有具體的「設備維修建議」、「故障排除指南」或「設備知識」。

            請將提取的內容整理成一個 JSON 列表，格式如下：
            [
              {
                "equipment_type": "設備名稱 (例如: 風力發電機葉片)",
                "content": "詳細的維修建議或故障排除步驟 (包含具體數值或判斷標準)",
                "category": "維修/故障/保養 (自行分類)"
              }
            ]

            注意事項：
            1. 忽略目錄、版權聲明、前言等無關內容。
            2. 內容(content)應該包含足夠的上下文。
            3. 如果文件很長，請優先提取最重要的維修知識。
            4. 僅回傳純 JSON 陣列，不要有 Markdown 標記。
            """

            response = model.generate_content([prompt, uploaded_file])
            
            # 3. 解析回應
            text = response.text.strip()
            # 清理 Markdown
            if text.startswith("```json"):
                text = text[7:]
            if text.startswith("```"):
                text = text[3:]
            if text.endswith("```"):
                text = text[:-3]
            text = text.strip()
            
            items = json.loads(text)
            
            if not isinstance(items, list):
                raise ValueError("AI response format error: not a list")

            # 4. 入庫
            count = 0
            for item in items:
                # 簡單檢查必要欄位
                if "content" not in item:
                    continue
                    
                await self.add_item(
                    content=item.get("content", ""),
                    equipment_type=item.get("equipment_type", "General"),
                    source_type="document",
                    source_id=source_filename,
                    metadata={"category": item.get("category"), "filename": source_filename, "imported_at": datetime.utcnow().isoformat()}
                )
                count += 1
            
            # 清理：雖然 Gemini 會自動過期，但我們可以嘗試刪除(如果 library 支援)，或不理會
            try:
                genai.delete_file(uploaded_file.name)
            except:
                pass

            return {"success": True, "count": count, "message": f"成功導入 {count} 筆知識"}

        except Exception as e:
            logger.error(f"Document import failed: {e}")
            return {"success": False, "error": str(e)}


