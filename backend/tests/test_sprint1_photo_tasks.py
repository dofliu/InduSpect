"""
Sprint 1 測試: 拍照任務清單產生 + 精準映射

測試範圍:
- Task 1.1: generate_photo_tasks() 從 field_map 產生拍照清單
- Task 1.2: API 端點 /generate-photo-tasks
- Task 1.4: precision_map_fields() 精準映射
"""

import sys
import os
import asyncio
import json
from datetime import datetime

# Fix Windows console encoding
if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')

# 確保可以匯入 backend 模組
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

# Mock settings 以避免需要真實 API key
os.environ.setdefault("GEMINI_API_KEY", "test-key")

from app.services.form_fill import FormFillService


# ============================================================
# 測試用 field_map（模擬電氣設備定期檢查表）
# ============================================================

SAMPLE_FIELD_MAP = [
    # --- 基本資訊欄位（不需拍照） ---
    {
        "field_id": "excel_Sheet1_B2",
        "field_name": "設備名稱",
        "field_type": "text",
        "label_location": {"sheet": "Sheet1", "cell": "B2", "row": 2, "column": 2},
        "value_location": {"sheet": "Sheet1", "cell": "C2", "row": 2, "column": 3, "direction": "right", "offset": 1},
        "is_merged": False,
        "merge_info": None,
        "mapping": None,
    },
    {
        "field_id": "excel_Sheet1_B3",
        "field_name": "設備編號",
        "field_type": "text",
        "label_location": {"sheet": "Sheet1", "cell": "B3", "row": 3, "column": 2},
        "value_location": {"sheet": "Sheet1", "cell": "C3", "row": 3, "column": 3, "direction": "right", "offset": 1},
        "is_merged": False,
        "merge_info": None,
        "mapping": None,
    },
    {
        "field_id": "excel_Sheet1_D2",
        "field_name": "檢查日期",
        "field_type": "date",
        "label_location": {"sheet": "Sheet1", "cell": "D2", "row": 2, "column": 4},
        "value_location": {"sheet": "Sheet1", "cell": "E2", "row": 2, "column": 5, "direction": "right", "offset": 1},
        "is_merged": False,
        "merge_info": None,
        "mapping": None,
    },
    {
        "field_id": "excel_Sheet1_D3",
        "field_name": "檢查人員姓名",
        "field_type": "text",
        "label_location": {"sheet": "Sheet1", "cell": "D3", "row": 3, "column": 4},
        "value_location": {"sheet": "Sheet1", "cell": "E3", "row": 3, "column": 5, "direction": "right", "offset": 1},
        "is_merged": False,
        "merge_info": None,
        "mapping": None,
    },

    # --- 檢查項目（同一列含 數值 + 判定 + 備註） ---

    # Row 6: 絕緣電阻 R相
    {
        "field_id": "excel_Sheet1_B6",
        "field_name": "絕緣電阻 R相",
        "field_type": "number",
        "label_location": {"sheet": "Sheet1", "cell": "B6", "row": 6, "column": 2},
        "value_location": {"sheet": "Sheet1", "cell": "C6", "row": 6, "column": 3, "direction": "right", "offset": 1},
        "is_merged": False,
        "merge_info": None,
        "mapping": None,
    },
    {
        "field_id": "excel_Sheet1_D6",
        "field_name": "判定",
        "field_type": "checkbox",
        "label_location": {"sheet": "Sheet1", "cell": "D6", "row": 6, "column": 4},
        "value_location": {"sheet": "Sheet1", "cell": "D6", "row": 6, "column": 4, "direction": "right", "offset": 0},
        "is_merged": False,
        "merge_info": None,
        "mapping": None,
    },
    {
        "field_id": "excel_Sheet1_E6",
        "field_name": "備註",
        "field_type": "text",
        "label_location": {"sheet": "Sheet1", "cell": "E6", "row": 6, "column": 5},
        "value_location": {"sheet": "Sheet1", "cell": "E6", "row": 6, "column": 5, "direction": "right", "offset": 0},
        "is_merged": False,
        "merge_info": None,
        "mapping": None,
    },

    # Row 7: 絕緣電阻 S相
    {
        "field_id": "excel_Sheet1_B7",
        "field_name": "絕緣電阻 S相",
        "field_type": "number",
        "label_location": {"sheet": "Sheet1", "cell": "B7", "row": 7, "column": 2},
        "value_location": {"sheet": "Sheet1", "cell": "C7", "row": 7, "column": 3, "direction": "right", "offset": 1},
        "is_merged": False,
        "merge_info": None,
        "mapping": None,
    },
    {
        "field_id": "excel_Sheet1_D7",
        "field_name": "判定",
        "field_type": "checkbox",
        "label_location": {"sheet": "Sheet1", "cell": "D7", "row": 7, "column": 4},
        "value_location": {"sheet": "Sheet1", "cell": "D7", "row": 7, "column": 4},
        "is_merged": False,
        "merge_info": None,
        "mapping": None,
    },

    # Row 8: 接地電阻
    {
        "field_id": "excel_Sheet1_B8",
        "field_name": "接地電阻",
        "field_type": "number",
        "label_location": {"sheet": "Sheet1", "cell": "B8", "row": 8, "column": 2},
        "value_location": {"sheet": "Sheet1", "cell": "C8", "row": 8, "column": 3, "direction": "right", "offset": 1},
        "is_merged": False,
        "merge_info": None,
        "mapping": None,
    },
    {
        "field_id": "excel_Sheet1_D8",
        "field_name": "判定結果",
        "field_type": "checkbox",
        "label_location": {"sheet": "Sheet1", "cell": "D8", "row": 8, "column": 4},
        "value_location": {"sheet": "Sheet1", "cell": "D8", "row": 8, "column": 4},
        "is_merged": False,
        "merge_info": None,
        "mapping": None,
    },
    {
        "field_id": "excel_Sheet1_E8",
        "field_name": "異常說明",
        "field_type": "text",
        "label_location": {"sheet": "Sheet1", "cell": "E8", "row": 8, "column": 5},
        "value_location": {"sheet": "Sheet1", "cell": "E8", "row": 8, "column": 5},
        "is_merged": False,
        "merge_info": None,
        "mapping": None,
    },

    # Row 9: 外觀檢查（非數值）
    {
        "field_id": "excel_Sheet1_B9",
        "field_name": "外觀檢查",
        "field_type": "text",
        "label_location": {"sheet": "Sheet1", "cell": "B9", "row": 9, "column": 2},
        "value_location": {"sheet": "Sheet1", "cell": "C9", "row": 9, "column": 3},
        "is_merged": False,
        "merge_info": None,
        "mapping": None,
    },

    # --- 結論/簽核欄位 ---
    {
        "field_id": "excel_Sheet1_B12",
        "field_name": "綜合判定結論",
        "field_type": "text",
        "label_location": {"sheet": "Sheet1", "cell": "B12", "row": 12, "column": 2},
        "value_location": {"sheet": "Sheet1", "cell": "C12", "row": 12, "column": 3},
        "is_merged": False,
        "merge_info": None,
        "mapping": None,
    },
    {
        "field_id": "excel_Sheet1_B13",
        "field_name": "檢查人員簽名",
        "field_type": "text",
        "label_location": {"sheet": "Sheet1", "cell": "B13", "row": 13, "column": 2},
        "value_location": {"sheet": "Sheet1", "cell": "C13", "row": 13, "column": 3},
        "is_merged": False,
        "merge_info": None,
        "mapping": None,
    },
]


