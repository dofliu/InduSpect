"""圖文檢測報告產生器（單一自帶內容的 HTML 檔）。

用途：把 `analyze-still` / `analyze-edge` / `analyze-video` 的數值結果，
連同疊圖照片與圖表，組成一份「看得懂、可交付、可列印成 PDF」的報告。

設計原則：
- **自帶內容**：照片以 base64 data URI 內嵌、圖表為內嵌 SVG、CSS 內嵌。
  單一 .html 檔可離線開啟、可 email、瀏覽器列印即成 PDF；不依賴任何外部資源。
- **數字由演算法算，AI 只解讀**：本模組只排版既有數值，不呼叫任何 AI。
- **AI 初判、需人工確認**（規格 §4.5）：沒偵測到異常 ≠ 沒有異常。報告開頭固定聲明，
  每個判定列都保留「人工確認」欄，不輸出「合格」字樣。
- 淺色/深色主題皆可讀（依 `prefers-color-scheme` 與 `data-theme` 切換）；
  列印時強制淺底黑字。
"""

from __future__ import annotations

import base64
import io
import os
from dataclasses import dataclass, field
from datetime import datetime
from html import escape
from typing import Any

import cv2
import numpy as np

from .charts import SERIES_ROLES, STATUS_ROLES, Series, bar_chart, line_chart

__all__ = ["CaseMeta", "build_report", "write_report", "image_data_uri"]

_MAX_EMBED_SIDE = 1400  # 內嵌影像最長邊（平衡可讀性與檔案大小）
_JPEG_QUALITY = 82


def image_data_uri(img_or_path, max_side: int = _MAX_EMBED_SIDE) -> str | None:
    """影像 → data URI（JPEG）。讀不到回傳 None，報告會顯示佔位文字而非壞掉。"""
    img = cv2.imread(img_or_path, cv2.IMREAD_COLOR) if isinstance(img_or_path, str) else img_or_path
    if img is None:
        return None
    h, w = img.shape[:2]
    scale = min(1.0, max_side / max(h, w))
    if scale < 1.0:
        img = cv2.resize(img, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)
    ok, buf = cv2.imencode(".jpg", img, [int(cv2.IMWRITE_JPEG_QUALITY), _JPEG_QUALITY])
    if not ok:
        return None
    return "data:image/jpeg;base64," + base64.b64encode(buf.tobytes()).decode("ascii")


@dataclass
class CaseMeta:
    """一次拍攝作業的識別資訊（對應規格 §7 的 wt_capture_sessions）。"""

    asset_id: str = "未命名資產"
    site_name: str = ""
    turbine_model: str = ""
    turbine_state: str = ""  # stopped / idling / running
    captured_at: str = ""
    inspector: str = ""
    weather_note: str = ""
    cm_per_px: float | None = None
    rotor_radius_m: float | None = None
    noise_floor_px: float | None = None
    notes: list[str] = field(default_factory=list)

    def rows(self) -> list[tuple[str, str]]:
        state = {"stopped": "停機", "idling": "怠速慢轉", "running": "運轉中"}.get(
            self.turbine_state, self.turbine_state or "未記錄")
        out = [
            ("資產編號", self.asset_id),
            ("風場 / 位置", self.site_name or "未記錄"),
            ("機型", self.turbine_model or "未記錄"),
            ("風機狀態", state),
            ("拍攝時間", self.captured_at or "未記錄"),
            ("檢測人員", self.inspector or "未記錄"),
        ]
        if self.weather_note:
            out.append(("天氣 / 風速", self.weather_note))
        if self.cm_per_px:
            out.append(("影像尺度", f"{self.cm_per_px:.2f} cm/px"))
        if self.rotor_radius_m:
            out.append(("葉片長度", f"{self.rotor_radius_m:.0f} m"))
        if self.noise_floor_px:
            out.append(("量測雜訊底", f"{self.noise_floor_px:.2f} px"))
        return out


# ---------------------------------------------------------------- HTML 片段


def _table(headers: list[str], rows: list[list[str]], cls: str = "") -> str:
    if not rows:
        return '<p class="empty">無資料</p>'
    th = "".join(f"<th>{escape(h)}</th>" for h in headers)
    body = "".join("<tr>" + "".join(f"<td>{c}</td>" for c in r) + "</tr>" for r in rows)
    return f'<table class="{cls}"><thead><tr>{th}</tr></thead><tbody>{body}</tbody></table>'


def _kv_table(rows: list[tuple[str, str]]) -> str:
    body = "".join(f"<tr><th>{escape(k)}</th><td>{escape(str(v))}</td></tr>" for k, v in rows)
    return f'<table class="kv"><tbody>{body}</tbody></table>'


def _status_chip(level: str, text: str) -> str:
    """狀態一律「圖示 + 文字 + 顏色」三重編碼，顏色從不單獨承載意義。"""
    icon = {"good": "●", "warning": "▲", "serious": "▲", "critical": "■"}.get(level, "●")
    return (f'<span class="chip chip-{escape(level)}"><span class="chip-icon" aria-hidden="true">{icon}</span>'
            f'{escape(text)}</span>')


def _stat_tile(label: str, value: str, sub: str = "", level: str | None = None) -> str:
    lv = f' data-level="{escape(level)}"' if level else ""
    sub_html = f'<div class="tile-sub">{escape(sub)}</div>' if sub else ""
    return (f'<div class="tile"{lv}><div class="tile-label">{escape(label)}</div>'
            f'<div class="tile-value">{escape(value)}</div>{sub_html}</div>')


