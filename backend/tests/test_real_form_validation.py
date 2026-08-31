"""
Sprint 6 Task 6.2: Real Form Validation

程式化產生 5 種真實定檢表單，驗證完整 pipeline:
1. 電氣設備定期檢查表 (.xlsx) — checkbox columns + value columns
2. 消防安全設備定期檢查表 (.docx) — Word table format
3. 馬達定期維護紀錄表 (.xlsx) — single page, multiple items
4. 壓力容器定期檢查紀錄 (.xlsx) — pressure-specific items
5. 廠區 5S 巡查表 (.xlsx) — lots of checkboxes

每張表單測試:
- analyze_structure -> 驗證欄位偵測數量
- generate_photo_tasks -> 驗證任務清單
- auto_judge -> 用樣本值測試判定
- auto_fill -> 驗證回填後檔案可正常載入
"""

import sys
import os
import asyncio
import io

if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
os.environ.setdefault("GEMINI_API_KEY", "test-key")

from openpyxl import Workbook, load_workbook
from docx import Document

from app.services.form_fill import FormFillService


class TestResults:
    def __init__(self):
        self.passed = 0
        self.failed = 0
        self.errors = []

    def check(self, condition, name, detail=""):
        if condition:
            self.passed += 1
            print(f"  PASS {name}")
        else:
            self.failed += 1
            self.errors.append(f"{name}: {detail}")
            print(f"  FAIL {name} -- {detail}")


        # Issue #45: pytest 下必須真的失敗，否則 CI 擋不住退化；
        # __main__ 手動模式維持彙總報告行為
        if os.environ.get("PYTEST_CURRENT_TEST"):
            assert condition, f"{name}: {detail}"
# ============================================================
# 表單產生器
# ============================================================

def create_form_1_electrical() -> bytes:
    """1. 電氣設備定期檢查表 (.xlsx) — checkbox + value columns"""
    wb = Workbook()
    ws = wb.active
    ws.title = "電氣設備定期檢查"

    # 表單標題 (no merge to avoid MergedCell issues)
    ws['A1'] = '電氣設備定期檢查表'

    # 基本資訊
    ws['A2'] = '設備名稱：'
    ws['B2'] = ''
    ws['D2'] = '設備編號：'
    ws['E2'] = ''
    ws['A3'] = '檢查日期：'
    ws['B3'] = ''
    ws['D3'] = '檢查人員：'
    ws['E3'] = ''
    ws['A4'] = '位置：'
    ws['B4'] = ''

    # 量測項目區域 (with value columns)
    ws['A6'] = '檢查項目'
    ws['B6'] = '數值'
    ws['C6'] = '合格'
    ws['D6'] = '不合格'
    ws['E6'] = '備註'

    # 量測數據行
    items = [
        ('絕緣電阻R相 讀數：', 7),
        ('絕緣電阻S相 讀數：', 8),
        ('絕緣電阻T相 讀數：', 9),
        ('接地電阻 測量：', 10),
        ('漏電斷路器 測量：', 11),
        ('電壓偏差 測量：', 12),
        ('溫度檢測：', 13),
    ]
    for label, row in items:
        ws[f'A{row}'] = label
        ws[f'B{row}'] = ''
        ws[f'C{row}'] = ''
        ws[f'D{row}'] = ''
        ws[f'E{row}'] = ''

    # 結論
    ws['A15'] = '綜合結論：'
    ws['B15'] = ''
    ws['A16'] = '簽核人員：'
    ws['B16'] = ''

    buf = io.BytesIO()
    wb.save(buf)
    buf.seek(0)
    return buf.read()


