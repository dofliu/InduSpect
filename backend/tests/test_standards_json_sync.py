"""
法規標準 JSON 同步守門測試（Tier 0 單一資料來源機制）

inspection_standards.py 是編輯來源；
flutter_app/assets/standards/inspection_standards.json 是內嵌到 App 的發布產物
（由 scripts/export_standards.py 產生，供 Dart 離線判定引擎使用）。

本測試確保兩者一致：修改 Python 標準後若忘記重新匯出 JSON，CI 會在此擋下，
避免 App 端與後端用到不同版本的法規標準（判定漂移 = 稽核風險）。
"""

import json
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.data.inspection_standards import ALL_STANDARDS  # noqa: E402

JSON_PATH = (
    Path(__file__).resolve().parents[2]
    / "flutter_app"
    / "assets"
    / "standards"
    / "inspection_standards.json"
)


def _load_payload() -> dict:
    assert JSON_PATH.exists(), (
        f"找不到 {JSON_PATH} — 請執行 `python scripts/export_standards.py` 重新匯出"
    )
    return json.loads(JSON_PATH.read_text(encoding="utf-8"))


def test_json_exists_and_has_version():
    payload = _load_payload()
    assert payload.get("version"), "JSON 必須帶版本欄位"
    assert payload.get("total") == len(ALL_STANDARDS)


def test_json_standards_match_python_source():
    """JSON standards 內容必須與 Python 來源完全一致（經 JSON round-trip 正規化後比較）。"""
    payload = _load_payload()
    # Python 來源先過一次 JSON round-trip，消除 tuple/list 等表示差異
    normalized_source = json.loads(json.dumps(ALL_STANDARDS, ensure_ascii=False))
    assert payload["standards"] == normalized_source, (
        "JSON 與 inspection_standards.py 不同步 — "
        "請執行 `python scripts/export_standards.py` 重新匯出"
    )


def test_json_category_counts():
    payload = _load_payload()
    counts: dict = {}
    for s in payload["standards"]:
        counts[s["category"]] = counts.get(s["category"], 0) + 1
    assert counts == payload["categories"]