def _figure(uri: str | None, caption: str, missing: str = "影像未提供或讀取失敗") -> str:
    if not uri:
        return f'<figure class="photo"><div class="photo-missing">{escape(missing)}</div>'\
               f'<figcaption>{escape(caption)}</figcaption></figure>'
    # 不用 loading="lazy"：影像已內嵌成 data URI（沒有網路可省），
    # 而延後載入會讓「列印成 PDF」與整頁截圖漏圖。
    return (f'<figure class="photo"><img src="{uri}" alt="{escape(caption)}"/>'
            f'<figcaption>{escape(caption)}</figcaption></figure>')


def _fmt(v: Any, digits: int = 2, unit: str = "") -> str:
    if v is None:
        return "—"
    try:
        f = float(v)
    except (TypeError, ValueError):
        return escape(str(v))
    if f != f:
        return "—"
    s = f"{f:.{digits}f}"
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return f"{s}{unit}"


# ---------------------------------------------------------------- 各層區段


_METRIC_LABELS = {
    "tip_deflection_px": "葉尖偏移",
    "radius_px": "葉片長度",
    "mean_width_px": "平均弦寬",
    "residual_rms_px": "形狀不規則度",
}


def _geometry_section(still: dict, overlay_uri: str | None, meta: CaseMeta) -> tuple[str, list[str]]:
    """幾何層：三片中心線互比 + 結構定位。回傳 (html, 發現清單)。"""
    blades = still.get("blades") or []
    cmp_ = still.get("comparison") or {}
    comps = cmp_.get("comparisons") or []
    st = still.get("structure") or {}
    findings: list[str] = []

    side = cmp_.get("view") == "side"
    if side:
        parts = ['<section id="geometry"><h2>幾何層 — 側視垂掛葉片彎曲</h2>',
                 '<p class="lede">側視時三片葉片的投影落在同一條垂直線上，三片互比不適用；'
                 '本層只量垂掛葉片的 flapwise 彎曲。單幀值含預彎，要與同一台的基線或正視互比結果'
                 '對照才有意義，所以這裡不設門檻、不做離群判定。</p>']
    else:
        parts = ['<section id="geometry"><h2>幾何層 — 三片葉片互比</h2>',
                 '<p class="lede">同一台風機三片葉片同批同型，在同一轉子位置的剪影應該一致；'
                 '差異本身就是訊號，不需要絕對量測也不需要歷史基線。</p>']
    parts.append('<div class="split">')
    parts.append(_figure(overlay_uri, f"分割與結構定位疊圖（{escape(os.path.basename(still.get('image', '')))}）"))
    parts.append(_kv_table([
        ("輪轂位置", f"({_fmt(st.get('hub', [None, None])[0], 0)}, {_fmt(st.get('hub', [None, None])[1], 0)}) px"
         if st.get("hub") else "—"),
        ("輪轂半徑", _fmt(st.get("hub_radius_px"), 1, " px")),
        ("塔架偵測", "成功" if st.get("tower_found") else "未找到"),
        ("相機 roll 校正", _fmt(st.get("tower_roll_deg"), 2, "°")),
        ("偵測到的葉片數", str(st.get("n_blades", 0))),
        ("分割前景占比", _fmt((still.get("segmentation") or {}).get("mask_area_frac", 0) * 100, 1, " %")),
    ]))
    parts.append("</div>")

    # 拍攝品質閘門：不合格就不給幾何結論。真實影像驗證顯示定位錯誤時輸出「看起來一樣正常」，
    # 所以擋在互比之前，把「安靜的錯答案」換成「明確的重拍指示」。
    q = still.get("capture_quality") or {}
    if q and not q.get("ok", True):
        parts.append('<div class="disclaimer"><strong>拍攝品質不合格，本層未做判定</strong>'
                     '結構定位的結果無法確認正確，任何三片互比的數值都不可採信。'
                     '請依下列指示重拍後再分析。</div>')
        parts.append('<ul class="findings">' +
                     "".join(f"<li>{escape(r)}</li>" for r in q.get("reasons", [])) + "</ul>")
        for w in q.get("warnings", []):
            parts.append(f'<p class="note">{escape(w)}</p>')
        parts.append("</section>")
        findings.append("幾何層：拍攝品質不合格（" + escape(q.get("reasons", ["原因未記錄"])[0].split("：")[0])
                        + "），未做三片互比，需重拍")
        return "\n".join(parts), findings
    for w in q.get("warnings", []):
        parts.append(f'<p class="warn">{escape(w)}</p>')

    if side:
        # 側視：只有垂掛那片的中心線有意義，上方那段是另兩片疊在一起。
        hb = cmp_.get("hanging_blade") or {}
        hi = hb.get("index")
        hang = blades[hi] if isinstance(hi, int) and 0 <= hi < len(blades) else None
        if hang:
            u = [x for x in (hang.get("u") or []) if x is not None]
            R = hang.get("radius_px") or 1.0
            ys = [(v * R if v is not None else float("nan")) for v in (hang.get("center") or [])][:len(u)]
            if len(u) >= 2 and len(ys) >= 2:
                parts.append(line_chart(
                    [Series(name="垂掛葉片", xs=u[:len(ys)], ys=ys, role=SERIES_ROLES[0])],
                    title="垂掛葉片中心線側向偏移", x_label="沿葉片長度位置（0 = 根部，1 = 葉尖）",
                    y_label="側向偏移 (px)", unit=" px", y_digits=1,
                    caption="單幀的彎曲含製造預彎；與同一台的基線或另一幀相減才是變化量。"))
        dev_cm = hb.get("tip_deflection_cm")
        parts.append("<h3>垂掛葉片量測</h3>")
        parts.append(_kv_table([
            ("垂掛葉片", f"葉片 {escape(str(hb.get('label', '—')))}（投影長度 {_fmt(hb.get('radius_px'), 0, ' px')}）"),
            ("彎曲係數", _fmt(hb.get("bend_coeff"), 4)),
            ("葉尖偏移（含預彎）", _fmt(hb.get("tip_deflection_px"), 1, " px")
             + (f"（{_fmt(dev_cm, 0, ' cm')}）" if dev_cm is not None else "")),
            ("擬合殘差 rms", _fmt(hb.get("residual_rms_px"), 2, " px")),
            ("三片互比", "不適用（側視）"),
        ]))
        if cmp_.get("note"):
            parts.append(f'<p class="note">{escape(cmp_["note"])}</p>')
        blades_chart: list = []
        comps = []
    else:
        blades_chart = blades

    # 中心線曲線（三片各一系列）
    series = []
    for i, b in enumerate(blades_chart[:3]):
        u = [x for x in (b.get("u") or []) if x is not None]
        c = b.get("center") or []
        R = b.get("radius_px") or 1.0
        ys = [(v * R if v is not None else float("nan")) for v in c][:len(u)]
        if len(u) >= 2 and len(ys) >= 2:
            series.append(Series(name=f"葉片 {chr(65 + i)}", xs=u[:len(ys)], ys=ys, role=SERIES_ROLES[i]))
    if series:
        parts.append(line_chart(
            series, title="三片葉片中心線側向偏移", x_label="沿葉片長度位置（0 = 根部，1 = 葉尖）",
            y_label="側向偏移 (px)", unit=" px", y_digits=1,
            caption="中心線取自遮罩兩側邊緣中點。三條曲線重合代表三片形狀一致；"
                    "單一片明顯偏離即為離群候選。"))

    # 互比指標
    if comps:
        rows = []
        chart_vals, chart_labels = [], []
        for c in comps:
            name = _METRIC_LABELS.get(c["metric"], c["metric"])
            vals = c.get("values") or []
            oi = c.get("outlier_index")
            dev_cm = c.get("outlier_deviation_cm")
            flagged = bool(c.get("flagged"))
            chip = _status_chip("critical", "離群，需人工確認") if flagged else _status_chip("good", "三片一致")
            rows.append([
                escape(name),
                " / ".join(_fmt(v, 2) for v in vals),
                f"葉片 {chr(65 + oi)}" if oi is not None else "—",
                _fmt(c.get("outlier_deviation"), 2, " px") + (f"（{_fmt(dev_cm, 0, ' cm')}）" if dev_cm else ""),
                _fmt(c.get("z"), 1),
                chip,
                '<span class="pending">☐ 待確認</span>' if flagged else "—",
            ])
            if c["metric"] == "tip_deflection_px":
                chart_labels = [f"葉片 {chr(65 + i)}" for i in range(len(vals))]
                chart_vals = list(vals)
            if flagged:
                findings.append(f"{name}：葉片 {chr(65 + oi)} 偏離另兩片 "
                                f"{_fmt(c.get('outlier_deviation'), 1, ' px')}"
                                f"{f'（約 {_fmt(dev_cm, 0)} cm）' if dev_cm else ''}，z = {_fmt(c.get('z'), 1)}")
        parts.append("<h3>互比指標</h3>")
        parts.append(_table(["指標", "三片量測值", "離群片", "偏離量", "z 值", "判定", "人工確認"], rows, "metrics"))
        if chart_vals:
            ref = (meta.noise_floor_px * 3, "偵測門檻 3σ") if meta.noise_floor_px else None
            parts.append(bar_chart(
                chart_labels, chart_vals, title="各片葉尖偏移量", unit=" px",
                roles=SERIES_ROLES[:len(chart_vals)], y_label="葉尖偏移 (px)", digits=2, reference=ref,
                caption="葉尖偏移 = 中心線二次擬合係數 × 葉片像素長度。"
                        "三片數值相近為正常；門檻線為量測雜訊底的 3 倍。"))
    if st.get("notes"):
        parts.append('<p class="note"><strong>演算法備註：</strong>' +
                     escape("；".join(st["notes"])) + "</p>")
    contaminated = sum(int(b.get("n_contaminated_bins") or 0) for b in blades)
    if contaminated:
        parts.append(f'<p class="warn">有 {contaminated} 個分箱的弦寬異常並經修補'
                     f'（多為雲塊或附著物黏在葉片邊緣）。此幀的幾何量測應降權或重拍。</p>')
        findings.append(f"影像品質：{contaminated} 個分箱受雲塊/附著物污染，幾何量測可信度下降")
    parts.append("</section>")
    return "\n".join(parts), findings


