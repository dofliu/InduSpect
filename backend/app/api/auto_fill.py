"""
自動回填 API - 定檢結果自動回填至原始 Excel/Word 表格

工作流程：
1. POST /analyze-structure  — 上傳定檢文件，深度分析表格結構
2. POST /map-fields         — AI 自動映射檢查結果到表格欄位
3. POST /preview            — 預覽回填結果
4. POST /execute            — 執行回填，回傳填好的文件
"""

from fastapi import APIRouter, HTTPException, UploadFile, File, Form
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field, field_validator
from typing import Optional
import logging
import io

from app.api.errors import internal_error
from app.services.form_fill import FormFillService
from app.services.history_service import HistoryService

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


# ---- Sprint 1: 拍照任務相關 Models ----

class PhotoTask(BaseModel):
    """拍照任務"""
    task_id: str
    field_ids: list[str]
    value_field_ids: list[str] = []
    judgment_field_ids: list[str] = []
    remarks_field_ids: list[str] = []
    display_name: str
    photo_hint: str
    expected_type: str = "text"
    expected_unit: str = ""
    sequence: int
    row_key: Optional[str] = None


class BasicInfoField(BaseModel):
    """基本資訊欄位（不需拍照）"""
    field_id: str
    field_name: str
    field_type: str
    value_location: Optional[dict] = None
    default_value: Optional[str] = None


class ConclusionField(BaseModel):
    """結論/簽核欄位"""
    field_id: str
    field_name: str
    field_type: str
    value_location: Optional[dict] = None


class PhotoTaskStats(BaseModel):
    """拍照任務統計"""
    total_tasks: int
    total_basic: int
    total_conclusion: int
    total_fields_covered: int


class GeneratePhotoTasksRequest(BaseModel):
    """產生拍照任務請求"""
    field_map: list[FieldMapEntry]


class GeneratePhotoTasksResponse(BaseModel):
    """產生拍照任務回應"""
    photo_tasks: list[PhotoTask]
    basic_info_fields: list[BasicInfoField]
    conclusion_fields: list[ConclusionField]
    stats: PhotoTaskStats


class PhotoTaskBinding(BaseModel):
    """拍照任務綁定（含 AI 分析結果）"""
    task_id: str
    field_ids: list[str]
    value_field_ids: list[str] = []
    judgment_field_ids: list[str] = []
    remarks_field_ids: list[str] = []
    ai_result: Optional[dict] = None


class PrecisionMapFieldsRequest(BaseModel):
    """精準映射請求（帶 photo_task_bindings）"""
    field_map: list[FieldMapEntry]
    inspection_results: list[InspectionResult]
    photo_task_bindings: Optional[list[PhotoTaskBinding]] = None


class PhotoBindingItem(BaseModel):
    """照片綁定項目（用於插入照片）"""
    task_id: str
    display_name: str
    photo_base64: Optional[str] = None
    capture_time: Optional[str] = None
    sequence: Optional[int] = 1


class InsertPhotosRequest(BaseModel):
    """照片插入請求"""
    photo_bindings: list[PhotoBindingItem]


# ============ API Endpoints ============

@router.post("/generate-photo-tasks", response_model=GeneratePhotoTasksResponse)
async def generate_photo_tasks(request: GeneratePhotoTasksRequest):
    """
    從表單欄位地圖自動產生拍照任務清單

    將表單欄位分為三類：
    1. photo_tasks: 需要拍照的檢查項目（同列欄位自動合併）
    2. basic_info_fields: 不需拍照的基本資訊（日期、人員等）
    3. conclusion_fields: 結論/簽核欄位

    使用時機: 在 analyze-structure 之後呼叫，取得拍照引導清單
    """
    try:
        service = FormFillService()

        result = await service.generate_photo_tasks(
            field_map=[f.model_dump() for f in request.field_map],
        )

        return result

    except Exception as e:
        logger.error(f"Generate photo tasks failed: {e}")
        raise internal_error(e)


