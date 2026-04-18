"""
欄位偵測與型別推測 — 通用表單處理工具函數

所有函數均為純函數，不依賴任何 domain 知識。
預設的 `DEFAULT_FIELD_KEYWORDS` 僅包含最普遍的中文表單標籤關鍵字；
如需 domain 專屬關鍵字，由呼叫端傳入 `keywords` 參數或覆寫預設集。
"""

import re
from typing import Iterable, Optional


# 通用欄位關鍵字（不含工業專屬詞彙）
DEFAULT_FIELD_KEYWORDS: tuple[str, ...] = (
    ':', '：',
    '日期', '姓名', '編號', '名稱', '備註', '地點', '位置',
    '時間', '人員', '部門', '單位', '公司',
    '狀態', '結果', '說明', '描述',
)


def is_field_label(
    text: str,
    keywords: Optional[Iterable[str]] = None,
) -> bool:
    """判斷文字是否為欄位標籤。

    Args:
        text: 欲檢查的文字。
        keywords: 自訂關鍵字集；若為 None 則使用 DEFAULT_FIELD_KEYWORDS。
    """
    text = text.strip()
    if not text or len(text) > 50:
        return False
    kw = keywords if keywords is not None else DEFAULT_FIELD_KEYWORDS
    return any(k in text for k in kw)


def is_placeholder(text: str) -> bool:
    """判斷文字是否為佔位符（空白、底線、{{...}}、<...>、[...]、///）"""
    text = text.strip()
    if not text:
        return True
    placeholder_patterns = [
        r'^[_＿]{2,}$',
        r'^\{\{.*\}\}$',
        r'^<.*>$',
        r'^\[.*\]$',
        r'^/{2,}$',
        r'^\s+$',
    ]
    return any(re.match(p, text) for p in placeholder_patterns)


# 型別推測關鍵字表（通用；domain 可擴充）
_NUMBER_HINTS = (
    '數量', '數值', 'number', '金額', '溫度', '壓力',
    '電流', '電壓', '轉速', '流量', '讀數', '頻率',
    '振動', '噪音', '油位', '水位', '濕度',
)
_DATE_HINTS = ('日期', 'date', '時間', 'time')
_CHECKBOX_HINTS = ('是否', '確認', 'check', '合格', '判定', '正常', '異常')


def guess_field_type(field_name: str) -> str:
    """根據欄位名稱猜測型別：date / number / checkbox / text"""
    name_lower = field_name.lower()
    if any(kw in name_lower for kw in _DATE_HINTS):
        return 'date'
    if any(kw in name_lower for kw in _NUMBER_HINTS):
        return 'number'
    if any(kw in name_lower for kw in _CHECKBOX_HINTS):
        return 'checkbox'
    return 'text'


def convert_value(value, field_type: str):
    """根據欄位類型轉換值。

    - number: 嘗試轉 int/float，失敗則回退為 str
    - checkbox: 統一輸出為 '合格' / '不合格' / 原字串
    - date / text: 轉為 str
    """
    if value is None:
        return None

    if field_type == 'number':
        try:
            if '.' in str(value):
                return float(value)
            return int(value)
        except (ValueError, TypeError):
            return str(value)

    if field_type == 'checkbox':
        v = str(value).strip().lower()
        if v in ['true', '1', '是', '合格', '正常', 'yes', 'ok', '通過']:
            return '合格'
        if v in ['false', '0', '否', '不合格', '異常', 'no', 'ng', '不通過']:
            return '不合格'
        return str(value)

    return str(value)


def is_section_header(text: str) -> bool:
    """判斷是否為區段標題（中文編號、表格表頭等）"""
    text = text.strip()
    if re.match(r'^[一二三四五六七八九十]+[、．.]', text):
        return True
    if re.match(r'^[（(][一二三四五六七八九十]+[）)]', text):
        return True
    header_patterns = [
        '項次', '檢查項目', '檢查標準', '檢查要點',
        '量測項目', '量測位置', '判定', '備註/異常說明', '備註',
    ]
    return text in header_patterns


def is_non_field_item(text: str) -> bool:
    """判斷文字不應作為可填寫欄位（標題、注意事項、簽核區等）"""
    text = text.strip()
    if len(text) > 30 or len(text) < 2:
        return True
    if is_section_header(text):
        return True
    non_field_patterns = [
        r'^注意事項',
        r'^簽核$',
        r'^\d+\.\s',
        r'^□',
    ]
    return any(re.match(p, text) for p in non_field_patterns)


def replace_paragraph_text_preserve_format(paragraph, new_text: str) -> None:
    """替換 python-docx 段落文字但保留第一個 run 的格式。"""
    if not paragraph.runs:
        paragraph.text = new_text
        return

    first_run = paragraph.runs[0]
    for run in paragraph.runs:
        run.text = ""
    first_run.text = new_text
