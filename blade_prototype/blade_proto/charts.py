"""極簡內嵌 SVG 圖表（無外部相依，可離線、可列印）。

設計依據（資料視覺化規範）：
- 類別色固定順序取用，不循環；本模組只開放前 3 槽（三片葉片），第 4 片以上不配色
- 量值用單一色階（藍），極性用雙色 + 中性灰中點
- 細記號：線寬 2px、標記 ≥8px、資料端 4px 圓角且貼齊基線
- 網格/座標軸退居背景（hairline）；文字一律用文字色，不用系列色
- ≥2 系列必有圖例，≤4 系列同時直接標註（識別不靠顏色單獨承載）
- 每個記號帶 `<title>`：瀏覽器原生 tooltip，無 JS、可列印

顏色以 CSS 變數（`var(--series-1)` 等）輸出，由 `report.py` 的 `:root` 定義淺/深色值，
故同一份 SVG 在兩種主題下都正確。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from html import escape

__all__ = ["Series", "line_chart", "bar_chart", "SERIES_ROLES", "STATUS_ROLES"]

# 類別色槽（全對比對驗證通過的前三槽）
SERIES_ROLES = ["var(--series-1)", "var(--series-2)", "var(--series-3)"]
STATUS_ROLES = {
    "good": "var(--status-good)",
    "warning": "var(--status-warning)",
    "serious": "var(--status-serious)",
    "critical": "var(--status-critical)",
}

_MAX_HOVER_POINTS = 28  # 每系列的 hover 取樣點上限（控制檔案大小）


@dataclass
class Series:
    name: str
    xs: list[float]
    ys: list[float]
    role: str = SERIES_ROLES[0]
    dashed: bool = False
    markers: list[int] = field(default_factory=list)  # 要特別標出的點索引


def _fmt(v: float, digits: int = 2) -> str:
    if v != v:  # NaN
        return "—"
    s = f"{v:.{digits}f}"
    return s.rstrip("0").rstrip(".") if "." in s else s


def _nice_ticks(lo: float, hi: float, target: int = 5) -> list[float]:
    """挑好看的刻度值（1/2/5 × 10^n）。"""
    if hi <= lo:
        hi = lo + 1.0
    raw = (hi - lo) / max(target, 2)
    mag = 10.0 ** (len(f"{int(abs(raw))}") - 1 if abs(raw) >= 1 else -1)
    while mag > abs(raw):
        mag /= 10.0
    step = next((m * mag for m in (1, 2, 5, 10) if m * mag >= raw), 10 * mag)
    start = step * (int(lo / step) - (1 if lo < 0 and lo % step else 0))
    ticks = []
    v = start
    while v <= hi + step * 0.5:
        ticks.append(round(v, 10))
        v += step
    return ticks


def _rounded_top(x: float, y: float, w: float, h: float, r: float = 4.0) -> str:
    """貼齊基線的長條：只有頂端兩角圓角。"""
    r = min(r, w / 2, max(h, 0.1))
    return (f"M{x:.1f},{y + h:.1f} V{y + r:.1f} Q{x:.1f},{y:.1f} {x + r:.1f},{y:.1f} "
            f"H{x + w - r:.1f} Q{x + w:.1f},{y:.1f} {x + w:.1f},{y + r:.1f} "
            f"V{y + h:.1f} Z")


def _frame(width: int, height: int, title: str, body: str, legend: str = "",
           caption: str = "") -> str:
    cap = f'<figcaption class="chart-cap">{escape(caption)}</figcaption>' if caption else ""
    return (f'<figure class="chart">\n'
            f'  <div class="chart-title">{escape(title)}</div>\n'
            f'  {legend}\n'
            f'  <svg viewBox="0 0 {width} {height}" role="img" '
            f'aria-label="{escape(title)}" preserveAspectRatio="xMidYMid meet">\n{body}\n  </svg>\n'
            f'  {cap}\n</figure>')


def _legend(items: list[tuple[str, str]]) -> str:
    """≥2 系列時必附圖例（色塊 + 文字色標籤）。"""
    if len(items) < 2:
        return ""
    chips = "".join(
        f'<span class="lg-item"><span class="lg-swatch" style="background:{c}"></span>'
        f'{escape(n)}</span>' for n, c in items)
    return f'<div class="chart-legend">{chips}</div>'


def line_chart(
    series: list[Series],
    *,
    title: str,
    x_label: str = "",
    y_label: str = "",
    unit: str = "",
    width: int = 720,
    height: int = 300,
    x_digits: int = 2,
    y_digits: int = 1,
    zero_line: bool = True,
    caption: str = "",
    direct_labels: bool = True,
) -> str:
    """折線圖。系列數 ≤ 3（類別色槽上限）；>3 請改小倍數或折疊。"""
    series = [s for s in series if len(s.xs) >= 2]
    if not series:
        return _frame(width, height, title, '<text x="20" y="40" class="svg-muted">無資料</text>')
    ml, mr, mt, mb = 62, 74 if direct_labels else 20, 16, 42
    pw, ph = width - ml - mr, height - mt - mb
    xs_all = [x for s in series for x in s.xs]
    ys_all = [y for s in series for y in s.ys if y == y]
    x0, x1 = min(xs_all), max(xs_all)
    y0, y1 = min(ys_all), max(ys_all)
    if y1 - y0 < 1e-9:
        y0, y1 = y0 - 1, y1 + 1
    pad = (y1 - y0) * 0.12
    y0, y1 = y0 - pad, y1 + pad
    yticks = _nice_ticks(y0, y1)
    y0, y1 = min(y0, yticks[0]), max(y1, yticks[-1])
    xticks = _nice_ticks(x0, x1)
    xticks = [t for t in xticks if x0 - 1e-9 <= t <= x1 + 1e-9] or [x0, x1]

    def px(x: float) -> float:
        return ml + (x - x0) / (x1 - x0 or 1) * pw

    def py(y: float) -> float:
        return mt + ph - (y - y0) / (y1 - y0 or 1) * ph

    out = []
    for t in yticks:
        out.append(f'<line class="svg-grid" x1="{ml}" y1="{py(t):.1f}" x2="{ml + pw}" y2="{py(t):.1f}"/>')
        out.append(f'<text class="svg-tick" x="{ml - 8}" y="{py(t) + 4:.1f}" text-anchor="end">{_fmt(t, y_digits)}</text>')
    if zero_line and y0 < 0 < y1:
        out.append(f'<line class="svg-axis" x1="{ml}" y1="{py(0):.1f}" x2="{ml + pw}" y2="{py(0):.1f}"/>')
    out.append(f'<line class="svg-axis" x1="{ml}" y1="{mt + ph}" x2="{ml + pw}" y2="{mt + ph}"/>')
    for t in xticks:
        out.append(f'<text class="svg-tick" x="{px(t):.1f}" y="{mt + ph + 18}" text-anchor="middle">{_fmt(t, x_digits)}</text>')
    if x_label:
        out.append(f'<text class="svg-muted" x="{ml + pw / 2:.0f}" y="{height - 8}" text-anchor="middle">{escape(x_label)}</text>')
    if y_label:
        out.append(f'<text class="svg-muted" x="{14}" y="{mt + ph / 2:.0f}" text-anchor="middle" '
                   f'transform="rotate(-90 14 {mt + ph / 2:.0f})">{escape(y_label)}</text>')

    dlabels: list[tuple[float, float, str]] = []
    for s in series:
        pts = [(px(x), py(y)) for x, y in zip(s.xs, s.ys) if y == y]
        if len(pts) < 2:
            continue
        d = " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)
        dash = ' stroke-dasharray="6 4"' if s.dashed else ""
        out.append(f'<polyline class="svg-line" points="{d}" stroke="{s.role}"{dash}><title>'
                   f'{escape(s.name)}</title></polyline>')
        step = max(1, len(pts) // _MAX_HOVER_POINTS)
        for i in range(0, len(pts), step):
            x, y = pts[i]
            out.append(f'<circle class="svg-hit" cx="{x:.1f}" cy="{y:.1f}" r="7" fill="{s.role}"><title>'
                       f'{escape(s.name)} · {escape(x_label) or "x"}={_fmt(s.xs[i], x_digits)} · '
                       f'{_fmt(s.ys[i], y_digits)}{escape(unit)}</title></circle>')
        for i in s.markers:
            if 0 <= i < len(pts):
                x, y = pts[i]
                out.append(f'<circle class="svg-marker" cx="{x:.1f}" cy="{y:.1f}" r="5" fill="{s.role}"><title>'
                           f'{escape(s.name)} · 標記點 {_fmt(s.xs[i], x_digits)}</title></circle>')
        if direct_labels and len(series) <= 4:
            lx, ly = pts[-1]
            dlabels.append((lx + 8, ly + 4, s.name))

    # 系列重合時尾端標註會疊在一起：依 y 排序後強制至少 14px 間距
    dlabels.sort(key=lambda t: t[1])
    for i in range(1, len(dlabels)):
        x, y, name = dlabels[i]
        prev_y = dlabels[i - 1][1]
        if y - prev_y < 14:
            dlabels[i] = (x, prev_y + 14, name)
    for x, y, name in dlabels:
        out.append(f'<text class="svg-dlabel" x="{x:.1f}" y="{min(y, mt + ph + 12):.1f}">{escape(name)}</text>')

    legend = _legend([(s.name, s.role) for s in series])
    return _frame(width, height, title, "\n".join("    " + o for o in out), legend, caption)


def bar_chart(
    labels: list[str],
    values: list[float],
    *,
    title: str,
    roles: list[str] | None = None,
    unit: str = "",
    width: int = 720,
    height: int = 260,
    digits: int = 2,
    y_label: str = "",
    caption: str = "",
    reference: tuple[float, str] | None = None,  # (值, 說明) 例如門檻線
) -> str:
    """直條圖。單一量值用單色；標示身分（例如三片葉片）時傳 roles 帶入類別色。"""
    vals = [v for v in values if v == v]
    if not labels or not vals:
        return _frame(width, height, title, '<text x="20" y="40" class="svg-muted">無資料</text>')
    ml, mr, mt, mb = 62, 24, 26, 44
    pw, ph = width - ml - mr, height - mt - mb
    lo = min(0.0, min(vals))
    hi = max(0.0, max(vals))
    if reference:
        lo, hi = min(lo, reference[0]), max(hi, reference[0])
    span = (hi - lo) or 1.0
    hi += span * 0.18
    yticks = _nice_ticks(lo, hi)
    lo, hi = min(lo, yticks[0]), max(hi, yticks[-1])

    def py(y: float) -> float:
        return mt + ph - (y - lo) / (hi - lo) * ph

    n = len(labels)
    slot = pw / n
    bw = min(slot - 2.0, 88.0)  # 相鄰長條間保留 2px 表面間隙
    out = []
    for t in yticks:
        out.append(f'<line class="svg-grid" x1="{ml}" y1="{py(t):.1f}" x2="{ml + pw}" y2="{py(t):.1f}"/>')
        out.append(f'<text class="svg-tick" x="{ml - 8}" y="{py(t) + 4:.1f}" text-anchor="end">{_fmt(t, digits)}</text>')
    base = py(0)
    out.append(f'<line class="svg-axis" x1="{ml}" y1="{base:.1f}" x2="{ml + pw}" y2="{base:.1f}"/>')
    if reference:
        rv, rname = reference
        out.append(f'<line class="svg-ref" x1="{ml}" y1="{py(rv):.1f}" x2="{ml + pw}" y2="{py(rv):.1f}"><title>'
                   f'{escape(rname)} = {_fmt(rv, digits)}{escape(unit)}</title></line>')
        out.append(f'<text class="svg-muted" x="{ml + pw}" y="{py(rv) - 6:.1f}" text-anchor="end">'
                   f'{escape(rname)} {_fmt(rv, digits)}{escape(unit)}</text>')
    for i, (lab, v) in enumerate(zip(labels, values)):
        cx = ml + slot * (i + 0.5)
        role = (roles[i] if roles and i < len(roles) else "var(--seq-500)")
        if v != v:
            out.append(f'<text class="svg-muted" x="{cx:.1f}" y="{base - 8:.1f}" text-anchor="middle">—</text>')
        else:
            top = py(max(v, 0.0)) if v >= 0 else base
            h = abs(py(v) - base)
            out.append(f'<path class="svg-bar" d="{_rounded_top(cx - bw / 2, top, bw, h)}" fill="{role}">'
                       f'<title>{escape(lab)} · {_fmt(v, digits)}{escape(unit)}</title></path>')
            ly = top - 8 if v >= 0 else base + h + 16
            out.append(f'<text class="svg-value" x="{cx:.1f}" y="{ly:.1f}" text-anchor="middle">'
                       f'{_fmt(v, digits)}{escape(unit)}</text>')
        out.append(f'<text class="svg-tick" x="{cx:.1f}" y="{mt + ph + 20}" text-anchor="middle">{escape(lab)}</text>')
    if y_label:
        out.append(f'<text class="svg-muted" x="14" y="{mt + ph / 2:.0f}" text-anchor="middle" '
                   f'transform="rotate(-90 14 {mt + ph / 2:.0f})">{escape(y_label)}</text>')
    return _frame(width, height, title, "\n".join("    " + o for o in out), "", caption)