def _surface_section(edge: dict, overlay_uri: str | None) -> tuple[str, list[str]]:
    """表面層：前緣粗糙度。"""
    findings: list[str] = []
    le_name = edge.get("leading_edge")
    top, bot = edge.get("top") or {}, edge.get("bottom") or {}
    le = top if le_name == "top" else (bot if le_name == "bottom" else top)
    te = bot if le_name == "top" else (top if le_name == "bottom" else bot)
    ratio = edge.get("le_over_te_rms_ratio")

    parts = ['<section id="surface"><h2>表面層 — 前緣粗糙度</h2>',
             '<p class="lede">對邊緣輪廓擬合平滑基線，殘差即粗糙度。'
             '這是手機尺度上唯一能<strong>量化</strong>的侵蝕指標——'
             '前緣受風砂雨水沖蝕會變粗糙，後緣不會，所以兩者比值比絕對值更可靠。</p>']
    parts.append('<div class="split">')
    parts.append(_figure(overlay_uri, f"葉片分區段照（{escape(os.path.basename(edge.get('image', '')))}）"))
    level = "good"
    verdict = "前後緣粗糙度相當，未見明顯侵蝕"
    if ratio is not None:
        if ratio >= 5.0:
            level, verdict = "critical", "前緣粗糙度為後緣 5 倍以上，疑似重度侵蝕"
        elif ratio >= 2.0:
            level, verdict = "serious", "前緣粗糙度明顯高於後緣，疑似侵蝕"
        elif ratio >= 1.5:
            level, verdict = "warning", "前緣粗糙度略高，建議下次複拍比對"
    if level != "good":
        findings.append(f"前緣侵蝕：前/後緣粗糙度比 {_fmt(ratio, 1)}，{verdict}")
    parts.append(_kv_table([
        ("前緣側", {"top": "畫面上緣", "bottom": "畫面下緣"}.get(le_name, "未指定")),
        ("葉片厚度（畫面）", _fmt(edge.get("median_thickness_px"), 0, " px")),
        ("軸線傾角", _fmt(edge.get("axis_angle_deg"), 1, "°")),
        ("邊緣取樣點數", str(le.get("n_samples", "—"))),
    ]))
    parts.append("</div>")
    parts.append(f'<div class="verdict">{_status_chip(level, verdict)}'
                 f'<span class="pending">☐ 待人工確認</span></div>')

    rows = []
    for name, d in (("前緣", le), ("後緣", te)):
        if not d:
            continue
        rows.append([
            escape(name), _fmt(d.get("rms_px"), 2, " px"),
            _fmt(d.get("rms_cm"), 2, " cm") if d.get("rms_cm") is not None else "—",
            _fmt(d.get("inward_p95_px"), 2, " px"), str(d.get("pit_count", "—")),
            _fmt(d.get("high_freq_ratio"), 2),
        ])
    parts.append("<h3>邊緣粗糙度指標</h3>")
    parts.append(_table(["邊緣", "殘差 rms", "換算實尺", "往內凹 p95", "凹坑數", "高頻能量比"], rows, "metrics"))
    if ratio is not None:
        parts.append(f'<p class="note">前緣 / 後緣 rms 比 = <strong>{_fmt(ratio, 2)}</strong>'
                     f'（≥ 2 視為侵蝕徵兆，≥ 5 為重度）</p>')

    zr = le.get("zone_rms_px") or []
    if len(zr) == 3:
        parts.append(bar_chart(
            ["根部段", "中段", "葉尖段"], list(zr), title="前緣粗糙度沿葉片分段",
            unit=" px", y_label="殘差 rms (px)", digits=2,
            caption="侵蝕通常從葉尖段開始（線速度最快、撞擊最劇烈），"
                    "分段數值可指出侵蝕的起始位置與範圍。"))
    parts.append("</section>")
    return "\n".join(parts), findings


