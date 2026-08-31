"""
表單填入服務 - Orchestrator

精簡後的協調器，將具體邏輯委派給各專責子服務：
- PhotoTaskService: 拍照任務產生
- FormAnalysisService: 結構分析、模板建立、欄位映射
- AutoFillService: 自動回填、預覽、報告
- CheckboxService: 勾選欄位偵測與回填
- PhotoProcessingService: 照片插入報告
- JudgmentService: 自動判定
"""

import logging
from typing import Optional
from datetime import datetime

from app.services.photo_task_service import PhotoTaskService
from app.services.form_analysis_service import FormAnalysisService
from app.services.auto_fill_service import AutoFillService
from app.services.checkbox_service import CheckboxService
from app.services.photo_processing_service import PhotoProcessingService
from app.services.judgment_service import JudgmentService
from app.services.form_utils import (
    is_field_label, is_placeholder, guess_field_type,
    convert_value, is_section_header, is_non_field_item,
    replace_paragraph_text_preserve_format,
)

# Re-export constants for backward compatibility
from app.constants import (  # noqa: F401
    FIELD_KEYWORDS, BASIC_INFO_KEYWORDS, JUDGMENT_KEYWORDS,
    REMARKS_KEYWORDS, CONCLUSION_KEYWORDS, INSPECTION_FIELDS,
)

logger = logging.getLogger(__name__)