# ============================================================
# 模擬 AI 分析結果 (photo_task_bindings)
# ============================================================

SAMPLE_INSPECTION_RESULTS = [
    {
        "equipment_name": "B棟1F配電盤",
        "equipment_type": "低壓配電設備",
        "equipment_id": "EQ-001",
        "inspection_date": "2026-03-13",
        "inspector_name": "王小明",
        "location": "B棟1樓電氣室",
        "condition_assessment": "設備運轉正常",
        "anomaly_description": "",
        "is_anomaly": False,
        "extracted_values": {
            "絕緣電阻_R": 52.3,
            "絕緣電阻_S": 48.7,
            "接地電阻": 85.2,
        },
        "notes": "",
    }
]


# ============================================================
# 測試函數
# ============================================================

class TestResults:
    """測試結果收集器"""
    def __init__(self):
        self.passed = 0
        self.failed = 0
        self.errors = []

    def check(self, condition: bool, test_name: str, detail: str = ""):
        if condition:
            self.passed += 1
            print(f"  ✅ {test_name}")
        else:
            self.failed += 1
            self.errors.append(f"{test_name}: {detail}")
            print(f"  ❌ {test_name} — {detail}")

        # Issue #45: pytest 下必須真的失敗，否則 CI 擋不住退化；
        # __main__ 手動模式維持彙總報告行為
        if os.environ.get("PYTEST_CURRENT_TEST"):
            assert condition, f"{test_name}: {detail}"
    def summary(self) -> str:
        total = self.passed + self.failed
        lines = [
            f"\n{'='*60}",
            f"測試結果: {self.passed}/{total} 通過",
            f"{'='*60}",
        ]
        if self.errors:
            lines.append("\n失敗項目:")
            for e in self.errors:
                lines.append(f"  - {e}")
        return "\n".join(lines)


