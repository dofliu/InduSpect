"""Mode B 分類表的守門測試。

這份表同時是標註指引與知識庫種子（見 `BLADE_CLOSEUP_TAXONOMY.md` 開頭），
所以它的內部一致性不是格式問題而是內容問題：`confused_with` 指到不存在的子類，
標註者就查不到「那我該怎麼分辨」，而那正是這張表存在的理由。
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "blade_prototype" / "data" / "closeup_taxonomy.json"
RENDER = ROOT / "blade_prototype" / "scripts" / "render_closeup_taxonomy.py"
MD = ROOT / "BLADE_CLOSEUP_TAXONOMY.md"


@pytest.fixture(scope="module")
def tax() -> dict:
    return json.loads(DATA.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def refs(tax: dict) -> set[str]:
    """所有可被 confused_with 指到的識別字。"""
    out = set()
    for c in tax["classes"]:
        out.add(c["id"])
        for s in c["subclasses"]:
            out.add(f"{c['id']}/{s['id']}")
    for n in tax["normal_structures"]:
        out.add(f"normal_structures/{n['id']}")
    return out


def test_four_mechanism_classes(tax: dict) -> None:
    """四類是與基線論文對照的基礎（規格 §3.1），不能隨手增刪。"""
    assert [c["id"] for c in tax["classes"]] == ["healthy", "surface", "environmental", "structural"]


def test_ids_unique(tax: dict) -> None:
    ids = [f"{c['id']}/{s['id']}" for c in tax["classes"] for s in c["subclasses"]]
    assert len(ids) == len(set(ids))
    n_ids = [n["id"] for n in tax["normal_structures"]]
    assert len(n_ids) == len(set(n_ids))


def test_confused_with_resolves(tax: dict, refs: set[str]) -> None:
    """易混淆對照要指得到，否則標註者查不到分辨方法。"""
    bad = []
    for c in tax["classes"]:
        for s in c["subclasses"]:
            bad += [(f"{c['id']}/{s['id']}", x) for x in s["confused_with"] if x not in refs]
    for n in tax["normal_structures"]:
        bad += [(f"normal_structures/{n['id']}", x) for x in n["confused_with"] if x not in refs]
    assert not bad, f"confused_with 指到不存在的項目：{bad}"


def test_confusion_is_symmetric(tax: dict) -> None:
    """A 說會跟 B 混淆，B 也要說會跟 A 混淆。

    不對稱的話標註者從其中一邊查就查不到另一邊，等於那條提示只有一半的人看得到。
    """
    pairs: dict[str, set[str]] = {}
    for c in tax["classes"]:
        for s in c["subclasses"]:
            pairs[f"{c['id']}/{s['id']}"] = set(s["confused_with"])
    for n in tax["normal_structures"]:
        pairs[f"normal_structures/{n['id']}"] = set(n["confused_with"])
    missing = [(a, b) for a, bs in pairs.items() for b in bs if a not in pairs.get(b, set())]
    assert not missing, f"單向的易混淆對照（要補反向）：{missing}"


def test_defect_subclasses_declare_resolution(tax: dict) -> None:
    """每個損傷子類都要說「多細才看得到」。

    規格 §9.4 規定沒有尺度不得報面積等級；要判斷手上的照片夠不夠細，
    得先知道這一類的門檻。留空等於那條約定沒有執行依據。
    """
    for c in tax["classes"]:
        for s in c["subclasses"]:
            if s["is_defect"]:
                assert isinstance(s["min_cm_per_px"], (int, float)), f"{c['id']}/{s['id']} 缺 min_cm_per_px"


def test_structural_subclasses_have_geometric_rule(tax: dict) -> None:
    """§5.3 的消融：structural 類只用影像檢索時 F1 = 0.000，一定要有文字的幾何規則。"""
    st = next(c for c in tax["classes"] if c["id"] == "structural")
    for s in st["subclasses"]:
        assert len(s["geometric_rule"]) >= 10, f"structural/{s['id']} 的幾何規則太空泛"


def test_level_zero_marked_undetectable(tax: dict) -> None:
    """IEA Level 0（針孔 < 1 mm）在合規取像條件下做不到（規格 §2.2），不可標成可偵測。"""
    lv0 = next(l for l in tax["severity_scales"]["iea_task46"]["levels"] if l["level"] == 0)
    assert lv0["detectable"] is False


def test_unverified_iea_levels_are_marked(tax: dict) -> None:
    """Level 3–5 的門檻尚未從 IEA 原文核對，判準欄必須明寫待核對。

    安全分級的門檻不可以憑印象填；這條測試擋的是「先寫個大概之後再說」。
    核對完成後把判準改成原文內容，這條測試自然會要求同步更新。
    """
    for lv in tax["severity_scales"]["iea_task46"]["levels"]:
        if lv["level"] >= 3:
            assert "核對" in lv["criterion"], f"Level {lv['level']} 的判準看起來已填但未標示來源核對狀態"


def test_decision_rules_ordered(tax: dict) -> None:
    assert [r["order"] for r in tax["decision_rules"]] == list(range(1, len(tax["decision_rules"]) + 1))


def test_split_keys_required(tax: dict) -> None:
    """§6.1「按葉片切不按照片切」靠必填欄位執行，不是靠記得。"""
    req = tax["record_schema"]["required"]
    assert "blade_id" in req and "flight_id" in req


def test_markdown_in_sync() -> None:
    """markdown 是產物，與 JSON 漂開就紅（做法同 backend/scripts/export_standards.py）。"""
    r = subprocess.run([sys.executable, str(RENDER), "--check"], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr or r.stdout
    assert MD.exists()


# --- 開放網路語料的判定檔（CLOSEUP_BASELINE_REPORT.md §3 的來源） -----------

TRIAGE = ROOT / "blade_prototype" / "data" / "closeup_triage.json"


@pytest.fixture(scope="module")
def triage() -> dict:
    return json.loads(TRIAGE.read_text(encoding="utf-8"))


def test_triage_complete_and_unique(triage: dict) -> None:
    recs = triage["records"]
    assert len(recs) == 200
    assert len({r["idx"] for r in recs}) == len(recs)
    assert len({r["file"] for r in recs}) == len(recs)
    assert all(r["triage"] in triage["labels"] for r in recs), "有判定不在 labels 說明裡"


def test_triage_licences_are_free(triage: dict) -> None:
    """NC / ND 的不得進語料（報告 §2：混進訓練資料整個模型就不能出貨）。"""
    bad = [r["idx"] for r in triage["records"]
           if any(k in r["licence"].lower().replace(" ", "-") for k in ("-nc", "-nd"))]
    assert not bad, f"非自由授權的影像：{bad}"


def test_triage_keeps_provenance(triage: dict) -> None:
    """影像不進版控，所以出處必須留在判定檔裡，否則數字無從追溯。"""
    for r in triage["records"]:
        assert r["landing"].startswith("http"), f"#{r['idx']} 沒有出處連結"
        assert r["licence"], f"#{r['idx']} 沒有授權"


def test_mode_a_gate_rejects_everything_out_of_domain(triage: dict) -> None:
    """報告 §6 的核心數字：Mode A 的拍攝閘門在非 Mode A 的照片上零放行。

    這條守的是已出貨的程式。哪天有人放寬閘門條件，這裡會先紅。
    """
    leaked = [r["idx"] for r in triage["records"]
              if r["triage"] != "mode_a" and r.get("mode_a_gate_ok")]
    assert not leaked, f"閘門放行了非 Mode A 的照片：{leaked}"