def _dynamics_section(video: dict, six_uris: list[tuple[str, str | None]]) -> tuple[str, list[str]]:
    """動態層：轉速、葉尖一致性、六點鐘取幀。"""
    findings: list[str] = []
    parts = ['<section id="dynamics"><h2>動態層 — 轉動影片</h2>',
             '<p class="lede">影片的價值在於「風機自己在轉」：不需要操作風機，'
             '演算法就能自動挑出每片葉片垂直向下（六點鐘）的那一幀，並比較三片的葉尖軌跡。</p>']
    view = video.get("view") or ("side" if video.get("direction") == "n/a" else "front")
    parts.append(_kv_table([
        ("視角", {"front": "正視（轉子面）", "side": "側視（轉子面邊視）"}.get(view, view)),
        ("分析幀數", str(video.get("n_frames", "—"))),
        ("有效幀率", _fmt(video.get("fps"), 1, " fps")),
        ("轉速", _fmt(video.get("rpm"), 2, " rpm")),
        ("轉向", {"ccw": "逆時鐘", "cw": "順時鐘", "n/a": "側視不適用"}.get(video.get("direction"), "—")),
    ]))

    med = video.get("radius_median_px") or []
    if len([m for m in med if m == m]) >= 2:
        labels = [f"葉片 {chr(65 + i)}" for i in range(len(med))]
        spread = (max(med) - min(med)) / (sum(med) / len(med)) * 100 if all(m == m for m in med) else float("nan")
        parts.append(bar_chart(
            labels, list(med), title="三片葉尖半徑（影片中位數）", unit=" px",
            roles=SERIES_ROLES[:len(med)], y_label="葉尖半徑 (px)", digits=1,
            caption="三片半徑應一致。單片偏短可能是葉尖損壞，"
                    "軌跡半徑不同則指向質量不平衡或該片變形。"))
        level, text = ("good", f"三片葉尖半徑一致（差異 {_fmt(spread, 1)}%）")
        if spread == spread and spread > 3.0:
            level, text = "critical", f"三片葉尖半徑差異 {_fmt(spread, 1)}%，超出 3% 容差"
            findings.append(text)
        parts.append(f'<div class="verdict">{_status_chip(level, text)}'
                     f'{"<span class=pending>☐ 待人工確認</span>" if level != "good" else ""}</div>')

    six = video.get("six_oclock_frames") or []
    if any(six):
        rows = [[f"葉片 {chr(65 + i)}", ", ".join(f"#{k}" for k in idxs) if idxs else "本段影片未通過六點鐘"]
                for i, idxs in enumerate(six)]
        parts.append("<h3>六點鐘取幀</h3>")
        parts.append(_table(["葉片", "幀索引"], rows, "metrics"))
        if six_uris:
            parts.append('<div class="grid">')
            for cap, uri in six_uris:
                parts.append(_figure(uri, cap))
            parts.append("</div>")
            parts.append('<p class="note">上列各幀可直接送入幾何層做三片互比'
                         '（葉片轉到六點鐘時距離最短、解析度最好）。</p>')
    for n in video.get("notes") or []:
        parts.append(f'<p class="note"><strong>演算法備註：</strong>{escape(n)}</p>')
    parts.append("</section>")
    return "\n".join(parts), findings