async def test_generate_photo_tasks():
    """測試 Task 1.1: generate_photo_tasks()"""
    print("\n" + "="*60)
    print("TEST: Task 1.1 — generate_photo_tasks()")
    print("="*60)

    results = TestResults()
    service = FormFillService()

    result = await service.generate_photo_tasks(SAMPLE_FIELD_MAP)

    photo_tasks = result["photo_tasks"]
    basic_info = result["basic_info_fields"]
    conclusion = result["conclusion_fields"]
    stats = result["stats"]

    # Test 1: 基本資訊欄位正確分類
    basic_names = [f["field_name"] for f in basic_info]
    results.check(
        "設備名稱" in basic_names,
        "基本資訊包含「設備名稱」"
    )
    results.check(
        "設備編號" in basic_names,
        "基本資訊包含「設備編號」"
    )
    results.check(
        "檢查日期" in basic_names,
        "基本資訊包含「檢查日期」"
    )
    results.check(
        "檢查人員姓名" in basic_names,
        "基本資訊包含「檢查人員姓名」"
    )
    results.check(
        len(basic_info) == 4,
        f"基本資訊共 4 個欄位",
        f"實際: {len(basic_info)} 個"
    )

    # Test 2: 結論欄位正確分類
    concl_names = [f["field_name"] for f in conclusion]
    results.check(
        "綜合判定結論" in concl_names,
        "結論包含「綜合判定結論」"
    )
    results.check(
        "檢查人員簽名" in concl_names,
        "結論包含「檢查人員簽名」"
    )
    results.check(
        len(conclusion) == 2,
        f"結論共 2 個欄位",
        f"實際: {len(conclusion)} 個"
    )

    # Test 3: 拍照任務數量
    results.check(
        len(photo_tasks) >= 3,
        f"至少 3 個拍照任務（絕緣R、絕緣S、接地+外觀）",
        f"實際: {len(photo_tasks)} 個"
    )

    # Test 4: 同一列的欄位合併為一個任務
    # Row 6 (絕緣電阻 R相 + 判定 + 備註) 應合併
    row6_tasks = [t for t in photo_tasks if t.get("row_key") == "Sheet1_row6"]
    results.check(
        len(row6_tasks) == 1,
        "Row 6 的三個欄位合併為一個拍照任務",
        f"實際: {len(row6_tasks)} 個任務"
    )

    if row6_tasks:
        task = row6_tasks[0]
        results.check(
            len(task["field_ids"]) == 3,
            "Row 6 任務涵蓋 3 個 field_ids（數值+判定+備註）",
            f"實際: {len(task['field_ids'])} 個"
        )
        results.check(
            "絕緣電阻 R相" in task["display_name"],
            "Row 6 任務主要名稱為「絕緣電阻 R相」",
            f"實際: {task['display_name']}"
        )
        results.check(
            task["expected_type"] == "number",
            "Row 6 任務預期類型為 number",
            f"實際: {task['expected_type']}"
        )
        results.check(
            task["expected_unit"] == "MΩ",
            "Row 6 任務預期單位為 MΩ",
            f"實際: {task['expected_unit']}"
        )

    # Test 5: 任務有 value/judgment/remarks 欄位分類
    row8_tasks = [t for t in photo_tasks if t.get("row_key") == "Sheet1_row8"]
    if row8_tasks:
        task = row8_tasks[0]
        results.check(
            len(task["value_field_ids"]) >= 1,
            "Row 8 有至少 1 個 value_field_id",
            f"實際: {task['value_field_ids']}"
        )
        results.check(
            len(task["judgment_field_ids"]) >= 1,
            "Row 8 有至少 1 個 judgment_field_id",
            f"實際: {task['judgment_field_ids']}"
        )
        results.check(
            len(task["remarks_field_ids"]) >= 1,
            "Row 8 有至少 1 個 remarks_field_id",
            f"實際: {task['remarks_field_ids']}"
        )

    # Test 6: 拍照提示語包含單位
    for task in photo_tasks:
        if task["expected_unit"]:
            results.check(
                task["expected_unit"] in task["photo_hint"],
                f"任務「{task['display_name']}」的提示語包含單位 {task['expected_unit']}",
                f"提示語: {task['photo_hint']}"
            )
            break

    # Test 7: 日期欄位有預設值
    date_fields = [f for f in basic_info if f["field_type"] == "date"]
    if date_fields:
        results.check(
            date_fields[0].get("default_value") is not None,
            "日期欄位有預設值（今天的日期）",
            f"預設值: {date_fields[0].get('default_value')}"
        )

    # Test 8: 任務按順序排列
    sequences = [t["sequence"] for t in photo_tasks]
    results.check(
        sequences == sorted(sequences),
        "拍照任務按順序排列",
        f"順序: {sequences}"
    )

    # Test 9: 所有欄位都被覆蓋
    total_covered = stats["total_fields_covered"]
    total_original = len(SAMPLE_FIELD_MAP)
    results.check(
        total_covered == total_original,
        f"所有 {total_original} 個欄位都被分類覆蓋",
        f"覆蓋: {total_covered}/{total_original}"
    )

    # Test 10: 基本資訊欄位不出現在拍照清單
    photo_field_ids = set()
    for t in photo_tasks:
        photo_field_ids.update(t["field_ids"])
    basic_field_ids = {f["field_id"] for f in basic_info}
    overlap = photo_field_ids & basic_field_ids
    results.check(
        len(overlap) == 0,
        "基本資訊欄位不出現在拍照清單中",
        f"重疊: {overlap}"
    )

    return results


