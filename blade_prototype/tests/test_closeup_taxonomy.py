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


def _iea(tax: dict) -> dict:
    return tax["severity_scales"]["iea_task46"]


def _iea_levels(tax: dict):
    for track, tr in _iea(tax)["tracks"].items():
        for lv in tr["levels"]:
            yield track, lv


def test_level_zero_marked_undetectable(tax: dict) -> None:
    """IEA Level 0 在單張近身照上判不了（要證明「沒有 ≥ 1 cm² 的實例」需要全覆蓋），不可標成可偵測。"""
    for track, lv in _iea_levels(tax):
        if lv["level"] == 0:
            assert lv["detectable"] is False, track


def test_iea_has_two_tracks_that_differ_only_where_the_source_does(tax: dict) -> None:
    """原文 §4.3.1 是兩條軌：有 LEP／無 LEP 的 Level 1–3 定義不同，Level 0 與 4–5 共用。

    舊版把兩軌壓成一軌——沒上 LEP 的葉片會被系統性判錯一到兩級。
    """
    tracks = _iea(tax)["tracks"]
    assert set(tracks) == {"lep", "no_lep"}
    by = {k: {lv["level"]: lv for lv in tr["levels"]} for k, tr in tracks.items()}
    for k in by:
        assert sorted(by[k]) == [0, 1, 2, 3, 4, 5], k
    for shared in (0, 4, 5):
        assert by["lep"][shared]["threshold"] == by["no_lep"][shared]["threshold"], shared
    for own in (1, 2, 3):
        assert by["lep"][own]["threshold"] != by["no_lep"][own]["threshold"], own


def test_iea_thresholds_are_the_source_text_not_a_guess(tax: dict) -> None:
    """安全分級的門檻不可以憑印象填：每一級都要有原文名稱、面積門檻、核對日期與來源網址。"""
    sc = _iea(tax)
    assert sc["verified_on"] and sc["source_url"].startswith("https://iea-wind.org/")
    for track, lv in _iea_levels(tax):
        assert "核對" not in lv["criterion"], f"{track}/L{lv['level']} 還是佔位文字"
        assert lv.get("title"), f"{track}/L{lv['level']} 缺原文名稱"
        assert "cm²" in lv["threshold"] or "m²" in lv["threshold"], f"{track}/L{lv['level']} 門檻不是面積"
    # 原文逐條：LEP 軌 L1 是 1–10 cm²、L3 是 ≥ 1 m²；No-LEP 軌 L1 是 ≤ 1 cm²；L4 雙門檻、L5 積層 ≥ 1 cm²
    lep = {lv["level"]: lv for lv in sc["tracks"]["lep"]["levels"]}
    nol = {lv["level"]: lv for lv in sc["tracks"]["no_lep"]["levels"]}
    assert "1 cm²" in lep[1]["threshold"] and "10 cm²" in lep[1]["threshold"]
    assert "1 m²" in lep[3]["threshold"]
    assert "≤ 1 cm²" in nol[1]["threshold"]
    assert "且" in lep[4]["threshold"] and "積層" in lep[4]["threshold"]
    assert "積層" in lep[5]["threshold"] and "≥ 1 cm²" in lep[5]["threshold"]


def test_iea_min_cm_per_px_follows_the_declared_rule(tax: dict) -> None:
    """解析度需求由公式算（√面積 / 15 px），不手填。舊版三級共用 0.46 沒有任何依據。"""
    import math
    for track, lv in _iea_levels(tax):
        expect = round(math.sqrt(lv["threshold_cm2"]) / 15, 3)
        assert lv["min_cm_per_px"] == expect, f"{track}/L{lv['level']}: {lv['min_cm_per_px']} != {expect}"
    # Level 4/5 的解析度需求與 Level 1 同級——「Level 3 以上任何組態都可以」是錯的
    lep = {lv["level"]: lv for lv in _iea(tax)["tracks"]["lep"]["levels"]}
    assert lep[5]["min_cm_per_px"] == lep[1]["min_cm_per_px"]


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
