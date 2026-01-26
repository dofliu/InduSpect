"""
表單填入服務 - AI 模板分析與報告生成
"""

import logging
import uuid
import io
from typing import Optional
from datetime import datetime

import google.generativeai as genai
from openpyxl import load_workbook
from docx import Document

from app.config import settings

logger = logging.getLogger(__name__)


class FormFillService:
    """表單自動填入服務"""
    
    def __init__(self):
        genai.configure(api_key=settings.gemini_api_key)
        
        # TODO: 正式環境改用資料庫
        self._templates: dict[str, dict] = {}
        self._reports: dict[str, dict] = {}
    
    async def list_templates(self) -> list[dict]:
        """列出所有模板"""
        return list(self._templates.values())
    
    async def get_template(self, template_id: str) -> Optional[dict]:
        """取得單一模板"""
        return self._templates.get(template_id)
    
    async def analyze_template(
        self,
        file_content: bytes,
        file_name: str,
        vendor_name: str,
        template_name: str,
        description: Optional[str] = None
    ) -> dict:
        """
        使用 AI 分析模板結構
        
        自動識別欄位並建議與巡檢資料的對應關係
        """
        template_id = str(uuid.uuid4())
        file_type = file_name.split('.')[-1].lower()
        
        # 解析模板內容
        if file_type == 'xlsx':
            fields, raw_structure = await self._parse_excel_template(file_content)
        elif file_type == 'docx':
            fields, raw_structure = await self._parse_word_template(file_content)
        else:
            raise ValueError(f"Unsupported file type: {file_type}")
        
        # 使用 AI 建議欄位對應
        suggested_mappings = await self._ai_suggest_mappings(fields, raw_structure)
        
        # 儲存模板
        template = {
            "id": template_id,
            "name": template_name,
            "vendor_name": vendor_name,
            "file_type": file_type,
            "description": description,
            "fields": fields,
            "file_content": file_content,  # 保存原始檔案
            "created_at": datetime.now().isoformat(),
        }
        self._templates[template_id] = template
        
        return {
            "success": True,
            "template_id": template_id,
            "detected_fields": fields,
            "suggested_mappings": suggested_mappings,
            "message": f"成功分析模板，識別到 {len(fields)} 個欄位"
        }
    
    async def _parse_excel_template(self, content: bytes) -> tuple[list[dict], str]:
        """解析 Excel 模板"""
        fields = []
        structure_lines = []
        
        wb = load_workbook(io.BytesIO(content))
        ws = wb.active
        
        for row_idx, row in enumerate(ws.iter_rows(max_row=50), 1):
            for cell in row:
                if cell.value:
                    # 檢測可能的欄位標籤
                    value = str(cell.value).strip()
                    structure_lines.append(f"{cell.coordinate}: {value}")
                    
                    # 簡單規則：包含冒號或特定關鍵字的可能是欄位標籤
                    if any(kw in value for kw in [':', '：', '日期', '姓名', '編號', '設備', '檢查', '備註']):
                        fields.append({
                            "field_id": f"field_{cell.coordinate}",
                            "field_name": value.rstrip(':：'),
                            "field_type": self._guess_field_type(value),
                            "location": cell.coordinate,
                            "mapping": None,
                        })
        
        return fields, "\n".join(structure_lines[:100])
    
    async def _parse_word_template(self, content: bytes) -> tuple[list[dict], str]:
        """解析 Word 模板"""
        fields = []
        structure_lines = []
        
        doc = Document(io.BytesIO(content))
        
        for para_idx, para in enumerate(doc.paragraphs):
            text = para.text.strip()
            if text:
                structure_lines.append(f"Para {para_idx}: {text}")
                
                # 檢測可能的欄位
                if any(kw in text for kw in [':', '：', '____', '＿＿']):
                    fields.append({
                        "field_id": f"field_para_{para_idx}",
                        "field_name": text.split(':')[0].split('：')[0].strip(),
                        "field_type": "text",
                        "location": f"paragraph_{para_idx}",
                        "mapping": None,
                    })
        
        # 也檢查表格
        for table_idx, table in enumerate(doc.tables):
            for row_idx, row in enumerate(table.rows):
                for cell_idx, cell in enumerate(row.cells):
                    text = cell.text.strip()
                    if text:
                        loc = f"table_{table_idx}_r{row_idx}_c{cell_idx}"
                        structure_lines.append(f"{loc}: {text}")
        
        return fields, "\n".join(structure_lines[:100])
    
    def _guess_field_type(self, field_name: str) -> str:
        """猜測欄位類型"""
        name_lower = field_name.lower()
        
        if any(kw in name_lower for kw in ['日期', 'date', '時間', 'time']):
            return 'date'
        elif any(kw in name_lower for kw in ['數量', '數值', 'number', '金額', '溫度', '壓力']):
            return 'number'
        elif any(kw in name_lower for kw in ['是否', '確認', 'check']):
            return 'checkbox'
        else:
            return 'text'
    
    async def _ai_suggest_mappings(
        self, 
        fields: list[dict], 
        raw_structure: str
    ) -> dict[str, str]:
        """使用 AI 建議欄位對應"""
        
        # 定義巡檢資料可用欄位
        inspection_fields = [
            "equipment_name",
            "equipment_type", 
            "inspection_date",
            "inspector_name",
            "location",
            "condition_assessment",
            "anomaly_description",
            "notes",
        ]
        
        try:
            model = genai.GenerativeModel('gemini-2.0-flash')
            
            fields_text = "\n".join([
                f"- {f['field_id']}: {f['field_name']} ({f['field_type']})"
                for f in fields
            ])
            
            prompt = f"""
你是一位表單分析專家。請分析以下廠商報告模板的欄位，並建議對應到巡檢資料的欄位。

【模板欄位】
{fields_text}

【巡檢資料可用欄位】
- equipment_name: 設備名稱
- equipment_type: 設備類型
- inspection_date: 巡檢日期
- inspector_name: 巡檢人員
- location: 位置
- condition_assessment: 狀況評估
- anomaly_description: 異常描述
- notes: 備註

請以 JSON 格式回應，格式如下：
{{"field_id": "對應的巡檢欄位", ...}}

只回應 JSON，不要其他文字。無法對應的欄位請填 null。
"""
            
            response = model.generate_content(prompt)
            
            # 嘗試解析 JSON
            import json
            import re
            
            # 提取 JSON 部分
            json_match = re.search(r'\{[^{}]+\}', response.text, re.DOTALL)
            if json_match:
                mappings = json.loads(json_match.group())
                return {k: v for k, v in mappings.items() if v}
            
        except Exception as e:
            logger.error(f"AI suggest mappings failed: {e}")
        
        return {}
    
    async def save_field_mappings(
        self, 
        template_id: str, 
        mappings: dict[str, str]
    ):
        """儲存欄位對應設定"""
        if template_id not in self._templates:
            raise ValueError(f"Template not found: {template_id}")
        
        template = self._templates[template_id]
        for field in template["fields"]:
            if field["field_id"] in mappings:
                field["mapping"] = mappings[field["field_id"]]
    
    async def preview_fill(
        self, 
        template_id: str, 
        inspection_data: dict
    ) -> dict:
        """預覽填入結果"""
        template = self._templates.get(template_id)
        if not template:
            raise ValueError(f"Template not found: {template_id}")
        
        field_values = {}
        warnings = []
        
        for field in template["fields"]:
            mapping = field.get("mapping")
            if mapping and mapping in inspection_data:
                value = inspection_data[mapping]
                if isinstance(value, dict):
                    value = str(value)
                field_values[field["field_name"]] = str(value) if value else ""
            else:
                field_values[field["field_name"]] = ""
                if mapping:
                    warnings.append(f"欄位 '{field['field_name']}' 對應的資料不存在")
        
        return {
            "template_name": template["name"],
            "vendor_name": template["vendor_name"],
            "field_values": field_values,
            "warnings": warnings,
        }
    
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
            # 根據模板類型處理
            if template["file_type"] == "xlsx":
                output_path = await self._fill_excel(template, inspection_data, report_id)
            elif template["file_type"] == "docx":
                output_path = await self._fill_word(template, inspection_data, report_id)
            else:
                raise ValueError(f"Unsupported template type: {template['file_type']}")
            
            # 更新報告狀態
            self._reports[report_id] = {
                "id": report_id,
                "status": "completed",
                "template_id": template_id,
                "output_path": output_path,
                "created_at": datetime.now().isoformat(),
            }
            
        except Exception as e:
            logger.error(f"Generate report failed: {e}")
            self._reports[report_id] = {
                "id": report_id,
                "status": "failed",
                "error": str(e),
            }
            raise
    
    async def _fill_excel(
        self, 
        template: dict, 
        inspection_data: dict,
        report_id: str
    ) -> str:
        """填入 Excel 模板"""
        wb = load_workbook(io.BytesIO(template["file_content"]))
        ws = wb.active
        
        for field in template["fields"]:
            mapping = field.get("mapping")
            if mapping and mapping in inspection_data:
                value = inspection_data[mapping]
                
                # 找到要填入的儲存格 (欄位位置的右邊或下方)
                location = field["location"]
                # 簡化：假設填入同一儲存格
                # 實際應用需要更複雜的邏輯
                ws[location] = value
        
        # 儲存
        output_path = f"/tmp/report_{report_id}.xlsx"
        wb.save(output_path)
        
        return output_path
    
    async def _fill_word(
        self, 
        template: dict, 
        inspection_data: dict,
        report_id: str
    ) -> str:
        """填入 Word 模板"""
        doc = Document(io.BytesIO(template["file_content"]))
        
        # 替換文字中的佔位符
        for para in doc.paragraphs:
            for field in template["fields"]:
                mapping = field.get("mapping")
                if mapping and mapping in inspection_data:
                    value = str(inspection_data[mapping] or "")
                    # 替換格式: {{field_name}}
                    placeholder = f"{{{{{field['field_name']}}}}}"
                    if placeholder in para.text:
                        para.text = para.text.replace(placeholder, value)
        
        output_path = f"/tmp/report_{report_id}.docx"
        doc.save(output_path)
        
        return output_path
    
    async def get_report_status(self, report_id: str) -> Optional[dict]:
        """取得報告狀態"""
        report = self._reports.get(report_id)
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
        report = self._reports.get(report_id)
        if report and report.get("status") == "completed":
            return report.get("output_path")
        return None
    
    async def delete_template(self, template_id: str):
        """刪除模板"""
        if template_id in self._templates:
            del self._templates[template_id]
