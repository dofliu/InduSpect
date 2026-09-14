"""Mode B 健康照／正常結構第一版標記的守門測試。

這三份檔案都是**單一標註者（模型）的第一版**，價值在於可被人複核、可被追溯。
測試守的是「不能偷偷升格」：任何一筆都不得在沒有人簽核的情況下變成 confirmed／healthy。
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
INTAKE = ROOT / "data" / "closeup_intake_wtb.json"
NS = ROOT / "data" / "closeup_normal_structures_wtb.json"
BOXES = ROOT / "data" / "closeup_normal_structure_boxes_wtb.json"
TAX = ROOT / "data" / "closeup_taxonomy.json"

N_IMAGES = 1065  # figshare 語料的張數；檔名 0.jpg … 1064.jpg


@pytest.fixture(scope="module")
def intake() -> dict:
    return json.loads(INTAKE.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def ns() -> dict:
    return json.loads(NS.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def boxes() -> dict:
    return json.loads(BOXES.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def tax() -> dict:
    return json.loads(TAX.read_text(encoding="utf-8"))


# --- 取像判定：全語料、每張一碼 ---------------------------------------------

def test_intake_covers_every_image(intake: dict) -> None:
    labels = intake["labels"]
    assert sorted(int(k) for k in labels) == list(range(N_IMAGES))
    assert set(labels.values()) <= set(intake["codes"])


def test_intake_crack_class_is_out_of_scope(intake: dict) -> None:
    """報告的核心數字：crack 類 0 張通過取像判定。這條釘住那個結論，改標記時會先紅。

    類別由 figshare 語料的 VOC 標註決定，這裡沒有那些 XML，所以釘的是報告寫死的索引集合。
    """
    labels = intake["labels"]
    n_pass = sum(1 for v in labels.values() if v == "P")
    assert n_pass == 839, f"合格張數變了：{n_pass}（報告寫 839）"
    n_whole = sum(1 for v in labels.values() if v == "W")
    assert n_whole == 185


def test_intake_declares_single_annotator(intake: dict) -> None:
    """不能讓人以為這是複核過的真值。"""
    assert "單一標註者" in intake["note"]


# --- 正常結構普查：抽樣 ⊆ 合格影像 ---------------------------------------

def test_ns_sample_is_subset_of_passing(intake: dict, ns: dict) -> None:
    passing = {k for k, v in intake["labels"].items() if v == "P"}
    keys = set(ns["labels"])
    assert len(keys) == 192
    assert keys <= passing, f"抽樣裡有沒通過取像判定的：{sorted(keys - passing)[:5]}"


def test_ns_codes_are_declared(ns: dict) -> None:
    codes = set(ns["codes"])
    bad = {k: v for k, v in ns["labels"].items() if not set(v) <= codes}
    assert not bad, f"未宣告的代碼：{bad}"


def test_ns_codes_map_to_taxonomy_normal_structures(ns: dict, tax: dict) -> None:
    """代碼說明裡引用的 normal_structures/* 要真的存在於分類表。"""
    ids = {n["id"] for n in tax["normal_structures"]}
    import re
    for code, desc in ns["codes"].items():
        for ref in re.findall(r"normal_structures/([a-z_]+)", desc):
            assert ref in ids, f"代碼 {code} 引用不存在的正常結構 {ref}"


def test_ns_survey_in_taxonomy_matches_labels(ns: dict, tax: dict) -> None:
    """分類表裡的普查數字是從標記檔算出來的，兩邊要一致。"""
    sv = tax["dataset_class_map"]["multiclass_wtb"]["normal_structure_survey"]
    assert sv["sample"] == len(ns["labels"])
    from collections import Counter
    c = Counter(ch for v in ns["labels"].values() for ch in v)
    assert sv["present"]["tip_marking（紅色葉尖塗裝）"] == c["r"]
    assert sv["present"]["ruler／比例尺"] == c["k"]
    assert sv["present"]["repair_patch"] == c["p"]
    assert sv["artifacts"]["灰色矩形塗抹（前處理）"] == c["a"]
    assert sv["artifacts"]["時間戳／文字燒錄"] == c["t"]
    for absent_code in ("L", "v"):
        assert c[absent_code] == 0, f"分類表說 {absent_code} 沒出現，標記檔裡卻有"


# --- 概略框：只在合格影像上、座標合法、沒有偷偷簽核 ------------------------

def test_boxes_reference_passing_images(intake: dict, boxes: dict) -> None:
    passing = {k for k, v in intake["labels"].items() if v == "P"}
    for b in boxes["boxes"]:
        idx = b["image"].removesuffix(".jpg")
        assert idx in passing, f"{b['image']} 沒通過取像判定卻有框"


def test_boxes_are_within_image(boxes: dict) -> None:
    for b in boxes["boxes"]:
        if b["bbox"] is None:
            assert b["kind"] == "none"
            continue
        x1, y1, x2, y2 = b["bbox"]
        assert 0 <= x1 < x2 <= 1024 and 0 <= y1 < y2 <= 1024, b


def test_boxes_kinds_resolve(boxes: dict, tax: dict) -> None:
    ids = {n["id"] for n in tax["normal_structures"]}
    for b in boxes["boxes"]:
        kind = b["kind"]
        if kind.startswith("normal_structures/"):
            assert kind.split("/", 1)[1] in ids, f"未知的正常結構 {kind}"
        else:
            assert kind == "none" or kind.split("/", 1)[0] in ("reference_object", "artifact"), kind


def test_nothing_is_confirmed_without_a_human(boxes: dict) -> None:
    """第一版標記全部 pending。誰把它改成 confirmed 又沒填人名，這裡會紅。"""
    assert boxes["human_status"] == "pending"
    assert boxes["annotator"] == "claude-first-pass"
    for b in boxes["boxes"]:
        assert b.get("approx") is True
        assert b.get("is_defect") is False
        assert b.get("human_status", "pending") == "pending"
