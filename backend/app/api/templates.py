"""
模板管理 API - 廠商報告模板的上傳、分析與管理
"""

from fastapi import APIRouter, HTTPException, UploadFile, File, Form
from pydantic import BaseModel
from typing import Optional
import logging
import uuid

from app.services.form_fill import FormFillService

router = APIRouter()
logger = logging.getLogger(__name__)


# ============ Request/Response Models ============

class TemplateField(BaseModel):
    """模板欄位定義"""
    field_id: str
    field_name: str
    field_type: str  # 'text' / 'number' / 'date' / 'checkbox'
    location: str    # Excel: 'A5', Word: 'paragraph_3'
    mapping: Optional[str] = None  # 對應的巡檢資料欄位
    default_value: Optional[str] = None


class TemplateInfo(BaseModel):
    """模板資訊"""
    id: str
    name: str
    vendor_name: str
    file_type: str   # 'xlsx' / 'docx' / 'pdf'
    description: Optional[str] = None
    fields: list[TemplateField]
    created_at: str
    

class TemplateAnalyzeResponse(BaseModel):
    """模板分析結果"""
    success: bool
    template_id: str
    detected_fields: list[TemplateField]
    suggested_mappings: dict[str, str]  # field_id -> inspection_field
    message: str


class TemplateMappingRequest(BaseModel):
    """確認/調整欄位對應"""
    template_id: str
    field_mappings: dict[str, str]  # field_id -> inspection_field


# ============ API Endpoints ============

@router.get("/", response_model=list[TemplateInfo])
async def list_templates():
    """取得所有廠商模板列表"""
    try:
        service = FormFillService()
        templates = await service.list_templates()
        return templates
    except Exception as e:
        logger.error(f"List templates failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/{template_id}", response_model=TemplateInfo)
async def get_template(template_id: str):
    """取得單一模板詳情"""
    try:
        service = FormFillService()
        template = await service.get_template(template_id)
        if not template:
            raise HTTPException(status_code=404, detail="模板不存在")
        return template
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Get template failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/upload", response_model=TemplateAnalyzeResponse)
async def upload_and_analyze_template(
    file: UploadFile = File(...),
    vendor_name: str = Form(...),
    template_name: str = Form(...),
    description: str = Form(None)
):
    """
    上傳廠商模板並自動分析欄位
    
    AI 會自動識別模板中的欄位，並建議與巡檢資料的對應關係
    """
    try:
        # 驗證檔案類型
        allowed_types = [
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',  # xlsx
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document',  # docx
            'application/vnd.ms-excel',  # xls
        ]
        
        if file.content_type not in allowed_types:
            raise HTTPException(
                status_code=400, 
                detail=f"不支援的檔案類型: {file.content_type}，請上傳 Excel 或 Word 檔案"
            )
        
        service = FormFillService()
        
        # 讀取檔案內容
        content = await file.read()
        
        # AI 分析模板結構
        result = await service.analyze_template(
            file_content=content,
            file_name=file.filename,
            vendor_name=vendor_name,
            template_name=template_name,
            description=description
        )
        
        return result
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Upload template failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/{template_id}/confirm-mapping")
async def confirm_field_mapping(template_id: str, request: TemplateMappingRequest):
    """
    確認欄位對應關係
    
    使用者確認或調整 AI 建議的欄位對應後，儲存設定
    """
    try:
        service = FormFillService()
        
        await service.save_field_mappings(
            template_id=template_id,
            mappings=request.field_mappings
        )
        
        return {"success": True, "message": "欄位對應已儲存"}
        
    except Exception as e:
        logger.error(f"Confirm mapping failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/{template_id}")
async def delete_template(template_id: str):
    """刪除模板"""
    try:
        service = FormFillService()
        await service.delete_template(template_id)
        return {"success": True, "message": "模板已刪除"}
    except Exception as e:
        logger.error(f"Delete template failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))