class FormFillService:
    """表單自動填入服務 — Orchestrator"""

    # 模板/報告狀態的行程內共享存放區（class-level）。
    #
    # 原本是 instance attribute，而各 endpoint 每個請求都 new 一個
    # FormFillService → 存進去的模板活不過單一請求，/reports 舊版流程
    # 跨請求必然 Template not found（LAUNCH_PLAN P1 發現）。
    # 改為 class-level 後單一實例（行程）內跨請求可用。
    #
    # 已知限制：多實例（Cloud Run max-instances>1）或重啟後仍會遺失 —
    # 真正的多實例支援需落 DB/GCS（核心 pipeline 不受影響：
    # /api/auto-fill/* 為無狀態設計，檔案隨請求帶入）。
    _templates: dict[str, dict] = {}

    def __init__(self):
        # Sub-services
        self._photo_task_service = PhotoTaskService()
        self._analysis_service = FormAnalysisService()
        self._auto_fill_service = AutoFillService()
        self._checkbox_service = CheckboxService()
        self._photo_service = PhotoProcessingService()
        self._judgment_service = JudgmentService()

    # ================================================================
    # 拍照任務清單產生（Sprint 1）
    # ================================================================

    async def generate_photo_tasks(
        self,
        field_map: list[dict],
    ) -> dict:
        """從 field_map 自動產生「拍照任務清單」"""
        return await self._photo_task_service.generate_photo_tasks(field_map)

    # ================================================================
    # 勾選式表格偵測 — 委派給 CheckboxService
    # ================================================================

    async def detect_checkbox_columns(
        self,
        file_content: bytes,
        file_name: str,
    ) -> dict:
        """偵測表單中的「合格/不合格」雙欄勾選結構"""
        return await self._checkbox_service.detect_checkbox_columns(file_content, file_name)

    # ================================================================
    # 勾選回填引擎 — 委派給 CheckboxService
    # ================================================================

    async def auto_fill_with_checkboxes(
        self,
        file_content: bytes,
        file_name: str,
        field_map: list[dict],
        fill_values: list[dict],
        dual_column_fields: list[dict] = None,
        check_symbol: str = "✓",
    ) -> bytes:
        """增強版自動回填: 支援勾選式表單"""
        return await self._checkbox_service.auto_fill_with_checkboxes(
            file_content, file_name, field_map, fill_values,
            dual_column_fields, check_symbol,
        )

    # ================================================================
    # 精準欄位映射（Sprint 1 Task 1.4）
    # ================================================================

    async def precision_map_fields(
        self,
        field_map: list[dict],
        inspection_results: list[dict],
        photo_task_bindings: list[dict],
    ) -> dict:
        """利用 photo_task_bindings 進行精準映射"""
        return await self._analysis_service.precision_map_fields(
            field_map, inspection_results, photo_task_bindings,
        )

    # ================================================================
    # 動態模板建立
    # ================================================================

    async def create_template_from_file(
        self,
        file_content: bytes,
        file_name: str,
        template_name: str,
        category: str = "一般設備",
        company: str = "",
        department: str = "",
    ) -> dict:
        """從真實廠商 Excel/Word 表單自動建立 InspectionTemplate JSON"""
        result = await self._analysis_service.create_template_from_file(
            file_content=file_content,
            file_name=file_name,
            template_name=template_name,
            category=category,
            company=company,
            department=department,
        )

        # 在記憶體中保存原始文件（供日後回填）
        template_id = result.get("template_id", "")
        template_json = result.get("template", {})
        self._templates[template_id] = {
            "id": template_id,
            "name": template_name,
            "vendor_name": company,
            "file_type": result.get("file_type", ""),
            "file_content": file_content,
            "field_map": result.get("field_map", []),
            "inspection_template": template_json,
            "created_at": datetime.now().isoformat(),
        }

        return {
            "success": result.get("success", True),
            "template_id": template_id,
            "template": template_json,
            "field_count": result.get("field_count", 0),
            "section_count": result.get("section_count", 0),
            "message": result.get("message", ""),
        }

    # ================================================================
    # 模板分析
    # ================================================================

    async def analyze_template(
        self,
        file_content: bytes,
        file_name: str,
        vendor_name: str,
        template_name: str,
        description: Optional[str] = None
    ) -> dict:
        """使用 AI 分析模板結構"""
        result = await self._analysis_service.analyze_template(
            file_content, file_name, vendor_name, template_name, description,
        )

        # 儲存模板到記憶體
        template = result.pop("_template", None)
        if template:
            self._templates[result["template_id"]] = template

        return result

    # ================================================================
    # 深度結構分析
    # ================================================================

    async def analyze_structure(
        self,
        file_content: bytes,
        file_name: str,
    ) -> dict:
        """深度分析表格結構，回傳完整的欄位位置地圖"""
        return await self._analysis_service.analyze_structure(file_content, file_name)

    # ================================================================
    # AI 欄位映射
    # ================================================================

    async def ai_map_fields(
        self,
        field_map: list[dict],
        inspection_results: list[dict],
    ) -> dict:
        """使用 AI 將欄位地圖與檢查結果進行智慧映射"""
        return await self._analysis_service.ai_map_fields(field_map, inspection_results)

    async def save_field_mappings(
        self,
        template_id: str,
        mappings: dict[str, str]
    ):
        """儲存欄位對應設定"""
        if template_id not in self._templates:
            raise ValueError(f"Template not found: {template_id}")

        template = self._templates[template_id]
        await self._analysis_service.save_field_mappings(template, mappings)

    # ================================================================
    # 自動回填引擎
    # ================================================================

    async def auto_fill(
        self,
        file_content: bytes,
        file_name: str,
        field_map: list[dict],
        fill_values: list[dict],
    ) -> bytes:
        """執行自動回填：將值寫入原始文件的指定位置"""
        return await self._auto_fill_service.auto_fill(
            file_content, file_name, field_map, fill_values,
        )

    # ================================================================
    # 預覽回填
    # ================================================================

    async def preview_fill(
        self,
        template_id: str,
        inspection_data: dict
    ) -> dict:
        """預覽填入結果（舊版 API 相容）"""
        template = self._templates.get(template_id)
        if not template:
            raise ValueError(f"Template not found: {template_id}")
        return await self._auto_fill_service.preview_fill(template, inspection_data)

    async def preview_auto_fill(
        self,
        field_map: list[dict],
        fill_values: list[dict],
    ) -> dict:
        """預覽自動回填結果（新版 API）"""
        return await self._auto_fill_service.preview_auto_fill(field_map, fill_values)

    # ================================================================
    # 報告生成（舊版 API 相容）
    # ================================================================

    async def generate_report(
        self,
        report_id: str,
        template_id: str,
        inspection_data: dict,
        output_format: str = "xlsx"
    ):
        """產生報告"""
        template = self._templates.get(template_id)
        if not template:
            raise ValueError(f"Template not found: {template_id}")

        try:
            output_path = await self._auto_fill_service.generate_report(
                report_id, template, inspection_data, output_format,
            )

            # 更新報告狀態
            self._templates[f"_report_{report_id}"] = {
                "id": report_id,
                "status": "completed",
                "template_id": template_id,
                "output_path": output_path,
                "created_at": datetime.now().isoformat(),
            }

        except Exception as e:
            logger.error(f"Generate report failed: {e}")
            self._templates[f"_report_{report_id}"] = {
                "id": report_id,
                "status": "failed",
                "error": str(e),
            }
            raise

    async def get_report_status(self, report_id: str) -> Optional[dict]:
        """取得報告狀態"""
        report = self._templates.get(f"_report_{report_id}")
        if not report:
            return None

        return {
            "success": report["status"] == "completed",
            "report_id": report_id,
            "status": report["status"],
            "message": "報告已完成" if report["status"] == "completed" else report.get("error", "處理中"),
            "download_url": f"/api/reports/{report_id}/download" if report["status"] == "completed" else None,
        }

    async def get_report_file(self, report_id: str) -> Optional[str]:
        """取得報告檔案路徑"""
        report = self._templates.get(f"_report_{report_id}")
        if report and report.get("status") == "completed":
            return report.get("output_path")
        return None

    # ================================================================
    # 照片自動插入報告 — 委派給 PhotoProcessingService
    # ================================================================

    async def insert_photos_into_report(
        self,
        file_content: bytes,
        file_name: str,
        photo_bindings: list[dict],
    ) -> bytes:
        """將照片自動插入到 Excel/Word 報告中"""
        return await self._photo_service.insert_photos_into_report(
            file_content, file_name, photo_bindings,
        )

    def _prepare_photo_for_insert(self, binding: dict):
        """準備照片（委派給 PhotoProcessingService）"""
        return self._photo_service._prepare_photo_for_insert(binding)

    # ================================================================
    # 自動判定 — 委派給 JudgmentService
    # ================================================================

    async def auto_judge(
        self,
        field_name: str,
        measured_value,
        unit: str = "",
        equipment_type: str = "",
    ) -> dict:
        """自動判定量測值是否合格"""
        return await self._judgment_service.auto_judge(
            field_name=field_name,
            measured_value=measured_value,
            unit=unit,
            equipment_type=equipment_type,
        )

    async def batch_auto_judge(
        self,
        readings: list[dict],
        equipment_type: str = "",
    ) -> list[dict]:
        """批次判定多筆量測值"""
        return await self._judgment_service.batch_auto_judge(
            readings=readings,
            equipment_type=equipment_type,
        )

    # ================================================================
    # 批次設備處理 — 委派給 JudgmentService
    # ================================================================

    async def batch_process(
        self,
        equipment_list: list[dict],
        field_map: list[dict],
    ) -> dict:
        """批次處理多台設備的定檢"""
        return await self._judgment_service.batch_process(
            equipment_list=equipment_list,
            field_map=field_map,
        )

    # ================================================================
    # 向後相容：委派私有方法供既有測試呼叫
    # ================================================================

    def _guess_unit(self, name: str) -> str:
        return self._photo_task_service._guess_unit(name)

    def _is_field_label(self, text: str) -> bool:
        return is_field_label(text)

    def _is_placeholder(self, text: str) -> bool:
        return is_placeholder(text)

    def _guess_field_type(self, field_name: str) -> str:
        return guess_field_type(field_name)

    def _convert_value(self, value, field_type: str = "text"):
        return convert_value(value, field_type)
