"""
將 inspection_standards.py 匯出為 JSON — 法規標準資料的單一來源機制

用途：
    Python 檔（backend/app/data/inspection_standards.py）為「編輯來源」，
    本腳本產生的 JSON 為「發布产物」，內嵌到 Flutter App 作離線判定
    （Tier 0，見 LAUNCH_PLAN.md §5.3）。

    tests/test_standards_json_sync.py 會驗證兩者一致 —
    修改標準後必須重跑本腳本，否則 CI 擋下。

執行：
    cd backend && python scripts/export_standards.py
"""

import json
import sys
from datetime import date
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = BACKEND_DIR.parent
OUTPUT_PATH = REPO_ROOT / "flutter_app" / "assets" / "standards" / "inspection_standards.json"

sys.path.insert(0, str(BACKEND_DIR))

from app.data.inspection_standards import ALL_STANDARDS  # noqa: E402


def main() -> None:
    categories: dict[str, int] = {}
    for s in ALL_STANDARDS:
        categories[s["category"]] = categories.get(s["category"], 0) + 1

    payload = {
        # 版本 = 匯出日 + 條數，App 端可據此顯示資料庫版本
        "version": f"{date.today().isoformat()}+{len(ALL_STANDARDS)}",
        "total": len(ALL_STANDARDS),
        "categories": categories,
        "standards": ALL_STANDARDS,
    }

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"已匯出 {len(ALL_STANDARDS)} 條標準 → {OUTPUT_PATH}")
    print(f"分類統計: {categories}")


if __name__ == "__main__":
    main()