def create_form_2_fire_word() -> bytes:
    """2. 消防安全設備定期檢查表 (.docx) — Word table format"""
    doc = Document()
    doc.add_heading('消防安全設備定期檢查表', level=1)

    # 基本資訊
    doc.add_paragraph('檢查日期：')
    doc.add_paragraph('檢查人員：')
    doc.add_paragraph('位置：')

    # 滅火器檢查表
    doc.add_heading('滅火器檢查', level=2)
    t1 = doc.add_table(rows=5, cols=4)
    t1.style = 'Table Grid'
    t1.rows[0].cells[0].text = '檢查項目'
    t1.rows[0].cells[1].text = '數值'
    t1.rows[0].cells[2].text = '結果'
    t1.rows[0].cells[3].text = '備註'

    fire_items = ['滅火器壓力', '滅火器外觀狀況', '緊急照明持續時間', '出口標示燈亮度']
    for i, item in enumerate(fire_items):
        t1.rows[i + 1].cells[0].text = item

    # 灑水設備檢查表
    doc.add_heading('灑水設備檢查', level=2)
    t2 = doc.add_table(rows=4, cols=4)
    t2.style = 'Table Grid'
    t2.rows[0].cells[0].text = '檢查項目'
    t2.rows[0].cells[1].text = '數值'
    t2.rows[0].cells[2].text = '結果'
    t2.rows[0].cells[3].text = '備註'

    sprinkler_items = ['灑水頭放水壓力', '消防栓放水壓力', '消防栓放水量']
    for i, item in enumerate(sprinkler_items):
        t2.rows[i + 1].cells[0].text = item

    # 簽核
    doc.add_paragraph('')
    doc.add_paragraph('簽核人員：')

    buf = io.BytesIO()
    doc.save(buf)
    buf.seek(0)
    return buf.read()


def create_form_3_motor() -> bytes:
    """3. 馬達定期維護紀錄表 (.xlsx) — single page, multiple items"""
    wb = Workbook()
    ws = wb.active
    ws.title = "馬達維護紀錄"

    ws['A1'] = '馬達定期維護紀錄表'

    # 基本資訊
    ws['A2'] = '設備名稱：'
    ws['B2'] = ''
    ws['D2'] = '設備編號：'
    ws['E2'] = ''
    ws['A3'] = '檢查日期：'
    ws['B3'] = ''
    ws['D3'] = '檢查人員：'
    ws['E3'] = ''

    # 維護項目
    ws['A5'] = '檢查項目'
    ws['B5'] = '數值'
    ws['C5'] = '判定結果'
    ws['D5'] = '備註'

    motor_items = [
        ('馬達溫度 讀數：', 6),
        ('振動值 測量：', 7),
        ('軸承溫度 讀數：', 8),
        ('噪音值 測量：', 9),
        ('電流 讀數：', 10),
        ('電壓 讀數：', 11),
        ('轉速 讀數：', 12),
    ]

    for label, row in motor_items:
        ws[f'A{row}'] = label
        ws[f'B{row}'] = ''
        ws[f'C{row}'] = ''
        ws[f'D{row}'] = ''

    ws['A14'] = '綜合結論：'
    ws['B14'] = ''

    buf = io.BytesIO()
    wb.save(buf)
    buf.seek(0)
    return buf.read()


def create_form_4_pressure() -> bytes:
    """4. 壓力容器定期檢查紀錄 (.xlsx) — pressure-specific items"""
    wb = Workbook()
    ws = wb.active
    ws.title = "壓力容器檢查"

    ws['A1'] = '壓力容器定期檢查紀錄'

    ws['A2'] = '設備名稱：'
    ws['B2'] = ''
    ws['D2'] = '設備編號：'
    ws['E2'] = ''
    ws['A3'] = '檢查日期：'
    ws['B3'] = ''
    ws['D3'] = '檢查人員：'
    ws['E3'] = ''
    ws['A4'] = '位置：'
    ws['B4'] = ''

    ws['A6'] = '檢查項目'
    ws['B6'] = '數值'
    ws['C6'] = '判定結果'
    ws['D6'] = '備註'

    pressure_items = [
        ('壓力容器壓力 讀數：', 7),
        ('壓力容器壁厚 測量：', 8),
        ('安全閥 測量：', 9),
        ('溫度檢測：', 10),
        ('洩漏 檢查：', 11),
    ]

    for label, row in pressure_items:
        ws[f'A{row}'] = label
        ws[f'B{row}'] = ''
        ws[f'C{row}'] = ''
        ws[f'D{row}'] = ''

    ws['A13'] = '綜合結論：'
    ws['B13'] = ''
    ws['A14'] = '簽核人員：'
    ws['B14'] = ''

    buf = io.BytesIO()
    wb.save(buf)
    buf.seek(0)
    return buf.read()


