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
from blade_proto.geometry import compare_blades, profiles_from_structure, side_view_summary
from blade_proto.quality import assess_capture
from blade_proto.surface import analyze_blade_edges
from blade_proto.synth import SceneSpec, render_blade_segment, render_front, render_side


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


_AUDIO_OK = {
    "audio": "a.wav", "sample_rate": 24000, "duration_s": 14.0,
    "blade_pass_hz": 0.6, "rotor_hz": 0.2, "rpm_from_audio": 12.0,
    "periodicity_confidence": 0.65, "am_depth_db": 17.6, "asymmetry_db": -5.5,
    "wind_dominance": 0.76, "envelope_snr_db": 11.4, "usable": True,
    "pass_times_s": [0.35, 2.02, 3.68], "notes": ["葉片標籤 A/B/C 為通過觀測者的先後順序（循環），非實際葉片編號"],
    "blades": [
        {"index": 0, "n_passes": 3, "band_level_db": -1.06, "high_band_ratio": 0.691,
         "tonal_freq_hz": 3469.0, "tonal_prominence_db": 1.5, "tonal_exclusive": False},
        {"index": 1, "n_passes": 3, "band_level_db": 4.44, "high_band_ratio": 0.774,
         "tonal_freq_hz": 1945.0, "tonal_prominence_db": 1.8, "tonal_exclusive": False},
        {"index": 2, "n_passes": 3, "band_level_db": 0.0, "high_band_ratio": 0.531,
         "tonal_freq_hz": 1406.0, "tonal_prominence_db": 16.5, "tonal_exclusive": True},
    ],
    "comparisons": [{"metric": "band_level_db", "values": [-1.06, 4.44, 0.0],
                     "deviations": [-1.06, 4.44, 0.0], "outlier_index": 1,
                     "outlier_deviation": 4.95, "others_spread": 1.06, "z": 6.2,
                     "flagged": True, "direction": "high"}],
    "spectra": {"freqs_hz": [400.0, 1400.0, 4000.0],
                "blade_db": [[-40.0, -39.0, -41.0], [-36.0, -35.0, -37.0], [-40.0, -24.0, -41.0]]},
}


def test_report_is_self_contained_and_embeds_images(tmp_path):
    still, still_img = _still_payload(tmp_path)
    edge, edge_img = _edge_payload(tmp_path)
    html = build_report(
        CaseMeta(asset_id="WTG-07", site_name="測試風場", turbine_state="stopped",
                 cm_per_px=12.0, rotor_radius_m=60.0, noise_floor_px=1.2),
        still=still, still_overlay=still_img, edge=edge, edge_overlay=edge_img,
        video=_VIDEO, audio=_AUDIO_OK, tool_version="test")
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
    for sid in ("summary", "geometry", "surface", "dynamics", "acoustic"):
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


def test_report_acoustic_section_names_the_blade_and_the_mechanism(tmp_path):
    """聲音層要指出「哪一片」與「哪種缺陷」，兩者都待人工確認。"""
    html = build_report(CaseMeta(asset_id="WTG-07"), audio=_AUDIO_OK)
    assert 'id="acoustic"' in html
    assert "葉片 B 的寬頻噪音高出另兩片" in html and "疑似前緣侵蝕" in html
    assert "葉片 C 在 1406 Hz" in html and "疑似後緣損傷或破洞" in html
    assert "僅此片出現" in html
    assert html.count("待人工確認") >= 2
    assert "12 rpm" in html  # 由音軌推得的轉速
    # 不對稱指標必須標示為描述量，避免被當門檻用
    assert "是描述量、不是判定門檻" in html


def test_report_acoustic_unusable_says_so_and_tells_how_to_refix(tmp_path):
    audio = dict(_AUDIO_OK, usable=False, blades=[], comparisons=[], spectra={},
                 notes=["包絡訊噪比僅 0.6 dB（門檻 1.5）：葉片通過的起伏被雜訊淹沒"])
    html = build_report(CaseMeta(), audio=audio)
    assert "音軌不可用於逐片比較" in html and "需重錄" in html
    assert "下風處" in html and "防風罩" in html
    assert "訊噪比僅 0.6 dB" in html
    assert "疑似前緣侵蝕" not in html  # 不可用時不得給出任何逐片判定


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


