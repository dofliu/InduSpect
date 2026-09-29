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

from blade_proto import intake as G_intake
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
    """側視整機照不會被硬拒收——**2026-09-28 起連「被判成側視」都不會發生**。

    舊版：Mode A 會從剪影推論出 view=side 而放行，硬規則刻意只認正視，
    因為側視規則在近身照上會誤放行（全語料 8/839 張 P，SPEC §13 第 13 項）。
    新版：側視改成宣告制（SPEC §13-16），而這裡沒有人宣告，所以同一張合成側視照
    走正視規則被 Mode A 拒收（只定位到 2 片）。**§13-13 那個漏洞因此是結構性關掉的**：
    這條路上不可能再出現 view=side。硬拒收的結論不變（只有 Mode A 正視放行才算整機照），
    所以近身照照樣留給探針判。
    """
    img, _ = render_side(SceneSpec())
    g = intake_geometry(img)
    assert not g.mode_a_ok, "沒有宣告卻被判成側視放行了"
    assert g.mode_a_view == "front"
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


def test_front_view_mode_a_pass_is_hard_rejected_and_no_side_view_leaks_remain(gate: dict) -> None:
    """Mode A 放行的處理，以及 §13-13 那個漏洞在語料上已經歸零。

    2026-09-16 這份語料上 Mode A 放行 10 張：正視 2（真值 W）+ **側視 8（真值全是 P）**，
    後者是側視規則在近身照上的誤放行。2026-09-28 側視改成呼叫端宣告制（SPEC §13-16）、
    2026-09-29 以現行程式重跑：**放行 10 → 2、側視 8 → 0、漏進 P 的 8 → 0**，
    而最終判定的每一個數字都沒變（那 8 張本來就沒被硬拒收，從來沒進過決策）。
    這條紅了有兩種可能：側視又變成從剪影推論的，或正視規則開始漏進近身照——兩種都要有人看到。
    """
    s = gate["summary"]
    rows = gate["images"]
    for i in s["hard_rejects"]:
        assert rows[i]["decision"] == "W" and rows[i]["geometry"]["mode_a_view"] == "front"
        # 硬拒收還要過「轉子上方要是天空」（2026-09-29）：正視放行是上界不是結論
        assert rows[i]["geometry"]["vegetation_above_hub"] is not None
        assert rows[i]["geometry"]["vegetation_above_hub"] <= G_intake.MAX_VEGETATION_ABOVE_HUB
    assert set(s["hard_rejects"]) <= {i for i in s["mode_a_ok"] if rows[i]["geometry"]["mode_a_view"] == "front"}
    assert s["mode_a_ok_by_view"]["side"] == 0, "沒有人宣告側視，卻有照片走側視規則放行"
    assert s["mode_a_leaks_into_P"] == [] and s["mode_a_leaks_into_P_by_view"] == {"front": 0, "side": 0}
    # 硬規則不得把任何真值 P 拒收：它只認正視三片 + 塔架 + 轉子上方是天空
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


# ---------------------------------------------------------------- 轉子背後要是天空（2026-09-29）

# 五張正視放行的植被值與硬拒收結論的**單一來源**：跨語料結果檔的 `front_passes`。
# 2026-09-29 的第一版另存過一份 `closeup_hard_reject_review.json`，那是「只重跑原本命中的那幾張」的
# 權宜之計；同日全語料重跑後那五個值逐位相同（單調性論證成立），副本就收掉了，免得兩份漂開。
CROSS_CORPUS_FILE = ROOT / "data" / "closeup_cross_corpus.json"


def _front_passes() -> list[dict]:
    doc = json.loads(CROSS_CORPUS_FILE.read_text(encoding="utf-8"))
    return [d for s in doc["summary"].values() for d in s["front_passes"]]


def _structure(hub, blades, tower=True):
    """給 _vegetation_above_hub 用的最小結構替身。"""
    class _B:
        def __init__(self, r): self.tip_radius_px = r
    class _S:
        pass
    s = _S()
    s.hub = hub
    s.blades = [_B(r) for r in blades]
    s.tower_found = tower
    return s


