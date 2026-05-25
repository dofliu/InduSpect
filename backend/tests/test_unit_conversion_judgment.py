"""
單位換算判定測試（2026-05-25）

AI 從照片抽取的讀數，單位寫法常與法規標準不一致（kΩ vs MΩ、°F vs °C、
Mohm vs MΩ）。若不換算就直接比較數值，會造成嚴重的安全誤判
（例：500 kΩ = 0.5 MΩ 應為不合格，卻因 500 ≥ 1.0 被誤判為合格）。

本檔覆蓋：
- normalize_unit：單位變體正規化
- convert_value：同維度換算（電阻/電流/電壓/壓力/溫度/時間/長度/速度）
- auto_judge：判定前自動換算，並回傳 converted_value / converted_unit
- 維度不相容時不換算、不誤判

async test 透過 CI 的 --asyncio-mode=auto 跑。
"""

import sys
import os

if sys.platform == "win32":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ.setdefault("GEMINI_API_KEY", "test-key")

import pytest

from app.data.inspection_standards import (
    normalize_unit,
    convert_value,
    InspectionStandardsDB,
)
from app.services.judgment_service import JudgmentService


# ============================================================
# normalize_unit
# ============================================================


def test_normalize_unit_temperature_variants():
    assert normalize_unit("℃") == "°C"
    assert normalize_unit("degC") == "°C"
    assert normalize_unit("°c") == "°C"
    assert normalize_unit("℉") == "°F"


def test_normalize_unit_ohm_variants():
    assert normalize_unit("Mohm") == "MΩ"
    assert normalize_unit("kohm") == "kΩ"
    assert normalize_unit("ohm") == "Ω"
    assert normalize_unit("Ohm") == "Ω"


def test_normalize_unit_pressure_and_micro():
    assert normalize_unit("kgf/cm2") == "kgf/cm²"
    assert normalize_unit("kg/cm²") == "kgf/cm²"
    assert normalize_unit("uΩ") == "μΩ"
    assert normalize_unit("uA") == "μA"


def test_normalize_unit_passthrough_and_blank():
    assert normalize_unit("MΩ") == "MΩ"
    assert normalize_unit("  V ") == "V"
    assert normalize_unit("") == ""
    assert normalize_unit(None) == ""
    # 未知單位原樣回傳
    assert normalize_unit("widgets") == "widgets"


# ============================================================
# convert_value — 同維度換算
# ============================================================


def test_convert_resistance_kohm_to_mohm():
    v, ok = convert_value(500, "kΩ", "MΩ")
    assert ok
    assert abs(v - 0.5) < 1e-9


def test_convert_resistance_mohm_to_ohm():
    v, ok = convert_value(1.0, "MΩ", "Ω")
    assert ok
    assert abs(v - 1_000_000) < 1e-3


def test_convert_current_amp_to_milliamp():
    v, ok = convert_value(0.05, "A", "mA")
    assert ok
    assert abs(v - 50.0) < 1e-9


def test_convert_pressure_kpa_to_mpa():
    v, ok = convert_value(850, "kPa", "MPa")
    assert ok
    assert abs(v - 0.85) < 1e-9


def test_convert_pressure_kgfcm2_to_mpa():
    # 10.197 kgf/cm² ≈ 1 MPa
    v, ok = convert_value(10.197, "kgf/cm²", "MPa")
    assert ok
    assert abs(v - 1.0) < 1e-3


def test_convert_temperature_f_to_c():
    v, ok = convert_value(185, "°F", "°C")
    assert ok
    assert abs(v - 85.0) < 1e-6


def test_convert_temperature_c_to_f():
    v, ok = convert_value(100, "°C", "°F")
    assert ok
    assert abs(v - 212.0) < 1e-6


def test_convert_identity_same_unit():
    v, ok = convert_value(52.3, "MΩ", "MΩ")
    assert ok
    assert v == 52.3


def test_convert_normalized_alias_equivalent():
    # Mohm 正規化後等同 MΩ，視為同單位
    v, ok = convert_value(3.3, "Mohm", "MΩ")
    assert ok
    assert abs(v - 3.3) < 1e-9


def test_convert_incompatible_dimensions_fails():
    # 溫度無法換算成電阻
    v, ok = convert_value(50, "°C", "MΩ")
    assert not ok
    assert v is None


def test_convert_blank_or_nonnumeric_fails():
    assert convert_value(10, "", "MΩ") == (None, False)
    assert convert_value(10, "MΩ", "") == (None, False)
    assert convert_value("正常", "MΩ", "Ω") == (None, False)