def test_report_refuses_geometry_conclusions_when_capture_is_rejected(tmp_path):
    """拍攝品質不合格時，報告不得呈現任何三片互比數值——真實影像驗證顯示定位錯誤時
    互比照樣吐得出一組看起來正常的數字，那才是危險的失敗模式。"""
    still, still_img = _still_payload(tmp_path, deflection_cm=(500, 0, 0))
    still["capture_quality"] = {
        "ok": False,
        "reasons": ["三片葉尖半徑差 84%（上限 15%）：同一台風機三片等長，"
                    "差這麼多代表有一片其實是地物、電線或別台風機，請重拍並確保只有一台風機在框內"],
        "warnings": ["沒有找到塔架：塔架傾斜與六點鐘方位判讀不可用（幾何互比仍可進行）"],
        "metrics": {"tip_radius_spread": 0.845},
    }
    html = build_report(CaseMeta(asset_id="WTG-09", noise_floor_px=1.2),
                        still=still, still_overlay=still_img)
    assert "拍攝品質不合格，本層未做判定" in html
    assert "葉尖半徑差 84%" in html
    assert "互比指標" not in html          # 表格整段不出現
    assert "離群，需人工確認" not in html   # 也不得下任何離群判定
    assert "需重拍" in html


def test_report_shows_capture_warnings_but_keeps_results_when_passed(tmp_path):
    still, still_img = _still_payload(tmp_path, deflection_cm=(500, 0, 0))
    still["capture_quality"] = {"ok": True, "reasons": [],
                                "warnings": ["地平線以上的前景占 20%（一般 <15%）：判定結果請降權看待"],
                                "metrics": {}}
    html = build_report(CaseMeta(asset_id="WTG-10", noise_floor_px=1.2),
                        still=still, still_overlay=still_img)
    assert "判定結果請降權看待" in html
    assert "互比指標" in html


def _side_payload(tmp_path):
    """合成側視照走完閘門 + side_view_summary 的 still payload（與 cli._analyze_still_payload 同形）。"""
    img, _ = render_side(SceneSpec.for_scale(6.0, "side", (1500, 2000), seed=2))
    path = str(tmp_path / "side.png")
    cv2.imwrite(path, img)
    seg = segment_turbine(img)
    st = find_structure(seg.mask, horizon_y=seg.horizon_y)
    v = assess_capture(seg, st, expected_view="side")  # 側視是宣告制（SPEC §13-16）
    assert v.metrics["view"] == "side", v.to_dict()
    profs = profiles_from_structure(st)
    return {
        "image": path, "size": [img.shape[1], img.shape[0]],
        "segmentation": {"threshold_sigma": seg.threshold, "mask_area_frac": float((seg.mask > 0).mean()),
                         "horizon_y": seg.horizon_y},
        "capture_quality": v.to_dict(),
        "structure": {"hub": st.hub, "hub_radius_px": st.hub_radius_px, "hub_refined": st.hub_refined,
                      "tower_found": st.tower_found, "tower_roll_deg": st.tower_angle_deg,
                      "tower_width_px": st.tower_width_px, "n_blades": len(st.blades), "notes": st.notes},
        "blades": [p.to_dict() for p in profs],
        "comparison": side_view_summary(profs, v.metrics["hanging_blade_index"], rotor_radius_m=60.0),
    }, path


def test_report_side_view_shows_hanging_blade_and_no_three_blade_verdict(tmp_path):
    """側視：報告要說「不互比、只量垂掛葉片」，不能出現三片一致／離群的判定，也不能出現「合格」。"""
    still, path = _side_payload(tmp_path)
    html = build_report(CaseMeta(asset_id="SIDE-01"), still=still, still_overlay=path)
    assert "側視垂掛葉片彎曲" in html and "垂掛葉片量測" in html and "垂掛葉片葉尖偏移" in html
    assert "三片一致" not in html and "離群，需人工確認" not in html
    assert "不適用（側視）" in html
    assert "合格" not in html.replace("不合格", "")
