"""
Sprint 3 測試: Task 3.1 + 3.2

Task 3.1: 法規標準值資料庫
Task 3.2: 自動判定 (auto_judge)
"""

import sys
import os
import asyncio
from datetime import datetime

if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
os.environ.setdefault("GEMINI_API_KEY", "test-key")

from app.data.inspection_standards import (
    InspectionStandardsDB, ALL_STANDARDS,
    ELECTRICAL_STANDARDS, FIRE_STANDARDS,
    MECHANICAL_STANDARDS, PRESSURE_STANDARDS,
)
from app.services.form_fill import FormFillService


class TestResults:
    def __init__(self):
        self.passed = 0
        self.failed = 0
        self.errors = []

    def check(self, condition, name, detail=""):
        if condition:
            self.passed += 1
            print(f"  ✅ {name}")
        else:
            self.failed += 1
            self.errors.append(f"{name}: {detail}")
            print(f"  ❌ {name} — {detail}")


        # Issue #45: pytest 下必須真的失敗，否則 CI 擋不住退化；
        # __main__ 手動模式維持彙總報告行為
        if os.environ.get("PYTEST_CURRENT_TEST"):
            assert condition, f"{name}: {detail}"
def test_database_coverage():
    """測試資料庫覆蓋率"""
    print("\n" + "="*60)
    print("TEST: Task 3.1 — 資料庫覆蓋率")
    print("="*60)

    results = TestResults()
    db = InspectionStandardsDB()

    # Test 1: 總項目數 >= 50（routine Session #6 由 35 拉高至 50）
    stats = db.get_stats()
    results.check(
        stats["total"] >= 50,
        f"總標準數 >= 50",
        f"實際: {stats['total']}"
    )

    # Test 2: 電氣 >= 15
    elec = db.get_by_category("electrical")
    results.check(
        len(elec) >= 15,
        f"電氣標準 >= 15",
        f"實際: {len(elec)}"
    )

    # Test 3: 消防 >= 13（Session #5 擴充後從 10 拉高至 13，留 2 條 buffer）
    fire = db.get_by_category("fire")
    results.check(
        len(fire) >= 13,
        f"消防標準 >= 13",
        f"實際: {len(fire)}"
    )

    # Test 4: 機械 >= 13（Session #4 擴充後從 10 拉高至 13）
    mech = db.get_by_category("mechanical")
    results.check(
        len(mech) >= 13,
        f"機械標準 >= 13",
        f"實際: {len(mech)}"
    )

    # Test 5: 壓力容器 >= 10（Session #3 擴充後從 3 拉高至 10）
    pres = db.get_by_category("pressure")
    results.check(
        len(pres) >= 10,
        f"壓力容器標準 >= 10",
        f"實際: {len(pres)}"
    )

    # Test 6: 每項都有法規依據
    with_reg = stats["with_regulation"]
    results.check(
        with_reg == stats["total"],
        f"每項都有法規依據",
        f"有法規: {with_reg}/{stats['total']}"
    )

    # Test 7: 每項都有 standard_id
    all_ids = [s["standard_id"] for s in ALL_STANDARDS]
    results.check(
        len(all_ids) == len(set(all_ids)),
        "所有 standard_id 唯一",
        f"重複: {[x for x in all_ids if all_ids.count(x) > 1]}"
    )

    # Test 8: 每項都有 keywords
    all_have_kw = all(len(s.get("keywords", [])) > 0 for s in ALL_STANDARDS)
    results.check(
        all_have_kw,
        "每項都有搜尋關鍵字"
    )

    return results


def test_standard_conditions():
    """測試比較模式覆蓋"""
    print("\n" + "="*60)
    print("TEST: Task 3.1 — 比較模式覆蓋")
    print("="*60)

    results = TestResults()

    conditions = set(s["pass_condition"] for s in ALL_STANDARDS)

    results.check("gte" in conditions, "支援 gte (>=) 比較")
    results.check("lte" in conditions, "支援 lte (<=) 比較")
    results.check("range" in conditions, "支援 range 比較")
    results.check("in_set" in conditions, "支援 in_set (枚舉) 比較")

    return results