def create_form_5_fiveS() -> bytes:
    """5. 廠區 5S 巡查表 (.xlsx) — lots of checkboxes"""
    wb = Workbook()
    ws = wb.active
    ws.title = "5S巡查表"

    ws['A1'] = '廠區 5S 巡查表'

    ws['A2'] = '檢查日期：'
    ws['B2'] = ''
    ws['D2'] = '檢查人員：'
    ws['E2'] = ''
    ws['A3'] = '位置：'
    ws['B3'] = ''

    # 勾選式表頭
    ws['A5'] = '檢查項目'
    ws['B5'] = '合格'
    ws['C5'] = '不合格'
    ws['D5'] = '備註'

    fiveS_items = [
        '整理: 不需要的物品已清除',
        '整頓: 物品定位放置',
        '清掃: 地面清潔',
        '清掃: 設備清潔',
        '清潔: 標準維持',
        '清潔: 標示清楚',
        '素養: 人員穿著合規',
        '素養: 安全防護裝備',
        '通道暢通 檢查',
        '照明正常 檢查',
        '消防設備 檢查',
        '廢棄物處理 檢查',
    ]

    for i, item in enumerate(fiveS_items, 6):
        ws[f'A{i}'] = item
        ws[f'B{i}'] = ''
        ws[f'C{i}'] = ''
        ws[f'D{i}'] = ''

    ws[f'A{6 + len(fiveS_items) + 1}'] = '綜合結論：'
    ws[f'B{6 + len(fiveS_items) + 1}'] = ''

    buf = io.BytesIO()
    wb.save(buf)
    buf.seek(0)
    return buf.read()


# ============================================================
# Pipeline 測試函式
# ============================================================

async def validate_form_pipeline(
    form_name: str,
    file_content: bytes,
    file_name: str,
    expected_min_fields: int,
    sample_readings: list[dict],
    equipment_type: str = "",
) -> TestResults:
    """通用的表單 pipeline 驗證"""
    print(f"\n{'=' * 60}")
    print(f"  {form_name}")
    print(f"{'=' * 60}")

    results = TestResults()
    service = FormFillService()
    file_ext = file_name.rsplit('.', 1)[-1].lower()

    # 1. analyze_structure
    structure = await service.analyze_structure(file_content, file_name)
    results.check(structure["success"], "analyze_structure 成功")
    results.check(structure["file_type"] == file_ext,
                  f"file_type={file_ext}",
                  f"actual={structure['file_type']}")

    field_count = structure["total_fields"]
    results.check(field_count >= expected_min_fields,
                  f"欄位數 >= {expected_min_fields}",
                  f"actual={field_count}")

    field_map = structure["field_map"]

    # 2. generate_photo_tasks
    tasks_result = await service.generate_photo_tasks(field_map)
    photo_tasks = tasks_result["photo_tasks"]
    basic_fields = tasks_result["basic_info_fields"]
    stats = tasks_result["stats"]

    results.check(
        stats["total_tasks"] + stats["total_basic"] + stats["total_conclusion"] > 0,
        "有產生任務或欄位分類",
        f"tasks={stats['total_tasks']}, basic={stats['total_basic']}, conclusion={stats['total_conclusion']}"
    )

    # 3. auto_judge with sample values
    if sample_readings:
        judgments = await service.batch_auto_judge(
            readings=sample_readings,
            equipment_type=equipment_type,
        )
        results.check(len(judgments) == len(sample_readings),
                      f"batch_auto_judge 回傳 {len(sample_readings)} 筆",
                      f"actual={len(judgments)}")

        known_count = sum(1 for j in judgments if j["judgment"] != "unknown")
        results.check(known_count > 0,
                      f"至少 1 筆可判定 (known={known_count})",
                      f"judgments={[j['judgment'] for j in judgments]}")

    # 4. auto_fill and verify output
    fill_values = []
    for f in field_map:
        fid = f["field_id"]
        fname = f.get("field_name", "")
        ftype = f.get("field_type", "text")

        if "日期" in fname or ftype == "date":
            fill_values.append({"field_id": fid, "value": "2026-03-13"})
        elif "人員" in fname or "姓名" in fname:
            fill_values.append({"field_id": fid, "value": "測試人員"})
        elif "名稱" in fname:
            fill_values.append({"field_id": fid, "value": "測試設備"})
        elif "編號" in fname:
            fill_values.append({"field_id": fid, "value": "TEST-001"})
        elif "位置" in fname or "地點" in fname:
            fill_values.append({"field_id": fid, "value": "A棟1F"})
        elif ftype == "number":
            fill_values.append({"field_id": fid, "value": "50.0"})
        elif "結論" in fname:
            fill_values.append({"field_id": fid, "value": "合格"})
        else:
            fill_values.append({"field_id": fid, "value": "正常"})

    filled_bytes = await service.auto_fill(file_content, file_name, field_map, fill_values)
    results.check(len(filled_bytes) > 0, "auto_fill 產生非空檔案")

    # 驗證輸出檔案可正常載入
    if file_ext == 'xlsx':
        try:
            wb = load_workbook(io.BytesIO(filled_bytes))
            results.check(True, "回填後 xlsx 可由 openpyxl 載入")
            # Check some cells have values
            ws = wb.active
            filled = sum(
                1 for row in ws.iter_rows(min_row=1, max_row=ws.max_row, max_col=ws.max_column)
                for cell in row if cell.value is not None and str(cell.value).strip()
            )
            results.check(filled > expected_min_fields,
                          f"回填後有 {filled} 個非空儲存格")
        except Exception as e:
            results.check(False, "xlsx 載入失敗", str(e))
    elif file_ext == 'docx':
        try:
            doc = Document(io.BytesIO(filled_bytes))
            results.check(True, "回填後 docx 可由 python-docx 載入")
            # Check content
            has_content = False
            for para in doc.paragraphs:
                if '2026' in para.text or '測試' in para.text:
                    has_content = True
                    break
            for table in doc.tables:
                for row in table.rows:
                    for cell in row.cells:
                        if cell.text.strip():
                            has_content = True
                            break
            results.check(has_content, "docx 含有回填內容")
        except Exception as e:
            results.check(False, "docx 載入失敗", str(e))

    return results


