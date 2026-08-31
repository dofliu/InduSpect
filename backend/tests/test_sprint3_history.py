"""
Sprint 3 測試: Task 3.3 + 3.4

Task 3.3: 歷史資料儲存與查詢
Task 3.4: 前次數值自動帶入 + 趨勢分析
"""

import sys
import os
import asyncio
import tempfile
from datetime import datetime

if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
os.environ.setdefault("GEMINI_API_KEY", "test-key")

from app.services.history_service import HistoryService


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
def create_test_service() -> HistoryService:
    """建立使用臨時 DB 的服務"""
    tmp = tempfile.NamedTemporaryFile(suffix='.db', delete=False)
    tmp.close()
    return HistoryService(db_path=tmp.name)


async def test_save_and_query():
    """測試儲存和查詢"""
    print("\n" + "="*60)
    print("TEST: Task 3.3 — 儲存與查詢")
    print("="*60)

    results = TestResults()
    service = create_test_service()

    # Test 1: 儲存記錄
    history_id = await service.save_inspection(
        equipment_id="EQ-001",
        equipment_name="B棟1F配電盤",
        template_id="tmpl_001",
        inspection_date="2026-03-13",
        inspector="王小明",
        results=[
            {"field_name": "絕緣電阻 R相", "value": 52.3, "unit": "MΩ", "judgment": "pass"},
            {"field_name": "接地電阻", "value": 45.0, "unit": "Ω", "judgment": "pass"},
        ]
    )
    results.check(
        history_id is not None and len(history_id) > 0,
        "成功儲存記錄並回傳 history_id"
    )

    # Test 2: 根據 history_id 查詢
    record = await service.get_by_id(history_id)
    results.check(
        record is not None,
        "根據 history_id 查詢成功"
    )
    results.check(
        record["equipment_id"] == "EQ-001",
        "equipment_id 正確"
    )
    results.check(
        record["equipment_name"] == "B棟1F配電盤",
        "equipment_name 正確"
    )
    results.check(
        len(record["results"]) == 2,
        f"results 有 2 筆",
        f"實際: {len(record['results'])}"
    )

    # Test 3: 根據設備查詢
    history = await service.get_history("EQ-001")
    results.check(
        len(history) == 1,
        "設備查詢回傳 1 筆"
    )

    # Test 4: 查詢不存在的設備
    empty = await service.get_history("NOT-EXIST")
    results.check(
        len(empty) == 0,
        "不存在的設備回傳空列表"
    )

    # Test 5: 最新記錄
    latest = await service.get_latest("EQ-001")
    results.check(
        latest is not None and latest["history_id"] == history_id,
        "get_latest 回傳正確"
    )

    # Test 6: 多筆記錄排序
    await service.save_inspection(
        equipment_id="EQ-001",
        inspection_date="2026-01-15",
        results=[{"field_name": "絕緣電阻 R相", "value": 65.0, "unit": "MΩ"}]
    )
    await service.save_inspection(
        equipment_id="EQ-001",
        inspection_date="2025-09-20",
        results=[{"field_name": "絕緣電阻 R相", "value": 80.0, "unit": "MΩ"}]
    )
    history2 = await service.get_history("EQ-001")
    results.check(
        len(history2) == 3,
        "3 筆記錄全部查到"
    )
    results.check(
        history2[0]["inspection_date"] >= history2[1]["inspection_date"],
        "記錄按日期降序排列"
    )

    # Test 7: 刪除
    deleted = await service.delete_history(history_id)
    results.check(
        deleted == True,
        "刪除成功"
    )
    after_delete = await service.get_by_id(history_id)
    results.check(
        after_delete is None,
        "刪除後查不到"
    )

    # 清理
    os.unlink(service.db_path)
    return results


