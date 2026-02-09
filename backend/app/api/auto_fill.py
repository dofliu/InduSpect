"""
自動回填 API - 定檢結果自動回填至原始 Excel/Word 表格

工作流程：
1. POST /analyze-structure  — 上傳定檢文件，深度分析表格結構
2. POST /map-fields         — AI 自動映射檢查結果到表格欄位
3. POST /preview            — 預覽回填結果
4. POST /execute            — 執行回填，回傳填好的文件
"""

from fastapi import APIRouter, HTTPException, UploadFile, File
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from typing import Optional
import logging
import io

from app.services.form_fill import FormFillService

router = APIRouter()
logger = logging.getLogger(__name__)


# ============ Request/Response Models ============

class FieldLocation(BaseModel):
    """欄位位置資訊"""
    sheet: Optional[str] = None       # Excel sheet name
    cell: Optional[str] = None        # Excel cell coordinate
    row: Optional[int] = None
    column: Optional[int] = None
    direction: Optional[str] = None   # 'right' / 'below'
    offset: Optional[int] = None
    type: Optional[str] = None        # 'paragraph' / 'table' (Word)
    paragraph_index: Optional[int] = None
    table_index: Optional[int] = None
    row_index: Optional[int] = None
    cell_index: Optional[int] = None
    replace_pattern: Optional[str] = None


class FieldMapEntry(BaseModel):
    """欄位地圖項目"""
    field_id: str
    field_name: str
    field_type: str
    label_location: Optional[dict] = None
    value_location: Optional[dict] = None
    is_merged: Optional[bool] = False
    merge_info: Optional[dict] = None
    mapping: Optional[str] = None


class StructureAnalysisResponse(BaseModel):
    """結構分析回應"""
    success: bool
    file_type: str
    field_map: list[FieldMapEntry]
    total_fields: int


class InspectionResult(BaseModel):
    """單筆 AI 檢查結果"""
    equipment_name: Optional[str] = None
    equipment_type: Optional[str] = None
    equipment_id: Optional[str] = None
    inspection_date: Optional[str] = None
    inspector_name: Optional[str] = None
    location: Optional[str] = None
    condition_assessment: Optional[str] = None
    anomaly_description: Optional[str] = None
    is_anomaly: Optional[bool] = False
    extracted_values: Optional[dict] = None
    notes: Optional[str] = None


class MapFieldsRequest(BaseModel):
    """AI 映射請求"""
    field_map: list[FieldMapEntry]
    inspection_results: list[InspectionResult]


class MappingItem(BaseModel):
    """映射項目"""
    field_id: str
    suggested_value: str
    source: str
    confidence: float


class MapFieldsResponse(BaseModel):
    """AI 映射回應"""
    success: bool
    mappings: list[MappingItem]
    unmapped_fields: list[str]
    error: Optional[str] = None


class FillValue(BaseModel):
    """要填入的值"""
    field_id: str
    value: str
    confidence: Optional[float] = None
    source: Optional[str] = None


class PreviewRequest(BaseModel):
    """預覽請求"""
    field_map: list[FieldMapEntry]
    fill_values: list[FillValue]


class PreviewItem(BaseModel):
    """預覽項目"""
    field_id: str
    field_name: str
    field_type: str
    value: Optional[str] = None
    confidence: float = 0.0
    source: str = ""
    has_target: bool = False


class PreviewResponse(BaseModel):
    """預覽回應"""
    preview_items: list[PreviewItem]
    total_fields: int
    filled_count: int
    warnings: list[str]


class AutoFillRequest(BaseModel):
    """自動回填請求"""
    field_map: list[FieldMapEntry]
    fill_values: list[FillValue]


# ============ API Endpoints ============

@router.post("/analyze-structure", response_model=StructureAnalysisResponse)
async def analyze_structure(file: UploadFile = File(...)):
    """
    深度分析定檢文件結構

    上傳 Excel (.xlsx) 或 Word (.docx) 定檢表格，
    系統自動識別所有欄位位置，回傳完整的 Field Position Map。
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

        content = await file.read()
        service = FormFillService()

        result = await service.analyze_structure(
            file_content=content,
            file_name=file.filename,
        )

        return result

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Analyze structure failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/map-fields", response_model=MapFieldsResponse)
async def map_fields(request: MapFieldsRequest):
    """
    AI 自動映射檢查結果到表格欄位

    根據表格結構 (field_map) 和 AI 檢查結果 (inspection_results)，
    使用 Gemini AI 智慧匹配並建議每個欄位應填入的值。
    """
    try:
        service = FormFillService()

        result = await service.ai_map_fields(
            field_map=[f.model_dump() for f in request.field_map],
            inspection_results=[r.model_dump() for r in request.inspection_results],
        )

        return result

    except Exception as e:
        logger.error(f"Map fields failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/preview", response_model=PreviewResponse)
async def preview_auto_fill(request: PreviewRequest):
    """
    預覽自動回填結果

    在實際執行回填前，顯示每個欄位即將填入的值、信心度、來源。
    允許使用者在前端逐項確認或修改。
    """
    try:
        service = FormFillService()

        result = await service.preview_auto_fill(
            field_map=[f.model_dump() for f in request.field_map],
            fill_values=[v.model_dump() for v in request.fill_values],
        )

        return result

    except Exception as e:
        logger.error(f"Preview auto-fill failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/execute")
async def execute_auto_fill(
    file: UploadFile = File(...),
    field_map_json: str = "",
    fill_values_json: str = "",
):
    """
    執行自動回填

    將確認的值寫入原始文件的指定位置，回傳填好的文件。
    保留原始格式（字體、邊框、合併儲存格、樣式等）。

    注意：field_map_json 和 fill_values_json 為 JSON 字串，
    因為 multipart/form-data 不支援直接傳遞複雜物件。
    """
    import json

    try:
        allowed_types = [
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
            'application/vnd.ms-excel',
        ]

        if file.content_type not in allowed_types:
            raise HTTPException(
                status_code=400,
                detail=f"不支援的檔案類型: {file.content_type}"
            )

        content = await file.read()
        field_map = json.loads(field_map_json) if field_map_json else []
        fill_values = json.loads(fill_values_json) if fill_values_json else []

        if not field_map or not fill_values:
            raise HTTPException(
                status_code=400,
                detail="field_map 和 fill_values 不可為空"
            )

        service = FormFillService()

        filled_bytes = await service.auto_fill(
            file_content=content,
            file_name=file.filename,
            field_map=field_map,
            fill_values=fill_values,
        )

        # 判斷輸出格式
        file_ext = file.filename.split('.')[-1].lower()
        if file_ext == 'xlsx':
            media_type = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        elif file_ext == 'docx':
            media_type = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        else:
            media_type = "application/octet-stream"

        output_filename = f"filled_{file.filename}"

        return StreamingResponse(
            io.BytesIO(filled_bytes),
            media_type=media_type,
            headers={
                "Content-Disposition": f'attachment; filename="{output_filename}"',
            }
        )

    except HTTPException:
        raise
    except json.JSONDecodeError as e:
        raise HTTPException(
            status_code=400,
            detail=f"JSON 格式錯誤: {e}"
        )
    except Exception as e:
        logger.error(f"Execute auto-fill failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))