async def test_precision_map_fields():
    """測試 Task 1.4: precision_map_fields()"""
    print("\n" + "="*60)
    print("TEST: Task 1.4 — precision_map_fields()")
    print("="*60)

    results = TestResults()
    service = FormFillService()

    # 先產生拍照任務以取得 bindings 結構
    task_result = await service.generate_photo_tasks(SAMPLE_FIELD_MAP)
    photo_tasks = task_result["photo_tasks"]

    # 建立 photo_task_bindings（模擬拍照後帶 AI 結果）
    bindings = []
    for task in photo_tasks:
        ai_result = None

        if "絕緣電阻 R" in task["display_name"]:
            ai_result = {
                "readings": [{"label": "絕緣電阻", "value": 52.3, "unit": "MΩ"}],
                "is_anomaly": False,
                "condition_assessment": "正常",
                "anomaly_description": "",
                "summary": "絕緣電阻正常",
            }
        elif "絕緣電阻 S" in task["display_name"]:
            ai_result = {
                "readings": [{"label": "絕緣電阻", "value": 48.7, "unit": "MΩ"}],
                "is_anomaly": False,
                "condition_assessment": "正常",
                "anomaly_description": "",
                "summary": "絕緣電阻正常",
            }
        elif "接地電阻" in task["display_name"]:
            ai_result = {
                "readings": [{"label": "接地電阻", "value": 85.2, "unit": "Ω"}],
                "is_anomaly": True,
                "condition_assessment": "數值偏高",
                "anomaly_description": "接地電阻 85.2Ω，接近標準上限 100Ω，建議安排維修",
                "summary": "接地電阻偏高",
            }
        elif "外觀" in task["display_name"]:
            ai_result = {
                "readings": [],
                "is_anomaly": False,
                "condition_assessment": "外觀正常，無鏽蝕或損壞",
                "anomaly_description": "",
                "summary": "外觀正常",
            }

        bindings.append({
            "task_id": task["task_id"],
            "field_ids": task["field_ids"],
            "value_field_ids": task["value_field_ids"],
            "judgment_field_ids": task["judgment_field_ids"],
            "remarks_field_ids": task["remarks_field_ids"],
            "ai_result": ai_result,
        })

    # 執行精準映射
    map_result = await service.precision_map_fields(
        field_map=SAMPLE_FIELD_MAP,
        inspection_results=SAMPLE_INSPECTION_RESULTS,
        photo_task_bindings=bindings,
    )

    mappings = map_result["mappings"]
    mapping_lookup = {m["field_id"]: m for m in mappings}

    # Test 1: 映射成功
    results.check(
        map_result["success"] is True,
        "precision_map_fields 回傳 success=True"
    )

    # Test 2: 絕緣電阻 R相數值正確映射
    r_phase = mapping_lookup.get("excel_Sheet1_B6")
    results.check(
        r_phase is not None,
        "絕緣電阻 R相 (B6) 有映射結果"
    )
    if r_phase:
        results.check(
            r_phase["suggested_value"] == "52.3",
            "絕緣電阻 R相 值 = 52.3",
            f"實際: {r_phase['suggested_value']}"
        )
        results.check(
            r_phase["confidence"] >= 0.9,
            f"絕緣電阻 R相 信心度 >= 0.9",
            f"實際: {r_phase['confidence']}"
        )

    # Test 3: 判定欄位正確映射（合格）
    judgment_r = mapping_lookup.get("excel_Sheet1_D6")
    results.check(
        judgment_r is not None,
        "R相判定欄位 (D6) 有映射結果"
    )
    if judgment_r:
        results.check(
            judgment_r["suggested_value"] == "合格",
            "R相判定 = 合格",
            f"實際: {judgment_r['suggested_value']}"
        )

    # Test 4: 接地電阻異常 → 不合格
    judgment_ground = mapping_lookup.get("excel_Sheet1_D8")
    results.check(
        judgment_ground is not None,
        "接地電阻判定欄位 (D8) 有映射結果"
    )
    if judgment_ground:
        results.check(
            judgment_ground["suggested_value"] == "不合格",
            "接地電阻判定 = 不合格",
            f"實際: {judgment_ground['suggested_value']}"
        )

    # Test 5: 異常備註有描述
    remarks_ground = mapping_lookup.get("excel_Sheet1_E8")
    results.check(
        remarks_ground is not None,
        "接地電阻備註欄位 (E8) 有映射結果"
    )
    if remarks_ground:
        results.check(
            "85.2" in remarks_ground["suggested_value"] or "偏高" in remarks_ground["suggested_value"],
            "接地電阻備註包含異常描述",
            f"實際: {remarks_ground['suggested_value']}"
        )

    # Test 6: 正常項目備註不是異常描述
    remarks_r = mapping_lookup.get("excel_Sheet1_E6")
    if remarks_r:
        results.check(
            "不合格" not in remarks_r["suggested_value"],
            "R相備註不包含「不合格」",
            f"實際: {remarks_r['suggested_value']}"
        )

    # Test 7: 基本資訊欄位由 general_info 填入
    equip_name = mapping_lookup.get("excel_Sheet1_B2")
    results.check(
        equip_name is not None,
        "設備名稱 (B2) 有映射結果"
    )
    if equip_name:
        results.check(
            equip_name["suggested_value"] == "B棟1F配電盤",
            "設備名稱 = B棟1F配電盤",
            f"實際: {equip_name['suggested_value']}"
        )

    date_field = mapping_lookup.get("excel_Sheet1_D2")
    results.check(
        date_field is not None,
        "檢查日期 (D2) 有映射結果"
    )
    if date_field:
        results.check(
            "2026-03-13" in date_field["suggested_value"],
            "檢查日期 = 2026-03-13",
            f"實際: {date_field['suggested_value']}"
        )

    # Test 8: 未映射欄位數量合理（結論/簽核不會被映射）
    unmapped = map_result.get("unmapped_fields", [])
    results.check(
        len(unmapped) <= 4,
        f"未映射欄位 <= 4 個",
        f"實際: {len(unmapped)} 個: {unmapped}"
    )

    return results