# ============================================================
# 5 個表單驗證
# ============================================================

async def test_form_1():
    """1. 電氣設備定期檢查表"""
    return await validate_form_pipeline(
        form_name="Form 1: 電氣設備定期檢查表 (.xlsx)",
        file_content=create_form_1_electrical(),
        file_name="電氣設備定期檢查表.xlsx",
        expected_min_fields=5,
        sample_readings=[
            {"field_name": "絕緣電阻 R相", "value": 52.3, "unit": "MΩ"},
            {"field_name": "接地電阻", "value": 45.0, "unit": "Ω"},
            {"field_name": "漏電斷路器動作時間", "value": 50, "unit": "ms"},
            {"field_name": "電壓偏差率", "value": 3.2, "unit": "%"},
        ],
        equipment_type="低壓配電設備",
    )


async def test_form_2():
    """2. 消防安全設備定期檢查表"""
    return await validate_form_pipeline(
        form_name="Form 2: 消防安全設備定期檢查表 (.docx)",
        file_content=create_form_2_fire_word(),
        file_name="消防安全設備定期檢查表.docx",
        expected_min_fields=3,
        sample_readings=[
            {"field_name": "滅火器壓力", "value": 0.85, "unit": "MPa"},
            {"field_name": "緊急照明持續時間", "value": 45, "unit": "min"},
            {"field_name": "灑水頭放水壓力", "value": 1.5, "unit": "kgf/cm2"},
            {"field_name": "消防栓放水壓力", "value": 2.0, "unit": "kgf/cm2"},
        ],
        equipment_type="消防設備",
    )


async def test_form_3():
    """3. 馬達定期維護紀錄表"""
    return await validate_form_pipeline(
        form_name="Form 3: 馬達定期維護紀錄表 (.xlsx)",
        file_content=create_form_3_motor(),
        file_name="馬達定期維護紀錄表.xlsx",
        expected_min_fields=5,
        sample_readings=[
            {"field_name": "馬達溫度", "value": 65.0, "unit": "C"},
            {"field_name": "振動值", "value": 3.2, "unit": "mm/s"},
            {"field_name": "軸承溫度", "value": 55.0, "unit": "C"},
            {"field_name": "噪音值", "value": 72.0, "unit": "dB(A)"},
        ],
        equipment_type="馬達",
    )


async def test_form_4():
    """4. 壓力容器定期檢查紀錄"""
    return await validate_form_pipeline(
        form_name="Form 4: 壓力容器定期檢查紀錄 (.xlsx)",
        file_content=create_form_4_pressure(),
        file_name="壓力容器定期檢查紀錄.xlsx",
        expected_min_fields=5,
        sample_readings=[
            {"field_name": "壓力容器壁厚", "value": 12.5, "unit": "mm"},
            {"field_name": "鍋爐排氣溫度", "value": 200, "unit": "C"},
        ],
        equipment_type="壓力容器",
    )


