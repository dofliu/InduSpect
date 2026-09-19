"""`scripts/closeup_cross_corpus.py` 的守門：Mode B 跨語料驗證（B3）。

守四件事：①分類表裡 WTBs2025 的對照要對得上——`ours` 是本表存在的子類、`wtb_equivalent` 是 wtb 語料真有的類；
②統計的算法不能反（lift 的定義、硬拒收只認正視放行、非葉片被判 P 才算放錯人）；③域分類器對「分得開」與
「同一個分布」要給出不同的答案；④進版控的結果檔要能自我對帳，且不含影像、不含特徵。
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import closeup_cross_corpus as X  # noqa: E402

TAX = json.loads(X.TAXONOMY.read_text(encoding="utf-8"))


# ---------------------------------------------------------------- ① 對照表


def _taxonomy_ids() -> set[str]:
    ids = set()
    for c in TAX["classes"]:
        for s in c["subclasses"]:
            ids.add(f"{c['id']}/{s['id']}")
    for n in TAX["normal_structures"]:
        ids.add(f"normal_structures/{n['id']}")
    return ids


def test_wtbs2025_map_resolves() -> None:
    ds = TAX["dataset_class_map"]["wtbs2025"]
    ids = _taxonomy_ids()
    wtb = {c["their"] for c in TAX["dataset_class_map"]["multiclass_wtb"]["classes"]}
    theirs = [c["their"] for c in ds["classes"]]
    assert len(theirs) == 9 and len(set(theirs)) == 9
    for c in ds["classes"]:
        assert c["ours"] and all(o in ids for o in c["ours"]), c["their"]
        assert all(w in wtb for w in c["wtb_equivalent"]), c["their"]
    # 汙染類沒有 wtb 對應：探針不可能對，統計時要排除而不是算成 0 分
    assert TAX["dataset_class_map"]["wtbs2025"]["licence"].startswith("CC0")
    for their in ("oil leakage", "surface stains"):
        row = next(c for c in ds["classes"] if c["their"] == their)
        assert row["wtb_equivalent"] == [] and row["ours"] == ["healthy/contamination"]


# ---------------------------------------------------------------- ② 統計


def test_short_id_strips_roboflow_hash() -> None:
    assert X._short_id("erosion/2181_jpg.rf.6eac6904bc320a5f6b35d3359771753d.jpg") == "erosion/2181"
    assert X._short_id("Blade/0000.jpg") == "Blade/0000"


def test_geom_code_only_front_pass_is_hard_reject() -> None:
    assert X.geom_code(None) == "missing"
    assert X.geom_code({"error": "ValueError"}) == "error"
    assert X.geom_code({"mode_a_ok": True, "mode_a_view": "front"}) == "front"
    assert X.geom_code({"mode_a_ok": True, "mode_a_view": "side"}) == "side"
    assert X.geom_code({"mode_a_ok": False}) == "reject"


def _rows() -> list[dict]:
    return [
        {"id": "Blade/1", "class": "Blade", "probe": "P", "p": [0.9, 0.05, 0.05], "geom": "reject"},
        {"id": "Blade/2", "class": "Blade", "probe": "W", "p": [0.2, 0.7, 0.1], "geom": "side"},
        {"id": "Van/1", "class": "Van", "probe": "P", "p": [0.6, 0.2, 0.2], "geom": "reject"},
        {"id": "Van/2", "class": "Van", "probe": "T", "p": [0.1, 0.1, 0.8], "geom": "error"},
        {"id": "Hub/1", "class": "Hub", "probe": "W", "p": [0.1, 0.8, 0.1], "geom": "front"},
    ]


def test_summarise_intake_false_accept_and_hard_reject() -> None:
    s = X.summarise_intake(_rows(), X.CORPORA["hf_sees"]["expected_intake"])
    assert s["per_class"]["Van"]["probe"] == {"P": 1, "W": 0, "T": 1}
    assert s["per_class"]["Van"]["expected"] == "T" and s["per_class"]["Van"]["agree_rate"] == 0.5
    assert s["false_accept_p_on_non_blade"] == {"n": 3, "as_P": 1, "rate": round(1 / 3, 4)}
    assert s["blade_as_P"] == {"n": 2, "as_P": 1, "rate": 0.5}
    assert s["hard_reject_total"] == 1 and s["side_pass_total"] == 1
    assert s["per_class"]["Hub"]["hard_reject_whole_turbine"] == 1


def test_summarise_defect_lift_against_marginal() -> None:
    classes = ["a", "b"]
    rows = [
        {"class": "x", "probe": "P", "defect_top": "a", "defect_set": ["a"]},
        {"class": "x", "probe": "P", "defect_top": "a", "defect_set": ["a"]},
        {"class": "x", "probe": "T", "defect_top": "b", "defect_set": []},
        {"class": "y", "probe": "P", "defect_top": "b", "defect_set": ["b"]},
        {"class": "z", "probe": "P", "defect_top": "a", "defect_set": ["a"]},   # 汙染類，無對應
    ]
    s = X.summarise_defect(rows, {"x": ["a"], "y": ["b"], "z": []}, classes)
    assert s["marginal"] == {"a": 3, "b": 2}
    x = s["per_class"]["x"]
    assert x["hit_rate"] == round(2 / 3, 4) and x["marginal_rate"] == 0.6
    assert x["lift"] == round((2 / 3) / 0.6, 2)
    assert x["hit_rate_probe_P"] == 1.0 and x["none_above_threshold"] == 1
    assert s["per_class"]["z"]["expected_wtb"] == [] and "hit_rate" not in s["per_class"]["z"]
    assert s["mapped_n"] == 4 and s["mapped_hit_rate"] == 0.75


def test_geometry_reasons_bucketed_per_class() -> None:
    geom = {
        "Van/1": {"mode_a_ok": False, "mode_a_reasons": ["三片葉尖半徑差 39%（上限 15%）：x", "只定位到 2 片葉片（應為 3）：y"]},
        "Van/2": {"mode_a_ok": False, "mode_a_reasons": ["三片葉尖半徑差 12%（上限 15%）：x"]},
        "Van/3": {"mode_a_ok": True, "mode_a_view": "front", "mode_a_reasons": []},
        "Hub/1": {"error": "ValueError: 遮罩為空", "mode_a_ok": False, "mode_a_reasons": ["Mode A 例外：ValueError"]},
    }
    r = X.geometry_reasons(geom)
    assert r["Van"] == {"三片葉尖半徑差 N%（…）": 2, "只定位到 N 片葉片（…）": 1}
    assert r["Hub"] == {"Mode A 例外（…）": 1}


def test_hard_reject_review_ids_are_short_ids() -> None:
    for rid in X.HARD_REJECT_REVIEW:
        assert X._short_id(rid) == rid and "/" in rid and ".rf." not in rid


# ---------------------------------------------------------------- ③ 域差


def test_domain_gap_separable_vs_identical() -> None:
    rng = np.random.default_rng(0)
    a = rng.normal(0.0, 1.0, size=(120, 16))
    b_same = rng.normal(0.0, 1.0, size=(120, 16))
    b_far = rng.normal(0.0, 1.0, size=(120, 16)) + 6.0
    same = X.domain_gap(a, b_same, folds=4)
    far = X.domain_gap(a, b_far, folds=4)
    assert same["balanced_accuracy"] < 0.65
    assert far["balanced_accuracy"] > 0.95
    # 最近鄰餘弦只是附帶的描述量（整體平移反而會讓向量更同向），不拿它當分得開的判準
    for g in (same, far):
        assert -1.0 <= g["nn_cosine_b_to_a_median"] <= 1.0 and -1.0 <= g["nn_cosine_a_within_median"] <= 1.0
        assert g["n_a"] == g["n_b"] == 120 and g["folds"] == 4


def test_probe_train_apply_shapes() -> None:
    rng = np.random.default_rng(1)
    feat = {str(i): rng.normal(size=8) for i in range(120)}
    intake = {str(i): ("P" if i % 3 else "W") for i in range(120)}
    for i in range(0, 120, 10):
        intake[str(i)] = "N"  # N → T
    X_tr, W = X.train_intake_probe(feat, intake)
    assert W.shape == (3, 9) and X_tr.shape == (120, 8)
    probs = X.apply_probe(X_tr, W, np.stack([feat[str(i)] for i in range(5)]))
    assert probs.shape == (5, 3) and np.all((probs >= 0) & (probs <= 1))


def test_intake_probe_refuses_tiny_training_set() -> None:
    feat = {str(i): np.zeros(4) for i in range(10)}
    with pytest.raises(X.CrossCorpusError):
        X.train_intake_probe(feat, {str(i): "P" for i in range(10)})


# ---------------------------------------------------------------- ④ 結果檔


def test_pack_unpack_roundtrip() -> None:
    classes = ["a", "b", "c"]
    rows = [
        {"id": "x/1", "class": "x", "probe": "P", "p": [0.9, 0.05, 0.05], "geom": "reject",
         "defect_top": "b", "defect_top_p": 0.7, "defect_set": ["a", "c"]},
        {"id": "y/2", "class": "y", "probe": "T", "p": [0.1, 0.2, 0.7], "geom": "side",
         "defect_top": "c", "defect_top_p": 0.51, "defect_set": []},
    ]
    packed = X.pack_rows(rows, classes)
    assert packed["probe"] == "PT" and packed["geom"] == "rs" and packed["defect_set"] == [0b101, 0]
    assert X.unpack_rows(packed, classes) == rows
    plain = [{k: v for k, v in r.items() if not k.startswith("defect")} for r in rows]
    assert X.unpack_rows(X.pack_rows(plain, classes), classes) == plain


@pytest.mark.skipif(not X.OUT.exists(), reason="還沒跑過跨語料")
def test_results_self_consistent_and_image_free() -> None:
    doc = json.loads(X.OUT.read_text(encoding="utf-8"))
    assert doc["summary"] == X.summarise(doc)
    for key, c in doc["corpora"].items():
        assert key in X.CORPORA
        assert "rows" not in c  # 進版控的是欄式打包，不是逐列 dict
        rows = X.rows_of(doc, key)
        assert c["n"] == len(rows) == c["rows_packed"]["n"]
        for r in rows[:50] + rows[-50:]:
            assert set(r) <= {"id", "class", "probe", "p", "geom", "defect_top", "defect_top_p", "defect_set"}
            assert r["probe"] in X.PROBE_CLASSES and len(r["p"]) == 3
            assert ".rf." not in r["id"] and "/" in r["id"]  # 不留 Roboflow 雜湊，也不留任何路徑
    assert doc["class_map"] == {c["their"]: c["wtb_equivalent"] for c in TAX["dataset_class_map"]["wtbs2025"]["classes"]}


@pytest.mark.skipif(not X.OUT.exists(), reason="還沒跑過跨語料")
def test_every_hard_reject_in_results_was_reviewed() -> None:
    """硬拒收在外部語料上只有個位數，每一張都要有人看過寫下為什麼——結果檔多出一張沒備註的就紅。"""
    doc = json.loads(X.OUT.read_text(encoding="utf-8"))
    for key in doc["corpora"]:
        for r in X.rows_of(doc, key):
            if r["geom"] == "front":
                assert r["id"] in X.HARD_REJECT_REVIEW, r["id"]


@pytest.mark.skipif(not X.OUT.exists(), reason="還沒跑過跨語料")
def test_report_in_sync_with_results() -> None:
    doc = json.loads(X.OUT.read_text(encoding="utf-8"))
    md = (ROOT / "CROSS_CORPUS_VALIDATION.md").read_text(encoding="utf-8")
    assert md == X.render_markdown(doc), "CROSS_CORPUS_VALIDATION.md 與結果檔不同步：重跑 closeup_cross_corpus.py report"