async def test_edge_cases():
    """測試邊界情況"""
    print("\n" + "="*60)
    print("TEST: 邊界情況測試")
    print("="*60)

    results = TestResults()
    service = FormFillService()

    # Test 1: 空 field_map
    result = await service.generate_photo_tasks([])
    results.check(
        len(result["photo_tasks"]) == 0,
        "空 field_map → 0 個拍照任務"
    )
    results.check(
        len(result["basic_info_fields"]) == 0,
        "空 field_map → 0 個基本資訊"
    )

    # Test 2: 全部都是基本資訊欄位
    basic_only = [
        {
            "field_id": "f1", "field_name": "設備名稱", "field_type": "text",
            "label_location": {"sheet": "S1", "cell": "A1", "row": 1, "column": 1},
            "value_location": {"sheet": "S1", "cell": "B1"}, "mapping": None,
        },
        {
            "field_id": "f2", "field_name": "檢查日期", "field_type": "date",
            "label_location": {"sheet": "S1", "cell": "A2", "row": 2, "column": 1},
            "value_location": {"sheet": "S1", "cell": "B2"}, "mapping": None,
        },
    ]
    result = await service.generate_photo_tasks(basic_only)
    results.check(
        len(result["photo_tasks"]) == 0,
        "全基本資訊 → 0 個拍照任務"
    )
    results.check(
        len(result["basic_info_fields"]) == 2,
        "全基本資訊 → 2 個基本資訊欄位"
    )

    # Test 3: 沒有 label_location 的欄位
    no_location = [
        {
            "field_id": "f3", "field_name": "溫度讀數", "field_type": "number",
            "label_location": {},
            "value_location": None, "mapping": None,
        },
    ]
    result = await service.generate_photo_tasks(no_location)
    results.check(
        len(result["photo_tasks"]) == 1,
        "無 label_location 的檢查欄位仍會產生拍照任務",
        f"實際任務數: {len(result['photo_tasks'])}"
    )

    # Test 4: precision_map_fields 無 AI 結果
    result = await service.precision_map_fields(
        field_map=SAMPLE_FIELD_MAP[:4],  # 只有基本資訊
        inspection_results=SAMPLE_INSPECTION_RESULTS,
        photo_task_bindings=[],
    )
    results.check(
        result["success"] is True,
        "無 bindings 時仍回傳 success=True"
    )

    return results


