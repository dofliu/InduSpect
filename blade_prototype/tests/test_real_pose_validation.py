"""`scripts/real_pose_validation.py` 的守門：真實照片上的姿態估計與補償驗證。

守三件事：①逐張分析函式在偏軸合成夾具上要重現 `blade_offaxis_reference.json` 的姿態與補償結論
（同一條路徑、同一組數字，否則報告量的不是 App 端那條）；②聚合器的「消掉／留下／新增」算法不能反；
③進版控的結果檔要能自我對帳（summary = summarise(images)），且報告裡的關鍵數字來自它。
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import real_pose_validation as R  # noqa: E402

FIXTURE_PNG = ROOT.parent / "flutter_app" / "test" / "assets" / "blade_offaxis_scene.png"
FIXTURE_REF = ROOT.parent / "flutter_app" / "test" / "assets" / "blade_offaxis_reference.json"
RESULTS = ROOT / "data" / "commons_pose_results.json"
RESULTS_MIRROR = ROOT / "data" / "commons_pose_results_mirror.json"


@pytest.fixture(scope="module")
def fixture_record() -> tuple[dict, dict]:
    import cv2

    ref = json.loads(FIXTURE_REF.read_text(encoding="utf-8"))
    img = cv2.imread(str(FIXTURE_PNG))
    rec = R.analyse_image(img, focal_35mm=ref["focal_35mm"], hub_height_m=ref["hub_height_m"],
                          rotor_radius_m=ref["rotor_radius_m"])
    rec.pop("_internals")
    return rec, ref


# ---------------------------------------------------------------- ① 與夾具同一條路徑


def test_fixture_pose_reproduced(fixture_record) -> None:
    rec, ref = fixture_record
    assert rec["verdict"]["ok"] and rec["view"] == "front"
    p = rec["pose"]
    for k in ("elevation_deg", "yaw_deg", "distance_m"):
        assert p[k] == pytest.approx(ref["pose_estimate"][k], abs=1e-3), k
    assert p["usable"] is True


def test_fixture_compensation_reproduced(fixture_record) -> None:
    rec, ref = fixture_record
    c = rec["comp"]
    assert c["prebend_fit_m"] == pytest.approx(ref["compensated"]["prebend_fit_m"], abs=0.01)
    assert c["deflection_compensated"] is True
    assert c["radius_compensated"] is False  # |yaw| 25° > 15°
    # 原始標記葉尖偏移，補償後只剩半徑（半徑沒補、原本就標）
    assert R.DEFL in rec["raw"]["flagged"]
    assert R.DEFL not in c["flagged"]
    assert c["flagged"] == ["radius_px"]


def test_fixture_hub_sensitivity_recorded(fixture_record) -> None:
    rec, _ = fixture_record
    hs = rec["hub_sensitivity"]
    assert set(hs) == {f"{f:.1f}" for f in R.HUB_SENSITIVITY}
    el = rec["pose"]["elevation_deg"]
    assert hs["0.8"]["elevation_deg"] < el < hs["1.2"]["elevation_deg"]  # 輪轂越高、仰角越大
    assert all(v["same_flags"] is not None for v in hs.values())


def test_no_focal_means_no_compensation_but_raw_kept() -> None:
    import cv2

    ref = json.loads(FIXTURE_REF.read_text(encoding="utf-8"))
    img = cv2.imread(str(FIXTURE_PNG))
    rec = R.analyse_image(img, focal_35mm=None, hub_height_m=ref["hub_height_m"], rotor_radius_m=ref["rotor_radius_m"])
    assert rec["raw"]["flagged"]  # 原始互比照做
    assert rec["pose"]["usable"] is False
    assert rec["comp"] is None  # 沒姿態就不補，不猜


# ---------------------------------------------------------------- ② 聚合


def _row(rid: str, raw_flags: list[str], comp_flags: list[str] | None, *, el: float = 10.0, model: str = "M",
         same_flags: bool = True) -> dict:
    row = {
        "id": rid, "model": model, "failed": False, "seconds": 1.0, "hub_height_source": "typical",
        "verdict": {"ok": True, "reasons": [], "warnings": []}, "view": "front",
        "raw": {"cm_per_px": 20.0, "flagged": raw_flags,
                "comparisons": [{"metric": R.DEFL, "flagged": R.DEFL in raw_flags, "outlier_deviation_cm": 200.0},
                                {"metric": R.RAD, "flagged": R.RAD in raw_flags, "outlier_deviation_cm": 50.0}]},
        "pose": {"usable": comp_flags is not None, "elevation_deg": el, "yaw_deg": 5.0, "distance_m": 300.0, "notes": []},
        "comp": None,
    }
    if comp_flags is not None:
        row["comp"] = {"prebend_fit_m": 3.0, "prebend_fit_ok": True, "radius_compensated": True, "flagged": comp_flags,
                       "blades_near_tower": [], "comparisons": [
                           {"metric": R.DEFL, "flagged": R.DEFL in comp_flags, "outlier_deviation_cm": 30.0},
                           {"metric": R.RAD, "flagged": R.RAD in comp_flags, "outlier_deviation_cm": 40.0}]}
        row["hub_sensitivity"] = {"0.8": {"elevation_deg": el - 2, "same_flags": same_flags},
                                  "1.2": {"elevation_deg": el + 2, "same_flags": True}}
    return row


def test_transitions_cleared_kept_new() -> None:
    rows = [
        _row("a", [R.DEFL], []),               # 消掉
        _row("b", [R.DEFL], [R.DEFL]),         # 留下
        _row("c", [], [R.DEFL]),               # 新增
        _row("d", [R.RAD], [R.RAD], same_flags=False),
        _row("e", [R.DEFL], None),             # 姿態不可用：不算進補償統計
    ]
    s = R.summarise(rows)
    assert s["accepted_front"] == 5 and s["pose_usable"] == 4 and s["compensated"] == 4
    assert s["tip_deflection"] == {"raw_flagged": 2, "comp_flagged": 2, "cleared": 1, "kept": 1, "new": 1}
    assert s["radius"]["raw_flagged"] == 1 and s["radius"]["kept"] == 1
    assert s["hub_sensitivity"] == {"n": 4, "flags_changed": 1, "elevation_delta_deg_median": 2.0,
                                    "factors": list(R.HUB_SENSITIVITY)}
    assert s["raw_defl_cm_median"] == 200.0 and s["comp_defl_cm_median"] == 30.0


def test_rejected_and_failed_are_bucketed() -> None:
    rows = [
        {"id": "r", "model": "M", "failed": False, "seconds": 1.0,
         "verdict": {"ok": False, "reasons": ["三片葉尖半徑差 39%（上限 15%）：請等轉子轉開"], "warnings": []}, "view": None},
        {"id": "f", "model": "M", "failed": True, "seconds": 1.0,
         "verdict": {"ok": False, "reasons": ["結構定位失敗（ValueError: 遮罩為空）：多半是天空模型被撐壞"], "warnings": []}},
    ]
    s = R.summarise(rows)
    assert s["rejected"] == 1 and s["failed"] == 1 and s["accepted"] == 0
    assert set(s["reject_reasons"]) == {"三片葉尖半徑差 N%（…）", "結構定位失敗（…）"}
    assert s["per_model"]["M"]["n"] == 2 and s["per_model"]["M"]["accepted"] == 0


def test_render_uses_summary_numbers() -> None:
    rows = [_row("a", [R.DEFL], []), _row("b", [R.DEFL], [R.DEFL])]
    for r in rows:
        r.update(title="t", page_url="", license="CC BY 4.0", artist="x", camera_model=None, orig_width=4000,
                 orig_height=3000, hub_height_m=100.0, focal_35mm=50.0, rotor_radius_m=41.0)
    md = R.render_markdown({"version": "t", "summary": R.summarise(rows), "images": rows})
    assert "原始標記葉尖偏移 **2** 張，補償後剩 **1**（消掉 1、留下 1、新增 0）" in md
    assert "| 葉尖偏移 | 2 | 1 | 1 | 1 | 0 |" in md


# ---------------------------------------------------------------- ③ 進版控的結果檔


@pytest.mark.skipif(not RESULTS.exists(), reason="還沒跑過 Commons 真實照片")
def test_results_file_self_consistent() -> None:
    doc = json.loads(RESULTS.read_text(encoding="utf-8"))
    assert doc["summary"] == R.summarise(doc["images"])
    assert doc["max_side"] == R.MAX_SIDE and doc["noise_floor_px"] == R.NOISE_FLOOR_PX
    ids = [r["id"] for r in doc["images"]]
    assert len(ids) == len(set(ids))
    for r in doc["images"]:
        assert r["license"] and r["page_url"]  # 來源與授權逐張留著，照片本體不在版控裡
        if r.get("comp"):
            assert r["pose"]["usable"] is True  # 沒姿態就不補
            assert r["raw"] is not None        # 原始值一律留


@pytest.mark.skipif(not RESULTS.exists(), reason="還沒跑過 Commons 真實照片")
def test_report_in_sync_with_results() -> None:
    doc = json.loads(RESULTS.read_text(encoding="utf-8"))
    doc["summary"] = R.summarise(doc["images"])
    md = (ROOT / "REAL_POSE_VALIDATION.md").read_text(encoding="utf-8")
    assert md == R.render_markdown(doc), "REAL_POSE_VALIDATION.md 與結果檔不同步：重跑 real_pose_validation.py report"


@pytest.mark.skipif(not RESULTS_MIRROR.exists(), reason="還沒跑過鏡像那批")
def test_mirror_report_in_sync_with_results() -> None:
    """第二批（鏡像原圖 66 張）的報告同樣不得手抄——與第一批同一條規則。"""
    doc = json.loads(RESULTS_MIRROR.read_text(encoding="utf-8"))
    doc["summary"] = R.summarise(doc["images"])
    md = (ROOT / "REAL_POSE_VALIDATION_MIRROR.md").read_text(encoding="utf-8")
    expected = R.render_markdown(doc, "data/commons_pose_results_mirror.json")
    assert md == expected, "REAL_POSE_VALIDATION_MIRROR.md 與結果檔不同步：重跑 real_pose_validation.py report"


@pytest.mark.skipif(not RESULTS_MIRROR.exists(), reason="還沒跑過鏡像那批")
def test_mirror_report_names_its_own_source() -> None:
    """報告標頭要指向自己的來源檔。舊版 render_markdown 把路徑寫死，第二批會宣稱自己來自第一批的檔案。"""
    md = (ROOT / "REAL_POSE_VALIDATION_MIRROR.md").read_text(encoding="utf-8")
    assert "data/commons_pose_results_mirror.json" in md
    assert "從 `data/commons_pose_results.json`" not in md


@pytest.mark.skipif(not (RESULTS.exists() and RESULTS_MIRROR.exists()), reason="兩批都要在")
def test_two_batches_are_separate_records() -> None:
    """兩批是**各自獨立**的紀錄，不可互相覆蓋。

    第一批 86 張是走 Commons 縮圖端點抓的，其中 70 張鏡像上拿不到（媒體凍結在 2013-03），
    要重抓得換一個沒被 upload.wikimedia.org 擋住的網路；第二批 66 張是鏡像原圖。
    影像只活在容器的 scratchpad 裡，回收就沒了，覆寫掉結果檔等於連數字都沒了，所以這裡釘住兩件事：
    兩個檔案都在、而且第一批的張數沒有被第二批改動。
    """
    first = json.loads(RESULTS.read_text(encoding="utf-8"))
    second = json.loads(RESULTS_MIRROR.read_text(encoding="utf-8"))
    assert len(first["images"]) == 86, "第一批 86 張的紀錄被動到了"
    assert len(second["images"]) == 66
    ids_first = {r["id"] for r in first["images"]}
    ids_second = {r["id"] for r in second["images"]}
    # 16 張重疊（同一張照片，縮圖 vs 原圖各跑一次），其餘各自獨立
    assert len(ids_first & ids_second) == 16


# 重疊的 16 張裡，兩批**真的拿到不同解析度**的只有這 7 張（2026-09-28 逐張量磁碟上的影像）：
# 第一批 1920 px 長邊、第二批 3648–4256 px 原圖。另外 9 張兩批是**同一個檔案**（逐位元相同）——
# Commons 縮圖端點在要求寬度 ≥ 原圖寬度時直接回原圖，所以那 9 張的「輸出一樣」是恆等式不是證據。
RESOLUTION_DIFFERED = [
    "c19326536", "c19669637", "c19674205", "c19674208", "c19674213", "c6326631", "c6326636",
]


@pytest.mark.skipif(not (RESULTS.exists() and RESULTS_MIRROR.exists()), reason="兩批都要在")
def test_source_resolution_does_not_change_the_gate() -> None:
    """重疊那 16 張：閘門的**收／不收**逐張相同——但證據只有 7 張，而且**全是拒收**。

    這條是方法學上的保險：剩下的 177 張只能在別的網路上用**縮圖**抓（鏡像凍結在 2013-03），
    如果解析度會改變閘門結論，那批數字就不能跟這兩批併著看。兩條路徑都先縮到 max_side 1024
    才進管線，所以理論上該一樣。但 2026-09-28 逐張比對磁碟上的影像後發現，
    **16 張裡只有 7 張真的是「縮圖 vs 原圖」**（見 RESOLUTION_DIFFERED），
    而那 7 張的內部量全都有變動——其中 c6326631 的葉片數 3 → 1、拒收理由整個換掉——
    **收／不收仍然相同，但這 7 張兩邊都是拒收**。放行那一側還沒有任何一張真的比較過不同解析度。

    所以這裡釘的是實際成立的那件事，不是更強的說法：①16 張的 `verdict.ok` 相同；
    ②輸出有差的**恰好**是那 7 張真的不同解析度的（有第 8 張有差，代表同檔案跑出不同結果，是真的壞了）；
    ③那 7 張兩邊都是拒收，也就是等價性在放行側仍未驗證——要補，得把已放行的照片降解析度重跑一次。
    """
    first = {r["id"]: r for r in json.loads(RESULTS.read_text(encoding="utf-8"))["images"]}
    second = {r["id"]: r for r in json.loads(RESULTS_MIRROR.read_text(encoding="utf-8"))["images"]}
    overlap = sorted(set(first) & set(second))

    differing_decision = [
        k for k in overlap
        if (first[k].get("verdict") or {}).get("ok") != (second[k].get("verdict") or {}).get("ok")
    ]
    assert differing_decision == [], f"不同來源的閘門收／不收不一致：{differing_decision}"

    differing_output = sorted(k for k in overlap if first[k].get("verdict") != second[k].get("verdict"))
    assert differing_output == sorted(RESOLUTION_DIFFERED), (
        "輸出有差的那組不再等於真的不同解析度的那組："
        f"有差 {differing_output}、不同解析度 {sorted(RESOLUTION_DIFFERED)}"
    )

    # 等價性目前只在拒收側被驗到——這一條紅了是好事（代表放行側終於有證據），但要同步改文件
    accepted = [k for k in RESOLUTION_DIFFERED if (first[k]["verdict"]["ok"] or second[k]["verdict"]["ok"])]
    assert accepted == [], f"放行側現在有不同解析度的樣本了，SPEC §13-15 的界線要改寫：{accepted}"
