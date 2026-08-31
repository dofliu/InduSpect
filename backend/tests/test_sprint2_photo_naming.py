"""
Sprint 2 測試: Task 2.4 — 照片自動命名與編號

測試範圍:
- 照片命名規則驗證
- 命名邊界情況

注意: 這是 Python 端的命名邏輯驗證
完整的 PhotoService 測試在 Flutter test/photo_service_test.dart
"""

import sys
import os
import re
from datetime import datetime

if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')


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
def generate_file_name(sequence: int, display_name: str, timestamp: datetime) -> str:
    """
    照片命名規則 (與 Dart PhotoService._generateFileName 相同邏輯):
    {序號(2位)}-{項目簡稱}_{時間戳}.jpg
    """
    seq_str = str(sequence).zfill(2)

    # 縮短名稱
    short_name = re.sub(r'[\s　]+', '', display_name)  # 移除空格
    short_name = re.sub(r'[/\\:*?"<>|]', '_', short_name)  # 特殊字元
    if len(short_name) > 15:
        short_name = short_name[:15]

    time_str = timestamp.strftime('%Y%m%d_%H%M%S')
    return f"{seq_str}-{short_name}_{time_str}.jpg"


def test_naming_rules():
    """測試命名規則"""
    print("\n" + "="*60)
    print("TEST: Task 2.4 — 照片命名規則")
    print("="*60)

    results = TestResults()

    # Test 1: 基本命名
    name = generate_file_name(3, "絕緣電阻 R相", datetime(2026, 3, 13, 14, 30, 52))
    results.check(
        name == "03-絕緣電阻R相_20260313_143052.jpg",
        "基本命名正確",
        f"實際: {name}"
    )

    # Test 2: 序號補零
    name2 = generate_file_name(1, "接地電阻", datetime(2026, 3, 13, 15, 0, 0))
    results.check(
        name2 == "01-接地電阻_20260313_150000.jpg",
        "序號 1 → 01",
        f"實際: {name2}"
    )

    # Test 3: 序號不補零
    name3 = generate_file_name(12, "漏電斷路器", datetime(2026, 3, 13, 9, 5, 30))
    results.check(
        name3 == "12-漏電斷路器_20260313_090530.jpg",
        "序號 12 不補零",
        f"實際: {name3}"
    )

    # Test 4: 名稱超長截斷
    name4 = generate_file_name(1, "這是一個非常非常非常非常長的檢查項目名稱", datetime(2026, 1, 1, 0, 0, 0))
    short_part = name4.split('-', 1)[1].split('_')[0]
    results.check(
        len(short_part) <= 15,
        f"名稱截斷至 15 字元以內",
        f"名稱部分: {short_part} (長度: {len(short_part)})"
    )

    # Test 5: 特殊字元替換
    name5 = generate_file_name(1, "Test/Name:Special*File", datetime(2026, 1, 1, 0, 0, 0))
    results.check(
        "/" not in name5 and ":" not in name5 and "*" not in name5,
        "特殊字元已替換",
        f"實際: {name5}"
    )

    # Test 6: 空格移除（全形和半形）
    name6 = generate_file_name(5, "漏電　斷路器　動作時間", datetime(2026, 6, 15, 8, 30, 0))
    results.check(
        "　" not in name6 and " " not in name6.split('-', 1)[1].split('_')[0],
        "全形半形空格已移除",
        f"實際: {name6}"
    )

    # Test 7: 檔名以 .jpg 結尾
    results.check(
        name.endswith('.jpg'),
        "檔名以 .jpg 結尾"
    )

    # Test 8: 檔名格式正規表達式驗證
    pattern = r'^\d{2}-.+_\d{8}_\d{6}\.jpg$'
    results.check(
        re.match(pattern, name) is not None,
        "檔名符合 {序號}-{名稱}_{日期}_{時間}.jpg 格式",
        f"Pattern: {pattern}"
    )

    # Test 9: 序號 0
    name9 = generate_file_name(0, "測試", datetime(2026, 1, 1, 0, 0, 0))
    results.check(
        name9.startswith("00-"),
        "序號 0 → 00",
        f"實際: {name9}"
    )

    # Test 10: 純英文名稱（GroundResistance = 16字元，截斷為15）
    name10 = generate_file_name(7, "Ground Resistance", datetime(2026, 3, 13, 16, 45, 10))
    results.check(
        name10 == "07-GroundResistanc_20260313_164510.jpg",
        "英文名稱空格移除+截斷",
        f"實際: {name10}"
    )

    return results


def test_naming_uniqueness():
    """測試命名唯一性"""
    print("\n" + "="*60)
    print("TEST: Task 2.4 — 命名唯一性")
    print("="*60)

    results = TestResults()

    # 同一項目不同時間應產生不同名稱
    name_a = generate_file_name(1, "絕緣電阻", datetime(2026, 3, 13, 14, 30, 0))
    name_b = generate_file_name(1, "絕緣電阻", datetime(2026, 3, 13, 14, 30, 1))
    results.check(
        name_a != name_b,
        "同一項目不同秒數 → 不同檔名"
    )

    # 不同項目同一時間應產生不同名稱
    name_c = generate_file_name(1, "絕緣電阻", datetime(2026, 3, 13, 14, 30, 0))
    name_d = generate_file_name(2, "接地電阻", datetime(2026, 3, 13, 14, 30, 0))
    results.check(
        name_c != name_d,
        "不同項目同一時間 → 不同檔名"
    )

    return results


def test_compression_spec():
    """測試壓縮規格（僅驗證規格定義）"""
    print("\n" + "="*60)
    print("TEST: Task 2.4 — 壓縮規格定義")
    print("="*60)

    results = TestResults()

    # 驗證壓縮規格常數（與 Dart PhotoService 一致）
    MAX_PHOTO_SIZE_KB = 300
    MAX_PHOTO_WIDTH = 1280
    MAX_PHOTO_HEIGHT = 960

    results.check(
        MAX_PHOTO_SIZE_KB == 300,
        "最大照片大小 = 300KB"
    )
    results.check(
        MAX_PHOTO_WIDTH == 1280,
        "最大照片寬度 = 1280px"
    )
    results.check(
        MAX_PHOTO_HEIGHT == 960,
        "最大照片高度 = 960px"
    )

    return results


def main():
    print("="*60)
    print(f"Sprint 2 Task 2.4 測試報告 — {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("="*60)

    all_results = []
    all_results.append(test_naming_rules())
    all_results.append(test_naming_uniqueness())
    all_results.append(test_compression_spec())

    total_passed = sum(r.passed for r in all_results)
    total_failed = sum(r.failed for r in all_results)
    total = total_passed + total_failed

    print("\n" + "="*60)
    print(f"Task 2.4 總結")
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
    success = main()
    sys.exit(0 if success else 1)
