"""WTBs2025 去重與分群（`scripts/wtbs2025_dedup.py`）的守門測試。

影像不進版控，所以這裡不重跑 pHash，只讀結果檔；檔名解析與分群邏輯用合成輸入驗。
最重要的一條是 `test_folder_is_not_an_image_level_label`：那是這份工作真正的發現，
`CROSS_CORPUS_VALIDATION.md` §3 的逐類數字要靠它來讀。
"""
from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / "data" / "wtbs2025_dedup.json"
REPORT = ROOT / "WTBS2025_DEDUP.md"

sys.path.insert(0, str(ROOT / "scripts"))
_spec = importlib.util.spec_from_file_location("wtbs2025_dedup", ROOT / "scripts" / "wtbs2025_dedup.py")
D = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(D)


@pytest.fixture(scope="module")
def doc() -> dict:
    return json.loads(RESULTS.read_text(encoding="utf-8"))


def test_report_in_sync_with_results(doc: dict) -> None:
    assert REPORT.read_text(encoding="utf-8") == D.render_markdown(doc, "data/wtbs2025_dedup.json")


def test_covers_the_whole_corpus(doc: dict) -> None:
    s = doc["summary"]
    assert s["n_files"] == 7544, "WTBs2025 是 7,544 張；數字變了代表換了語料版本"
    assert sum(v["n_files"] for v in s["per_class"].values()) == s["n_files"]
    assert len(s["per_class"]) == 9


def test_filename_dedup_only_touches_two_classes(doc: dict) -> None:
    """接棒筆記寫的「按原始編號去重」只影響 `oil leakage` 與 `lightning strikes`。

    其餘七類的檔名編號不重複——這一條紅了代表語料換版或解析規則壞了。
    """
    per = doc["summary"]["per_class"]
    augmented = {c for c, v in per.items() if v["n_files"] != v["n_original_ids"]}
    assert augmented == {"oil leakage", "lightning strikes"}, augmented
    assert per["oil leakage"]["n_original_ids"] == 29
    assert per["lightning strikes"]["n_original_ids"] == 57


def test_folder_is_not_an_image_level_label(doc: dict) -> None:
    """**這份工作真正的發現**：同一張照片出現在多個類別資料夾。

    WTBs2025 是 YOLO 偵測語料，一張照片含幾種缺陷就被複製到幾個資料夾、各自只帶那一類的框。
    所以拿資料夾當影像級標籤算逐類指標，是拿部分標籤當全部。
    紅了代表語料換版或門檻改了——`CROSS_CORPUS_VALIDATION.md` §3 的讀法要跟著改。
    """
    s = doc["summary"]
    assert s["cross_class_identical_pairs"] > 0
    sample = s["cross_class_pixel_sample"]
    assert sample["checked"] >= 20
    assert sample["identical"] / sample["checked"] > 0.9, "跨類別配對不再是同一張了"


def test_gan_variant_is_a_copy_not_a_generated_image(doc: dict) -> None:
    """`lightning strikes` 的 `GAN` 尾碼會讓人以為是生成影像——實測是重新編碼的複本。"""
    g = doc["summary"]["gan_variant_check"]
    assert g["checked"] >= 20
    assert g["same_as_original"] == g["checked"]
    assert g["max_abs_diff"] < D.IDENTICAL_PIXEL_DIFF


def test_original_id_parses_both_naming_schemes() -> None:
    """兩套命名都要解得對：Roboflow 的 `.rf.<hash>` 與 lightning 的尾碼。"""
    assert D.original_id("2181_jpg.rf.be3dbf38dfe6f7b0660af1f8e60bb04b.jpg") == ("2181", "roboflow")
    assert D.original_id("1_JPG_jpg.rf.3d1db85709b221c390d360cdd10f88d9.jpg") == ("1", "roboflow")
    assert D.original_id("0.jpg") == ("0", "original")
    assert D.original_id("0GAN.png") == ("0", "GAN")
    assert D.original_id("0fl.png") == ("0", "fl")
    assert D.original_id("怪檔名.jpg") == ("怪檔名", "unknown")


def test_analyse_groups_identical_hashes_and_flags_cross_class() -> None:
    """分群邏輯用合成雜湊驗：一樣的 hash 要收成一群，跨類別的要被點名。"""
    same = "00" * 8
    other = "ff" * 8
    rows = {"a": {"1_jpg.rf.aaaaaaaa.jpg": same, "2_jpg.rf.bbbbbbbb.jpg": other},
            "b": {"3_jpg.rf.cccccccc.jpg": same}}
    s = D.analyse(rows)
    assert s["n_files"] == 3
    assert s["n_original_ids"] == 3          # 檔名編號各自不同
    assert s["n_content_groups"] == 2        # 但內容上 a/1 與 b/3 是同一群
    assert s["cross_class_identical_pairs"] == 1


def test_thresholds_are_declared_in_the_result(doc: dict) -> None:
    """門檻要寫在結果檔裡，報告才說得出自己用的是哪一個。"""
    s = doc["summary"]
    assert s["content_threshold"] == D.CONTENT_THRESHOLD
    assert s["identical_threshold"] == D.IDENTICAL_THRESHOLD
