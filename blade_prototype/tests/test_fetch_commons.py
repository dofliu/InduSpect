"""`scripts/fetch_commons_turbines.py` 的守門：Commons 整機照來源。

守三件事：①縮圖網址只准改成 Wikimedia 常用寬度（非常用寬度會被 429，實測過）；②機型推斷的優先序與「對到兩個就不猜」；
③接受規則——沒有型錄尺寸的照片不進候選（沒有轉子半徑就沒有 cm/px、也沒有姿態）。
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import fetch_commons_turbines as F  # noqa: E402

THUMB = "https://upload.wikimedia.org/wikipedia/commons/thumb/0/0c/X.jpg/2400px-X.jpg"


def test_standard_thumb_url_rewrites_to_common_width() -> None:
    assert F.standard_thumb_url(THUMB) == THUMB.replace("2400px", "1920px")
    assert F.standard_thumb_url(THUMB, 1280) == THUMB.replace("2400px", "1280px")
    assert F.standard_thumb_url(None) is None
    assert F.standard_thumb_url("https://upload.wikimedia.org/wikipedia/commons/0/0c/X.jpg") == \
        "https://upload.wikimedia.org/wikipedia/commons/0/0c/X.jpg"  # 原圖網址原樣回


def test_standard_thumb_url_refuses_uncommon_width() -> None:
    with pytest.raises(ValueError):
        F.standard_thumb_url(THUMB, 2400)


def test_infer_model_prefers_file_category() -> None:
    key, basis = F.infer_model(["Category:Enercon E-82", "Category:Wind turbines in Germany"], "Vestas V90 in the background")
    assert key == "Enercon E-82" and basis == "Category:Enercon E-82".replace("Category:", "category:Category:")


def test_infer_model_from_category_name_and_description() -> None:
    assert F.infer_model(["Category:Enercon E-53 in Lower Saxony"], "") == ("Enercon E-53", "category-name")
    assert F.infer_model(["Category:Wind turbines in Denmark"], "A Vestas V-90 at dusk") == ("Vestas V90", "description")
    assert F.infer_model([], "Enercon E82 E2, hub height 98 m") == ("Enercon E-82", "description")
    assert F.infer_model([], "Siemens SWT-2.3-93 nacelle") == ("Siemens SWT-2.3-93", "description")


def test_infer_model_does_not_guess() -> None:
    assert F.infer_model([], "two turbines: an E-82 next to a V90") == (None, None)  # 對到兩個
    assert F.infer_model([], "Autobahn E 82 exit, no turbine model here") == (None, None)  # 空白隔開的不算
    assert F.infer_model([], "V900 only") == (None, None)  # 數字接著數字不算 V90


def test_every_spec_has_a_regex_that_matches_its_own_key() -> None:
    for key in F.MODEL_SPECS:
        assert F._model_regex(key).search(key), key


def test_accept_requires_licence_focal_size_and_spec() -> None:
    base = {"license": "CC BY-SA 4.0", "focal_35mm": 50.0, "width": 4000, "height": 3000, "rotor_diameter_m": 82.0}
    assert F._accept(base, 1600) == (True, "ok")
    assert F._accept({**base, "license": "Fair use"}, 1600) == (False, "license")
    assert F._accept({**base, "focal_35mm": None}, 1600) == (False, "no_f35")
    assert F._accept({**base, "width": 1200}, 1600) == (False, "small")
    assert F._accept({**base, "rotor_diameter_m": None}, 1600) == (False, "no_spec")


def test_hub_height_from_description() -> None:
    assert F._hub_from_description("Enercon E-82 E2 with a hub height of 138 m") == 138.0
    assert F._hub_from_description("Nabenhöhe 98,5 m") == 98.5
    assert F._hub_from_description("a 500 m long road") is None


def test_subcategories_breadth_first_with_depth() -> None:
    tree = {
        "Category:Enercon E-82": ["Category:Enercon E-82 E2", "Category:Enercon E-82 in Poland"],
        "Category:Enercon E-82 E2": ["Category:Windpark X"],
        "Category:Enercon E-82 in Poland": [],
        "Category:Windpark X": ["Category:Enercon E-82"],  # 環：不得回到根
    }

    def fake(url: str) -> dict:
        import urllib.parse
        q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
        return {"query": {"categorymembers": [{"title": x} for x in tree[q["cmtitle"][0]]]}}

    assert F.subcategories("Category:Enercon E-82", 1, 0.0, fetch=fake) == \
        ["Category:Enercon E-82 E2", "Category:Enercon E-82 in Poland"]
    assert F.subcategories("Category:Enercon E-82", 3, 0.0, fetch=fake) == \
        ["Category:Enercon E-82 E2", "Category:Enercon E-82 in Poland", "Category:Windpark X"]