@router.post("/precision-map-fields", response_model=MapFieldsResponse)
async def precision_map_fields(request: PrecisionMapFieldsRequest):
    """
    精準映射（帶 photo_task_bindings）

    當有 photo_task_bindings 時，利用照片與欄位的綁定關係進行精準映射，
    大幅提升映射準確率。無 bindings 時退回通用映射。
    """
    try:
        service = FormFillService()

        if request.photo_task_bindings:
            result = await service.precision_map_fields(
                field_map=[f.model_dump() for f in request.field_map],
                inspection_results=[r.model_dump() for r in request.inspection_results],
                photo_task_bindings=[b.model_dump() for b in request.photo_task_bindings],
            )
        else:
            result = await service.ai_map_fields(
                field_map=[f.model_dump() for f in request.field_map],
                inspection_results=[r.model_dump() for r in request.inspection_results],
            )

        return result

    except Exception as e:
        logger.error(f"Precision map fields failed: {e}")
        raise internal_error(e)


@router.post("/insert-photos")
async def insert_photos(
    file: UploadFile = File(...),
    photo_bindings_json: str = Form(""),
):
    """
    將照片自動插入到 Excel/Word 報告中

    photo_bindings_json: JSON 字串，包含照片資訊陣列
    每個元素需要: task_id, display_name, photo_base64, capture_time, sequence
    """
    import json as json_module

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
        photo_bindings = json_module.loads(photo_bindings_json) if photo_bindings_json else []

        if not photo_bindings:
            raise HTTPException(status_code=400, detail="photo_bindings 不可為空")

        service = FormFillService()

        result_bytes = await service.insert_photos_into_report(
            file_content=content,
            file_name=file.filename,
            photo_bindings=photo_bindings,
        )

        file_ext = file.filename.split('.')[-1].lower()
        if file_ext == 'xlsx':
            media_type = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        elif file_ext == 'docx':
            media_type = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        else:
            media_type = "application/octet-stream"

        output_filename = f"photos_{file.filename}"

        return StreamingResponse(
            io.BytesIO(result_bytes),
            media_type=media_type,
            headers={
                "Content-Disposition": f'attachment; filename="{output_filename}"',
            }
        )

    except HTTPException:
        raise
    except json_module.JSONDecodeError as e:
        raise HTTPException(status_code=400, detail=f"JSON 格式錯誤: {e}")
    except Exception as e:
        logger.error(f"Insert photos failed: {e}")
        raise internal_error(e)


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
        raise internal_error(e)


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
        raise internal_error(e)


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
        raise internal_error(e)