def _acoustic_section(audio: dict) -> tuple[str, list[str]]:
    """聲音層：逐片寬頻位準、窄頻哨音、可用性。"""
    findings: list[str] = []
    blades = audio.get("blades") or []
    comps = audio.get("comparisons") or []
    usable = bool(audio.get("usable"))

    parts = ['<section id="acoustic"><h2>聲音層 — 逐片音軌分析</h2>',
             '<p class="lede">現場人員本來就是靠耳朵先發現葉片問題的，這一層把它量化。'
             '前緣侵蝕會讓寬頻噪音上升；後緣裂縫或破洞會發出窄頻哨音。'
             '關鍵是三片葉片每轉各通過觀測者一次，缺陷葉片的聲音<strong>以葉片通過週期出現</strong>，'
             '所以把音軌依通過時刻切成三份互比，就能指出是哪一片在叫——'
             '這也是它跟「整台都吵」「風噪很大」的分辨方式。</p>']
    parts.append(_kv_table([
        ("音軌長度", _fmt(audio.get("duration_s"), 1, " 秒")),
        ("取樣率", f"{audio.get('sample_rate', '—')} Hz"),
        ("轉速（由音軌推得）", _fmt(audio.get("rpm_from_audio"), 2, " rpm")),
        ("葉片通過頻率", _fmt(audio.get("blade_pass_hz"), 3, " Hz")),
        ("轉動週期信賴度", _fmt(audio.get("periodicity_confidence"), 2)),
        ("葉片通過調變深度", _fmt(audio.get("am_depth_db"), 1, " dB")),
        ("1P / 3P 不對稱", _fmt(audio.get("asymmetry_db"), 1, " dB")),
        ("低頻（風噪）占比", _fmt((audio.get("wind_dominance") or 0) * 100, 0, " %")),
        ("包絡訊噪比", _fmt(audio.get("envelope_snr_db"), 1, " dB")),
        ("偵測到的通過次數", str(len(audio.get("pass_times_s") or []))),
    ]))

    if not usable:
        reasons = "；".join(audio.get("notes") or []) or "訊號條件不足"
        parts.append(f'<div class="verdict">{_status_chip("warning", "音軌不可用於逐片比較")}'
                     f'<span class="pending">☐ 需重錄</span></div>')
        parts.append(f'<p class="warn">{escape(reasons)}</p>')
        parts.append('<p class="note">聲音層對風噪特別敏感。重錄要點：站到<strong>下風處</strong>、'
                     '麥克風加防風罩、避開變電站與道路噪音、錄至少 3 圈（12 rpm 約 15 秒）。</p>')
        findings.append("聲音層：音軌不可用於逐片比較（見該節說明），本次不採計")
        parts.append("</section>")
        return "\n".join(parts), findings

    # 逐片寬頻位準
    levels = [b.get("band_level_db") for b in blades]
    labels = [f"葉片 {chr(65 + int(b.get('index', i)))}" for i, b in enumerate(blades)]
    lvl_cmp = next((c for c in comps if c["metric"] == "band_level_db"), None)
    if any(v is not None and v == v for v in levels):
        parts.append(bar_chart(
            labels, [float(v) if v is not None else float("nan") for v in levels],
            title="各片寬頻噪音位準（相對三片中位數）", unit=" dB",
            roles=SERIES_ROLES[:len(levels)], y_label="相對位準 (dB)", digits=2,
            caption="前緣侵蝕會讓該片的寬頻噪音變大。只有「比另兩片吵」才是缺陷徵兆——"
                    "比較安靜不是異常，所以本指標只往高的方向判。"))

    # 逐片平均頻譜
    spectra = audio.get("spectra") or {}
    freqs = spectra.get("freqs_hz") or []
    series = []
    for i, ydb in enumerate(spectra.get("blade_db") or []):
        if len(ydb) == len(freqs) and len(freqs) >= 2 and i < len(SERIES_ROLES):
            series.append(Series(name=labels[i] if i < len(labels) else f"葉片 {chr(65 + i)}",
                                 xs=list(freqs), ys=list(ydb), role=SERIES_ROLES[i]))
    if series:
        parts.append(line_chart(
            series, title="各片通過時的平均頻譜", x_label="頻率 (Hz)", y_label="位準 (dB)",
            unit=" dB", x_digits=0, y_digits=0,
            caption="三條曲線整體上下平移 = 寬頻位準差（侵蝕）；某一片冒出一根細峰 = 窄頻哨音"
                    "（後緣裂縫或破洞）。滑過曲線可看逐點數值。"))

    rows = []
    for i, b in enumerate(blades):
        tf, tp_db = b.get("tonal_freq_hz"), b.get("tonal_prominence_db")
        excl = bool(b.get("tonal_exclusive"))
        tone = "—"
        if tf is not None and tf == tf and tp_db is not None and tp_db == tp_db:
            tone = f"{_fmt(tf, 0, ' Hz')}（突出 {_fmt(tp_db, 1, ' dB')}）"
            if excl:
                tone += " " + _status_chip("critical", "僅此片出現")
        rows.append([
            escape(labels[i]), str(b.get("n_passes", "—")),
            _fmt(b.get("band_level_db"), 2, " dB"), _fmt(b.get("high_band_ratio"), 3), tone,
            '<span class="pending">☐ 待確認</span>' if excl or (
                lvl_cmp and lvl_cmp.get("flagged") and lvl_cmp.get("outlier_index") == i) else "—",
        ])
    parts.append("<h3>逐片聲學指標</h3>")
    parts.append(_table(["葉片", "通過次數", "寬頻位準", "高頻占比", "窄頻哨音", "人工確認"],
                        rows, "metrics"))

    if lvl_cmp:
        if lvl_cmp.get("flagged"):
            oi = lvl_cmp["outlier_index"]
            text = (f"葉片 {chr(65 + oi)} 的寬頻噪音高出另兩片 "
                    f"{_fmt(lvl_cmp.get('outlier_deviation'), 1, ' dB')}"
                    f"（z = {_fmt(lvl_cmp.get('z'), 1)}），疑似前緣侵蝕")
            parts.append(f'<div class="verdict">{_status_chip("critical", text)}'
                         f'<span class="pending">☐ 待人工確認</span></div>')
            findings.append("聲音層：" + text)
        else:
            parts.append(f'<div class="verdict">'
                         f'{_status_chip("good", "三片寬頻位準一致，未見單片噪音異常")}</div>')
    for i, b in enumerate(blades):
        if b.get("tonal_exclusive"):
            text = (f"葉片 {chr(65 + i)} 在 {_fmt(b.get('tonal_freq_hz'), 0, ' Hz')} 有僅此片出現的窄頻哨音"
                    f"（突出 {_fmt(b.get('tonal_prominence_db'), 1, ' dB')}），疑似後緣損傷或破洞")
            parts.append(f'<div class="verdict">{_status_chip("critical", text)}'
                         f'<span class="pending">☐ 待人工確認</span></div>')
            findings.append("聲音層：" + text)

    for n in audio.get("notes") or []:
        parts.append(f'<p class="note"><strong>演算法備註：</strong>{escape(n)}</p>')
    parts.append('<p class="note"><strong>1P / 3P 不對稱</strong>是描述量、不是判定門檻：'
                 '合成資料實測顯示它在健康與單片缺陷之間會重疊，'
                 '真正可靠的判別是上面的逐片位準互比。</p>')
    parts.append("</section>")
    return "\n".join(parts), findings


