"""圖文報告（`report.py` + `charts.py`）。

驗的是「報告是否真的可交付」：自帶內容、影像真的內嵌、數值有出現、
異常有被標成待人工確認、沒有異常時不會謊稱合格。
"""

import base64
import os
import re

import cv2
import pytest

from blade_proto.charts import SERIES_ROLES, Series, bar_chart, line_chart
from blade_proto.report import CaseMeta, build_report, image_data_uri, write_report
from blade_proto.segmentation import find_structure, segment_turbine
from blade_proto.geometry import compare_blades, profiles_from_structure
from blade_proto.surface import analyze_blade_edges
from blade_proto.synth import SceneSpec, render_blade_segment, render_front


def _still_payload(tmp_path, deflection_cm=(500, 0, 0)):
    img, _ = render_front(SceneSpec(cm_per_px=12.0, azimuth_deg=90.0,
                                    tip_deflection_cm=deflection_cm, seed=3))
    path = str(tmp_path / "front.png")
    cv2.imwrite(path, img)
    seg = segment_turbine(img)
    st = find_structure(seg.mask)
    profs = profiles_from_structure(st)
    return {
        "image": path,
        "size": [img.shape[1], img.shape[0]],
        "segmentation": {"threshold_sigma": seg.threshold,
                         "mask_area_frac": float((seg.mask > 0).mean())},
        "structure": {"hub": st.hub, "hub_radius_px": st.hub_radius_px,
                      "hub_refined": st.hub_refined, "tower_found": st.tower_found,
                      "tower_roll_deg": st.tower_angle_deg,
                      "tower_width_px": st.tower_width_px,
                      "n_blades": len(st.blades), "notes": st.notes},
        "blades": [p.to_dict() for p in profs],
        "comparison": compare_blades(profs, noise_floor_px=1.2, cm_per_px=12.0),
    }, path


def _edge_payload(tmp_path, erosion_cm=3.0):
    img, _ = render_blade_segment(cm_per_px=0.4, erosion_amp_cm=erosion_cm, seed=1)
    path = str(tmp_path / "seg.png")
    cv2.imwrite(path, img)
    res = analyze_blade_edges(img, cm_per_px=0.4, leading_edge="top")
    return {"image": path, **res.to_dict()}, path


_VIDEO = {
    "video": "side.mp4", "view": "side", "fps": 15.0, "n_frames": 75,
    "rpm": 12.0, "direction": "n/a",
    "six_oclock_frames": [[6], [32], [56]],
    "radius_median_px": [224.6, 220.5, 224.4],
    "radius_outlier_index": 1, "radius_deviation_px": -3.9,
    "notes": ["側視：葉片標籤 0/1/2 為通過六點鐘的先後順序（循環），非實際葉片編號"],
}


def test_report_is_self_contained_and_embeds_images(tmp_path):
    still, still_img = _still_payload(tmp_path)
    edge, edge_img = _edge_payload(tmp_path)
    html = build_report(
        CaseMeta(asset_id="WTG-07", site_name="測試風場", turbine_state="stopped",
                 cm_per_px=12.0, rotor_radius_m=60.0, noise_floor_px=1.2),
        still=still, still_overlay=still_img, edge=edge, edge_overlay=edge_img,
        video=_VIDEO, tool_version="test")
    out = str(tmp_path / "report.html")
    write_report(out, html)
    assert os.path.getsize(out) > 20_000

    # 自帶內容：不引用任何外部資源
    assert "<!doctype html>" in html.lower()
    assert not re.search(r'(src|href)\s*=\s*"(?!data:)(https?:)?//', html)
    assert "<script" not in html.lower()  # 純靜態，離線與列印都不依賴 JS
    # 影像真的內嵌，且解得回可讀的 JPEG
    uris = re.findall(r'src="data:image/jpeg;base64,([^"]+)"', html)
    assert len(uris) >= 2
    for u in uris:
        raw = base64.b64decode(u)
        assert raw[:2] == b"\xff\xd8"  # JPEG SOI
        assert len(raw) > 2000
    # 三層都有區段、四個主題色變數都定義
    for sid in ("summary", "geometry", "surface", "dynamics"):
        assert f'id="{sid}"' in html
    for token in ("--series-1", "--status-critical", "prefers-color-scheme", '[data-theme="dark"]'):
        assert token in html


