"""第一遍標記的守門：它可以排順序，永遠不可以變成簽核。

`closeup_candidate_firstpass.py` 把 1,842 格健康候選逐格看過一遍，但看的人是模型不是人。
這一批測試守的就是那條界線——先驗進得去、決策進不來。
"""

from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import closeup_candidate_firstpass as fp  # noqa: E402
import closeup_review_tool as rt  # noqa: E402

N_TILES = 1842  # CLOSEUP_HEALTHY_SET.md §4 的 blade_like 候選格數


@pytest.fixture(scope="module")
def doc() -> dict:
    return json.loads(fp.FIRSTPASS.read_text(encoding="utf-8"))


def _layout(tiles_per_sheet: list[list[dict]]) -> dict:
    sheets = []
    for i, tiles in enumerate(tiles_per_sheet):
        sheets.append(dict(sheet=f"cand{i:02d}.jpg",
                           tiles=[dict(slot=k + 1, split_group=1, **t) for k, t in enumerate(tiles)]))
    return dict(grid=[6, 8], tile_px=256, sheets=sheets)


def _tile(x: int, y: int, image: str = "1.jpg") -> dict:
    return dict(image=image, x=x, y=y, w=256, h=256)


# --------------------------------------------------------------------------
# 這一遍不是簽核
# --------------------------------------------------------------------------

def test_firstpass_declares_itself_unreviewed(doc):
    assert doc["meta"]["annotator"] == "claude-first-pass"
    assert doc["meta"]["human_status"] == "unreviewed"


def test_the_firstpass_annotator_is_rejected_by_the_review_tool(doc):
    """名字就是那道門：模型名整批擋，所以這份標記進不了決策檔。"""
    with pytest.raises(rt.IngestError):
        rt.validate_annotator(doc["meta"]["annotator"])


def test_a_firstpass_export_cannot_be_merged_into_decisions(doc):
    items = [dict(item_id="a" * 16, queue="healthy", image="1.jpg", region=[0, 0, 256, 256])]
    exported = dict(annotator=doc["meta"]["annotator"], items_fingerprint="x",
                    decisions=[dict(item_id="a" * 16, decision="yes", view_scale=1.0)])
    with pytest.raises(rt.IngestError):
        rt.merge_decisions(rt._empty_decisions(), exported,
                           {it["item_id"]: it for it in items},
                           rt.validate_annotator(exported["annotator"]), items_fp="x")


def test_pack_refuses_to_write_if_the_annotator_stops_being_blocked(monkeypatch):
    """自我對帳：黑名單若哪天放寬，這份標記就不該再產出。"""
    monkeypatch.setattr(fp, "MODEL_ANNOTATOR", __import__("re").compile(r"^$"))
    with pytest.raises(fp.FirstPassError):
        fp.pack(_layout([[_tile(0, 0)]]), {"c00": "b"})


# --------------------------------------------------------------------------
# 身分綁像素
# --------------------------------------------------------------------------

def test_item_ids_are_the_healthy_queue_ids(doc):
    for t in doc["tiles"]:
        assert t["item_id"] == rt.item_id("healthy", t["image"], (t["x"], t["y"], t["w"], t["h"]))


def test_every_candidate_tile_is_labelled_once(doc):
    assert doc["meta"]["n_tiles"] == N_TILES == len(doc["tiles"])
    assert len({t["item_id"] for t in doc["tiles"]}) == N_TILES


def test_verify_names_tiles_that_no_longer_match_the_candidates(doc):
    manifest = dict(tiles=[dict(image=t["image"], x=t["x"], y=t["y"], w=t["w"], h=t["h"],
                                bg_guess="blade_like") for t in doc["tiles"][:-1]])
    out = fp.verify(doc, manifest)
    assert out["unlabelled"] == 0
    assert out["problems"] and "對不上" in out["problems"][0]


# --------------------------------------------------------------------------
# 封閉字彙與數量
# --------------------------------------------------------------------------

