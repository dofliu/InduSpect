"""真實影像驗證報告產生器（`scripts/make_validation_report.py`）。

真實語料不進版控，所以這裡用合成影像 + 假的 results.json 當夾具，驗的是**契約**：
報告自帶內容、統計由資料算出（不是寫死）、缺影像不會炸、以及「只給一組結果」與
「給前後兩組」兩種模式都成立。它同時是 `blade_proto.report._CSS` 與 `charts` 的
迴歸網——那兩個模組改名或改結構，這支腳本會先在這裡壞掉，而不是在要交報告的時候。
"""

import base64
import importlib.util
import json
import os
import re

import cv2
import pytest

from blade_proto.synth import SceneSpec, render_front

_SPEC = importlib.util.spec_from_file_location(
    "make_validation_report",
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                 "scripts", "make_validation_report.py"))
mvr = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(mvr)


# 用敘述段落真的會引用的 id，才會走到 pair_block / solo_block 的內嵌影像分支。
# 「b78792bf 有疊圖、126b2482 沒疊圖、1573f056 連語料都沒有」三種狀態各一。
HAS_OVERLAY = "b78792bf"      # §3 F1 的對照案例
NO_OVERLAY = "126b2482"       # §4 引用，但故意不給疊圖
SOLO = "06a2eac4"             # §6 閘門放行的單張
OUTSIDE = "08233c81"          # 設計範圍外

LABELS = {
    HAS_OVERLAY: {"category": "single", "hub": [0.5, 0.4], "set": "A",
                  "sky": "clear", "framing": "near", "conditions": ["荒原地面"]},
    NO_OVERLAY: {"category": "single", "hub": [0.5, 0.4], "set": "A",
                 "sky": "cloud", "framing": "near", "conditions": ["濃積雲"]},
    SOLO: {"category": "single", "hub": [0.5, 0.4], "set": "B",
           "sky": "clear", "framing": "near", "conditions": ["樹林遮蔽"]},
    OUTSIDE: {"category": "multi", "set": "B", "conditions": ["多台同框"]},
}


def _result(key, *, hub_ok=True, blades=3, spread=0.05, failed=False, gate=True):
    if failed:
        return {"id": key, "category": LABELS[key]["category"], "failed": True,
                "conditions": LABELS[key].get("conditions", []),
                "verdict": {"ok": False, "reasons": ["結構定位失敗"], "warnings": [], "metrics": {}}}
    return {
        "id": key, "category": LABELS[key]["category"], "failed": False,
        "conditions": LABELS[key].get("conditions", []),
        "hub_err_diag": 0.01 if hub_ok else 0.30, "hub_ok": hub_ok,
        "n_blades": blades, "tip_radius_spread_frac": spread,
        "verdict": {"ok": gate, "reasons": [], "warnings": [], "metrics": {}},
    }


@pytest.fixture
def corpus(tmp_path):
    """兩張合成全機照 + 一張假的「多台同框」，湊出 manifest 與兩組 results.json。"""
    img, _ = render_front(SceneSpec(cm_per_px=12.0, azimuth_deg=90.0, seed=4))
    cdir = tmp_path / "corpus"
    cdir.mkdir()
    man = []
    for key in LABELS:
        cv2.imwrite(str(cdir / f"{key}.jpg"), img)
        man.append({"id": key + "-0000-0000", "file": f"{key}.jpg", "title": f"照片 {key}",
                    "creator": "某人", "license": "by-sa",
                    "landing": f"https://example.org/{key}"})
    (cdir / "manifest.json").write_text(json.dumps(man, ensure_ascii=False), encoding="utf-8")

    for phase, recs in (
        # 刻意的落差：3 張 single 改動前 0 命中、改動後 2 命中；
        # 設計範圍外那張改動前安靜給出三葉、改動後只剩一片。
        ("before", [_result(HAS_OVERLAY, hub_ok=False, blades=0, spread=None, gate=False),
                    _result(NO_OVERLAY, failed=True),
                    _result(SOLO, hub_ok=False, blades=2, spread=0.5, gate=False),
                    _result(OUTSIDE, blades=3, spread=0.9, gate=False)]),
        ("after", [_result(HAS_OVERLAY),
                   _result(NO_OVERLAY, failed=True),
                   _result(SOLO),
                   _result(OUTSIDE, blades=1, spread=None, gate=False)]),
    ):
        d = tmp_path / phase
        d.mkdir()
        (d / "results.json").write_text(json.dumps(recs, ensure_ascii=False), encoding="utf-8")
        for key in (HAS_OVERLAY, SOLO):  # NO_OVERLAY 故意不給，測缺影像分支
            cv2.imwrite(str(d / f"{key}_overlay.jpg"), img)
    return tmp_path, cdir


