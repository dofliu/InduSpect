"""解析度靈敏度（`scripts/resolution_sensitivity.py`）的守門測試。

這批釘的是 `RESOLUTION_SENSITIVITY.md` 那幾句話**真的是從結果檔算出來的**，以及
結果檔本身的形狀不會被無聲改掉。影像不進版控，所以這裡不重跑管線，只讀結果檔。

最重要的一條是 `test_side_views_flip_but_fronts_do_not`：SPEC §13-15 現在說
「換來源會弄丟側視」，那句話的依據就是這個檔。哪天它變成不翻了（例如側視規則補強了），
這個測試會紅——那是好事，但文件要跟著改，不能靜悄悄地留著舊結論。
"""
from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / "data" / "commons_pose_resolution_check.json"
REPORT = ROOT / "RESOLUTION_SENSITIVITY.md"


def _load_module():
    sys.path.insert(0, str(ROOT / "scripts"))
    spec = importlib.util.spec_from_file_location(
        "resolution_sensitivity", ROOT / "scripts" / "resolution_sensitivity.py")
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


S = _load_module()


@pytest.fixture(scope="module")
def doc() -> dict:
    return json.loads(RESULTS.read_text(encoding="utf-8"))


def test_results_file_shape(doc: dict) -> None:
    """每張都是「原圖那一跑放行」的照片——這份實驗量的是放行會不會掉。"""
    assert doc["variants"][0] == "orig"
    assert len(doc["variants"]) >= 2, "至少要有一個縮圖變體才有得比"
    assert len(doc["images"]) == 9, "放行照是 9 張（正視 5、側視 4）"
    for rid, r in doc["images"].items():
        assert r["variants"]["orig"]["ok"] is True, f"{rid} 在原圖那一跑不是放行"


def test_report_in_sync_with_results(doc: dict) -> None:
    """報告由結果檔渲染，數字不手抄。"""
    assert REPORT.read_text(encoding="utf-8") == S.render_markdown(
        doc, "data/commons_pose_resolution_check.json")


def test_side_views_flip_but_fronts_do_not(doc: dict) -> None:
    """量到的結構：**側視每一張都翻，正視一張都沒翻**（2026-09-28 實測）。

    翻＝收／不收、取景分類、葉片數、有沒有找到塔架任一個變了。
    """
    variants = [v for v in doc["variants"] if v != "orig"]
    sides, fronts = [], []
    for rid, r in doc["images"].items():
        base = r["variants"]["orig"]
        flipped = [v for v in variants
                   if (x := r["variants"].get(v))
                   and any(x[k] != base[k] for k in S.COMPARE_KEYS)]
        (sides if base["view"] == "side" else fronts).append((rid, flipped))

    assert len(sides) == 4 and len(fronts) == 5
    unflipped_sides = [rid for rid, f in sides if not f]
    assert unflipped_sides == [], f"側視改成穩定了，SPEC §13-15 要跟著改：{unflipped_sides}"
    flipped_fronts = [rid for rid, f in fronts if f]
    assert flipped_fronts == [], f"正視也開始翻了，結論要改寫：{flipped_fronts}"


def test_recompression_alone_is_enough_to_flip(doc: dict) -> None:
    """同一個像素尺寸、只差 JPEG 品質，翻掉的集合就不一樣——所以原因不只是解析度。

    這一條撐的是報告 §1 底下那句話；沒有它，讀者會以為只要抓夠大就沒事。
    """
    same_size = [v for v in doc["variants"] if v.startswith("w1280")]
    assert len(same_size) == 2, "要有兩個同尺寸不同品質的變體才比得出來"
    a, b = same_size
    for rid, sizes in doc["sizes"].items():
        if sizes.get(a) and sizes.get(b):
            assert sizes[a] == sizes[b], f"{rid}：兩個變體的像素尺寸不同，比不出再壓縮的效果"
    differing = [rid for rid, r in doc["images"].items()
                 if (x := r["variants"].get(a)) and (y := r["variants"].get(b))
                 and any(x[k] != y[k] for k in S.COMPARE_KEYS)]
    assert differing, "兩個品質之間沒有任何一張不同，報告 §1 的那句話要拿掉"


def test_note_keeps_the_simulation_caveat(doc: dict) -> None:
    """縮圖是本機模擬的，不是 Wikimedia 產的——這個限制不可以在改檔時掉了。"""
    assert "模擬" in doc["note"] and "Wikimedia" in doc["note"]


def test_summarise_ignores_continuous_wobble() -> None:
    """連續量（半徑離散）動一點點不算「翻掉」——否則每一張都會被算成翻掉。

    這守的是 `COMPARE_KEYS` 只收類別型欄位的那個決定。
    """
    base = {"ok": True, "view": "front", "n_blades": 3, "tower_found": True,
            "radius_spread": 0.100, "raw_flagged": [], "prebend_fit_ok": True}
    wobble = {**base, "radius_spread": 0.104}
    flip = {**base, "view": "side"}
    rows = {"a": {"variants": {"orig": base, "w1280q85": wobble}},
            "b": {"variants": {"orig": base, "w1280q85": flip}}}
    s = S.summarise(rows)["w1280q85"]
    assert s["compared"] == 2
    assert s["view_flipped"] == 1, "只有真的換了取景分類的那張算"
    assert s["gate_flipped"] == 0