async def test_unit_guessing():
    """測試單位推測"""
    print("\n" + "="*60)
    print("TEST: 單位推測 (_guess_unit)")
    print("="*60)

    results = TestResults()
    service = FormFillService()

    test_cases = [
        ("絕緣電阻 R相", "MΩ"),
        ("接地電阻", "Ω"),
        ("馬達溫度", "°C"),
        ("輸入電壓", "V"),
        ("運轉電流", "A"),
        ("振動值", "mm/s"),
        ("環境濕度", "%RH"),
        ("外觀檢查", ""),  # 非數值不應有單位
    ]

    for name, expected_unit in test_cases:
        actual = service._guess_unit(name)
        results.check(
            actual == expected_unit,
            f"「{name}」→ 單位 = '{expected_unit}'",
            f"實際: '{actual}'"
        )

    return results


# ============================================================
# 主程式
# ============================================================

async def main():
    print("="*60)
    print(f"Sprint 1 測試報告 — {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("="*60)

    all_results = []

    # 執行所有測試
    all_results.append(await test_generate_photo_tasks())
    all_results.append(await test_precision_map_fields())
    all_results.append(await test_edge_cases())
    all_results.append(await test_unit_guessing())

    # 總結
    total_passed = sum(r.passed for r in all_results)
    total_failed = sum(r.failed for r in all_results)
    total = total_passed + total_failed

    print("\n" + "="*60)
    print(f"Sprint 1 總結")
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
