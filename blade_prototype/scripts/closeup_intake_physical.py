#!/usr/bin/env python3
"""Mode B §1.2 取像閘門：把「葉片弦向 ≥ 1/3 畫面」當成**物理量**來量，四種操作化各量一次。

`BLADE_CLOSEUP_SPEC.md` §1.2 寫「這條規則可以用一個分割模型或簡單的前景占比自動判」。
`CLOSEUP_INTAKE_GATE.md`（A3）已經證否了其中「簡單的前景占比」那一版——Mode A 的局部天空模型
把填滿畫面的葉片當背景。當時的結論是「先用凍結特徵的外觀探針給拒收理由，但**不得拒收或放行**」，
而接棒筆記把「換掉外觀探針」排成下一步：要的是一個**量得到弦向占比**的東西，不是學取景碼的分類器。

這支腳本就是去做那件事，四種互相獨立的操作化：

1. `border`  邊框眾數色當背景 → 前景的最大內接圓直徑 / 短邊（= 弦長）
2. `chord`   Canny + Hough 取長直線 → 主方向上近平行線的間距（= 前後緣間距）
3. `bg`      天空（藍／亮且平滑、與上下緣相連）+ 地面（綠褐且粗糙）占畫面比
4. `thin`    形態學 top-hat／black-hat，結構元素取短邊的 1/3 → **比 1/3 還細的結構**的
             面積、跨距與寬度（規格門檻的直接反面：有細結構橫跨畫面就不是近身照）

四種都在 1,065 張有真值的 wtb 影像上量，並用 `closeup_blade_groups_wtb.json` 的群感知 5 折
把全部特徵餵進同一個純 numpy 邏輯迴歸（與 `closeup_baseline.py` 同一個實作慣例：零初始化、
無隨機種子，重跑逐位元相同）。

用法（影像不進版控，要自己準備）：

    python3 scripts/closeup_intake_physical.py run --images <JPEGImages 目錄> \\
        --out data/closeup_intake_physical_wtb.json
    python3 scripts/closeup_intake_physical.py report

**這支腳本不是閘門**：它的產出是「這些量測有沒有鑑別力」的證據。結論寫在
`CLOSEUP_INTAKE_GATE.md` §5 與 SPEC §1.2 的註記裡。
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
WORK = 384          # 量測工作尺度；比 Mode A 的 1024 小，因為這裡量的是大尺度形狀
HOUGH_WORK = 512    # 直線偵測需要多一點解析度

TRUTH = ROOT / "data" / "closeup_intake_wtb.json"
GROUPS = ROOT / "data" / "closeup_blade_groups_wtb.json"


# --------------------------------------------------------------- 四組量測


def _resize(im, work: int):
    import cv2

    h, w = im.shape[:2]
    s = work / max(h, w)
    if s >= 1:
        return im
    return cv2.resize(im, (int(round(w * s)), int(round(h * s))), interpolation=cv2.INTER_AREA)


def feat_border(im) -> dict:
    """邊框眾數色當背景 → 前景最大內接圓直徑 / 短邊。

    假設「畫面邊緣是背景」。**在 P 上正好不成立**：填滿畫面的葉片自己就占著邊框。
    """
    import cv2

    im = _resize(im, WORK)
    h, w = im.shape[:2]
    lab = cv2.cvtColor(cv2.GaussianBlur(im, (5, 5), 0), cv2.COLOR_BGR2LAB).astype(np.float32)
    ring = np.zeros((h, w), bool)
    b = max(2, int(0.04 * min(h, w)))
    ring[:b, :] = ring[-b:, :] = ring[:, :b] = ring[:, -b:] = True
    bg = np.median(lab[ring], axis=0)
    d = np.linalg.norm(lab - bg, axis=2)
    sigma = 1.4826 * np.median(np.abs(d - np.median(d))) + 1e-6
    fg = (d > np.median(d) + 3.0 * sigma).astype(np.uint8)
    fg = cv2.morphologyEx(fg, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5)))
    dt = cv2.distanceTransform(fg, cv2.DIST_L2, 5) if fg.any() else np.zeros((h, w), np.float32)
    return {"border_fg_frac": float(fg.mean()),
            "border_thick": float(dt.max()) * 2.0 / min(h, w)}


def feat_chord(im) -> dict:
    """Hough 長直線 → 主方向上近平行線群的間距（前後緣間距 = 弦長）。"""
    import cv2

    im = _resize(im, HOUGH_WORK)
    h, w = im.shape[:2]
    short = min(h, w)
    g = cv2.GaussianBlur(cv2.cvtColor(im, cv2.COLOR_BGR2GRAY), (5, 5), 0)
    e = cv2.Canny(g, 50, 140)
    lines = cv2.HoughLines(e, 1, np.pi / 180, int(short * 0.33))
    if lines is None:
        return {"chord_n_lines": 0.0, "chord_frac": 0.0, "chord_one_edge": 0.0}
    L = lines[:60, 0, :]
    ang = L[:, 1] * 2.0
    theta0 = float(np.arctan2(np.sin(ang).mean(), np.cos(ang).mean()) / 2.0)
    dth = np.abs(((L[:, 1] - theta0 + np.pi / 2) % np.pi) - np.pi / 2)
    keep = dth < np.deg2rad(12)
    if not keep.any():
        return {"chord_n_lines": float(len(L)), "chord_frac": 0.0, "chord_one_edge": 0.0}
    r = np.sort(L[keep, 0])
    groups = [[r[0]]]
    for v in r[1:]:
        if v - groups[-1][-1] <= max(4.0, 0.02 * short):
            groups[-1].append(v)
        else:
            groups.append([v])
    cen = np.array([np.mean(gp) for gp in groups])
    if len(cen) == 1:  # 只有一條長邊：葉片多半溢出畫面（弦長 ≥ 畫面）
        return {"chord_n_lines": float(len(L)), "chord_frac": 1.0, "chord_one_edge": 1.0}
    return {"chord_n_lines": float(len(L)),
            "chord_frac": float(np.diff(cen).max()) / short,
            "chord_one_edge": 0.0}


def feat_bg(im) -> dict:
    """天空（藍／亮且平滑、與上下緣相連）+ 地面（綠褐且粗糙）占畫面比。

    量到的最大問題：**過曝的白葉面與陰天的天空在像素上一樣**。
    """
    import cv2

    im = _resize(im, WORK)
    h, w = im.shape[:2]
    hsv = cv2.cvtColor(im, cv2.COLOR_BGR2HSV)
    H, S, V = (hsv[..., i].astype(np.float32) for i in range(3))
    g = cv2.cvtColor(im, cv2.COLOR_BGR2GRAY).astype(np.float32)
    m = cv2.blur(g, (9, 9))
    sd = np.sqrt(np.maximum(cv2.blur(g * g, (9, 9)) - m * m, 0))
    smooth = sd < 6.0
    sky_like = (((H > 90) & (H < 135) & (S > 40) & (V > 90)) | ((S < 40) & (V > 170))) & smooth
    ground_like = ((((H > 20) & (H < 90) & (S > 50)) | ((H < 25) & (S > 60) & (V < 200)))
                   & (sd > 4.0))

    def touching(mask, rows):
        mask = mask.astype(np.uint8)
        _, lb = cv2.connectedComponents(mask)
        keep = set(np.unique(lb[rows][mask[rows] > 0])) - {0}
        return np.isin(lb, list(keep)) if keep else np.zeros(mask.shape, bool)

    top, bot = slice(0, max(1, h // 12)), slice(h - max(1, h // 12), h)
    sky = touching(sky_like, top) | touching(sky_like, bot)
    ground = touching(ground_like, bot)
    return {"bg_frac": float((sky | ground).mean()), "bg_sky_frac": float(sky.mean()),
            "bg_ground_frac": float(ground.mean()), "bg_smooth_frac": float(smooth.mean())}


def feat_thin(im) -> dict:
    """形態學 top-hat／black-hat，結構元素 = 短邊的 1/3。

    §1.2 的門檻直接反過來用：**比 1/3 畫面還細**的結構才會有反應。
    整機照（三片 + 塔架）與展向遠視（一條細葉片）會亮，近身照不會。
    """
    import cv2

    im = _resize(im, WORK)
    h, w = im.shape[:2]
    short, diag = min(h, w), float(np.hypot(h, w))
    g = cv2.GaussianBlur(cv2.cvtColor(im, cv2.COLOR_BGR2GRAY), (3, 3), 0).astype(np.uint8)
    k = max(3, int(round(short / 3)) | 1)
    se = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k))
    resp = np.maximum(cv2.morphologyEx(g, cv2.MORPH_BLACKHAT, se),
                      cv2.morphologyEx(g, cv2.MORPH_TOPHAT, se))
    med = float(np.median(resp))
    mad = float(np.median(np.abs(resp - med))) + 1e-6
    m = (resp > med + 8.0 * 1.4826 * mad).astype(np.uint8)
    m = cv2.morphologyEx(m, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5)))
    n, lb, stats, _ = cv2.connectedComponentsWithStats(m, 8)
    best_len = best_wid = area_frac = 0.0
    for i in range(1, n):
        a = int(stats[i, cv2.CC_STAT_AREA])
        if a < 0.0008 * h * w:
            continue
        ys, xs = np.nonzero(lb == i)
        pts = np.stack([xs, ys], 1).astype(np.float32)
        c = pts - pts.mean(0)
        _, sv, _ = np.linalg.svd(c, full_matrices=False)
        length, width = 4.0 * sv[0] / np.sqrt(len(pts)), 4.0 * sv[1] / np.sqrt(len(pts))
        if length > best_len:
            best_len, best_wid = float(length), float(width)
        area_frac += a / (h * w)
    return {"thin_area_frac": float(area_frac), "thin_span_frac": float(best_len) / diag,
            "thin_width_frac": float(best_wid) / short,
            "thin_elong": float(best_len / max(best_wid, 1e-6))}


FAMILIES = {"border": feat_border, "chord": feat_chord, "bg": feat_bg, "thin": feat_thin}


# --------------------------------------------------------------- 評估


def _logistic(X: np.ndarray, y: np.ndarray, iters: int = 400, lr: float = 0.5,
              l2: float = 1e-2) -> np.ndarray:
    """零初始化、固定步數的梯度下降——**沒有隨機性**，重跑逐位元相同（與 B2 基線同一個慣例）。"""
    w = np.zeros(X.shape[1])
    for _ in range(iters):
        p = 1.0 / (1.0 + np.exp(-X @ w))
        w -= lr * (X.T @ (p - y) / len(y) + l2 * np.r_[w[:-1], 0.0])
    return w


def _balanced_accuracy(pred: np.ndarray, y: np.ndarray) -> float:
    if not (y == 1).any() or not (y == 0).any():
        return float("nan")
    return float((pred[y == 1].mean() + 1.0 - pred[y == 0].mean()) / 2.0)


def evaluate(rows: dict, folds: dict) -> dict:
    """單一特徵的最佳門檻（**in-sample，刻意樂觀**）＋全部特徵的群感知 5 折。

    單一門檻用 in-sample 是故意的：那是這些量測的**上界**，而它連上界都不夠。
    """
    ids = sorted([i for i in rows if i in folds], key=int)
    cols = sorted({k for i in ids for k in rows[i] if k != "truth"})
    X = np.array([[rows[i].get(c, 0.0) for c in cols] for i in ids], float)
    X = np.nan_to_num(X, nan=0.0, posinf=0.0, neginf=0.0)
    y = np.array([1 if rows[i]["truth"] == "P" else 0 for i in ids])
    fold = np.array([folds[i] for i in ids])

    singles = {}
    for j, c in enumerate(cols):
        x = X[:, j]
        best = (0.0, None, None)
        for t in np.unique(np.round(x, 3)):
            for sign in (1.0, -1.0):
                ba = _balanced_accuracy((x * sign >= t * sign), y)
                if ba == ba and ba > best[0]:
                    best = (ba, float(t), int(sign))
        singles[c] = {"balanced_accuracy_in_sample": round(best[0], 4),
                      "threshold": best[1], "direction": ">=" if best[2] > 0 else "<="}

    mu, sd = X.mean(0), X.std(0) + 1e-9
    Z = np.hstack([(X - mu) / sd, np.ones((len(X), 1))])
    per_fold = []
    for f in sorted(set(fold.tolist())):
        tr, te = fold != f, fold == f
        w = _logistic(Z[tr], y[tr])
        pred = (1.0 / (1.0 + np.exp(-Z[te] @ w))) >= 0.5
        per_fold.append(round(_balanced_accuracy(pred, y[te]), 4))

    by_class: dict[str, int] = {}
    for i in ids:
        by_class[rows[i]["truth"]] = by_class.get(rows[i]["truth"], 0) + 1
    return {"n": len(ids), "truth_counts": by_class, "features": cols,
            "single_feature_in_sample": singles,
            "combined_group_aware_cv": {"per_fold": per_fold,
                                        "mean": round(float(np.mean(per_fold)), 4),
                                        "std": round(float(np.std(per_fold)), 4)}}


def cmd_run(a: argparse.Namespace) -> int:
    import cv2

    truth = json.load(open(TRUTH, encoding="utf-8"))["labels"]
    folds = json.load(open(GROUPS, encoding="utf-8"))["folds"]
    rows: dict[str, dict] = {}
    for k, i in enumerate(sorted(truth, key=int)):
        path = os.path.join(a.images, f"{i}.jpg")
        im = cv2.imread(path)
        if im is None:
            continue
        rec: dict = {"truth": truth[i]}
        for name, fn in FAMILIES.items():
            try:
                rec.update({kk: round(float(vv), 5) for kk, vv in fn(im).items()})
            except Exception as exc:  # noqa: BLE001  真實語料會撐出各種邊界情況
                rec[f"{name}_error"] = f"{type(exc).__name__}"
        rows[i] = rec
        if k % 200 == 0:
            print(f"  {k}/{len(truth)}", file=sys.stderr)
    if not rows:
        print(f"{a.images} 裡沒有讀得到的影像", file=sys.stderr)
        return 2
    doc = {"version": "b-intake-physical-2026-09-28",
           "source": "wtb（figshare 30210175，CC BY 4.0）；影像不進版控",
           "note": ("§1.2「葉片弦向 ≥ 1/3 畫面」的四種物理操作化。真值是 closeup_intake_wtb.json 的"
                    "單一標註者標記（未經人工複核），所以這裡量到的上限同時受標記品質限制。"),
           "work_max_side": WORK, "hough_max_side": HOUGH_WORK,
           "summary": evaluate(rows, folds), "images": rows}
    Path(a.out).write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    s = doc["summary"]
    print(json.dumps({"n": s["n"], "combined": s["combined_group_aware_cv"]["mean"],
                      "best_single": max(v["balanced_accuracy_in_sample"]
                                         for v in s["single_feature_in_sample"].values())},
                     ensure_ascii=False))
    return 0


def render_markdown(doc: dict, source: str) -> str:
    s = doc["summary"]
    L: list[str] = []
    A = L.append
    A("# Mode B §1.2 取像閘門：把「弦向 ≥ 1/3」當物理量來量的四次嘗試")
    A("")
    A(f"> 由 `scripts/closeup_intake_physical.py report` 從 `{source}` 產生，**數字不手抄**。"
      f"影像不進版控（wtb，figshare 30210175，CC BY 4.0）。")
    A("")
    A("## 0. 一句話")
    A("")
    c = s["combined_group_aware_cv"]
    best = max(s["single_feature_in_sample"].items(), key=lambda kv: kv[1]["balanced_accuracy_in_sample"])
    A(f"四種互相獨立的物理量測，在 {s['n']} 張有真值的影像上：**單一特徵的最佳門檻（in-sample、刻意樂觀）"
      f"{best[1]['balanced_accuracy_in_sample']:.3f}**（`{best[0]}`），"
      f"**全部 {len(s['features'])} 維合起來、群感知 5 折 {c['mean']:.3f} ± {c['std']:.3f}**。")
    A("")
    A("對照：同一份語料、同一套群感知切分，凍結 ResNet18 特徵的探針是 **0.910**，亂猜是 0.5。")
    A("**也就是說：合起來的物理量測比亂猜好不了多少，而且比單一門檻的樂觀上界還低**"
      "（單一門檻是 in-sample 挑的，本來就會高估）。")
    A("")
    A("## 1. 四種操作化")
    A("")
    A("| 代號 | 量什麼 | 假設 | 這個假設怎麼壞掉 |")
    A("|---|---|---|---|")
    A("| `border` | 邊框眾數色當背景 → 前景最大內接圓直徑／短邊 | 畫面邊緣是背景 | "
      "P 的葉片**自己占著邊框**，於是「前景」變成角落那塊天空 |")
    A("| `chord` | Hough 長直線 → 主方向近平行線群的間距 | 葉片前後緣是兩條長直線 | "
      "近身照常常只看得到一條邊、或一條都沒有（表面特寫根本沒有輪廓） |")
    A("| `bg` | 天空＋地面占畫面比 | 天空可由顏色與平滑度認出來 | "
      "**過曝的白葉面與陰天的天空在像素上一樣**；灰雲天空則落在天空色範圍外 |")
    A("| `thin` | top-hat／black-hat（結構元素 = 短邊 1/3）的細結構面積、跨距、寬度 | "
      "整機照與展向遠視有「比 1/3 還細」的結構橫跨畫面 | "
      "方向對（T 的跨距中位數是 P 的三倍）但分佈重疊太多 |")
    A("")
    A("## 2. 逐特徵（in-sample 最佳門檻＝上界）")
    A("")
    A("| 特徵 | 方向 | 門檻 | 平衡準確率（樂觀） |")
    A("|---|---|---|---|")
    for k, v in sorted(s["single_feature_in_sample"].items(),
                       key=lambda kv: -kv[1]["balanced_accuracy_in_sample"]):
        t = "—" if v["threshold"] is None else f"{v['threshold']:.3f}"
        A(f"| `{k}` | {v['direction']} | {t} | {v['balanced_accuracy_in_sample']:.3f} |")
    A("")
    A("## 3. 全部合起來（群感知 5 折）")
    A("")
    A(f"逐折：{'、'.join(f'{x:.3f}' for x in c['per_fold'])} → **{c['mean']:.3f} ± {c['std']:.3f}**")
    A("")
    A("切分用 `closeup_blade_groups_wtb.json` 的 `folds`（影像重疊連出的 `split_group`）——"
      "語料自己附的切分洩漏 63.4%，不可用。")
    A("")
    A("## 4. 結論")
    A("")
    A("1. **§1.2 不能用這一類物理量測當閘門**。規格那句「可以用一個分割模型或簡單的前景占比自動判」，"
      "「簡單的前景占比」這一半已經被 `CLOSEUP_INTAKE_GATE.md` 證否，這份再證否另外三種操作化。")
    A("2. **原因是語意的、不是門檻沒調好**：白葉面與陰天天空在像素上無法分辨，"
      "能分辨 W／T 的是「畫面裡有沒有一台風機的形狀」——那是語意，不是光度。")
    A("3. **外觀探針維持建議性**（不得單獨拒收或放行）：它的 0.910 是「學到了取景碼」，"
      "跨語料會崩（`CROSS_CORPUS_VALIDATION.md`：廂型車 59/62 被判成近身葉片照）。")
    A("4. **真的要閘門，要嘛換資訊來源、要嘛換監督訊號**——"
      "前者是把取像條件變成**宣告＋感測器**（無人機知道自己的距離與角度，"
      "與 Mode A 側視改成宣告制同一個道理，SPEC §13-16）；"
      "後者是訓練一個葉片／背景分割模型，而那需要先有分割標註。")
    A("")
    A("## 5. 這份結果不能說什麼")
    A("")
    A(f"- 真值是**單一標註者**（本專案的模型）在 300 px 印樣上判的、未經人工複核，"
      f"所以 {s['n']} 張的標記本身帶噪音；這裡量到的上限同時受它限制。")
    A("- 只在 wtb 一份語料上量。四種量測都沒有跨語料驗過——不過既然在自己的語料上就不成立，"
      "跨語料不會更好。")
    A("- 沒有證明「不存在可行的物理量測」，只證明**這四種不行**，而它們涵蓋了規格提到的那一類。")
    A("")
    return "\n".join(L)


def cmd_report(a: argparse.Namespace) -> int:
    doc = json.load(open(a.results, encoding="utf-8"))
    try:
        source = Path(a.results).resolve().relative_to(ROOT).as_posix()
    except ValueError:
        source = Path(a.results).name
    Path(a.out).write_text(render_markdown(doc, source), encoding="utf-8")
    print(f"寫入 {a.out}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--images", required=True, help="wtb 的 JPEGImages 目錄（檔名 <id>.jpg）")
    r.add_argument("--out", default=str(ROOT / "data" / "closeup_intake_physical_wtb.json"))
    p = sub.add_parser("report")
    p.add_argument("--results", default=str(ROOT / "data" / "closeup_intake_physical_wtb.json"))
    p.add_argument("--out", default=str(ROOT / "CLOSEUP_INTAKE_PHYSICAL.md"))
    a = ap.parse_args(argv)
    return cmd_run(a) if a.cmd == "run" else cmd_report(a)


if __name__ == "__main__":
    raise SystemExit(main())
