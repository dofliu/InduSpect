"""`scripts/blade_test_report.py` 的守門：測試報告裡的數字是它算的，它算錯報告就錯。"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "blade_test_report.py")


def _load():
    spec = importlib.util.spec_from_file_location("blade_test_report", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def m():
    return _load()


def _rec(id_, category, *, hub_ok=None, n_blades=3, ok=True, reasons=(), warnings=(),
         angles=(90.0, 210.0, 330.0), flagged=(), seconds=0.3, mask=0.05):
    return {
        "id": id_, "category": category, "hub_ok": hub_ok, "n_blades": n_blades,
        "failed": False, "seconds": seconds, "mask_area_frac": mask,
        "tip_angles_deg": list(angles), "comparison_flagged": list(flagged),
        "hub_err_px": 3.0 if hub_ok else 80.0,
        "verdict": {"ok": ok, "reasons": list(reasons), "warnings": list(warnings)},
    }


LABELS = {"images": {
    "aaa": {"category": "single", "sky": "clear"},
    "bbb": {"category": "single", "sky": "cloud"},
    "ccc": {"category": "multi", "sky": "clear"},
}}


def test_reason_bucket_collapses_numbers(m):
    a = m.reason_bucket("三片葉尖半徑差 39%（上限 15%）：同一台風機三片等長")
    b = m.reason_bucket("三片葉尖半徑差 115%（上限 15%）：同一台風機三片等長")
    assert a == b == "三片葉尖半徑差 N%（上限 N%）"
    assert m.reason_bucket("只定位到 2 片葉片（應為 3）：可能…") == "只定位到 N 片葉片（應為 N）"


def test_angular_gap_dev(m):
    assert m.angular_gap_dev([90, 210, 330]) == 0
    assert m.angular_gap_dev([0, 100, 200]) == pytest.approx(40)   # 100/100/160
    assert m.angular_gap_dev([350, 110, 230]) == 0                   # 跨 0° 也要對
    assert m.angular_gap_dev([10, 20]) is None
    assert m.angular_gap_dev(None) is None


def test_summarise_counts_hits_gates_and_false_accepts(m):
    res = {
        "aaa": _rec("aaa", "single", hub_ok=True, ok=True, flagged=["radius_px"], warnings=["畫面裡還有另一個轉子"]),
        "bbb": _rec("bbb", "single", hub_ok=False, n_blades=2, ok=False,
                    reasons=["只定位到 2 片葉片（應為 3）：…"], mask=0.0),
        "ccc": _rec("ccc", "multi", ok=True),   # 範圍外卻放行 = 誤放行，要被算出來
    }
    s = m.summarise(res, LABELS["images"])
    assert (s["single"], s["outside"]) == (2, 1)
    assert s["hub_ok"] == 1 and s["three_blades"] == 1 and s["empty_mask_single"] == 1
    assert s["accepted"] == 2 and s["accepted_hub_ok"] == 1
    assert s["accepted_outside"] == 1, "誤放行沒有被算出來"
    assert s["loud_fail_outside"] == 0
    assert s["second_rotor_warnings"] == 1
    assert s["by_sky"]["clear"] == {"n": 1, "hub_ok": 1, "three": 1, "accepted": 1}
    assert s["by_sky"]["cloud"] == {"n": 1, "hub_ok": 0, "three": 0, "accepted": 0}
    assert s["reject_reasons"] == {"只定位到 N 片葉片（應為 N）": 1}


def test_diff_against_reports_flips_only(m):
    base = {"aaa": _rec("aaa", "single", hub_ok=True), "bbb": _rec("bbb", "single", hub_ok=False, ok=False)}
    same = {k: json.loads(json.dumps(v)) for k, v in base.items()}
    assert m.diff_against(same, base) == []
    flipped = {k: json.loads(json.dumps(v)) for k, v in base.items()}
    flipped["bbb"]["hub_ok"] = True
    flipped["bbb"]["verdict"]["ok"] = True
    d = m.diff_against(flipped, base)
    assert ("bbb", "hub_ok", False, True) in d and ("bbb", "verdict.ok", False, True) in d
    assert not any(x[0] == "aaa" for x in d)
    assert m.diff_against({"zzz": _rec("zzz", "single")}, base)[0][1] == "baseline 缺此張"


def test_cli_renders_tables_and_zero_diffs(tmp_path):
    labels = tmp_path / "labels.json"
    labels.write_text(json.dumps(LABELS, ensure_ascii=False), encoding="utf-8")
    res = [_rec("aaa", "single", hub_ok=True), _rec("bbb", "single", hub_ok=False, n_blades=2, ok=False,
                                                    reasons=["只定位到 2 片葉片（應為 3）：…"]),
           _rec("ccc", "multi", n_blades=1, ok=False, reasons=["只定位到 1 片葉片（應為 3）：…"])]
    for name in ("after", "base"):
        d = tmp_path / name
        d.mkdir()
        (d / "results.json").write_text(json.dumps(res, ensure_ascii=False), encoding="utf-8")
    out_json = tmp_path / "summary.json"
    p = subprocess.run([sys.executable, SCRIPT, "--after", str(tmp_path / "after"), "--baseline", str(tmp_path / "base"),
                        "--labels", str(labels), "--json", str(out_json)],
                       capture_output=True, text=True, check=True)
    assert "| 輪轂命中（誤差 ≤ 對角線 5%） | 1/2 |" in p.stdout
    assert "| 閘門誤放行（範圍外卻放行） | 0 / 1 |" in p.stdout
    assert "有差異的欄位 **0** 個" in p.stdout
    summ = json.loads(out_json.read_text(encoding="utf-8"))["summary"]
    assert summ["hub_ok"] == 1 and summ["baseline_diffs"] == []