def test_codes_are_a_closed_vocabulary(doc):
    assert {t["code"] for t in doc["tiles"]} <= set(fp.VOCAB)
    assert doc["meta"]["counts"] == dict(Counter(t["code"] for t in doc["tiles"]))


def test_read_codes_refuses_a_letter_outside_the_table(tmp_path):
    p = tmp_path / "c00.txt"
    p.write_text("bbbz\n", encoding="utf-8")
    with pytest.raises(fp.FirstPassError):
        fp.read_codes(p)


def test_pack_refuses_when_the_sheet_and_the_labels_disagree():
    layout = _layout([[_tile(0, 0), _tile(256, 0), _tile(512, 0)]])
    with pytest.raises(fp.FirstPassError):
        fp.pack(layout, {"c00": "bb"})


def test_pack_refuses_a_sheet_with_no_labels_and_labels_with_no_sheet():
    layout = _layout([[_tile(0, 0)], [_tile(256, 0)]])
    with pytest.raises(fp.FirstPassError):
        fp.pack(layout, {"c00": "b"})
    with pytest.raises(fp.FirstPassError):
        fp.pack(_layout([[_tile(0, 0)]]), {"c00": "b", "c09": "b"})


def test_measured_fraction_replaces_the_64_sample_estimate(doc):
    """報告裡的數字要來自這 1,842 格，不是 64 格抽樣。"""
    n = len(doc["tiles"])
    b = doc["meta"]["counts"]["b"]
    assert doc["meta"]["blade_surface_fraction"] == pytest.approx(b / n, abs=5e-5)
    assert doc["meta"]["blade_present_fraction"] == pytest.approx(
        (b + doc["meta"]["counts"]["e"]) / n, abs=5e-5)


# --------------------------------------------------------------------------
# 先驗只改順序
# --------------------------------------------------------------------------

def _items(codes: list[str], doc: dict) -> list[dict]:
    by_code: dict[str, list[dict]] = {}
    for t in doc["tiles"]:
        by_code.setdefault(t["code"], []).append(t)
    out = []
    for i, c in enumerate(codes):
        t = by_code[c][i]
        out.append(dict(item_id=t["item_id"], queue="healthy", image=t["image"],
                        region=[t["x"], t["y"], t["w"], t["h"]], caption=f"{t['image']}"))
    return out


def test_prior_reorders_but_keeps_exactly_the_same_items(doc):
    items = _items(["n", "u", "e", "b"], doc)
    before = {it["item_id"] for it in items}
    stats = fp_apply(items, doc)
    assert {it["item_id"] for it in items} == before
    assert stats["matched"] == 4 and stats["missing"] == 0
    assert [it["prior"] for it in items] == ["b", "e", "u", "n"]


def test_prior_never_writes_a_decision(doc):
    items = _items(["b", "n"], doc)
    fp_apply(items, doc)
    for it in items:
        assert "human_status" not in it and "decision" not in it
        assert it["prior_annotator"] == "claude-first-pass"
        assert "未複核" in it["caption"]


def test_items_without_a_prior_are_kept_and_counted(doc):
    items = _items(["b"], doc) + [dict(item_id="z" * 16, queue="healthy", image="9999.jpg",
                                       region=[0, 0, 256, 256], caption="9999.jpg")]
    stats = fp_apply(items, doc)
    assert stats["matched"] == 1 and stats["missing"] == 1
    assert len(items) == 2


def test_status_breaks_the_backlog_down_by_prior(doc):
    items = _items(["b", "b", "e", "n"], doc)
    fp_apply(items, doc)
    items_doc = dict(meta=dict(fingerprint="x"), items=items)
    decisions = dict(entries=[dict(item_id=items[0]["item_id"], queue="healthy",
                                   human_status="healthy", annotator="某人")])
    summary = rt.summarise_status(items_doc, decisions)
    assert summary["remaining"]["healthy"] == 3
    assert summary["remaining_by_prior"] == {"b": 1, "e": 1, "n": 1}


def fp_apply(items: list[dict], doc: dict) -> dict:
    return rt.apply_firstpass_prior(items, doc)
