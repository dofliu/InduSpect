"""Mode B 取像閘門（`BLADE_CLOSEUP_SPEC.md` §1.2）的**幾何那一半**：問「這張是不是整機照」。

§1.2 說「這條規則可以用一個分割模型或簡單的前景占比自動判」。實測（`CLOSEUP_INTAKE_GATE.md`）
的答案是：**用 Mode A 的分割量前景占比判不出來**——局部天空模型把填滿畫面的葉片當背景，
P（合格）的前景占比中位數比 W（整機）還低，單一門檻的平衡準確率只有 0.5–0.7。原因不是
門檻沒調好，而是天空模型假設「背景是平滑的天空」，近身照的背景正是葉片本身。

所以這支模組只做它做得準的那件事：把整張照片交給 Mode A 的分割 → 結構定位 → 拍攝閘門，
**Mode A 以正視規則放行（三片 + 塔架）= 這是一張可用的整機照 = Mode B 一定要拒收**（那張該走 Mode A）。
這是硬規則，不是分數。它抓不到「整機但 Mode A 也拒收」的照片（W 裡大多數是這種），那部分由
`scripts/closeup_intake_gate.py` 的外觀探針補。

**側視放行不算。** 全語料實測 Mode A 放行 10 張，其中 8 張是真值 P 的近身照，全部走的是側視規則
（`quality.detect_side_view`：恰好兩個垂直的伸長元件、一上一下、有塔架）——填滿畫面的葉片被一道
裂縫或接縫切成上下兩段，塔架找到的是葉片自己。那條規則是為 Mode A 的側視整機照設計的，
在近身照上會誤放行（SPEC §13 第 14 項），所以這裡只認 `view == "front"` 的放行。

不可退化的約定：
1. 這裡**不判 P**。「Mode A 不放行」≠「近身照合格」，兩者之間有整機遠景、展向遠視、機艙特寫。
2. 幾何量（前景占比、葉片數、塔架）一律回傳給呼叫端當**佐證**，不是判定依據。
"""

from __future__ import annotations

from dataclasses import asdict, dataclass

import cv2
import numpy as np

from .quality import assess_capture
from .segmentation import find_structure, segment_turbine

# Mode A 走的工作尺度（`scripts/closeup_corpus_report.py` 的分流重跑用同一個數）。
WORK_MAX_SIDE = 1024


@dataclass
class IntakeGeometry:
    """一張照片丟進 Mode A 之後看到什麼。`mode_a_ok=True` 是唯一有判定力的欄位。"""

    mode_a_ok: bool
    mode_a_view: str | None          # assess_capture 的 metrics["view"]：front／side；沒定位到就 None
    mode_a_reasons: list[str]
    mask_frac: float
    n_blades: int
    tower_found: bool
    hub_radius_frac: float
    error: str | None = None

    @property
    def reject_as_whole_turbine(self) -> bool:
        """Mode A **正視**放行就是整機照。側視放行在近身照上會誤觸（見模組說明），交給探針。"""
        return self.mode_a_ok and self.mode_a_view == "front"

    def to_dict(self) -> dict:
        d = asdict(self)
        d["reject_as_whole_turbine"] = self.reject_as_whole_turbine
        return d


def _to_work_scale(img_bgr: np.ndarray, max_side: int) -> np.ndarray:
    h, w = img_bgr.shape[:2]
    s = max_side / max(h, w)
    if s >= 1.0:
        return img_bgr
    return cv2.resize(img_bgr, (int(round(w * s)), int(round(h * s))), interpolation=cv2.INTER_AREA)


def intake_geometry(img_bgr: np.ndarray, max_side: int = WORK_MAX_SIDE) -> IntakeGeometry:
    """跑 Mode A 的三步（分割 → 結構定位 → 拍攝閘門），任何一步丟例外都收成 `error`，
    不往外丟：閘門的呼叫端要的是「這張能不能用」，不是 traceback。"""
    img = _to_work_scale(img_bgr, max_side)
    h, w = img.shape[:2]
    try:
        seg = segment_turbine(img)
        mask_frac = float(np.count_nonzero(seg.mask)) / float(h * w)
        st = find_structure(seg.mask, horizon_y=seg.horizon_y)
        verdict = assess_capture(seg, st)
        return IntakeGeometry(
            mode_a_ok=bool(verdict.ok),
            mode_a_view=verdict.metrics.get("view"),
            mode_a_reasons=list(verdict.reasons),
            mask_frac=mask_frac,
            n_blades=len(st.blades),
            tower_found=bool(st.tower_found),
            hub_radius_frac=float(st.hub_radius_px or 0.0) / float(min(h, w)),
        )
    except Exception as exc:  # noqa: BLE001  分割在極端輸入上會丟各種例外，全部收成拒收理由
        return IntakeGeometry(
            mode_a_ok=False,
            mode_a_view=None,
            mode_a_reasons=[f"Mode A 例外：{type(exc).__name__}"],
            mask_frac=0.0,
            n_blades=0,
            tower_found=False,
            hub_radius_frac=0.0,
            error=f"{type(exc).__name__}: {exc}"[:200],
        )
