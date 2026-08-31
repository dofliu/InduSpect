"""
模板管理 API - 廠商報告模板的上傳、分析與管理

整合後的端點：
- POST /create-from-file  — 從真實表單建立模板（主要端點）
- GET  /defaults           — 預設模板清單
- GET  /recent             — 最近使用的模板
- POST /record-usage       — 記錄模板使用

已移除的端點（原使用記憶體 dict，重啟即消失）：
- GET  /                   — 已移除（改用 /defaults）
- GET  /{template_id}      — 已移除
- POST /upload             — 已移除（與 /create-from-file 重複）
- POST /{template_id}/confirm-mapping — 已移除
- DELETE /{template_id}    — 已移除
"""

from fastapi import APIRouter, HTTPException, UploadFile, File, Form
from pydantic import BaseModel
from typing import Optional
import logging

from app.api.errors import internal_error
from app.services.form_fill import FormFillService
from app.services.template_service import TemplateService

router = APIRouter()
logger = logging.getLogger(__name__)


# ============ Request/Response Models ============

class RecordUsageRequest(BaseModel):
    """模板使用紀錄請求"""
    user_id: str
    template_id: str
    file_name: str = ""


# ============ 主要端點 ============

@router.post("/create-from-file")
async def create_template_from_file(
    file: UploadFile = File(...),
    template_name: str = Form(...),
    category: str = Form("一般設備"),
    company: str = Form(""),
    department: str = Form(""),
):
    """
    從真實廠商表單自動建立檢測模板

    上傳 Excel/Word 定檢表格，AI 自動分析結構並產生
    InspectionTemplate JSON，可直接用於 App 端引導式填寫。

    流程：
    1. 上傳真實表單 → AI 分析欄位結構
    2. AI 自動分組、推測欄位類型、產生 sections/fields
    3. 回傳完整 InspectionTemplate JSON + 原始文件綁定資訊
    4. App 端儲存為永久模板，之後每次直接選用
    """
    try:
        allowed_types = [
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
            'application/vnd.ms-excel',
        ]

        if file.content_type not in allowed_types:
            raise HTTPException(
                status_code=400,
                detail=f"不支援的檔案類型: {file.content_type}，請上傳 Excel 或 Word 檔案"
            )

        service = FormFillService()
        content = await file.read()

        result = await service.create_template_from_file(
            file_content=content,
            file_name=file.filename,
            template_name=template_name,
            category=category,
            company=company,
            department=department,
        )

        return result

    except HTTPException:
        raise
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        logger.error(f"Create template from file failed: {e}")
        raise internal_error(e)


# ============ 範本庫端點（Sprint 5） ============

@router.get("/defaults", response_model=list)
async def get_default_templates():
    """取得預設模板清單"""
    try:
        service = TemplateService()
        return service.get_default_templates()
    except Exception as e:
        logger.error(f"Get default templates failed: {e}")
        raise internal_error(e)


@router.get("/recent", response_model=list)
async def get_recent_templates(user_id: str):
    """取得使用者最近使用的模板"""
    try:
        service = TemplateService()
        return service.get_recent_templates(user_id=user_id)
    except Exception as e:
        logger.error(f"Get recent templates failed: {e}")
        raise internal_error(e)


@router.post("/record-usage")
async def record_template_usage(request: RecordUsageRequest):
    """記錄模板使用"""
    try:
        service = TemplateService()
        ok = service.record_template_usage(
            user_id=request.user_id,
            template_id=request.template_id,
            file_name=request.file_name,
        )
        return {"success": ok}
    except Exception as e:
        logger.error(f"Record template usage failed: {e}")
        raise internal_error(e)
