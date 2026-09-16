"""Mode B 取像閘門（§1.2）的守門。

守三件事：①幾何硬規則的方向不能反（整機照 → 拒收、近身照 → 不因為幾何而放行）；
②進版控的逐張結果檔要能自我對帳（判定 = decide(probe, geometry)、統計 = summarise(rows)）；
③數字有地板——探針的平衡準確率、P／W recall 退到地板以下時這裡先紅，而 T 類的低 recall
是**已知並記錄**的限制，不拿它當通過條件。
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import pytest

from blade_proto.intake import IntakeGeometry, intake_geometry
from blade_proto.synth import SceneSpec, render_blade_segment, render_front, render_side

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import closeup_intake_gate as G  # noqa: E402


@pytest.fixture(scope="module")
def gate() -> dict:
    return json.loads(G.GATE.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def intake() -> dict:
    return json.loads(G.B.INTAKE.read_text(encoding="utf-8"))["labels"]


# ---------------------------------------------------------------- 幾何硬規則


def test_whole_turbine_scene_is_rejected_by_geometry() -> None:
    """合成正視整機照：Mode A 放行 → Mode B 硬拒收，理由指向 Mode A。"""
    img, _ = render_front(SceneSpec())
    g = intake_geometry(img)
    assert g.mode_a_ok and g.mode_a_view == "front" and g.reject_as_whole_turbine
    assert g.n_blades == 3 and g.tower_found
    decision, reason = G.decide({"probe": "P"}, g.to_dict())
    assert decision == "W" and "Mode A" in reason


def test_side_view_pass_is_left_to_the_probe_not_hard_rejected() -> None:
    """側視規則在近身照上會誤放行（全語料 8/839 張 P，SPEC §13 第 13 項），所以硬規則只認正視。
    合成側視整機照：Mode A 放行、view=side、**不**硬拒收——它由探針處理（W recall 0.95）。"""
    img, _ = render_side(SceneSpec())
    g = intake_geometry(img)
    assert g.mode_a_ok and g.mode_a_view == "side"
    assert not g.reject_as_whole_turbine
    assert G.decide({"probe": "W"}, g.to_dict())[0] == "W"


def test_frame_filling_blade_is_not_a_whole_turbine_but_area_says_nothing() -> None:
    """長焦分區段照：不會被硬規則拒收；同時它的前景占比比整機照還小——這就是
    「前景占比量不出 §1.2」的直接證據（局部天空模型把填滿畫面的葉片當背景）。"""
    blade = render_blade_segment()
    img = blade[0] if isinstance(blade, tuple) else blade
    g = intake_geometry(img)
    whole, _ = render_front(SceneSpec())
    assert not g.reject_as_whole_turbine
    assert g.mask_frac < intake_geometry(whole).mask_frac


def test_geometry_never_raises_on_degenerate_input() -> None:
    g = intake_geometry(np.zeros((6, 9, 3), np.uint8))
    assert isinstance(g, IntakeGeometry) and not g.mode_a_ok
    assert g.error is not None or g.mode_a_reasons


def test_decide_lets_geometry_override_probe_only_towards_rejection() -> None:
    assert G.decide({"probe": "P"}, {"reject_as_whole_turbine": True})[0] == "W"
    assert G.decide({"probe": "W"}, {"reject_as_whole_turbine": False})[0] == "W"
    assert G.decide({"probe": "P"}, {"reject_as_whole_turbine": False})[0] == "P"
    assert G.decide({"probe": "P"}, None)[0] == "P"
    assert G.decide({"probe": "T"}, None)[0] == "T"


# ---------------------------------------------------------------- 逐張結果檔自我對帳


def test_gate_file_covers_every_intake_label_with_geometry(gate: dict, intake: dict) -> None:
    rows = gate["images"]
    assert set(rows) == set(intake) and len(rows) == 1065
    assert gate["geometry_included"] is True
    for i, r in rows.items():
        assert r["truth"] == intake[i]
        assert r["truth_merged"] == G.MERGE.get(intake[i], intake[i])
        assert r["probe"] in G.PROBE_CLASSES and r["decision"] in G.PROBE_CLASSES
        assert "geometry" in r and "mode_a_ok" in r["geometry"]


def test_gate_file_decisions_and_summary_are_reproducible_from_rows(gate: dict) -> None:
    rows = gate["images"]
    for r in rows.values():
        d, reason = G.decide(r, r["geometry"])
        assert (d, reason) == (r["decision"], r["reason"])
    assert G.summarise(rows, True) == gate["summary"]


def test_gate_file_features_match_the_shipped_npz(gate: dict) -> None:
    _, meta = G.load_features(G.FEATURES)
    assert gate["features"] == meta


def test_front_view_mode_a_pass_is_hard_rejected_and_side_view_leaks_are_recorded(gate: dict) -> None:
    s = gate["summary"]
    rows = gate["images"]
    for i in s["hard_rejects"]:
        assert rows[i]["decision"] == "W" and rows[i]["geometry"]["mode_a_view"] == "front"
    assert s["hard_rejects"] == [i for i in s["mode_a_ok"] if rows[i]["geometry"]["mode_a_view"] == "front"]
    # Mode A 放行但真值是 P：Mode A 閘門在近身照上的誤放行，逐張記錄當回歸案例。實測全部走側視規則——
    # 這條釘住「正視規則沒有漏進近身照」；側視那些數量若變也要有人看到（SPEC §13 第 13 項）。
    leaks = s["mode_a_leaks_into_P"]
    assert leaks == [i for i in s["mode_a_ok"] if rows[i]["truth_merged"] == "P"]
    assert s["mode_a_leaks_into_P_by_view"]["front"] == 0
    assert "996" in leaks and s["mode_a_leaks_into_P_by_view"]["side"] == len(leaks) >= 8
    # 硬規則不得把任何真值 P 拒收：它只認正視三片 + 塔架
    assert all(rows[i]["truth_merged"] != "P" for i in s["hard_rejects"])


def test_gate_numbers_have_a_floor(gate: dict) -> None:
    """地板取實測值往下留一點餘裕：探針 P 對非 P 平衡準確率 0.91、P recall 0.99、W recall 0.95。
    T 類（41 張）recall 0.20 是已知限制，**不設地板**——設了會逼人把 T 的張數湊上去或調門檻。"""
    s = gate["summary"]
    assert s["balanced_accuracy_P_final"] >= 0.85
    assert s["per_class_recall"]["P"]["recall"] >= 0.95
    assert s["per_class_recall"]["W"]["recall"] >= 0.90
    assert s["per_class_recall"]["T"]["n"] < 60, "T 類張數大幅增加時請重新評估是否該給它地板"


def test_summary_counts_are_consistent(gate: dict) -> None:
    s = gate["summary"]
    assert sum(v["n"] for v in s["per_class_recall"].values()) == s["n"] == 1065
    assert sum(sum(r.values()) for r in s["confusion_final"].values()) == 1065
    fa = {i for i, r in gate["images"].items() if r["truth_merged"] != "P" and r["decision"] == "P"}
    assert set(s["false_accept"]) == fa


# ---------------------------------------------------------------- 探針


def test_probe_is_deterministic_and_uses_argmax(intake: dict) -> None:
    feat, _ = G.load_features(G.FEATURES)
    folds = json.loads(G.B.GROUPS.read_text(encoding="utf-8"))["folds"]
    sub = {i: c for i, c in intake.items() if int(i) < 200}
    a = G.probe_classes(sub, folds, feat)
    b = G.probe_classes(sub, folds, feat)
    assert a == b and set(a) == set(sub)
    for r in a.values():
        best = max(("P", "W", "T"), key=lambda c: r[f"p_{c}"])
        assert r["probe"] == best
        assert r["truth"] in G.PROBE_CLASSES


def test_build_refuses_when_features_miss_part_of_the_corpus(tmp_path: Path) -> None:
    z = np.load(G.FEATURES, allow_pickle=False)
    keep = 500
    meta = json.loads(str(z["meta"]))
    np.savez(tmp_path / "f.npz", ids=z["ids"][:keep], X=z["X"][:keep], meta=json.dumps(meta))
    with pytest.raises(G.IntakeGateError):
        G.build(None, tmp_path / "f.npz")