# ---------------------------------------------------------------- 主組裝


_CSS = """
:root{
  color-scheme: light;
  --page:#f9f9f7; --surface:#fcfcfb; --ink:#0b0b0b; --ink-2:#52514e; --muted:#898781;
  --grid:#e1e0d9; --axis:#c3c2b7; --border:rgba(11,11,11,.10);
  --series-1:#2a78d6; --series-2:#eb6834; --series-3:#1baf7a; --seq-500:#256abf;
  --status-good:#0ca30c; --status-warning:#fab219; --status-serious:#ec835a; --status-critical:#d03b3b;
}
@media (prefers-color-scheme: dark){
  :root:not([data-theme="light"]){
    color-scheme: dark;
    --page:#0d0d0d; --surface:#1a1a19; --ink:#fff; --ink-2:#c3c2b7; --muted:#898781;
    --grid:#2c2c2a; --axis:#383835; --border:rgba(255,255,255,.10);
    --series-1:#3987e5; --series-2:#d95926; --series-3:#199e70; --seq-500:#3987e5;
  }
}
:root[data-theme="dark"]{
  color-scheme: dark;
  --page:#0d0d0d; --surface:#1a1a19; --ink:#fff; --ink-2:#c3c2b7; --muted:#898781;
  --grid:#2c2c2a; --axis:#383835; --border:rgba(255,255,255,.10);
  --series-1:#3987e5; --series-2:#d95926; --series-3:#199e70; --seq-500:#3987e5;
}
*{box-sizing:border-box}
body{margin:0;background:var(--page);color:var(--ink);
  font:15px/1.65 system-ui,-apple-system,"Segoe UI","Noto Sans TC",sans-serif}
.wrap{max-width:1000px;margin:0 auto;padding:32px 24px 80px}
header.doc{border-bottom:2px solid var(--ink);padding-bottom:16px;margin-bottom:24px}
header.doc h1{margin:0 0 6px;font-size:26px;letter-spacing:-.01em}
header.doc .sub{color:var(--ink-2);font-size:14px}
h2{font-size:19px;margin:40px 0 10px;padding-bottom:6px;border-bottom:1px solid var(--border)}
h3{font-size:15px;margin:24px 0 8px;color:var(--ink-2)}
p{margin:8px 0}
.lede{color:var(--ink-2);max-width:74ch}
.disclaimer{background:var(--surface);border:1px solid var(--border);
  border-left:4px solid var(--status-warning);border-radius:8px;padding:12px 16px;margin:20px 0}
.disclaimer strong{display:block;margin-bottom:4px}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px;margin:16px 0}
.tile{background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:14px 16px}
.tile-label{font-size:12px;color:var(--muted);letter-spacing:.02em}
.tile-value{font-size:26px;font-weight:600;margin-top:2px}
.tile-sub{font-size:12px;color:var(--ink-2);margin-top:2px}
.tile[data-level="critical"]{border-left:4px solid var(--status-critical)}
.tile[data-level="serious"]{border-left:4px solid var(--status-serious)}
.tile[data-level="warning"]{border-left:4px solid var(--status-warning)}
.tile[data-level="good"]{border-left:4px solid var(--status-good)}
table{border-collapse:collapse;width:100%;margin:10px 0;font-size:14px;background:var(--surface)}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--border);vertical-align:top}
thead th{font-size:12px;color:var(--muted);font-weight:600;letter-spacing:.02em;
  border-bottom:1px solid var(--axis);white-space:nowrap}
table.kv{width:auto;min-width:280px}
table.kv th{color:var(--muted);font-weight:500;white-space:nowrap;width:40%}
table.metrics td{font-variant-numeric:tabular-nums}
.split{display:flex;gap:20px;flex-wrap:wrap;align-items:flex-start;margin:14px 0}
.split>*{flex:1 1 320px;min-width:0;margin:0}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:14px;margin:14px 0}
figure.photo{margin:0;background:var(--surface);border:1px solid var(--border);
  border-radius:10px;overflow:hidden}
figure.photo img{display:block;width:100%;height:auto}
figure.photo figcaption{font-size:12px;color:var(--ink-2);padding:8px 10px;border-top:1px solid var(--border)}
.photo-missing{padding:36px 12px;text-align:center;color:var(--muted);font-size:13px}
figure.chart{margin:18px 0;background:var(--surface);border:1px solid var(--border);
  border-radius:10px;padding:14px 16px 10px}
.chart-title{font-size:14px;font-weight:600;margin-bottom:2px}
.chart-cap{font-size:12px;color:var(--ink-2);margin-top:6px;max-width:74ch}
.chart-legend{display:flex;gap:16px;flex-wrap:wrap;margin:6px 0 4px;font-size:12px;color:var(--ink-2)}
.lg-item{display:inline-flex;align-items:center;gap:6px}
.lg-swatch{width:10px;height:10px;border-radius:2px;display:inline-block}
figure.chart svg{width:100%;height:auto;display:block;overflow:visible}
.svg-grid{stroke:var(--grid);stroke-width:1}
.svg-axis{stroke:var(--axis);stroke-width:1}
.svg-ref{stroke:var(--muted);stroke-width:1;stroke-dasharray:5 4}
.svg-tick{fill:var(--muted);font-size:11px;font-variant-numeric:tabular-nums}
.svg-muted{fill:var(--muted);font-size:11px}
.svg-value{fill:var(--ink-2);font-size:11px;font-variant-numeric:tabular-nums;
  paint-order:stroke;stroke:var(--surface);stroke-width:3px;stroke-linejoin:round}
.svg-dlabel{fill:var(--ink-2);font-size:11px;
  paint-order:stroke;stroke:var(--surface);stroke-width:3px;stroke-linejoin:round}
.svg-line{fill:none;stroke-width:2;stroke-linejoin:round;stroke-linecap:round}
.svg-hit{opacity:0;}
.svg-hit:hover{opacity:1;stroke:var(--surface);stroke-width:2}
.svg-marker{stroke:var(--surface);stroke-width:2}
.svg-bar{stroke:var(--surface);stroke-width:1}
.chip{display:inline-flex;align-items:center;gap:6px;font-size:13px;font-weight:600}
.chip-icon{font-size:11px}
.chip-good{color:var(--status-good)} .chip-warning{color:var(--ink)}
.chip-serious{color:var(--ink)} .chip-critical{color:var(--status-critical)}
.chip-warning .chip-icon{color:var(--status-warning)}
.chip-serious .chip-icon{color:var(--status-serious)}
.verdict{display:flex;gap:16px;align-items:center;flex-wrap:wrap;background:var(--surface);
  border:1px solid var(--border);border-radius:8px;padding:10px 14px;margin:12px 0}
.pending{color:var(--muted);font-size:13px}
.note{font-size:13px;color:var(--ink-2)}
.warn{font-size:13px;color:var(--ink);background:var(--surface);border:1px solid var(--border);
  border-left:4px solid var(--status-serious);border-radius:6px;padding:8px 12px}
.empty{color:var(--muted);font-size:13px}
ol.findings{padding-left:22px} ol.findings li{margin:4px 0}
footer.doc{margin-top:48px;padding-top:14px;border-top:1px solid var(--border);
  font-size:12px;color:var(--muted)}
@media print{
  :root{--page:#fff;--surface:#fff;--ink:#000;--ink-2:#333;--muted:#666;
    --grid:#ddd;--axis:#999;--border:rgba(0,0,0,.2)}
  body{font-size:11pt}
  .wrap{max-width:none;padding:0}
  section{break-inside:avoid-page}
  figure.chart,figure.photo,table{break-inside:avoid}
  .svg-hit{display:none}
}
"""