def test_find_matching():
    """測試模糊匹配"""
    print("\n" + "="*60)
    print("TEST: Task 3.1 — 模糊匹配查詢")
    print("="*60)

    results = TestResults()
    db = InspectionStandardsDB()

    # Test 1: 精確名稱匹配
    std = db.find_matching_standard("絕緣電阻")
    results.check(
        std is not None and std["standard_id"] == "elec_insulation_lv",
        "「絕緣電阻」匹配到低壓絕緣標準",
        f"實際: {std['standard_id'] if std else 'None'}"
    )

    # Test 2: 帶修飾語的匹配
    std2 = db.find_matching_standard("絕緣電阻 R相")
    results.check(
        std2 is not None and "insulation" in str(std2.get("keywords", [])),
        "「絕緣電阻 R相」匹配到絕緣標準"
    )

    # Test 3: 帶單位匹配更精準
    std3 = db.find_matching_standard("絕緣電阻", unit="MΩ")
    results.check(
        std3 is not None and std3["unit"] == "MΩ",
        "帶單位 MΩ 匹配更精準"
    )

    # Test 4: 接地電阻
    std4 = db.find_matching_standard("接地電阻")
    results.check(
        std4 is not None and std4["standard_id"] == "elec_ground_resistance",
        "「接地電阻」正確匹配",
        f"實際: {std4['standard_id'] if std4 else 'None'}"
    )

    # Test 5: 漏電斷路器
    std5 = db.find_matching_standard("漏電斷路器動作時間")
    results.check(
        std5 is not None and "rcd" in std5["standard_id"],
        "「漏電斷路器動作時間」正確匹配"
    )

    # Test 6: 滅火器壓力
    std6 = db.find_matching_standard("滅火器壓力")
    results.check(
        std6 is not None and std6["standard_id"] == "fire_extinguisher_pressure",
        "「滅火器壓力」正確匹配"
    )

    # Test 7: 馬達溫度
    std7 = db.find_matching_standard("馬達溫度")
    results.check(
        std7 is not None and std7["standard_id"] == "mech_motor_temp",
        "「馬達溫度」正確匹配"
    )

    # Test 8: 無匹配的回傳 None
    std8 = db.find_matching_standard("不存在的項目名稱xyz")
    results.check(
        std8 is None,
        "不存在的項目回傳 None"
    )

    return results


def test_judge_values():
    """測試判定邏輯"""
    print("\n" + "="*60)
    print("TEST: Task 3.1 — 判定邏輯")
    print("="*60)

    results = TestResults()
    db = InspectionStandardsDB()

    # gte 測試: 絕緣電阻 >= 1.0 MΩ
    std = db.get_by_id("elec_insulation_lv")

    # 合格
    r1 = db.judge_value(std, 52.3)
    results.check(r1["judgment"] == "pass", "絕緣 52.3 MΩ → pass")

    # 不合格
    r2 = db.judge_value(std, 0.5)
    results.check(r2["judgment"] == "fail", "絕緣 0.5 MΩ → fail")

    # 警告（>= 合格但 < warning）
    r3 = db.judge_value(std, 1.5)
    results.check(r3["judgment"] == "warning", "絕緣 1.5 MΩ → warning")

    # lte 測試: 接地電阻 <= 100 Ω
    std2 = db.get_by_id("elec_ground_resistance")

    r4 = db.judge_value(std2, 50)
    results.check(r4["judgment"] == "pass", "接地 50 Ω → pass")

    r5 = db.judge_value(std2, 120)
    results.check(r5["judgment"] == "fail", "接地 120 Ω → fail")

    r6 = db.judge_value(std2, 90)
    results.check(r6["judgment"] == "warning", "接地 90 Ω → warning (> 80)")

    # range 測試: 滅火器壓力 0.7~0.98 MPa
    std3 = db.get_by_id("fire_extinguisher_pressure")

    r7 = db.judge_value(std3, 0.85)
    results.check(r7["judgment"] == "pass", "滅火器 0.85 MPa → pass")

    r8 = db.judge_value(std3, 0.5)
    results.check(r8["judgment"] == "fail", "滅火器 0.5 MPa → fail")

    r9 = db.judge_value(std3, 1.2)
    results.check(r9["judgment"] == "fail", "滅火器 1.2 MPa → fail")

    # in_set 測試: 潤滑油液位
    std4 = db.get_by_id("mech_oil_level")

    r10 = db.judge_value(std4, "正常")
    results.check(r10["judgment"] == "pass", "油位「正常」→ pass")

    r11 = db.judge_value(std4, "過低")
    results.check(r11["judgment"] == "fail", "油位「過低」→ fail")

    # 非數值輸入 → unknown
    r12 = db.judge_value(std, "無法量測")
    results.check(r12["judgment"] == "unknown", "非數值「無法量測」→ unknown")

    # 標準文字格式
    results.check(
        "≥" in r1["standard_text"] or ">=" in r1["standard_text"],
        f"標準文字包含比較符號: {r1['standard_text']}"
    )
    results.check(
        r1["regulation"] != "",
        f"包含法規依據: {r1['regulation']}"
    )

    return results


