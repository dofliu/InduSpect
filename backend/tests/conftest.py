"""
InduSpect AI — 測試共用設定

所有測試檔共用的前置設定和工具類別
"""

import sys
import os

# Windows 編碼修正
if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')

# 確保可以 import app 模組
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

# 設定測試環境變數
os.environ.setdefault("GEMINI_API_KEY", "test-key")


class TestResults:
    """統一的測試結果追蹤器"""

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
            msg = f"  ❌ {name}"
            if detail:
                msg += f" — {detail}"
            print(msg)
            self.errors.append(name)

        # Issue #45: pytest 下必須真的失敗，否則 CI 擋不住退化；
        # __main__ 手動模式維持彙總報告行為
        if os.environ.get("PYTEST_CURRENT_TEST"):
            assert condition, f"{name}: {detail}"
    def summary(self, section_name=""):
        total = self.passed + self.failed
        prefix = f"[{section_name}] " if section_name else ""
        print(f"\n{prefix}結果: {self.passed}/{total} 通過")
        if self.errors:
            print(f"失敗項目:")
            for e in self.errors:
                print(f"  - {e}")
        return self.failed == 0