# ============================================================
# auto_judge — 換算後判定（核心安全修正）
# ============================================================


async def test_auto_judge_insulation_kohm_below_threshold_fails():
    """500 kΩ = 0.5 MΩ < 1.0 MΩ → fail（修正前因未換算誤判為 pass）"""
    svc = JudgmentService()
    r = await svc.auto_judge("絕緣電阻", 500, "kΩ")

    assert r["judgment"] == "fail"
    assert r["standard_id"] == "elec_insulation_lv"
    assert r["converted_value"] is not None
    assert abs(r["converted_value"] - 0.5) < 1e-9
    assert r["converted_unit"] == "MΩ"
    # 原始讀數仍以使用者輸入呈現，方便對照
    assert r["measured_value"] == 500
    assert r["unit"] == "kΩ"


async def test_auto_judge_insulation_kohm_above_threshold_passes():
    """3000 kΩ = 3.0 MΩ ≥ 2.0 warning → pass"""
    svc = JudgmentService()
    r = await svc.auto_judge("絕緣電阻", 3000, "kΩ")

    assert r["judgment"] == "pass"
    assert abs(r["converted_value"] - 3.0) < 1e-9


async def test_auto_judge_rcd_current_amp_to_milliamp_fails():
    """漏電動作電流 0.05 A = 50 mA > 30 mA 上限 → fail"""
    svc = JudgmentService()
    r = await svc.auto_judge("漏電斷路器動作電流", 0.05, "A")

    assert r["judgment"] == "fail"
    assert abs(r["converted_value"] - 50.0) < 1e-9
    assert r["converted_unit"] == "mA"


async def test_auto_judge_temperature_fahrenheit_converted():
    """馬達溫度 185°F = 85°C → 超過上限（含 warning 區）"""
    svc = JudgmentService()
    r = await svc.auto_judge("馬達溫度", 185, "°F", equipment_type="電動機")

    assert r["converted_value"] is not None
    assert abs(r["converted_value"] - 85.0) < 1e-6
    assert r["converted_unit"] == "°C"
    assert r["judgment"] in ("fail", "warning")


async def test_auto_judge_same_unit_no_conversion_marker():
    """同單位時 converted_value 應為 None（未發生換算）"""
    svc = JudgmentService()
    r = await svc.auto_judge("絕緣電阻", 52.3, "MΩ")

    assert r["judgment"] == "pass"
    assert r["converted_value"] is None
    assert r["converted_unit"] is None


async def test_auto_judge_blank_unit_judges_raw_value():
    """未提供單位時，沿用原值判定（假設已是標準單位）"""
    svc = JudgmentService()
    r = await svc.auto_judge("絕緣電阻", 0.5, "")

    assert r["judgment"] == "fail"
    assert r["converted_value"] is None


async def test_auto_judge_alias_unit_mohm_matches_and_no_false_conversion():
    """Mohm 正規化後等同 MΩ：正常匹配且不標記為換算"""
    svc = JudgmentService()
    r = await svc.auto_judge("絕緣電阻", 5.0, "Mohm")

    assert r["standard_id"] == "elec_insulation_lv"
    assert r["judgment"] == "pass"
    assert r["converted_value"] is None  # 正規化後同單位，視為未換算


# ============================================================
# find_matching_standard — 欄位名稱相關性為必要條件
# （修正前：只要設備類型相同，不相干欄位也會硬湊到某條標準）
# ============================================================


def test_match_requires_field_name_relevance_even_with_equipment_type():
    db = InspectionStandardsDB()
    # 欄位名稱與任何標準都不相關，即使設備類型相符也不應匹配
    assert db.find_matching_standard("不存在項目", "", "低壓配電設備") is None
    assert db.find_matching_standard("隨機文字XYZ", "MΩ", "低壓配電設備") is None


def test_match_relevant_field_still_matches_with_equipment_type():
    db = InspectionStandardsDB()
    s = db.find_matching_standard("絕緣電阻 R相", "MΩ", "低壓配電設備")
    assert s is not None
    assert s["standard_id"] == "elec_insulation_lv"


async def test_auto_judge_unrelated_field_with_equipment_type_is_unknown():
    """不相干欄位在帶設備類型時仍應為 unknown，不可捏造判定"""
    svc = JudgmentService()
    r = await svc.auto_judge("不存在項目", 1.0, "", equipment_type="低壓配電設備")
    assert r["judgment"] == "unknown"
    assert r["standard_id"] is None