def build_report(
    meta: CaseMeta,
    *,
    still: dict | None = None,
    still_overlay: str | None = None,
    edge: dict | None = None,
    edge_overlay: str | None = None,
    video: dict | None = None,
    six_frames: list[str] | None = None,
    audio: dict | None = None,
    tool_version: str = "",
) -> str:
    """組出完整報告 HTML（字串）。所有影像參數為檔案路徑，會被內嵌成 data URI。"""
    sections: list[str] = []
    findings: list[str] = []
    layers_run: list[str] = []

    if still:
        html, f = _geometry_section(still, image_data_uri(still_overlay) if still_overlay else None, meta)
        sections.append(html)
        findings += f
        layers_run.append("幾何層")
    if edge:
        html, f = _surface_section(edge, image_data_uri(edge_overlay) if edge_overlay else None)
        sections.append(html)
        findings += f
        layers_run.append("表面層")
    if video:
        uris = []
        for p in (six_frames or [])[:6]:
            name = os.path.basename(p)
            blade = name
            if name.startswith("blade"):
                try:  # 檔名 blade0_frameNNNNN.png → 葉片 A（與表格同一套標籤）
                    blade = f"葉片 {chr(65 + int(name.split('_')[0][5:]))}"
                except (ValueError, IndexError):
                    pass
            uris.append((f"{blade}（{name}）", image_data_uri(p, 700)))
        html, f = _dynamics_section(video, uris)
        sections.append(html)
        findings += f
        layers_run.append("動態層")
    if audio:
        html, f = _acoustic_section(audio)
        sections.append(html)
        findings += f
        layers_run.append("聲音層")

    # 摘要磚
    level = "critical" if findings else "good"
    tiles = [_stat_tile("檢出項目", str(len(findings)),
                        "需人工確認" if findings else "本次未檢出異常", level)]
    if still:
        cmpd = still.get("comparison") or {}
        if cmpd.get("view") == "side":
            hb = cmpd.get("hanging_blade") or {}
            tiles.append(_stat_tile("垂掛葉片葉尖偏移", _fmt(hb.get("tip_deflection_px"), 1, " px"),
                                    "側視，含預彎；不做三片互比", "good"))
        else:
            flagged = sum(1 for c in (cmpd.get("comparisons") or []) if c.get("flagged"))
            tiles.append(_stat_tile("幾何離群指標", f"{flagged} / {len(cmpd.get('comparisons') or [])}",
                                    "三片互比", "critical" if flagged else "good"))
    if edge:
        r = edge.get("le_over_te_rms_ratio")
        tiles.append(_stat_tile("前緣/後緣粗糙度比", _fmt(r, 2), "≥ 2 為侵蝕徵兆",
                                "critical" if (r or 0) >= 5 else ("serious" if (r or 0) >= 2 else "good")))
    if video:
        tiles.append(_stat_tile("轉速", _fmt(video.get("rpm"), 2, " rpm"),
                                f"{video.get('n_frames', '—')} 幀"))
    if audio:
        if audio.get("usable"):
            lvl = next((c for c in (audio.get("comparisons") or [])
                        if c["metric"] == "band_level_db"), None)
            tone = any(b.get("tonal_exclusive") for b in (audio.get("blades") or []))
            bad = bool((lvl and lvl.get("flagged")) or tone)
            tiles.append(_stat_tile(
                "聲音層", "有異常" if bad else "三片一致",
                "寬頻位準／窄頻哨音", "critical" if bad else "good"))
        else:
            tiles.append(_stat_tile("聲音層", "不可用", "風噪或訊噪比不足", "warning"))

    if findings:
        find_html = ('<ol class="findings">' +
                     "".join(f"<li>{escape(x)}</li>" for x in findings) + "</ol>")
    else:
        find_html = ('<p class="note">演算法在本次資料中未檢出超出門檻的異常。'
                     '<strong>這不等於葉片沒有問題</strong>——手機地面拍攝看不到髮絲裂縫與早期蝕點，'
                     '仍須依規定執行無人機或近距離檢測。</p>')

    generated = datetime.now().strftime("%Y-%m-%d %H:%M")
    head = [
        f'<header class="doc"><h1>風力機葉片地面目視檢測報告</h1>',
        f'<div class="sub">{escape(meta.asset_id)}'
        f'{" · " + escape(meta.site_name) if meta.site_name else ""}'
        f' · 產生時間 {generated}</div></header>',
        '<section id="summary"><h2>檢測摘要</h2>',
        '<div class="disclaimer"><strong>本報告為演算法初判，需人工確認</strong>'
        '未檢出異常不等於沒有異常。手機地面拍攝屬 Level 1 目視篩檢，'
        '受解析度物理限制，無法取代無人機定檢或近距離檢測；所有判定列的「人工確認」欄'
        '須由具資格的檢測人員簽核後才具效力。</div>',
        f'<div class="tiles">{"".join(tiles)}</div>',
        _kv_table(meta.rows()),
        "<h3>檢出項目</h3>", find_html,
    ]
    if meta.notes:
        head.append('<h3>現場備註</h3><ul>' +
                    "".join(f"<li>{escape(n)}</li>" for n in meta.notes) + "</ul>")
    head.append("</section>")

    foot = [
        '<footer class="doc">',
        f'分析層：{escape("、".join(layers_run) or "無")}｜'
        f'產生工具：blade_proto{(" " + escape(tool_version)) if tool_version else ""}｜'
        f'報告為單一自帶內容 HTML，可離線開啟，瀏覽器列印即可存成 PDF。<br>',
        '數值全部由演算法計算（無 AI 參與）；表格即為圖表的資料檢視。',
        "</footer>",
    ]
    return ("<!doctype html>\n<html lang=\"zh-Hant\">\n<head>\n<meta charset=\"utf-8\"/>\n"
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"/>\n"
            f"<title>葉片檢測報告 — {escape(meta.asset_id)}</title>\n<style>{_CSS}</style>\n"
            "</head>\n<body>\n<div class=\"wrap\">\n"
            + "\n".join(head) + "\n" + "\n".join(sections) + "\n" + "\n".join(foot)
            + "\n</div>\n</body>\n</html>\n")


def write_report(path: str, html: str) -> str:
    d = os.path.dirname(os.path.abspath(path))
    if d:
        os.makedirs(d, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(html)
    return path
