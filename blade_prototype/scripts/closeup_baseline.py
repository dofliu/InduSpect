#!/usr/bin/env python3
"""Mode B 的離線基線：手工特徵 + 邏輯迴歸（純 numpy）。

**這不是規格 §8 的三條基線。** §8.1／8.2 要打 Gemini（本容器沒有任何 API 金鑰）、
§8.3 要 PyTorch（沒裝，也沒有 GPU）。這一條是**能離線跑、不花錢、可重現**的那條，
它回答一個協定需要先知道的問題：

    這份語料裡有多少訊號，是單純的外觀統計就能拿到的？

如果手工特徵就逼近 VLM 的數字，那 VLM 並沒有在做領域推理——它也只是在比對外觀。
所以這條基線的用途是**當地板**，不是當成果：任何一條 §8 的基線要證明自己有價值，
得明顯高過這裡的數字，而不只是高過亂猜。

做法（全部決定性，沒有隨機種子）：
- 特徵：512 px 工作尺度上的顏色（Lab 4×4 格）、梯度與方向直方圖、Laplacian 高頻能量、
  Canny 邊緣密度與 Hough 長線段（裂縫是長直線）、暗斑與亮斑的最大連通元件（雷擊碳化／掉漆）、
  綠色與紅色占比（生物附著／葉尖塗裝）。共 123 維。
- 分類：逐類獨立的邏輯迴歸（one-vs-rest），標準化後全批梯度下降，L2 正則。
- 切分：一律用群感知 5 折（`closeup_blade_groups_wtb.json`），每折用其餘四折訓練。
- 評估域：預設只用取像合格的 839 張（Mode B 的輸入定義）。

用法：
    python scripts/closeup_baseline.py run <語料根目錄> --out preds_baseline.json
    python scripts/closeup_eval.py eval --predictions preds_baseline.json
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
TRUTH = ROOT / "data" / "closeup_truth_wtb.json"
GROUPS = ROOT / "data" / "closeup_blade_groups_wtb.json"
INTAKE = ROOT / "data" / "closeup_intake_wtb.json"

WORK = 512
N_ITER = 600
LR = 0.5
L2 = 1e-2


# --- 特徵 -----------------------------------------------------------------

def image_features(bgr) -> np.ndarray:
    """一張影像 → 123 維。每一組都對應一個「人看得懂」的線索。"""
    import cv2

    img = cv2.resize(bgr, (WORK, WORK), interpolation=cv2.INTER_AREA)
    lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB)
    hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)
    grey = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    f: list[float] = []

    # 1. 顏色：Lab 4×4 格的均值與標準差（96）——底色、髒污、塗裝分布
    cell = WORK // 4
    for r in range(4):
        for c in range(4):
            blk = lab[r * cell:(r + 1) * cell, c * cell:(c + 1) * cell].reshape(-1, 3)
            f += list(blk.mean(axis=0)) + list(blk.std(axis=0))

    # 2. 色相占比（4）——綠=生物附著、紅=葉尖塗裝、暗=雷擊碳化、亮=過曝或掉漆
    h, s, v = hsv[:, :, 0].astype(np.float32), hsv[:, :, 1].astype(np.float32), hsv[:, :, 2].astype(np.float32)
    n = h.size
    f.append(float(((s > 50) & (h > 35) & (h < 85)).sum()) / n)
    f.append(float(((s > 60) & ((h < 12) | (h > 168))).sum()) / n)
    f.append(float((v < 60).sum()) / n)
    f.append(float((v > 235).sum()) / n)

    # 3. 梯度與方向直方圖（10）——紋理粗細與有沒有主方向
    gx = cv2.Sobel(grey, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(grey, cv2.CV_32F, 0, 1, ksize=3)
    mag = cv2.magnitude(gx, gy)
    f.append(float(mag.mean()))
    f.append(float(np.percentile(mag, 95)))
    ang = (np.arctan2(gy, gx) % np.pi) / np.pi * 8
    hist, _ = np.histogram(ang[mag > mag.mean()], bins=8, range=(0, 8))
    f += list(hist / max(1, hist.sum()))

    # 4. 高頻能量（2）——龜裂與網狀裂紋是高頻
    lap = cv2.Laplacian(grey, cv2.CV_32F)
    f.append(float(lap.var()))
    blur = cv2.GaussianBlur(grey.astype(np.float32), (0, 0), 3)
    f.append(float(np.abs(grey - blur).mean()) / (float(grey.std()) + 1e-3))

    # 5. 邊緣與長直線（4）——裂縫是長而直的，侵蝕不是
    edges = cv2.Canny(grey, 60, 160)
    f.append(float(edges.mean()) / 255.0)
    lines = cv2.HoughLinesP(edges, 1, np.pi / 180, threshold=60, minLineLength=WORK // 6, maxLineGap=8)
    if lines is None or len(lines) == 0:
        f += [0.0, 0.0, 0.0]
    else:
        # OpenCV 4 回 (N,1,4)、OpenCV 5 回 (N,4)，兩種都要吃
        seg = np.asarray(lines).reshape(-1, 4)
        lens = np.hypot(seg[:, 2] - seg[:, 0], seg[:, 3] - seg[:, 1])
        angs = np.arctan2(seg[:, 3] - seg[:, 1], seg[:, 2] - seg[:, 0]) % np.pi
        f += [float(len(seg)) / 50.0, float(lens.max()) / (WORK * 1.414), float(angs.std())]

    # 6. 暗斑與亮斑的最大連通元件（5）——雷擊碳化是一塊暗的、掉漆是一塊亮的
    for mask in (grey < max(10, grey.mean() - 2 * grey.std()),
                 grey > min(245, grey.mean() + 2 * grey.std())):
        m = mask.astype(np.uint8)
        f.append(float(m.mean()))
        num, _, stats, _ = cv2.connectedComponentsWithStats(m, 8)
        f.append(float(stats[1:, cv2.CC_STAT_AREA].max()) / m.size if num > 1 else 0.0)
    # 最大暗元件的長寬比（1）——碳化偏圓、刮痕偏長
    m = (grey < max(10, grey.mean() - 2 * grey.std())).astype(np.uint8)
    num, _, stats, _ = cv2.connectedComponentsWithStats(m, 8)
    if num > 1:
        k = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
        w_, h_ = stats[k, cv2.CC_STAT_WIDTH], stats[k, cv2.CC_STAT_HEIGHT]
        f.append(float(max(w_, h_)) / max(1.0, float(min(w_, h_))))
    else:
        f.append(0.0)

    # 7. 色差邊緣（2）——顏色變化而非亮度變化的邊界（藻類、塗裝界線）
    for ch in (1, 2):
        c = lab[:, :, ch].astype(np.float32)
        f.append(float(cv2.magnitude(cv2.Sobel(c, cv2.CV_32F, 1, 0, ksize=3),
                                     cv2.Sobel(c, cv2.CV_32F, 0, 1, ksize=3)).mean()))
    return np.asarray(f, dtype=np.float64)


# --- 邏輯迴歸（純 numpy，決定性）------------------------------------------

def fit_logreg(X: np.ndarray, y: np.ndarray, n_iter: int = N_ITER, lr: float = LR,
               l2: float = L2) -> np.ndarray:
    """全批梯度下降。零初始化 + 固定迭代數 = 同樣的輸入永遠同樣的權重。"""
    w = np.zeros(X.shape[1])
    m = X.shape[0]
    for _ in range(n_iter):
        p = 1.0 / (1.0 + np.exp(-np.clip(X @ w, -30, 30)))
        grad = X.T @ (p - y) / m + l2 * np.r_[0.0, w[1:]]
        w -= lr * grad
    return w


def standardise(train: np.ndarray, other: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    mu, sd = train.mean(axis=0), train.std(axis=0) + 1e-9
    z = lambda A: np.c_[np.ones(len(A)), (A - mu) / sd]
    return z(train), z(other)


def run_folds(feat: dict[str, np.ndarray], truth: dict[str, list[str]], classes: list[str],
              folds: dict[str, int], ids: list[str]) -> dict[str, list[str]]:
    """每一折用其餘四折訓練，只預測這一折。訓練池與測試池整群分離（群感知切分保證）。"""
    pred: dict[str, list[str]] = {i: [] for i in ids}
    for f in sorted({folds[i] for i in ids}):
        tr = [i for i in ids if folds[i] != f]
        te = [i for i in ids if folds[i] == f]
        Xtr, Xte = standardise(np.stack([feat[i] for i in tr]), np.stack([feat[i] for i in te]))
        for c in classes:
            y = np.array([1.0 if c in truth[i] else 0.0 for i in tr])
            if y.sum() == 0:
                continue
            w = fit_logreg(Xtr, y)
            p = 1.0 / (1.0 + np.exp(-np.clip(Xte @ w, -30, 30)))
            for i, pi in zip(te, p):
                if pi >= 0.5:
                    pred[i].append(c)
    return {i: sorted(v) for i, v in pred.items()}


def cmd_run(args: argparse.Namespace) -> int:
    import cv2

    ds = Path(args.dataset)
    truth_doc = json.loads(TRUTH.read_text(encoding="utf-8"))
    truth, classes = truth_doc["labels"], truth_doc["classes"]
    folds = {k: v for k, v in json.loads(GROUPS.read_text(encoding="utf-8"))["folds"].items()}
    intake = json.loads(INTAKE.read_text(encoding="utf-8"))["labels"]

    ids_all = sorted(truth, key=int)
    in_domain = [i for i in ids_all if intake.get(i) == "P"]
    ids = in_domain if args.domain == "intake_P" else ids_all

    feat = {}
    for i in ids_all:
        img = cv2.imread(str(ds / "JPEGImages" / f"{i}.jpg"))
        if img is not None:
            feat[i] = image_features(img)
    ids = [i for i in ids if i in feat]

    pred = run_folds(feat, truth, classes, folds, ids)
    doc = dict(
        model=f"手工特徵 + 邏輯迴歸（純 numpy，{len(next(iter(feat.values())))} 維）／域={args.domain}",
        note="**不是規格 §8 的三條基線**：§8.1／8.2 需要 Gemini API 金鑰（本容器沒有）、"
             "§8.3 需要 PyTorch（未安裝）。這條是能離線跑、不花錢、可重現的地板，"
             "用來回答「這份語料裡有多少訊號是單純外觀統計就能拿到的」。",
        split="folds", predictions=pred)
    Path(args.out).write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")

    # 域外行為：拿同一組權重去看整機照，§8.3 說的「分布外崩掉」在這裡先看一眼
    out_of_domain = [i for i in ids_all if i in feat and intake.get(i) != "P"]
    ood = {}
    if out_of_domain and args.domain == "intake_P":
        Xtr, Xood = standardise(np.stack([feat[i] for i in ids]), np.stack([feat[i] for i in out_of_domain]))
        for c in classes:
            y = np.array([1.0 if c in truth[i] else 0.0 for i in ids])
            if y.sum() == 0:
                continue
            w = fit_logreg(Xtr, y)
            p = 1.0 / (1.0 + np.exp(-np.clip(Xood @ w, -30, 30)))
            hit = sum(1 for i, pi in zip(out_of_domain, p) if pi >= 0.5 and c in truth[i])
            ood[c] = dict(predicted=int((p >= 0.5).sum()),
                          truth_here=sum(1 for i in out_of_domain if c in truth[i]), tp=hit)
        Path(args.out).with_suffix(".ood.json").write_text(
            json.dumps(dict(n_out_of_domain=len(out_of_domain), per_class=ood),
                       ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(json.dumps(dict(images=len(ids), out=args.out, out_of_domain=len(out_of_domain)),
                     ensure_ascii=False))
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Mode B 離線基線")
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("dataset")
    r.add_argument("--out", required=True)
    r.add_argument("--domain", default="intake_P", choices=("intake_P", "all"))
    r.set_defaults(func=cmd_run)
    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
