"""Mode B 人工複核工具的守門測試。

這支工具是「第一版標記」與「可用資料」之間唯一的那道門，所以測的重點不是它跑不跑得動，
而是**它擋不擋得住不該通過的東西**：模型自己簽核、在縮圖上升格、決策套到別的像素上、
以及「跳過」被當成「乾淨」。四條規則各有反向測試。
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("closeup_review_tool", ROOT / "scripts" / "closeup_review_tool.py")
rt = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rt)

NS = json.loads((ROOT / "data" / "closeup_normal_structures_wtb.json").read_text(encoding="utf-8"))
BOXES = json.loads((ROOT / "data" / "closeup_normal_structure_boxes_wtb.json").read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def dataset(tmp_path_factory) -> Path:
    """假語料：只要檔名對得上三份標記檔即可，內容是雜訊。真語料不進版控。"""
    import cv2
    ds = tmp_path_factory.mktemp("ds") / "JPEGImages"
    ds.mkdir(parents=True)
    names = {f"{k}.jpg" for k, v in NS["labels"].items() if "x" in v} | set(BOXES["images"]) | {"7.jpg"}
    rng = np.random.default_rng(0)
    for n in names:
        img = rng.integers(0, 255, (1024, 1024, 3), dtype=np.uint8)
        cv2.imwrite(str(ds / n), img)
    return ds.parent


@pytest.fixture(scope="module")
def manifest(tmp_path_factory) -> Path:
    tiles = [
        dict(image="7.jpg", x=0, y=0, w=256, h=256, bg_guess="blade_like", image_artifact_tags=""),
        dict(image="7.jpg", x=256, y=0, w=256, h=256, bg_guess="blade_like", image_artifact_tags="a"),
        dict(image="7.jpg", x=512, y=0, w=256, h=256, bg_guess="sky_like", image_artifact_tags=""),
    ]
    p = tmp_path_factory.mktemp("mf") / "healthy_candidates.json"
    p.write_text(json.dumps(dict(summary={}, tiles=tiles), ensure_ascii=False), encoding="utf-8")
    return p


@pytest.fixture(scope="module")
def workspace(tmp_path_factory, dataset: Path, manifest: Path) -> Path:
    out = tmp_path_factory.mktemp("ws")
    rt.main(["build", str(dataset), str(out), "--manifest", str(manifest)])
    return out


@pytest.fixture()
def items_doc(workspace: Path) -> dict:
    return json.loads((workspace / "items.json").read_text(encoding="utf-8"))


# --- 身分：決策綁在像素上 -------------------------------------------------

def test_item_id_binds_to_pixels() -> None:
    a = rt.item_id("healthy", "7.jpg", (0, 0, 256, 256))
    assert a == rt.item_id("healthy", "7.jpg", (0, 0, 256, 256))
    assert a != rt.item_id("healthy", "7.jpg", (16, 0, 256, 256)), "座標不同卻拿到同一個身分"
    assert a != rt.item_id("boxes", "7.jpg", (0, 0, 256, 256)), "佇列不同卻拿到同一個身分"


# --- build ---------------------------------------------------------------

def test_build_emits_self_contained_workspace(workspace: Path, items_doc: dict) -> None:
    assert (workspace / "review.html").exists()
    for it in items_doc["items"]:
        assert (workspace / it["crop"]).exists()
        assert (workspace / it["context"]).exists()
    html = (workspace / "review.html").read_text(encoding="utf-8")
    # file:// 下 fetch 會被 CORS 擋掉，所以資料一定要內嵌。
    assert "fetch(" not in html
    assert items_doc["items"][0]["item_id"] in html


def test_build_healthy_takes_only_requested_bg_guess(items_doc: dict) -> None:
    healthy = [it for it in items_doc["items"] if it["queue"] == "healthy"]
    assert len(healthy) == 2, "預設只收 blade_like，sky_like 不該進來"
    assert {it["region"][0] for it in healthy} == {0, 256}


def test_build_covers_the_two_small_queues(items_doc: dict) -> None:
    ns = [it for it in items_doc["items"] if it["queue"] == "ns_recheck"]
    boxes = [it for it in items_doc["items"] if it["queue"] == "boxes"]
    assert {it["image"] for it in ns} == {f"{k}.jpg" for k, v in NS["labels"].items() if "x" in v}
    assert all(it["region"] == [0, 0, 1024, 1024] for it in ns), "x 複核要在全解析度上看整張"
    assert len(boxes) == sum(1 for b in BOXES["boxes"] if b["bbox"] is not None)
    assert all(it["overlay"] is not None for it in boxes), "框要畫得出來才複核得了"


# --- ingest：四條規則的反向測試 -------------------------------------------

def _exported(items: list[dict], decision="yes", scale=2.0, reason=None) -> dict:
    return dict(annotator="王小明", items_fingerprint="x",
                decisions=[dict(item_id=it["item_id"], decision=decision, reason=reason,
                                view_scale=scale, decided_at="2026-09-14T00:00:00Z") for it in items])


def test_model_annotator_is_refused(items_doc: dict) -> None:
    """規則 1：第一版標記的 claude-first-pass 不可以經由匯入變成簽核。"""
    for name in ("claude-first-pass", "GPT-4o", "", "  ", None, "auto-labeler"):
        with pytest.raises(rt.IngestError):
            rt.validate_annotator(name)
    assert rt.validate_annotator("王小明") == "王小明"


def test_promotion_below_one_to_one_is_refused(items_doc: dict) -> None:
    """規則 3：654 的教訓——縮圖上看到的不算數。但『否決』不受限（縮圖也看得出不是葉片）。"""
    items = [it for it in items_doc["items"] if it["queue"] == "healthy"]
    index = {it["item_id"]: it for it in items_doc["items"]}
    doc, stats = rt.merge_decisions(rt._empty_decisions(), _exported(items, scale=0.6), index, "王小明", items_fp="f")
    assert stats["rejected_low_scale"] == len(items) and doc["entries"] == []
    doc, stats = rt.merge_decisions(rt._empty_decisions(), _exported(items, "no", scale=0.6), index, "王小明", items_fp="f")
    assert stats["accepted"] == len(items) and stats["rejected_low_scale"] == 0


def test_unknown_item_is_refused(items_doc: dict) -> None:
    """規則 4：對不上像素的決策不收。"""
    index = {it["item_id"]: it for it in items_doc["items"]}
    exported = dict(decisions=[dict(item_id="deadbeefdeadbeef", decision="yes", view_scale=2.0)])
    doc, stats = rt.merge_decisions(rt._empty_decisions(), exported, index, "王小明", items_fp="f")
    assert stats["rejected_unknown_item"] == 1 and doc["entries"] == []


def test_skip_is_not_healthy(items_doc: dict) -> None:
    """規則 2：跳過、沒看的都不進決策檔，維持 unreviewed。"""
    index = {it["item_id"]: it for it in items_doc["items"]}
    it = items_doc["items"][0]
    exported = dict(decisions=[dict(item_id=it["item_id"], decision="skip", view_scale=2.0)])
    doc, stats = rt.merge_decisions(rt._empty_decisions(), exported, index, "王小明", items_fp="f")
    assert doc["entries"] == [] and stats["skipped_no_decision"] == 1


def test_accepted_entry_carries_who_and_how(items_doc: dict) -> None:
    index = {it["item_id"]: it for it in items_doc["items"]}
    items = [it for it in items_doc["items"] if it["queue"] == "healthy"][:1]
    doc, stats = rt.merge_decisions(rt._empty_decisions(), _exported(items), index, "王小明", items_fp="fp1")
    e = doc["entries"][0]
    assert (e["human_status"], e["annotator"], e["view_scale"], e["revision"]) == ("healthy", "王小明", 2.0, 1)
    assert e["items_fingerprint"] == "fp1" and e["region"] == items[0]["region"]
    # 同一格再判一次是改判，不是多一筆。
    doc2, stats2 = rt.merge_decisions(doc, _exported(items, "no", reason="not_blade"), index, "李小華", items_fp="fp1")
    assert len(doc2["entries"]) == 1 and stats2["updated"] == 1
    assert doc2["entries"][0]["human_status"] == "rejected"
    assert doc2["entries"][0]["reason"] == "not_blade" and doc2["entries"][0]["revision"] == 2


def test_queue_yes_status_per_queue(items_doc: dict) -> None:
    """三個佇列的 yes 意義不同，寫進去的狀態也要不同。"""
    index = {it["item_id"]: it for it in items_doc["items"]}
    for queue, expect in (("healthy", "healthy"), ("ns_recheck", "confirmed"), ("boxes", "confirmed")):
        items = [it for it in items_doc["items"] if it["queue"] == queue][:1]
        doc, _ = rt.merge_decisions(rt._empty_decisions(), _exported(items), index, "王小明", items_fp="f")
        assert doc["entries"][0]["human_status"] == expect


def test_unknown_reason_code_is_dropped_not_stored(items_doc: dict) -> None:
    index = {it["item_id"]: it for it in items_doc["items"]}
    items = [it for it in items_doc["items"] if it["queue"] == "healthy"][:1]
    doc, _ = rt.merge_decisions(rt._empty_decisions(), _exported(items, "no", reason="因為我覺得"), index,
                                "王小明", items_fp="f")
    assert doc["entries"][0]["reason"] is None


# --- status --------------------------------------------------------------

def test_status_counts_remaining_and_flags_stale(items_doc: dict) -> None:
    index = {it["item_id"]: it for it in items_doc["items"]}
    items = [it for it in items_doc["items"] if it["queue"] == "healthy"][:1]
    doc, _ = rt.merge_decisions(rt._empty_decisions(), _exported(items), index, "王小明", items_fp="f")
    s = rt.summarise_status(items_doc, doc)
    assert s["remaining"]["healthy"] == 1 and s["stale_entries"] == []
    # 候選重新產生後對不上的，要被列出來而不是默默留著。
    shrunk = dict(meta=items_doc["meta"], items=[it for it in items_doc["items"] if it["queue"] != "healthy"])
    assert rt.summarise_status(shrunk, doc)["stale_entries"] == [items[0]["item_id"]]


# --- 版控中的決策檔：永遠不得出現沒有人簽的升格 ---------------------------

def test_committed_decisions_have_no_unsigned_promotion() -> None:
    doc = json.loads((ROOT / "data" / "closeup_review_decisions.json").read_text(encoding="utf-8"))
    for e in doc["entries"]:
        assert not rt.MODEL_ANNOTATOR.match(e["annotator"]), f"{e['item_id']} 的簽核人不是人"
        if e["human_status"] in ("healthy", "confirmed"):
            assert e["view_scale"] >= 1.0, f"{e['item_id']} 在縮圖上升格"