def test_vegetation_above_hub_separates_sky_from_field() -> None:
    """量測本身：輪轂上方是天空 → 0；是農田 → 接近 1。

    這條把「量測寫壞了」與「門檻取錯了」分開。
    """
    h = w = 200
    sky = np.zeros((h, w, 3), np.uint8)
    sky[:, :] = (235, 206, 135)          # BGR 天藍
    field = np.zeros((h, w, 3), np.uint8)
    field[:, :] = (40, 140, 60)          # BGR 草綠
    mask = np.zeros((h, w), np.uint8)    # 全背景：圓盤內都是背景
    st = _structure((100.0, 150.0), [80.0])
    assert G_intake._vegetation_above_hub(sky, mask, st) == pytest.approx(0.0, abs=1e-6)
    assert G_intake._vegetation_above_hub(field, mask, st) > 0.9


def test_vegetation_above_hub_is_none_when_not_measurable() -> None:
    """圓盤內背景太少（遮罩填滿）或沒有葉片 → None，而 None **不擋**（沒有證據不是拒收的理由）。"""
    img = np.full((200, 200, 3), 200, np.uint8)
    full = np.full((200, 200), 255, np.uint8)
    assert G_intake._vegetation_above_hub(img, full, _structure((100.0, 150.0), [80.0])) is None
    assert G_intake._vegetation_above_hub(img, np.zeros((200, 200), np.uint8),
                                          _structure((100.0, 150.0), [])) is None


def test_hard_reject_needs_sky_behind_the_rotor() -> None:
    """硬拒收 = Mode A 正視放行 **且** 轉子上方是天空。量不到時維持舊行為（擋）。"""
    def geom(veg):
        return G_intake.IntakeGeometry(mode_a_ok=True, mode_a_view="front", mode_a_reasons=[],
                                       mask_frac=0.05, n_blades=3, tower_found=True,
                                       hub_radius_frac=0.01, vegetation_above_hub=veg)
    assert geom(0.0).reject_as_whole_turbine
    assert geom(G_intake.MAX_VEGETATION_ABOVE_HUB).reject_as_whole_turbine
    assert not geom(G_intake.MAX_VEGETATION_ABOVE_HUB + 0.01).reject_as_whole_turbine
    assert geom(None).reject_as_whole_turbine, "量不到就不擋會讓硬規則靜悄悄失效"


def test_threshold_sits_between_the_reviewed_cases() -> None:
    """門檻不是憑感覺挑的：**逐張複核過的正視放行**裡，誤觸最低 0.27、正確的 0.00，門檻要落在中間。

    這一條紅了代表複核結果變了（有人重看、語料換版、或加了新的案例），門檻要跟著重新取。
    """
    rows = _front_passes()
    misfire = [r["veg"] for r in rows if not r["hard"]]
    correct = [r["veg"] for r in rows if r["hard"]]
    assert misfire and correct
    assert max(correct) < G_intake.MAX_VEGETATION_ABOVE_HUB < min(misfire), (
        f"門檻 {G_intake.MAX_VEGETATION_ABOVE_HUB} 沒有落在 正確 {correct} 與 誤觸 {misfire} 之間")


def test_every_reviewed_hard_reject_has_a_note() -> None:
    """每一張正視放行都要有人工備註——這條在 2026-09-29 抓到一則寫錯的（`Blade/0407`）。

    備註在 `closeup_cross_corpus.HARD_REJECT_REVIEW`，量在結果檔，兩邊的 id 集合要對得上：
    多一張沒備註的、或留著一則指向已經不存在的照片的備註，都要紅。
    """
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "closeup_cross_corpus", ROOT / "scripts" / "closeup_cross_corpus.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    ids = {r["id"] for r in _front_passes()}
    assert ids == set(mod.HARD_REJECT_REVIEW), ids ^ set(mod.HARD_REJECT_REVIEW)
    for rid in ids:
        assert mod.HARD_REJECT_REVIEW[rid].strip(), rid