async def test_auto_judge_service():
    """測試 FormFillService.auto_judge"""
    print("\n" + "="*60)
    print("TEST: Task 3.2 — auto_judge()")
    print("="*60)

    results = TestResults()
    service = FormFillService()

    # Test 1: 絕緣電阻合格
    r1 = await service.auto_judge("絕緣電阻 R相", 52.3, "MΩ")
    results.check(
        r1["judgment"] == "pass",
        "絕緣電阻 52.3 MΩ → pass"
    )
    results.check(
        r1["confidence"] >= 0.9,
        f"信心度 >= 0.9 (實際: {r1['confidence']})"
    )
    results.check(
        r1["standard_id"] is not None,
        f"有匹配的 standard_id: {r1['standard_id']}"
    )

    # Test 2: 接地電阻不合格
    r2 = await service.auto_judge("接地電阻", 120, "Ω")
    results.check(
        r2["judgment"] == "fail",
        "接地電阻 120 Ω → fail"
    )

    # Test 3: 漏電斷路器合格
    r3 = await service.auto_judge("漏電斷路器動作時間", 50, "ms")
    results.check(
        r3["judgment"] == "pass",
        "漏電斷路器 50 ms → pass"
    )

    # Test 4: 滅火器壓力不合格
    r4 = await service.auto_judge("滅火器壓力", 0.3, "MPa")
    results.check(
        r4["judgment"] == "fail",
        "滅火器壓力 0.3 MPa → fail"
    )

    # Test 5: 不認識的項目 → unknown
    r5 = await service.auto_judge("不存在的項目", 99)
    results.check(
        r5["judgment"] == "unknown",
        "不認識的項目 → unknown"
    )
    results.check(
        r5["confidence"] == 0.0,
        "不認識的項目信心度 = 0"
    )

    # Test 6: 批次判定
    readings = [
        {"field_name": "絕緣電阻", "value": 52.3, "unit": "MΩ"},
        {"field_name": "接地電阻", "value": 85.2, "unit": "Ω"},
        {"field_name": "漏電斷路器動作時間", "value": 50, "unit": "ms"},
        {"field_name": "馬達溫度", "value": 95, "unit": "°C"},
    ]
    batch_results = await service.batch_auto_judge(readings)

    results.check(
        len(batch_results) == 4,
        f"批次判定回傳 4 筆結果"
    )
    results.check(
        batch_results[0]["judgment"] == "pass",
        "批次: 絕緣 52.3 → pass"
    )
    results.check(
        batch_results[1]["judgment"] == "warning",
        "批次: 接地 85.2 → warning",
        f"實際: {batch_results[1]['judgment']}"
    )
    results.check(
        batch_results[3]["judgment"] == "fail",
        "批次: 馬達溫度 95°C → fail (>80)"
    )

    return results


async def main():
    print("="*60)
    print(f"Sprint 3 Task 3.1+3.2 測試報告 — {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("="*60)

    all_results = []
    all_results.append(test_database_coverage())
    all_results.append(test_standard_conditions())
    all_results.append(test_find_matching())
    all_results.append(test_judge_values())
    all_results.append(await test_auto_judge_service())

    total_passed = sum(r.passed for r in all_results)
    total_failed = sum(r.failed for r in all_results)
    total = total_passed + total_failed

    print("\n" + "="*60)
    print(f"Sprint 3 Task 3.1+3.2 總結")
    print("="*60)
    print(f"總測試數: {total}")
    print(f"通過: {total_passed} ✅")
    print(f"失敗: {total_failed} ❌")
    print(f"通過率: {total_passed/total*100:.1f}%" if total > 0 else "N/A")

    if total_failed > 0:
        print("\n失敗清單:")
        for r in all_results:
            for e in r.errors:
                print(f"  ❌ {e}")

    return total_failed == 0


if __name__ == "__main__":
    success = asyncio.run(main())
    sys.exit(0 if success else 1)
