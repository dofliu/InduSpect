"""
RAG 查詢 API - 提供相似案例檢索與維修建議
"""

from fastapi import APIRouter, HTTPException, Depends, UploadFile, File
from pydantic import BaseModel
from typing import Optional
import logging

from app.services.rag import RAGService
from app.services.embedding import EmbeddingService

router = APIRouter()
logger = logging.getLogger(__name__)


# ============ Request/Response Models ============

class RAGQueryRequest(BaseModel):
    """RAG 查詢請求"""
    equipment_type: str
    anomaly_description: str
    condition_assessment: Optional[str] = None
    extracted_values: Optional[dict] = None
    filters: Optional[dict] = None  # 新增過濾條件
    top_k: int = 5
    
    class Config:
        json_schema_extra = {
            "example": {
                "equipment_type": "齒輪與滑塊機構",
                "anomaly_description": "齒輪齒面與滑塊周圍有大量黑色黏稠狀髒污與舊潤滑劑堆積",
                "condition_assessment": "潤滑劑狀況不佳，需要清潔與重新潤滑",
                "top_k": 5
            }
        }


class RAGResult(BaseModel):
    """單筆 RAG 查詢結果"""
    id: str
    similarity: float
    equipment_type: str
    content: str
    source_type: str  # 'inspection' / 'history' / 'document'
    metadata: Optional[dict] = None


class RAGQueryResponse(BaseModel):
    """RAG 查詢回應"""
    query_text: str
    results: list[RAGResult]
    suggestions: list[str]  # AI 生成的維修建議


class AddToRAGRequest(BaseModel):
    """新增資料到 RAG 知識庫"""
    equipment_type: str
    content: str
    source_type: str  # 'inspection' / 'history' / 'document'
    source_id: Optional[str] = None
    metadata: Optional[dict] = None
    
    class Config:
        json_schema_extra = {
            "example": {
                "equipment_type": "齒輪與滑塊機構",
                "content": "齒輪表面大量髒污堆積，建議使用工業清潔劑清理後重新塗抹潤滑脂",
                "source_type": "inspection",
                "source_id": "insp-2026-001",
                "metadata": {"inspector": "張三", "location": "廠區 A"}
            }
        }


class AddToRAGResponse(BaseModel):
    """新增 RAG 資料回應"""
    success: bool
    id: str
    message: str


# ============ API Endpoints ============

@router.post("/query", response_model=RAGQueryResponse)
async def query_similar_cases(request: RAGQueryRequest):
    """
    查詢相似案例
    
    根據巡檢結果查詢歷史相似案例，提供維修建議
    """
    try:
        print(f"🔍 [Backend] RAG Query received: {request.equipment_type}")
        rag_service = RAGService()
        
        # 建構查詢文字
        query_text = f"""
設備類型: {request.equipment_type}
異常描述: {request.anomaly_description}
狀況評估: {request.condition_assessment or '無'}
"""
        
        # 執行 RAG 查詢
        results = await rag_service.search_similar(
            query_text=query_text,
            top_k=request.top_k,
            filters=request.filters
        )
        print(f"✅ [Backend] Found {len(results)} similar cases")
        
        # 根據結果生成建議
        suggestions = await rag_service.generate_suggestions(
            query=request.model_dump(),
            similar_cases=results
        )
        print(f"💡 [Backend] Generated {len(suggestions)} suggestions")
        
        return RAGQueryResponse(
            query_text=query_text.strip(),
            results=results,
            suggestions=suggestions
        )
        
    except Exception as e:
        logger.error(f"RAG query failed: {e}")
        print(f"❌ [Backend] RAG query failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/add", response_model=AddToRAGResponse)
async def add_to_knowledge_base(request: AddToRAGRequest):
    """
    新增資料到知識庫
    
    將巡檢記錄、歷史資料或文件加入 RAG 向量資料庫
    """
    try:
        print(f"📝 [Backend] Adding to knowledge base: {request.equipment_type}")
        rag_service = RAGService()
        
        # 建構完整內容
        full_content = f"[{request.equipment_type}] {request.content}"
        
        # 加入知識庫
        item_id = await rag_service.add_item(
            content=full_content,
            equipment_type=request.equipment_type,
            source_type=request.source_type,
            source_id=request.source_id,
            metadata=request.metadata
        )
        
        print(f"✅ [Backend] Successfully added item: {item_id}")
        
        return AddToRAGResponse(
            success=True,
            id=item_id,
            message="成功加入知識庫"
        )
        
    except Exception as e:
        logger.error(f"Add to RAG failed: {e}")
        print(f"❌ [Backend] Add to RAG failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/stats")
async def get_knowledge_base_stats():
    """取得知識庫統計資訊"""
    try:
        rag_service = RAGService()
        stats = await rag_service.get_stats()
        return stats
    except Exception as e:
        logger.error(f"Get stats failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/items")
async def get_knowledge_items(skip: int = 0, limit: int = 100):
    """
    取得知識庫項目列表
    """
    try:
        rag_service = RAGService()
        items = await rag_service.get_all_items(skip=skip, limit=limit)
        return items
    except Exception as e:
        logger.error(f"Get items failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/items/{item_id}")
async def delete_knowledge_item(item_id: str):
    """
    刪除知識庫項目
    """
    try:
        rag_service = RAGService()
        success = await rag_service.delete_item(item_id)
        if not success:
            raise HTTPException(status_code=404, detail="Item not found")
        return {"success": True, "message": "Item deleted"}
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Delete item failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/upload")
async def upload_document(file: UploadFile = File(...)):
    """
    上傳並分析維修手冊
    """
    import shutil
    import os
    import uuid
    from app.services.rag import UPLOAD_DIR
    
    try:
        source_filename = file.filename
        
        # 確保目錄存在
        if not os.path.exists(UPLOAD_DIR):
            os.makedirs(UPLOAD_DIR)
            
        # 儲存暫存檔
        temp_filename = f"{uuid.uuid4()}_{source_filename}"
        temp_path = os.path.join(UPLOAD_DIR, temp_filename)
        
        with open(temp_path, "wb") as buffer:
            shutil.copyfileobj(file.file, buffer)
            
        print(f"📄 [Backend] Received file: {source_filename}, analyzing...")
        
        rag_service = RAGService()
        result = await rag_service.import_from_document(temp_path, source_filename)
        
        # 清理暫存檔
        if os.path.exists(temp_path):
            os.remove(temp_path)
            
        return result
        
    except Exception as e:
        logger.error(f"Upload failed: {e}")
        print(f"❌ [Backend] Upload failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


