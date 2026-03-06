"""
報告生成 API - 根據巡檢資料填入廠商模板並產生報告
"""

from fastapi import APIRouter, HTTPException, BackgroundTasks
from fastapi.responses import FileResponse
from pydantic import BaseModel
from typing import Optional
import logging
import uuid
from datetime import datetime

from app.services.form_fill import FormFillService

router = APIRouter()
logger = logging.getLogger(__name__)


# ============ Request/Response Models ============

class InspectionData(BaseModel):
    """巡檢資料"""
    inspection_id: str
    equipment_name: str
    equipment_type: str
    inspection_date: str
    inspector_name: Optional[str] = None
    location: Optional[str] = None
    
    # AI 分析結果
    condition_assessment: str
    anomaly_description: Optional[str] = None
    extracted_values: Optional[dict] = None  # 儀表讀數等
    
    # 其他
    notes: Optional[str] = None
    photos: Optional[list[str]] = None  # 照片 URL 列表
    
    class Config:
        json_schema_extra = {
            "example": {
                "inspection_id": "INSP-2026-001",
                "equipment_name": "大型齒輪與滑塊機構",
                "equipment_type": "傳動系統",
                "inspection_date": "2026-01-23",
                "inspector_name": "張三",
                "location": "A 廠區 2 樓",
                "condition_assessment": "潤滑劑狀況不佳，需要清潔與重新潤滑",
                "anomaly_description": "齒輪齒面與滑塊周圍有大量黑色黏稠狀髒污與舊潤滑劑堆積",
                "extracted_values": {"潤滑劑顏色": "黑色", "髒污程度": "嚴重"}
            }
        }


class GenerateReportRequest(BaseModel):
    """產生報告請求"""
    template_id: str
    inspection_data: InspectionData
    output_format: str = "xlsx"  # 'xlsx' / 'docx' / 'pdf'


class GenerateReportResponse(BaseModel):
    """產生報告回應"""
    success: bool
    report_id: str
    status: str  # 'processing' / 'completed' / 'failed'
    message: str
    download_url: Optional[str] = None


class ReportPreviewRequest(BaseModel):
    """預覽報告請求"""
    template_id: str
    inspection_data: InspectionData


class ReportPreviewResponse(BaseModel):
    """預覽報告回應 - 顯示填入的欄位對應"""
    template_name: str
    vendor_name: str
    field_values: dict[str, str]  # field_name -> filled_value
    warnings: list[str]  # 可能有問題的欄位提醒


class BatchGenerateRequest(BaseModel):
    """批次產生報告請求 (離線佇列同步)"""
    reports: list[GenerateReportRequest]


class BatchGenerateResponse(BaseModel):
    """批次產生報告回應"""
    success: bool
    total: int
    processed: int
    failed: int
    results: list[GenerateReportResponse]


# ============ API Endpoints ============

@router.post("/preview", response_model=ReportPreviewResponse)
async def preview_report(request: ReportPreviewRequest):
    """
    預覽報告填入結果
    
    在實際產生報告前，顯示各欄位將填入的值，讓使用者確認
    """
    try:
        service = FormFillService()
        
        preview = await service.preview_fill(
            template_id=request.template_id,
            inspection_data=request.inspection_data.model_dump()
        )
        
        return preview
        
    except Exception as e:
        logger.error(f"Preview report failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/generate", response_model=GenerateReportResponse)
async def generate_report(
    request: GenerateReportRequest,
    background_tasks: BackgroundTasks
):
    """
    產生廠商報告
    
    根據巡檢資料填入選定的廠商模板，產生完成的報告檔案
    """
    try:
        service = FormFillService()
        
        # 建立報告記錄
        report_id = str(uuid.uuid4())
        
        # 背景執行報告產生
        background_tasks.add_task(
            service.generate_report,
            report_id=report_id,
            template_id=request.template_id,
            inspection_data=request.inspection_data.model_dump(),
            output_format=request.output_format
        )
        
        return GenerateReportResponse(
            success=True,
            report_id=report_id,
            status="processing",
            message="報告產生中，完成後可下載"
        )
        
    except Exception as e:
        logger.error(f"Generate report failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/{report_id}/status", response_model=GenerateReportResponse)
async def get_report_status(report_id: str):
    """查詢報告產生狀態"""
    try:
        service = FormFillService()
        status = await service.get_report_status(report_id)
        
        if not status:
            raise HTTPException(status_code=404, detail="報告不存在")
            
        return status
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Get report status failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/{report_id}/download")
async def download_report(report_id: str):
    """下載產生完成的報告"""
    try:
        service = FormFillService()
        file_path = await service.get_report_file(report_id)
        
        if not file_path:
            raise HTTPException(status_code=404, detail="報告檔案不存在或尚未完成")
        
        return FileResponse(
            path=file_path,
            filename=f"report_{report_id}.xlsx",
            media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        )
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Download report failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/batch", response_model=BatchGenerateResponse)
async def batch_generate_reports(request: BatchGenerateRequest):
    """
    批次產生報告 (離線佇列同步)
    
    處理 App 離線時累積的報告產生請求
    """
    try:
        service = FormFillService()
        
        results = []
        failed_count = 0
        
        for req in request.reports:
            try:
                report_id = str(uuid.uuid4())
                
                # 同步執行 (批次模式)
                await service.generate_report(
                    report_id=report_id,
                    template_id=req.template_id,
                    inspection_data=req.inspection_data.model_dump(),
                    output_format=req.output_format
                )
                
                results.append(GenerateReportResponse(
                    success=True,
                    report_id=report_id,
                    status="completed",
                    message="報告已產生"
                ))
                
            except Exception as e:
                failed_count += 1
                results.append(GenerateReportResponse(
                    success=False,
                    report_id="",
                    status="failed",
                    message=str(e)
                ))
        
        return BatchGenerateResponse(
            success=failed_count == 0,
            total=len(request.reports),
            processed=len(request.reports) - failed_count,
            failed=failed_count,
            results=results
        )
        
    except Exception as e:
        logger.error(f"Batch generate failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))