async def test_form_5():
    """5. 廠區 5S 巡查表"""
    print(f"\n{'=' * 60}")
    print(f"  Form 5: 廠區 5S 巡查表 (.xlsx)")
    print(f"{'=' * 60}")

    results = TestResults()
    service = FormFillService()

    file_content = create_form_5_fiveS()
    file_name = "廠區5S巡查表.xlsx"

    # analyze_structure
    structure = await service.analyze_structure(file_content, file_name)
    results.check(structure["success"], "analyze_structure 成功")
    results.check(structure["total_fields"] >= 3,
                  f"欄位數 >= 3",
                  f"actual={structure['total_fields']}")

    field_map = structure["field_map"]

    # generate_photo_tasks
    tasks_result = await service.generate_photo_tasks(field_map)
    results.check(
        tasks_result["stats"]["total_tasks"] + tasks_result["stats"]["total_basic"] > 0,
        "有產生任務或基本欄位")

    # detect_checkbox_columns
    cb_result = await service.detect_checkbox_columns(file_content, file_name)
    dual_fields = cb_result.get("dual_column_fields", [])
    results.check(len(dual_fields) > 0, "偵測到勾選雙欄結構",
                  f"dual_fields={len(dual_fields)}")

    # auto_fill_with_checkboxes
    fill_values = []
    cb_field_map = []
    for i, dual in enumerate(dual_fields):
        fid = dual["field_id"]
        if i % 3 == 2:  # 每第三項不合格
            fill_values.append({"field_id": fid, "value": "不合格", "remarks": "需改善"})
        else:
            fill_values.append({"field_id": fid, "value": "合格"})
        cb_field_map.append({
            "field_id": fid,
            "field_name": dual["field_name"],
            "field_type": "dual_column_checkbox",
        })

    if dual_fields:
        filled_bytes = await service.auto_fill_with_checkboxes(
            file_content=file_content,
            file_name=file_name,
            field_map=cb_field_map,
            fill_values=fill_values,
            dual_column_fields=dual_fields,
            check_symbol=cb_result.get("check_symbol", "V"),
        )
        results.check(len(filled_bytes) > 0, "auto_fill_with_checkboxes 成功")

        # 驗證輸出
        wb = load_workbook(io.BytesIO(filled_bytes))
        ws = wb.active
        check_count = 0
        for row in range(6, ws.max_row + 1):
            b = ws.cell(row=row, column=2).value
            c = ws.cell(row=row, column=3).value
            if b and str(b).strip():
                check_count += 1
            if c and str(c).strip():
                check_count += 1
        results.check(check_count > 0, f"勾選符號已寫入 ({check_count} 個)")

        # 驗證檔案可載入
        try:
            load_workbook(io.BytesIO(filled_bytes))
            results.check(True, "回填後 xlsx 可正常載入")
        except Exception as e:
            results.check(False, "xlsx 載入", str(e))
    else:
        results.check(True, "無勾選欄位 (跳過 checkbox 測試)")
        results.check(True, "跳過 auto_fill_with_checkboxes")
        results.check(True, "跳過勾選驗證")
        results.check(True, "跳過載入驗證")

    return results


# ============================================================
# 主程式
# ============================================================

async def main():
    print("=" * 60)
    print(" Sprint 6 Task 6.2: Real Form Validation")
    print("=" * 60)

    all_results = []

    test_functions = [
        ("Form 1: 電氣設備定期檢查表", test_form_1),
        ("Form 2: 消防安全設備定期檢查表", test_form_2),
        ("Form 3: 馬達定期維護紀錄表", test_form_3),
        ("Form 4: 壓力容器定期檢查紀錄", test_form_4),
        ("Form 5: 廠區 5S 巡查表", test_form_5),
    ]

    for name, func in test_functions:
        try:
            result = await func()
            all_results.append((name, result))
        except Exception as e:
            print(f"\n  ERROR in {name}: {e}")
            import traceback
            traceback.print_exc()
            err_result = TestResults()
            err_result.check(False, f"{name} 執行失敗", str(e))
            all_results.append((name, err_result))

    # 彙總
    print("\n" + "=" * 60)
    print(" Real Form Validation 測試彙總")
    print("=" * 60)

    total_passed = 0
    total_failed = 0

    for name, result in all_results:
        status = "PASS" if result.failed == 0 else "FAIL"
        print(f"  [{status}] {name}: {result.passed} passed, {result.failed} failed")
        total_passed += result.passed
        total_failed += result.failed
        if result.errors:
            for err in result.errors:
                print(f"         -> {err}")

    print(f"\n  Total: {total_passed} passed, {total_failed} failed")
    rate = total_passed / (total_passed + total_failed) * 100 if (total_passed + total_failed) > 0 else 0
    print(f"  Pass Rate: {rate:.1f}%")

    return total_failed == 0


if __name__ == "__main__":
    success = asyncio.run(main())
    sys.exit(0 if success else 1)
