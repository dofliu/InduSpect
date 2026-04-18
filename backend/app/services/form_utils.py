"""
表單處理共用工具函數 — 向後相容層

實作已搬移至 `app.autofill_core.field_detection`（通用、與 domain 解耦）。
本模組僅重新匯出，並保留工業巡檢專屬的 `is_field_label` 行為（使用
`app.constants.FIELD_KEYWORDS` 作為預設關鍵字）。
"""

from app.constants import FIELD_KEYWORDS
from app.autofill_core.field_detection import (
    is_placeholder,
    is_section_header,
    is_non_field_item,
    guess_field_type,
    convert_value,
    replace_paragraph_text_preserve_format,
)
from app.autofill_core.field_detection import is_field_label as _is_field_label_generic


def is_field_label(text: str) -> bool:
    """判斷文字是否為欄位標籤（套用工業巡檢專屬關鍵字集）"""
    return _is_field_label_generic(text, keywords=FIELD_KEYWORDS)


__all__ = [
    "is_field_label",
    "is_placeholder",
    "is_section_header",
    "is_non_field_item",
    "guess_field_type",
    "convert_value",
    "replace_paragraph_text_preserve_format",
]
