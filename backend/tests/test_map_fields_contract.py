"""`/map-fields` 的契約守門。

這批測試存在的原因是一個已出貨的斷裂：App 的核心 5 步驟流程送的是
`{field_label, value, ai_result}`，而 `InspectionResult` 一個都沒宣告——
pydantic 預設 `extra='ignore'`，於是**整包檢測資料被靜默丟掉**，
prompt 裡剩下一串空記錄，AI 憑欄位名臆造值，端點還回報 success=true。

守三件事：①App 實際送的資料要進得了 prompt；②全空的輸入不准去問 AI；
③沒宣告的欄位要當場被擋下來，不是默默吃掉。
"""

import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
os.environ.setdefault("GEMINI_API_KEY", "test-key-for-unit-tests")

from app.api.auto_fill import InspectionResult  # noqa: E402
from app.services.form_analysis_service import FormAnalysisService  # noqa: E402


FIELD_MAP = [
    {"field_id": "f1", "field_name": "軸承溫度", "field_type": "number"},
    {"field_id": "f2", "field_name": "檢查日期", "field_type": "date"},
]

# App 的核心流程實際送出的形狀（form_inspection_screen.dart `_autoFillOriginalForm`）
APP_PAYLOAD = [
    {
        "field_label": "軸承溫度",
        "value": 68.0,
        "ai_result": {
            "equipment_type": "感應電動機",
            "condition_assessment": "運轉正常",
            "is_anomaly": False,
            "readings": {"軸承溫度": {"value": 68.0, "unit": "°C"}},
        },
    }
]


@pytest.fixture
def captured_prompt(monkeypatch):
    """攔下送進 Gemini 的 prompt，不真的打 API。"""
    seen = {}

    def fake_generate_text(prompt, **kwargs):
        seen["prompt"] = prompt
        return '[{"field_id": "f1", "suggested_value": "68", "source": "軸承溫度", "confidence": 0.9}]'

    monkeypatch.setattr(
        "app.services.form_analysis_service.gemini_client.generate_text",
        fake_generate_text,
    )
    return seen


class TestAppPayloadReachesTheModel:
    @pytest.mark.asyncio
    async def test_declared_fields_accept_the_apps_shape(self):
        """App 送的三個欄位必須是宣告過的，不然 model_dump 之後就沒了。"""
        parsed = InspectionResult(**APP_PAYLOAD[0]).model_dump()
        assert parsed["field_label"] == "軸承溫度"
        assert parsed["value"] == 68.0
        assert parsed["ai_result"]["readings"]["軸承溫度"]["value"] == 68.0

    @pytest.mark.asyncio
    async def test_the_measured_value_appears_in_the_prompt(self, captured_prompt):
        """真正要守的：量到的值要出現在 prompt 裡。

        修好之前這裡會紅——prompt 裡只有一串 None，AI 只能憑欄位名編。
        """
        service = FormAnalysisService()
        results = [InspectionResult(**r).model_dump() for r in APP_PAYLOAD]
        await service.ai_map_fields(field_map=FIELD_MAP, inspection_results=results)

        prompt = captured_prompt["prompt"]
        assert "68" in prompt, "量測值沒進 prompt，AI 只能臆造"
        assert "軸承溫度" in prompt
        assert "°C" in prompt, "單位沒進 prompt，AI 無從判斷量綱"

    @pytest.mark.asyncio
    async def test_legacy_shape_still_works(self, captured_prompt):
        """舊的 equipment_name/extracted_values 形狀不能被改壞。"""
        service = FormAnalysisService()
        legacy = [
            InspectionResult(
                equipment_name="1號泵浦",
                condition_assessment="正常",
                extracted_values={"軸承溫度": 68.0},
            ).model_dump()
        ]
        await service.ai_map_fields(field_map=FIELD_MAP, inspection_results=legacy)
        prompt = captured_prompt["prompt"]
        assert "1號泵浦" in prompt
        assert "68" in prompt


class TestEmptyInputIsRefused:
    @pytest.mark.asyncio
    async def test_all_empty_results_do_not_reach_the_model(self, monkeypatch):
        """全空的輸入不准去問 AI——問了就是請它編。"""
        called = {"n": 0}

        def fake(prompt, **kwargs):
            called["n"] += 1
            return "[]"

        monkeypatch.setattr(
            "app.services.form_analysis_service.gemini_client.generate_text", fake
        )

        service = FormAnalysisService()
        empty = [InspectionResult().model_dump(), InspectionResult().model_dump()]
        result = await service.ai_map_fields(
            field_map=FIELD_MAP, inspection_results=empty
        )

        assert called["n"] == 0, "空輸入不該送進 AI"
        assert result["success"] is False
        assert "沒有可用" in result.get("error", "") or "empty" in result.get("error", "").lower()

    @pytest.mark.asyncio
    async def test_no_results_at_all_is_refused(self, monkeypatch):
        called = {"n": 0}
        monkeypatch.setattr(
            "app.services.form_analysis_service.gemini_client.generate_text",
            lambda prompt, **kw: called.__setitem__("n", called["n"] + 1) or "[]",
        )
        service = FormAnalysisService()
        result = await service.ai_map_fields(field_map=FIELD_MAP, inspection_results=[])
        assert called["n"] == 0
        assert result["success"] is False


class TestUnknownFieldsAreRejected:
    def test_a_field_nobody_declared_is_an_error_not_a_silent_drop(self):
        """下一次契約漂開時要當場紅，不要又靜默丟掉三年。"""
        from pydantic import ValidationError

        with pytest.raises(ValidationError):
            InspectionResult(field_labl="打錯字的欄位名", value=1)