def test_report_flags_defect_and_requires_human_confirmation(tmp_path):
    """有缺陷的案例：必須出現在檢出清單、標為待確認，且不出現「合格」字樣。"""
    still, still_img = _still_payload(tmp_path, deflection_cm=(500, 0, 0))
    edge, edge_img = _edge_payload(tmp_path, erosion_cm=3.0)
    html = build_report(CaseMeta(asset_id="WTG-07", cm_per_px=12.0, noise_floor_px=1.2),
                        still=still, still_overlay=still_img,
                        edge=edge, edge_overlay=edge_img)
    assert "葉尖偏移" in html and "離群，需人工確認" in html
    assert "待確認" in html
    assert "疑似侵蝕" in html or "重度侵蝕" in html
    assert "本報告為演算法初判，需人工確認" in html
    assert "合格" not in html  # 篩檢報告不下合格判定
    # 偏移量以實尺呈現（12 cm/px × ~41 px ≈ 5 m 級）
    assert re.search(r"約 \d+ cm", html)


def test_report_does_not_claim_healthy_when_nothing_found(tmp_path):
    still, still_img = _still_payload(tmp_path, deflection_cm=(0, 0, 0))
    # 只留幾何互比這一項判定：合成天空的雲塊會讓部分分箱被判污染（那是另一條
    # 正當的檢出項目，見 test_report_reports_contaminated_bins），此處測「零檢出」分支
    for b in still["blades"]:
        b["n_contaminated_bins"] = 0
    html = build_report(CaseMeta(asset_id="WTG-08", noise_floor_px=1.2),
                        still=still, still_overlay=still_img)
    assert "三片一致" in html
    assert "這不等於葉片沒有問題" in html
    assert "無法取代無人機定檢" in html


def test_report_reports_contaminated_bins_as_a_finding(tmp_path):
    """雲塊/附著物黏在葉片邊緣會讓弦寬異常；報告要把它當成獨立的可信度警訊列出。"""
    still, still_img = _still_payload(tmp_path, deflection_cm=(0, 0, 0))
    still["blades"][0]["n_contaminated_bins"] = 5
    html = build_report(CaseMeta(noise_floor_px=1.2), still=still, still_overlay=still_img)
    assert "分箱的弦寬異常並經修補" in html
    assert "降權或重拍" in html
    assert "可信度下降" in html


def test_report_survives_missing_images_and_empty_layers(tmp_path):
    still, _ = _still_payload(tmp_path)
    html = build_report(CaseMeta(), still=still, still_overlay=str(tmp_path / "nope.png"))
    assert "影像未提供或讀取失敗" in html
    assert 'id="surface"' not in html and 'id="dynamics"' not in html
    assert image_data_uri(str(tmp_path / "nope.png")) is None


def test_charts_are_inline_svg_with_hover_and_legend():
    s = [Series("葉片 A", [0, 0.5, 1], [0, -5, -10], SERIES_ROLES[0]),
         Series("葉片 B", [0, 0.5, 1], [0, 0.1, 0.2], SERIES_ROLES[1])]
    svg = line_chart(s, title="測試", x_label="span", unit=" px")
    assert svg.count("<title>") >= 4  # 每系列一個 + 取樣點 hover
    assert "chart-legend" in svg and "葉片 A" in svg and "葉片 B" in svg
    assert "var(--series-1)" in svg and "var(--series-2)" in svg
    assert "<script" not in svg

    bar = bar_chart(["根部段", "中段", "葉尖段"], [0.2, 1.3, 1.1], title="分段",
                    unit=" px", reference=(1.0, "門檻"))
    assert "門檻" in bar and bar.count("<path") == 3
    assert "var(--seq-500)" in bar  # 單一量值用色階，不用類別色


def test_charts_handle_nan_and_single_series():
    svg = line_chart([Series("只有一條", [0, 1], [1, 2])], title="單系列")
    assert "chart-legend" not in svg  # 單系列不需圖例，標題已指明
    bar = bar_chart(["A", "B", "C"], [1.0, float("nan"), 2.0], title="含缺值")
    assert bar.count("<path") == 2 and "—" in bar
    assert line_chart([], title="空").count("無資料") == 1
