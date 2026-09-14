"""Mode B 評估協定（B1）的守門測試。

這支腳本是規格 §6 四條規則的執行者，所以測的是**它會不會讓不該過的東西過**：
少於 30 張的類別不准出現數字、未普查的誤報不准被算成「乾淨表面上的誤報」、
健康照 0 張時不准印 0、切分宣告不符要拒跑、跨機制類的類別不准被硬彙總。
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("closeup_eval", ROOT / "scripts" / "closeup_eval.py")
ev = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ev)

TRUTH = json.loads((ROOT / "data" / "closeup_truth_wtb.json").read_text(encoding="utf-8"))
SUBSETS = json.loads((ROOT / "data" / "closeup_subsets_wtb.json").read_text(encoding="utf-8"))
GROUPS = json.loads((ROOT / "data" / "closeup_blade_groups_wtb.json").read_text(encoding="utf-8"))
TAX = json.loads((ROOT / "data" / "closeup_taxonomy.json").read_text(encoding="utf-8"))
DEMO = json.loads((ROOT / "data" / "closeup_leakage_demo_wtb.json").read_text(encoding="utf-8"))
N = 1065


# --- §6 第 3 條：少於 30 張不報 -------------------------------------------

def test_small_class_never_shows_numbers() -> None:
    counts = {"rare": dict(n_truth=29, tp=29, fn=0, fp=0), "common": dict(n_truth=30, tp=15, fn=15, fp=5)}
    m = ev.metrics_with_floor(counts)
    assert m["rare"]["recall"] is None and m["rare"]["precision"] is None and m["rare"]["f1"] is None
    assert m["rare"]["suppressed_reason"] and not m["rare"]["reportable"]
    assert m["common"]["recall"] == pytest.approx(0.5), "剛好 30 張要報"


def test_markdown_prints_not_reported_instead_of_a_number() -> None:
    """把數字藏起來只有在畫面上真的看不到數字才算數。"""
    truth = {"0": ["a"], "1": ["a"], "2": []}
    pred = {"0": ["a"], "1": [], "2": ["a"]}
    r = _minimal_result(truth, pred, ["a"])
    md = ev.render_markdown(r)
    row = next(line for line in md.splitlines() if line.startswith("| `a`"))
    assert "不報" in row, row
    assert "0." not in row and "1.0" not in row, f"n < 30 的類別在表上仍出現了數字：{row}"


def _minimal_result(truth, pred, classes) -> dict:
    ids = sorted(truth)
    return dict(model="t", split="folds", split_note="", split_is_group_respecting=True,
                leaking_groups=[], leakage_warning=None, n_images_evaluated=len(ids),
                n_missing_predictions=0, coverage_note="", primary_metric="per_class_recall",
                per_class=ev.metrics_with_floor(ev.per_class_counts(truth, pred, classes, ids)),
                per_fold_recall={}, cooccurrence=ev.cooccurrence(truth, pred, classes, ids),
                false_positives=ev.false_positive_breakdown(truth, pred, ids, {}, {}),
                subsets=[], mechanism_rollup=dict(mapped={}, unmapped=classes, note=""),
                footnote_accuracy=dict(exact_match=0.5, caveat="附註，不得當標題"),
                upper_bound_note="")


# --- 多標籤計數 -----------------------------------------------------------

def test_multi_label_counts_are_per_class_not_per_image() -> None:
    truth = {"0": ["a", "b"], "1": ["a"], "2": []}
    pred = {"0": ["a"], "1": ["b"], "2": ["a"]}
    c = ev.per_class_counts(truth, pred, ["a", "b"], ["0", "1", "2"])
    assert c["a"] == dict(n_truth=2, tp=1, fn=1, fp=1)
    assert c["b"] == dict(n_truth=1, tp=0, fn=1, fp=1)


# --- §6 第 4 條：誤報分項 -------------------------------------------------

def test_unsurveyed_false_positives_are_not_counted_as_clean() -> None:
    truth = {"0": [], "1": [], "2": []}
    pred = {"0": ["a"], "1": ["a"], "2": ["a"]}
    ns = {"0": "r", "1": ""}          # 0 有正常結構、1 普查過但沒有、2 未普查
    fp = ev.false_positive_breakdown(truth, pred, ["0", "1", "2"], {}, ns)
    assert fp["buckets"] == dict(on_normal_structure=1, on_surveyed_without_normal_structure=1,
                                 not_surveyed=1)


def test_artifact_only_labels_do_not_count_as_normal_structure() -> None:
    """灰色塗抹／時間戳／人手是**痕跡**不是正常結構，混進去會讓誤報歸因失真。"""
    fp = ev.false_positive_breakdown({"0": []}, {"0": ["a"]}, ["0"], {}, {"0": "at"})
    assert fp["buckets"]["on_surveyed_without_normal_structure"] == 1


def test_no_healthy_images_reports_not_measurable_not_zero() -> None:
    fp = ev.false_positive_breakdown({"0": ["a"]}, {"0": ["a"]}, ["0"], {}, {})
    assert fp["healthy_images"] == 0
    assert fp["healthy_false_positive_rate"] is None and "量不到" in fp["note"]


# --- §6 第 1 條：切分 -----------------------------------------------------

def test_split_that_cuts_a_group_is_detected() -> None:
    gid = {"0": 1, "1": 1, "2": 2}
    ok, bad = ev.split_is_group_respecting({"0": "train", "1": "test", "2": "test"}, gid)
    assert not ok and bad == [1]
    ok, _ = ev.split_is_group_respecting({"0": "train", "1": "train", "2": "test"}, gid)
    assert ok


def test_official_split_is_stamped_as_leaking() -> None:
    official = {str(i): ("test" if i < 3 else "train") for i in range(6)}
    truth = dict(labels={str(i): ["a"] for i in range(6)}, classes=["a"])
    groups = dict(groups={str(i): (0 if i in (0, 3) else i) for i in range(6)},
                  folds={str(i): i % 2 for i in range(6)},
                  proposed_split={str(i): "train" for i in range(6)})
    pred = dict(model="m", split="official", official_split=official,
                predictions={str(i): ["a"] for i in range(3)})
    r = ev.evaluate(truth, pred, groups, {}, {}, TAX, split="official")
    assert r["split_is_group_respecting"] is False
    assert r["leakage_warning"] and "虛高" in r["leakage_warning"]
    assert "⚠️" in ev.render_markdown(r)


def test_declaring_one_split_and_running_another_is_refused() -> None:
    truth = dict(labels={"0": ["a"]}, classes=["a"])
    groups = dict(groups={"0": 0}, folds={"0": 0}, proposed_split={"0": "test"})
    pred = dict(split="folds", predictions={"0": ["a"]})
    with pytest.raises(ev.EvalError):
        ev.evaluate(truth, pred, groups, {}, {}, TAX, split="proposed")


def test_typos_are_refused_rather_than_silently_scored() -> None:
    truth = dict(labels={"0": ["a"]}, classes=["a"])
    groups = dict(groups={"0": 0}, folds={"0": 0}, proposed_split={"0": "test"})
    for bad in (dict(split="folds", predictions={"7": ["a"]}),
                dict(split="folds", predictions={"0": ["A"]})):
        with pytest.raises(ev.EvalError):
            ev.evaluate(truth, bad, groups, {}, {}, TAX, split="folds")


# --- 機制類彙總只在對照明確時 ---------------------------------------------

def test_ambiguous_classes_are_not_rolled_up() -> None:
    m = ev.unambiguous_mechanism_map(TAX)
    assert set(m) == {"crack", "surface_injure", "thunderstrike"}, \
        "跨機制類的 craze／hide_craze／corrosion 不可以被彙總"
    assert m["thunderstrike"] == "environmental" and m["surface_injure"] == "surface"


# --- 版控中的資料檔 -------------------------------------------------------

def test_truth_covers_the_corpus_and_has_no_healthy_image() -> None:
    labels = TRUTH["labels"]
    assert sorted(int(k) for k in labels) == list(range(N))
    assert not [k for k, v in labels.items() if not v], "這份語料每張都有缺陷框，出現健康照要先查清楚"
    their = {row["their"] for row in TAX["dataset_class_map"]["multiclass_wtb"]["classes"]}
    assert set(TRUTH["classes"]) == their, "真值的類別要跟分類表的語料對照表一致"


def test_truth_is_the_union_of_both_annotators() -> None:
    for k, v in list(TRUTH["per_annotator"].items())[:50]:
        assert set(TRUTH["labels"][k]) == set(v["a"]) | set(v["b"])


def test_subsets_keep_unsurveyed_as_null() -> None:
    art = SUBSETS["annotation_artifact"]
    assert any(v is None for v in art.values()), "未普查要是 null，不可以當成「沒有痕跡」"
    assert sum(1 for v in art.values() if v is not None) == 192
    assert 0 < sum(1 for v in SUBSETS["low_light"].values() if v) < N


def test_leakage_demo_isolates_one_variable() -> None:
    """報告引用的 0.204 要留在版控裡，改了就該紅。"""
    assert DEMO["test_images"] == 161 and DEMO["train_images"] == 745
    assert DEMO["test_images_with_same_group_in_train"] == 102
    assert DEMO["mean_recall_delta"] == pytest.approx(0.204, abs=0.001)
    assert "不是任何特定模型的預測值" in DEMO["caveat"]
    for row in DEMO["per_class"]:
        if row["with_leak"] is None:
            assert row["n"] < ev.MIN_PER_CLASS, "只有不足 30 張的類別可以留白"
