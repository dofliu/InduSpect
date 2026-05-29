"""
judge-readings 端點合約測試

行動 App「自動 AI 定檢」在批次 AI 分析後，會呼叫
POST /api/auto-fill/judge-readings 取得法規標準判定。
本測試以 FastAPI TestClient 鎖定該端點的回傳合約，
確保 Flutter 端 BackendApiService.judgeReadings() 串接的欄位不被破壞：

- success / judgments / warnings / summary 四個頂層鍵
- judgments 與輸入 readings「同序」且筆數一致（Flutter 以索引回填）
- pass / fail / warning / unknown 分類正確
- summary 各計數正確
- 單位換算（kΩ → MΩ）會在 converted_value / converted_unit 透明顯示
"""

import os
import sys

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ.setdefault("GEMINI_API_KEY", "test-key")

from app.api.auto_fill import router  # noqa: E402


@pytest.fixture(scope="module")
def client():
    app = FastAPI()
    app.include_router(router, prefix="/api/auto-fill")
    return TestClient(app)


def _post(client, readings, equipment_type=""):
    resp = client.post(
        "/api/auto-fill/judge-readings",
        json={"readings": readings, "equipment_type": equipment_type},
    )
    assert resp.status_code == 200, resp.text
    return resp.json()


def test_top_level_contract(client):
    data = _post(client, [{"field_name": "絕緣電阻", "value": 52.3, "unit": "MΩ"}], "電氣")
    assert set(data.keys()) == {"success", "judgments", "warnings", "summary"}
    assert data["success"] is True
    assert isinstance(data["judgments"], list)
    assert isinstance(data["warnings"], list)
    assert isinstance(data["summary"], dict)


def test_judgment_item_fields(client):
    data = _post(client, [{"field_name": "絕緣電阻", "value": 52.3, "unit": "MΩ"}], "電氣")
    j = data["judgments"][0]
    for key in (
        "field_name",
        "measured_value",
        "unit",
        "judgment",
        "standard_text",
        "regulation",
        "converted_value",
        "converted_unit",
    ):
        assert key in j, f"缺少欄位 {key}"


def test_order_preserved_and_classification(client):
    readings = [
        {"field_name": "絕緣電阻 R相", "value": 52.3, "unit": "MΩ"},   # pass
        {"field_name": "絕緣電阻 S相", "value": 0.5, "unit": "MΩ"},    # fail
        {"field_name": "某不存在的項目", "value": 3.14, "unit": "X"},   # unknown
    ]
    data = _post(client, readings, "電氣")
    judgments = data["judgments"]

    # 同序 + 同筆數（Flutter 以索引回填，順序必須一致）
    assert len(judgments) == len(readings)
    assert [j["field_name"] for j in judgments] == [r["field_name"] for r in readings]

    assert judgments[0]["judgment"] == "pass"
    assert judgments[1]["judgment"] == "fail"
    assert judgments[2]["judgment"] == "unknown"


def test_summary_counts(client):
    readings = [
        {"field_name": "絕緣電阻 R相", "value": 52.3, "unit": "MΩ"},
        {"field_name": "絕緣電阻 S相", "value": 0.5, "unit": "MΩ"},
        {"field_name": "某不存在的項目", "value": 3.14, "unit": "X"},
    ]
    data = _post(client, readings, "電氣")
    s = data["summary"]
    assert s["total_readings"] == 3
    assert s["pass_count"] == 1
    assert s["fail_count"] == 1
    assert s["unknown_count"] == 1


def test_warnings_populated_for_fail(client):
    data = _post(
        client,
        [{"field_name": "絕緣電阻 S相", "value": 0.5, "unit": "MΩ"}],
        "電氣",
    )
    assert data["summary"]["fail_count"] == 1
    assert any("不合格" in w for w in data["warnings"])


def test_unit_conversion_surfaced(client):
    """500 kΩ = 0.5 MΩ，應判不合格且帶出換算值（避免單位數量級誤判）。"""
    data = _post(
        client,
        [{"field_name": "絕緣電阻", "value": 500, "unit": "kΩ"}],
        "電氣",
    )
    j = data["judgments"][0]
    assert j["judgment"] == "fail"
    assert j["converted_unit"] == "MΩ"
    assert j["converted_value"] == pytest.approx(0.5, rel=1e-6)


def test_empty_readings(client):
    data = _post(client, [], "電氣")
    assert data["success"] is True
    assert data["judgments"] == []
    assert data["summary"]["total_readings"] == 0
