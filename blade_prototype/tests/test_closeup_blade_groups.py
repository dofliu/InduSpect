"""Mode B 切分群組的守門測試。

這份群組檔是規格 §6 第 1 條（按葉片切不按照片切）唯一的執行依據，所以測的是
**它作為安全機制有沒有效**：群整群走、提議切分零洩漏、K 折零洩漏且每類撐得起 §6 第 3 條，
以及「群不是 blade_id」這件事沒有在文件上被悄悄改掉。
"""

from __future__ import annotations

import collections
import importlib.util
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("closeup_blade_groups",
                                               ROOT / "scripts" / "closeup_blade_groups.py")
bg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bg)

DOC = json.loads((ROOT / "data" / "closeup_blade_groups_wtb.json").read_text(encoding="utf-8"))
N = 1065
MIN_PER_CLASS = 30   # 規格 §6 第 3 條：每類少於 30 張不報 P/R/F1


@pytest.fixture(scope="module")
def gid() -> dict[int, int]:
    return {int(k): v for k, v in DOC["groups"].items()}


@pytest.fixture(scope="module")
def folds() -> dict[int, int]:
    return {int(k): v for k, v in DOC["folds"].items()}


# --- 純函式 ---------------------------------------------------------------

def test_grouping_is_transitive_and_threshold_respecting() -> None:
    """A~B、B~C 要併成一群；低於門檻的邊不算。"""
    pairs = [dict(a=0, b=1, inliers=20), dict(a=1, b=2, inliers=20), dict(a=3, b=4, inliers=5)]
    g = bg.group_by_threshold(pairs, 5, threshold=12)
    assert g[0] == g[1] == g[2]
    assert g[3] != g[4], "內點 5 低於門檻 12，不該連起來"


def test_sweep_shows_the_runaway_below_the_plateau() -> None:
    """門檻掃描是門檻選擇的依據，不是裝飾：低門檻串連失控這件事要看得到。"""
    rows = {r["threshold"]: r for r in DOC["threshold"]["sweep"]}
    assert rows[8]["largest"] > 500, "門檻 8 應該落在失控區"
    assert all(rows[t]["largest"] <= 25 for t in (12, 15, 20, 25, 30, 40)), "12 以上應該是平台"
    assert DOC["threshold"]["inliers"] == 12


def test_proposed_split_keeps_groups_whole(gid: dict[int, int]) -> None:
    split = {int(k): v for k, v in DOC["proposed_split"].items()}
    by_group = collections.defaultdict(set)
    for i, g in gid.items():
        by_group[g].add(split[i])
    bad = {g: s for g, s in by_group.items() if len(s) > 1}
    assert not bad, f"這些群被拆到不同子集：{list(bad)[:5]}"


def test_proposed_split_has_no_leakage(gid: dict[int, int]) -> None:
    """近重複不得跨 train/test——這是整份檔案存在的理由。"""
    split = {int(k): v for k, v in DOC["proposed_split"].items()}
    members = bg.group_members(gid)
    for sub in ("test", "val"):
        leaked = [i for i in split if split[i] == sub
                  and any(split.get(j) == "train" for j in members[gid[i]] if j != i)]
        assert not leaked, f"{sub} 有 {len(leaked)} 張在 train 裡有近重複"


def test_folds_keep_groups_whole_and_have_no_leakage(gid: dict[int, int], folds: dict[int, int]) -> None:
    members = bg.group_members(gid)
    for i, g in gid.items():
        assert len({folds[j] for j in members[g]}) == 1, f"群 {g} 被拆到不同折"
    k = max(folds.values()) + 1
    for f in range(k):
        leaked = [i for i in folds if folds[i] == f
                  and any(folds.get(j) != f for j in members[gid[i]])]
        assert not leaked, f"第 {f} 折有跨折的近重複"


def test_folds_make_per_class_reporting_possible() -> None:
    """§6 第 3 條在單一切分上做不到（test 只剩 9 張 thunderstrike），K 折要補起來。"""
    total: collections.Counter = collections.Counter()
    for f, row in DOC["folds_class_counts"].items():
        for cls, n in row.items():
            if cls != "size":
                total[cls] += n
    assert total, "沒有逐折逐類張數就沒有依據"
    small = {c: n for c, n in total.items() if n < MIN_PER_CLASS}
    assert not small, f"這些類別加總仍不足 {MIN_PER_CLASS} 張：{small}"
    sizes = [row["size"] for row in DOC["folds_class_counts"].values()]
    assert max(sizes) - min(sizes) <= 0.1 * (sum(sizes) / len(sizes)), f"折大小不平衡：{sizes}"


def test_propose_folds_never_splits_a_group() -> None:
    """純函式層級：兩群五張，兩折，群不得被拆。"""
    gid = {0: 0, 1: 0, 2: 0, 3: 3, 4: 3}
    classes = {0: ["a"], 1: ["a"], 2: ["b"], 3: ["a"], 4: ["b"]}
    f = bg.propose_folds(gid, classes, k=2)
    assert f[0] == f[1] == f[2] and f[3] == f[4]


# --- 語料附的官方切分：不可用，而且理由要留著 -----------------------------

def test_official_split_leakage_is_recorded() -> None:
    lk = DOC["leakage_official_split"]
    assert lk["test"]["pct"] > 50, "官方切分的洩漏是不用它的唯一理由，數字不見了就該紅"
    assert lk["cross_train_test_pairs"] > 0


def test_groups_cover_every_image(gid: dict[int, int]) -> None:
    assert sorted(gid) == list(range(N))
    assert DOC["counts"]["images"] == N


def test_file_does_not_claim_to_be_blade_id() -> None:
    """群是「不可分開」不是「同一支葉片」。這句話被刪掉就是規格被悄悄放寬了。"""
    assert "blade_id" in DOC["note"] and "下界" in DOC["note"]
    assert "split_group" in DOC["note"]
