"""
autofill_core — 通用表單自動回填核心模組

此套件與工業巡檢 domain 完全解耦，可獨立用於任何 Excel/Word 表單自動回填情境
（例如公文表格、辦公文件輔助）。

## 模組邊界（IMPORTANT）

此套件**不得**引用：
- `app.data.inspection_standards`（工業法規標準庫）
- `app.services.judgment_service`（合格/不合格判定）
- `app.constants.INSPECTION_FIELDS`（巡檢專屬欄位）
- 任何 `app.models.*` 中的巡檢資料結構

允許依賴：openpyxl、python-docx、google.generativeai（AI 映射為 optional）、
以及本套件內的模組。

## 組成

| 模組 | 職責 |
|------|------|
| `field_detection` | 欄位標籤、佔位符、型別偵測、值轉換 |
| `excel_engine` | Excel 讀寫、合併儲存格處理、格式保留 |
| `word_engine` | Word 段落/表格讀寫、格式保留 |
| `structure_analyzer` | Excel/Word 結構深度分析 → field_map |
| `ai_mapper` | 將任意 source_records 映射到 field_map（通用） |

## 資料格式

### field_map
```python
[{
    "field_id": str,
    "field_name": str,
    "field_type": "text" | "number" | "date" | "checkbox",
    "label_location": {...},   # 標籤位置
    "value_location": {...},   # 值位置（供回填用）
}, ...]
```

### fill_values
```python
[{"field_id": str, "value": Any, "confidence": float, "source": str}, ...]
```
"""

from app.autofill_core.field_detection import (
    is_field_label,
    is_placeholder,
    is_section_header,
    is_non_field_item,
    guess_field_type,
    convert_value,
    replace_paragraph_text_preserve_format,
    DEFAULT_FIELD_KEYWORDS,
)
from app.autofill_core.excel_engine import ExcelAutoFillEngine
from app.autofill_core.word_engine import WordAutoFillEngine
from app.autofill_core.structure_analyzer import StructureAnalyzer

__all__ = [
    "is_field_label",
    "is_placeholder",
    "is_section_header",
    "is_non_field_item",
    "guess_field_type",
    "convert_value",
    "replace_paragraph_text_preserve_format",
    "DEFAULT_FIELD_KEYWORDS",
    "ExcelAutoFillEngine",
    "WordAutoFillEngine",
    "StructureAnalyzer",
]
