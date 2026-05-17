"""
JudgmentService 直接單元測試（weekly routine — 2026-05-16）

既有 test_sprint3_standards.py 透過 FormFillService 間接測試了 auto_judge，
但 JudgmentService 本身（拆分後的純規則類）沒有直接的 pytest 覆蓋。本檔補上：

涵蓋面：
- 各 pass_condition 類型：gte / lte / range
- 多類別：electrical / fire / mechanical / pressure
- 邊界情境：unknown field、空 readings、無單位
- batch_auto_judge：混合 pass/fail/unknown、順序、空清單
- 回傳 dict 結構：必須欄位齊全且型別正確

所有 async test 透過 CI 的 --asyncio-mode=auto 跑（無需 @pytest.mark.asyncio 裝飾）。
"""

import sys
import os

if sys.platform == "win32":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ.setdefault("GEMINI_API_KEY", "test-key")

import pytest

from app.services.judgment_service import JudgmentService


# 共用必含欄位（auto_judge 回傳 dict 的 contract）
REQUIRED_FIELDS = {
    "field_name",
    "measured_value",
    "unit",
    "judgment",
    "standard_text",
    "regulation",
    "confidence",
    "standard_id",
}


# ============================================================
# auto_judge: gte（越大越好）— 電氣絕緣電阻
# ============================================================


async def test_auto_judge_electrical_insulation_pass():
    """絕緣電阻 52.3 MΩ ≥ 1.0 MΩ → pass，且高信心度"""
    svc = JudgmentService()
    r = await svc.auto_judge("絕緣電阻 R相", 52.3, "MΩ")

    assert r["judgment"] == "pass"
    assert r["confidence"] >= 0.9
    assert r["standard_id"] == "elec_insulation_lv"
    assert r["regulation"]  # 非空字串


async def test_auto_judge_returns_required_fields():
    """回傳 dict 必含全部 contract 欄位"""
    svc = JudgmentService()
    r = await svc.auto_judge("絕緣電阻", 10.0, "MΩ")

    missing = REQUIRED_FIELDS - set(r.keys())
    assert not missing, f"缺少欄位: {missing}"


# ============================================================
# auto_judge: lte（越小越好）— 電氣接地電阻
# ============================================================


async def test_auto_judge_ground_resistance_fail():
    """接地電阻 120 Ω > 100 Ω 上限 → fail"""
    svc = JudgmentService()
    r = await svc.auto_judge("接地電阻", 120.0, "Ω")

    assert r["judgment"] == "fail"
    assert r["standard_id"] == "elec_ground_resistance"
    # fail 同樣是高信心度（規則明確）
    assert r["confidence"] >= 0.9


async def test_auto_judge_ground_resistance_pass():
    """接地電阻 50 Ω < 100 Ω 上限 → pass"""
    svc = JudgmentService()
    r = await svc.auto_judge("接地電阻", 50.0, "Ω")

    assert r["judgment"] == "pass"


# ============================================================
# auto_judge: range（範圍）— 滅火器壓力
# ============================================================


async def test_auto_judge_extinguisher_pressure_in_range_pass():
    """滅火器壓力 0.85 MPa 在 [0.7, 0.98] 範圍內 → pass"""
    svc = JudgmentService()
    r = await svc.auto_judge("滅火器壓力", 0.85, "MPa")

    assert r["judgment"] == "pass"
    assert r["standard_id"] == "fire_extinguisher_pressure"


async def test_auto_judge_extinguisher_pressure_below_range_fail():
    """滅火器壓力 0.5 MPa 低於下限 0.7 → fail"""
    svc = JudgmentService()
    r = await svc.auto_judge("滅火器壓力", 0.5, "MPa")

    assert r["judgment"] == "fail"


async def test_auto_judge_extinguisher_pressure_above_range_fail():
    """滅火器壓力 1.2 MPa 高於上限 0.98 → fail"""
    svc = JudgmentService()
    r = await svc.auto_judge("滅火器壓力", 1.2, "MPa")

    assert r["judgment"] == "fail"


# ============================================================
# auto_judge: 機械類覆蓋（馬達溫度）
# ============================================================


async def test_auto_judge_motor_temp_mechanical_category():
    """馬達溫度 90°C > 80°C → fail（驗證機械類覆蓋）"""
    svc = JudgmentService()
    r = await svc.auto_judge("馬達溫度", 90.0, "°C")

    assert r["judgment"] == "fail"
    assert r["standard_id"] == "mech_motor_temp"


# ============================================================
# auto_judge: 無匹配標準 → unknown
# ============================================================


async def test_auto_judge_unknown_field_returns_unknown():
    """field_name 完全找不到匹配 → judgment='unknown'，不會誤判 pass/fail"""
    svc = JudgmentService()
    r = await svc.auto_judge("某不存在的奇怪欄位 XYZ123", 42.0, "")

    assert r["judgment"] == "unknown"
    assert r["standard_id"] is None
    assert r["confidence"] == 0.0
    # 必須仍包含原始量測值供前端顯示
    assert r["measured_value"] == 42.0


async def test_auto_judge_unknown_field_no_regulation():
    """unknown 時不應該攜帶任何法規依據（避免誤導使用者）"""
    svc = JudgmentService()
    r = await svc.auto_judge("不存在的項目", 1.0, "X")

    assert r["regulation"] == ""
    assert r["standard_text"] == ""


# ============================================================
# batch_auto_judge：批次判定
# ============================================================


async def test_batch_auto_judge_mixed_results():
    """混合 pass/fail/unknown 三種結果，順序與輸入一致"""
    svc = JudgmentService()
    readings = [
        {"field_name": "絕緣電阻 R相", "value": 52.3, "unit": "MΩ"},   # pass
        {"field_name": "接地電阻", "value": 150.0, "unit": "Ω"},        # fail
        {"field_name": "完全沒這項目", "value": 1.0, "unit": ""},        # unknown
    ]
    results = await svc.batch_auto_judge(readings)

    assert len(results) == 3
    assert results[0]["judgment"] == "pass"
    assert results[1]["judgment"] == "fail"
    assert results[2]["judgment"] == "unknown"


async def test_batch_auto_judge_empty_input():
    """空 readings → 空 results，不應 raise"""
    svc = JudgmentService()
    results = await svc.batch_auto_judge([])

    assert results == []


async def test_batch_auto_judge_preserves_field_names():
    """batch 結果的 field_name 應原樣保留輸入值（給前端對位）"""
    svc = JudgmentService()
    readings = [
        {"field_name": "我的接地電阻 (Phase A)", "value": 50.0, "unit": "Ω"},
    ]
    results = await svc.batch_auto_judge(readings)

    assert results[0]["field_name"] == "我的接地電阻 (Phase A)"
    assert results[0]["judgment"] == "pass"


# ============================================================
# 邊界：unit 推導 fallback
# ============================================================


async def test_auto_judge_uses_standard_unit_when_input_unit_blank():
    """輸入 unit='' 但匹配到標準時，回傳的 unit 應 fallback 為標準的 unit"""
    svc = JudgmentService()
    r = await svc.auto_judge("絕緣電阻", 10.0, "")

    # 標準的 unit 是 "MΩ"
    assert r["unit"] == "MΩ"


# 允許此檔以 `python test_judgment_service.py` 直接執行（與 sprint test 風格相容）
if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
