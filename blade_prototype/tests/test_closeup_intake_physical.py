"""§1.2 物理量測（`scripts/closeup_intake_physical.py`）的守門測試。

這批釘的是一個**否定結果**：四種物理操作化都當不了 §1.2 的閘門。否定結果一樣會腐壞——
有人把量測改好了、或有人把結論讀成「所以用探針就好」，都要被擋下來。影像不進版控，
所以這裡不重跑量測，只讀結果檔；量測本身的行為用合成影像驗。
"""
from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / "data" / "closeup_intake_physical_wtb.json"
REPORT = ROOT / "CLOSEUP_INTAKE_PHYSICAL.md"

sys.path.insert(0, str(ROOT / "scripts"))
_spec = importlib.util.spec_from_file_location(
    "closeup_intake_physical", ROOT / "scripts" / "closeup_intake_physical.py")
M = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(M)

# 探針在同一份語料、同一套群感知切分上的平衡準確率（CLOSEUP_INTAKE_GATE.md）。
PROBE_BALANCED_ACCURACY = 0.910


@pytest.fixture(scope="module")
def doc() -> dict:
    return json.loads(RESULTS.read_text(encoding="utf-8"))


def test_results_cover_the_labelled_corpus(doc: dict) -> None:
    truth = json.loads((ROOT / "data" / "closeup_intake_wtb.json").read_text(encoding="utf-8"))
    assert doc["summary"]["n"] == len(truth["labels"]) == 1065
    assert doc["summary"]["truth_counts"]["P"] == 839


def test_report_in_sync_with_results(doc: dict) -> None:
    assert REPORT.read_text(encoding="utf-8") == M.render_markdown(
        doc, "data/closeup_intake_physical_wtb.json")


def test_physical_measurements_do_not_gate(doc: dict) -> None:
    """**這是這份工作的結論**：四種量測合起來比亂猜好不了多少。

    紅了代表有人把量測改好了——那是好消息，但 SPEC §1.2 的註記與
    `CLOSEUP_INTAKE_GATE.md` §5 的「探針維持建議性」要跟著重新檢討，不能靜悄悄地留著舊結論。
    """
    combined = doc["summary"]["combined_group_aware_cv"]["mean"]
    assert combined < 0.65, f"物理量測變得有鑑別力了（{combined}），文件要跟著改"
    assert combined < PROBE_BALANCED_ACCURACY


def test_single_thresholds_are_reported_as_optimistic(doc: dict) -> None:
    """單一門檻是 in-sample 挑的，本來就高估——而它連高估都只到 0.63。

    合起來的 CV 值比單一門檻的 in-sample 上界還低，這件事本身就是「沒有可泛化訊號」的證據。
    """
    singles = doc["summary"]["single_feature_in_sample"]
    best = max(v["balanced_accuracy_in_sample"] for v in singles.values())
    assert 0.5 < best < 0.70
    assert doc["summary"]["combined_group_aware_cv"]["mean"] < best


def test_all_four_families_are_present(doc: dict) -> None:
    """四種操作化都要在結果裡——少一種，結論就不是「四種都不行」。"""
    feats = doc["summary"]["features"]
    for prefix in ("border_", "chord_", "bg_", "thin_"):
        assert any(f.startswith(prefix) for f in feats), prefix


def test_thin_family_responds_to_a_thin_bar_and_not_to_a_filled_frame() -> None:
    """量測本身是對的（用合成影像驗）：細長桿有反應、整片填滿沒有。

    這條把「量測寫壞了」與「量測沒鑑別力」分開——結論是後者，不是前者。
    """
    filled = np.full((300, 400, 3), 200, np.uint8)
    bar = filled.copy()
    bar[:, 195:205] = 40           # 寬 10 px ≈ 短邊的 3%，遠比 1/3 細
    f_filled = M.feat_thin(filled)
    f_bar = M.feat_thin(bar)
    assert f_bar["thin_area_frac"] > f_filled["thin_area_frac"]
    assert f_bar["thin_span_frac"] > 0.3, f_bar
    assert f_filled["thin_area_frac"] == pytest.approx(0.0, abs=1e-6)


def test_border_family_measures_thickness_not_area() -> None:
    """`border_thick` 量的是最大內接圓直徑／短邊——粗的物體要比細的大。"""
    thin = np.full((300, 300, 3), 30, np.uint8)
    thin[:, 145:155] = 240
    thick = np.full((300, 300, 3), 30, np.uint8)
    thick[:, 100:200] = 240
    assert M.feat_border(thick)["border_thick"] > M.feat_border(thin)["border_thick"]


def test_logistic_is_deterministic() -> None:
    """零初始化、固定步數、無隨機種子——重跑逐位元相同（與 B2 基線同一個慣例）。"""
    rng = np.random.default_rng(0)
    X = rng.normal(size=(60, 4))
    y = (X[:, 0] > 0).astype(float)
    w1, w2 = M._logistic(X, y), M._logistic(X, y)
    assert np.array_equal(w1, w2)