@router.post("/execute")
async def execute_auto_fill(
    file: UploadFile = File(...),
    field_map_json: str = Form(""),
    fill_values_json: str = Form(""),
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
        raise internal_error(e)


# ============ Sprint 4: One-Stop Inspection Workflow ============

class ReadingItem(BaseModel):
    """單筆量測讀數

    Issue #47 輸入驗證：
    - value 拒絕 NaN/inf（NaN 進入 gte/lte 比較必為 False → 誤判 fail，屬安全問題）
    - field_name 去空白後不可為空、長度上限防呆
    """
    field_name: str = Field(max_length=200)
    value: float = Field(allow_inf_nan=False)
    unit: str = Field(default="", max_length=32)

    @field_validator("field_name")
    @classmethod
    def _field_name_not_blank(cls, v: str) -> str:
        stripped = v.strip()
        if not stripped:
            raise ValueError("field_name 不可為空白")
        return stripped


class EquipmentInfo(BaseModel):
    """設備資訊"""
    equipment_id: str
    equipment_name: str = ""
    equipment_type: str = ""
    location: str = ""


class OneStopProcessRequest(BaseModel):
    """一站式檢查流程請求"""
    equipment_info: EquipmentInfo
    readings: list[ReadingItem]
    field_map: list[FieldMapEntry]
    photo_task_bindings: Optional[list[PhotoTaskBinding]] = None
    inspection_results: Optional[list[InspectionResult]] = None
    inspector_name: str = ""
    inspection_date: str = ""


class JudgmentResult(BaseModel):
    """判定結果"""
    field_name: str
    measured_value: float
    unit: str = ""
    judgment: str = "unknown"
    standard_text: str = ""
    regulation: str = ""
    confidence: float = 0.0
    standard_id: Optional[str] = None
    # 讀數單位與標準單位不一致時，換算成標準單位後的數值（用於前端透明顯示）
    converted_value: Optional[float] = None
    converted_unit: Optional[str] = None


class PreviousValueItem(BaseModel):
    """前次數值項目"""
    field_name: str
    value: Optional[float] = None
    unit: str = ""
    date: str = ""


class OneStopProcessResponse(BaseModel):
    """一站式檢查流程回應"""
    success: bool
    judgments: list[JudgmentResult]
    mappings: list[MappingItem]
    unmapped_fields: list[str]
    previous_values: list[PreviousValueItem]
    warnings: list[str]
    summary: dict


@router.post("/one-stop-process", response_model=OneStopProcessResponse)
async def one_stop_process(request: OneStopProcessRequest):
    """
    一站式定檢流程 — 後端編排器

    整合以下步驟:
    1. 對每筆量測讀數執行 auto_judge（自動判定合格/不合格）
    2. 呼叫 precision_map_fields 進行欄位精準映射
    3. 查詢歷史資料取得前次數值
    4. 回傳合併預覽結果（judgments + mappings + previous_values + warnings）
    """
    try:
        form_service = FormFillService()
        history_service = HistoryService()

        # Step 1: 批次自動判定
        readings_for_judge = [
            {
                "field_name": r.field_name,
                "value": r.value,
                "unit": r.unit,
            }
            for r in request.readings
        ]

        judgments = await form_service.batch_auto_judge(
            readings=readings_for_judge,
            equipment_type=request.equipment_info.equipment_type,
        )

        # Step 2: 精準映射
        # 構建 inspection_results（如果沒有提供，從 readings 建立）
        if request.inspection_results:
            ir_dicts = [r.model_dump() for r in request.inspection_results]
        else:
            # 從 readings + equipment_info 組合成 inspection_results
            extracted_values = {}
            for r in request.readings:
                extracted_values[r.field_name] = {
                    "value": r.value,
                    "unit": r.unit,
                }
            ir_dicts = [{
                "equipment_name": request.equipment_info.equipment_name,
                "equipment_type": request.equipment_info.equipment_type,
                "equipment_id": request.equipment_info.equipment_id,
                "inspection_date": request.inspection_date,
                "inspector_name": request.inspector_name,
                "location": request.equipment_info.location,
                "extracted_values": extracted_values,
            }]

        if request.photo_task_bindings:
            map_result = await form_service.precision_map_fields(
                field_map=[f.model_dump() for f in request.field_map],
                inspection_results=ir_dicts,
                photo_task_bindings=[b.model_dump() for b in request.photo_task_bindings],
            )
        else:
            # 無 photo_task_bindings 時使用基本映射（不呼叫 AI）
            map_result = {
                "success": True,
                "mappings": [],
                "unmapped_fields": [f.field_id for f in request.field_map],
            }

        # Step 3: 查詢前次數值
        field_names = [r.field_name for r in request.readings]
        previous_values_dict = await history_service.get_previous_values(
            equipment_id=request.equipment_info.equipment_id,
            field_names=field_names,
        )

        previous_values = []
        for fn, pv in previous_values_dict.items():
            previous_values.append({
                "field_name": fn,
                "value": pv.get("value"),
                "unit": pv.get("unit", ""),
                "date": pv.get("date", ""),
            })

        # Step 4: 組裝警告
        warnings = []
        fail_count = 0
        warning_count = 0

        for j in judgments:
            if j["judgment"] == "fail":
                fail_count += 1
                warnings.append(
                    f"不合格: {j['field_name']} = {j['measured_value']}{j.get('unit', '')}，"
                    f"標準: {j.get('standard_text', '')}"
                )
            elif j["judgment"] == "warning":
                warning_count += 1
                warnings.append(
                    f"警告: {j['field_name']} = {j['measured_value']}{j.get('unit', '')} 接近不合格"
                )

        # 趨勢警告
        for fn in field_names:
            trend = await history_service.analyze_trend(
                equipment_id=request.equipment_info.equipment_id,
                field_name=fn,
            )
            if trend and trend.get("warning"):
                warnings.append(trend["warning"])

        # 組裝 summary
        summary = {
            "total_readings": len(request.readings),
            "pass_count": sum(1 for j in judgments if j["judgment"] == "pass"),
            "fail_count": fail_count,
            "warning_count": warning_count,
            "unknown_count": sum(1 for j in judgments if j["judgment"] == "unknown"),
            "mapped_fields": len(map_result.get("mappings", [])),
            "unmapped_fields": len(map_result.get("unmapped_fields", [])),
            "has_previous_data": len(previous_values) > 0,
        }

        return {
            "success": True,
            "judgments": judgments,
            "mappings": map_result.get("mappings", []),
            "unmapped_fields": map_result.get("unmapped_fields", []),
            "previous_values": previous_values,
            "warnings": warnings,
            "summary": summary,
        }

    except Exception as e:
        logger.error(f"One-stop process failed: {e}")
        raise internal_error(e)


# ============ Sprint 5: Batch Inspection Mode ============

class BatchEquipmentItem(BaseModel):
    """批次處理中的單一設備項目"""
    equipment_info: EquipmentInfo
    readings: list[ReadingItem]
    inspector_name: str = ""
    inspection_date: str = ""


class BatchProcessRequest(BaseModel):
    """批次檢查處理請求"""
    equipment_list: list[BatchEquipmentItem]
    field_map: list[FieldMapEntry]


class BatchEquipmentResult(BaseModel):
    """單一設備的批次處理結果"""
    equipment_id: str
    equipment_name: str
    success: bool
    judgments: list[JudgmentResult]
    warnings: list[str]
    summary: dict
    error: Optional[str] = None


class BatchProcessResponse(BaseModel):
    """批次檢查處理回應"""
    success: bool
    total_equipment: int
    processed_count: int
    failed_count: int
    results: list[BatchEquipmentResult]
    overall_summary: dict


@router.post("/batch-process", response_model=BatchProcessResponse)
async def batch_process(request: BatchProcessRequest):
    """
    批次定檢處理 — 一次處理多台設備

    對每台設備執行 one-stop-process 流程（自動判定），
    回傳所有設備的彙總結果。
    """
    try:
        form_service = FormFillService()

        results = await form_service.batch_process(
            equipment_list=[item.model_dump() for item in request.equipment_list],
            field_map=[f.model_dump() for f in request.field_map],
        )

        return results

    except Exception as e:
        logger.error(f"Batch process failed: {e}")
        raise internal_error(e)


# ============ 輕量級讀數判定（App 自動定檢用） ============

class JudgeReadingsRequest(BaseModel):
    """讀數判定請求 — 行動 App 在 AI 辨識後直接送出讀數做標準判定

    Issue #47：readings 數量上限防呆（單張表單欄位至多數十筆，500 已極寬鬆）
    """
    readings: list[ReadingItem] = Field(max_length=500)
    equipment_type: str = Field(default="", max_length=100)


class JudgeReadingsResponse(BaseModel):
    """讀數判定回應"""
    success: bool
    judgments: list[JudgmentResult]
    warnings: list[str]
    summary: dict


@router.post("/judge-readings", response_model=JudgeReadingsResponse)
async def judge_readings(request: JudgeReadingsRequest):
    """
    輕量級讀數判定 — 不需 field_map / 歷史資料

    行動 App 在「一鍵自動檢測」批次 AI 分析後，把抽取到的數值讀數送進來，
    依 56 條法規標準自動判定合格/不合格/警告（判定前自動換算單位）。
    比 /one-stop-process 輕量，適合 App 在拍照分析流程中即時呼叫。
    """
    try:
        form_service = FormFillService()

        readings_for_judge = [
            {"field_name": r.field_name, "value": r.value, "unit": r.unit}
            for r in request.readings
        ]

        judgments = await form_service.batch_auto_judge(
            readings=readings_for_judge,
            equipment_type=request.equipment_type,
        )

        warnings = []
        for j in judgments:
            if j["judgment"] == "fail":
                warnings.append(
                    f"不合格: {j['field_name']} = {j['measured_value']}{j.get('unit', '')}，"
                    f"標準: {j.get('standard_text', '')}"
                )
            elif j["judgment"] == "warning":
                warnings.append(
                    f"警告: {j['field_name']} = {j['measured_value']}{j.get('unit', '')} 接近不合格"
                )

        summary = {
            "total_readings": len(judgments),
            "pass_count": sum(1 for j in judgments if j["judgment"] == "pass"),
            "fail_count": sum(1 for j in judgments if j["judgment"] == "fail"),
            "warning_count": sum(1 for j in judgments if j["judgment"] == "warning"),
            "unknown_count": sum(1 for j in judgments if j["judgment"] == "unknown"),
        }

        return {
            "success": True,
            "judgments": judgments,
            "warnings": warnings,
            "summary": summary,
        }

    except Exception as e:
        logger.error(f"Judge readings failed: {e}")
        raise internal_error(e)