async def test_previous_values():
    """測試前次數值帶入"""
    print("\n" + "="*60)
    print("TEST: Task 3.4 — 前次數值自動帶入")
    print("="*60)

    results = TestResults()
    service = create_test_service()

    # 建立歷史資料
    await service.save_inspection(
        equipment_id="EQ-001",
        inspection_date="2026-03-13",
        results=[
            {"field_name": "絕緣電阻 R相", "value": 52.3, "unit": "MΩ", "judgment": "pass"},
            {"field_name": "接地電阻", "value": 45.0, "unit": "Ω", "judgment": "pass"},
            {"field_name": "漏電斷路器動作時間", "value": 50, "unit": "ms", "judgment": "pass"},
        ]
    )

    # Test 1: 取得前次值
    prev = await service.get_previous_values(
        equipment_id="EQ-001",
        field_names=["絕緣電阻 R相", "接地電阻", "不存在的欄位"]
    )

    results.check(
        "絕緣電阻 R相" in prev,
        "找到「絕緣電阻 R相」的前次值"
    )
    results.check(
        prev.get("絕緣電阻 R相", {}).get("value") == 52.3,
        "前次值 = 52.3"
    )
    results.check(
        prev.get("絕緣電阻 R相", {}).get("unit") == "MΩ",
        "前次單位 = MΩ"
    )
    results.check(
        "接地電阻" in prev,
        "找到「接地電阻」的前次值"
    )
    results.check(
        "不存在的欄位" not in prev,
        "不存在的欄位正確回傳空"
    )

    # Test 2: 無歷史資料的設備
    prev2 = await service.get_previous_values(
        equipment_id="NO-EXIST",
        field_names=["絕緣電阻 R相"]
    )
    results.check(
        len(prev2) == 0,
        "無歷史設備回傳空 dict（不報錯）"
    )

    os.unlink(service.db_path)
    return results


async def test_trend_analysis():
    """測試趨勢分析"""
    print("\n" + "="*60)
    print("TEST: Task 3.4 — 趨勢分析")
    print("="*60)

    results = TestResults()
    service = create_test_service()

    # 建立連續下降的歷史資料
    await service.save_inspection(
        equipment_id="EQ-001",
        inspection_date="2025-09-20",
        results=[{"field_name": "絕緣電阻 R相", "value": 80.0, "unit": "MΩ"}]
    )
    await service.save_inspection(
        equipment_id="EQ-001",
        inspection_date="2025-12-15",
        results=[{"field_name": "絕緣電阻 R相", "value": 65.0, "unit": "MΩ"}]
    )
    await service.save_inspection(
        equipment_id="EQ-001",
        inspection_date="2026-03-13",
        results=[{"field_name": "絕緣電阻 R相", "value": 52.0, "unit": "MΩ"}]
    )

    # Test 1: 趨勢分析 — 連續下降
    trend = await service.analyze_trend("EQ-001", "絕緣電阻 R相")

    results.check(
        trend is not None,
        "趨勢分析有結果"
    )
    results.check(
        trend["trend"] == "declining",
        f"趨勢 = declining",
        f"實際: {trend['trend']}"
    )
    results.check(
        len(trend["values"]) == 3,
        f"值序列有 3 筆",
        f"實際: {trend['values']}"
    )
    results.check(
        trend["values"] == [80.0, 65.0, 52.0],
        "值序列從舊到新排列"
    )
    results.check(
        trend["consecutive_decline"] >= 2,
        f"連續下降 >= 2 次",
        f"實際: {trend['consecutive_decline']}"
    )
    results.check(
        trend["warning"] is not None and "下降" in trend["warning"],
        "產生下降警告",
        f"警告: {trend['warning']}"
    )

    # Test 2: 穩定趨勢
    service2 = create_test_service()
    await service2.save_inspection(
        equipment_id="EQ-002",
        inspection_date="2025-09-20",
        results=[{"field_name": "接地電阻", "value": 50, "unit": "Ω"}]
    )
    await service2.save_inspection(
        equipment_id="EQ-002",
        inspection_date="2025-12-15",
        results=[{"field_name": "接地電阻", "value": 52, "unit": "Ω"}]
    )
    await service2.save_inspection(
        equipment_id="EQ-002",
        inspection_date="2026-03-13",
        results=[{"field_name": "接地電阻", "value": 48, "unit": "Ω"}]
    )

    trend2 = await service2.analyze_trend("EQ-002", "接地電阻")
    results.check(
        trend2["trend"] == "stable",
        f"穩定趨勢 = stable",
        f"實際: {trend2['trend']}"
    )
    results.check(
        trend2["warning"] is None,
        "穩定趨勢無警告"
    )

    # Test 3: 資料不足
    trend3 = await service.analyze_trend("NO-EXIST", "絕緣電阻")
    results.check(
        trend3["trend"] == "insufficient",
        "無資料 → insufficient"
    )

    os.unlink(service.db_path)
    os.unlink(service2.db_path)
    return results


async def main():
    print("="*60)
    print(f"Sprint 3 Task 3.3+3.4 測試報告 — {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("="*60)

    all_results = []
    all_results.append(await test_save_and_query())
    all_results.append(await test_previous_values())
    all_results.append(await test_trend_analysis())

    total_passed = sum(r.passed for r in all_results)
    total_failed = sum(r.failed for r in all_results)
    total = total_passed + total_failed

    print("\n" + "="*60)
    print(f"Sprint 3 Task 3.3+3.4 總結")
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