def _build(tmp_path, cdir, *, with_before=True):
    c = mvr.Corpus(LABELS, [str(cdir)], [str(tmp_path / "after")],
                   [str(tmp_path / "before")] if with_before else [])
    return c, mvr.build_html(c)


def test_report_is_self_contained_and_embeds_images(corpus):
    tmp_path, cdir = corpus
    _, html = _build(tmp_path, cdir)
    assert "<!doctype html>" in html.lower()
    assert not re.search(r'(src|href)\s*=\s*"(?!data:)(https?:)?//', html)
    assert "<script" not in html.lower()
    uris = re.findall(r'src="data:image/jpeg;base64,([^"]+)"', html)
    assert uris, "報告裡應該有內嵌影像"
    for u in uris:
        raw = base64.b64decode(u)
        assert raw[:2] == b"\xff\xd8" and len(raw) > 2000  # 真的是可讀的 JPEG


def test_stats_come_from_the_data_not_hardcoded(corpus):
    """夾具刻意設成「2 張 single，改動前 0 命中、改動後 1 命中」——報告要照數字講。"""
    tmp_path, cdir = corpus
    c, html = _build(tmp_path, cdir)
    assert mvr.summarise(c, c.singles(), "before")["hit"] == 0
    assert mvr.summarise(c, c.singles(), "after")["hit"] == 2
    assert "0 / 3" in html and "2 / 3" in html
    # 超出設計範圍卻安靜給出三葉結構：改動前 1 張、改動後 0 張
    assert mvr.quiet_three(c, "before") == [OUTSIDE]
    assert mvr.quiet_three(c, "after") == []


def test_usable_requires_hub_blades_and_consistent_radii():
    """「真正可用」三個條件缺一不可——半徑離散大代表抓到地物當葉片。"""
    assert mvr._usable({"hub_ok": True, "n_blades": 3, "tip_radius_spread_frac": 0.05})
    assert not mvr._usable({"hub_ok": True, "n_blades": 3, "tip_radius_spread_frac": 0.9})
    assert not mvr._usable({"hub_ok": True, "n_blades": 2, "tip_radius_spread_frac": 0.01})
    assert not mvr._usable({"hub_ok": False, "n_blades": 3, "tip_radius_spread_frac": 0.01})
    assert not mvr._usable({"hub_ok": True, "n_blades": 3, "tip_radius_spread_frac": None})


def test_missing_overlay_degrades_instead_of_crashing(corpus):
    """Openverse 的搜尋結果會漂移，抓不到的案例要缺圖而不是整份報告掛掉。"""
    tmp_path, cdir = corpus
    c, html = _build(tmp_path, cdir)
    assert "影像未提供或讀取失敗" in html      # NO_OVERLAY 沒有疊圖
    assert mvr.image_uri(None) is None
    assert mvr.image_uri(str(tmp_path / "nope.jpg")) is None
    # 敘述段落引用的 id 不在語料裡時，只留一行說明
    assert "語料中沒有 <code>1573f056</code>" in html


def test_single_state_mode_drops_the_before_columns(corpus):
    tmp_path, cdir = corpus
    _, both = _build(tmp_path, cdir)
    _, only = _build(tmp_path, cdir, with_before=False)
    assert "改動前後總結果" in both and "3. 修好的失敗模式" in both
    assert "總結果" in only and "修好的失敗模式" not in only
    assert "<b>改動前</b>" in both and "<b>改動前</b>" not in only
    assert "<b>結果</b>" in only


def test_report_keeps_the_safety_framing(corpus):
    """這份報告的立場不能被改掉：篩檢、需人工確認、不下合格判定。"""
    tmp_path, cdir = corpus
    _, html = _build(tmp_path, cdir)
    assert "天空模型是唯一真正的瓶頸" in html
    assert "看起來合格的錯誤報告" in html
    assert "Phase 1 之前先補分割" in html
    assert "某人" in html and "CC BY-SA" in html   # 授權署名不可省
    assert "https://example.org/" in html          # 來源頁要留得住
