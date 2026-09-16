#!/usr/bin/env python3
"""線性探針：凍結特徵 + B2 同一個 numpy 邏輯迴歸 + 同一套群感知 5 折。**不 import torch。**

特徵由 `closeup_features_cnn.py` 抽好存在 npz 裡（已進版控），所以這支在沒有 torch、
沒有語料本體的機器上也跑得動——跟 `closeup_eval.py` 一樣。

與 B2（`closeup_baseline.py`）**只差特徵**：分類器（`fit_logreg`）、標準化、折、評估域全部沿用，
所以兩邊的數字可以直接比。

用法：
    python scripts/closeup_probe.py run --out preds_probe.json [--features data/closeup_features_resnet18_wtb.npz]
    python scripts/closeup_eval.py eval --predictions preds_probe.json --split folds
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import closeup_baseline as B  # noqa: E402  純 numpy，不會把 torch 拉進來

ROOT = Path(__file__).resolve().parents[1]
FEATURES = ROOT / "data" / "closeup_features_resnet18_wtb.npz"


class ProbeError(Exception):
    pass


def load_features(path: Path) -> tuple[dict[str, np.ndarray], dict]:
    z = np.load(path, allow_pickle=False)
    ids = [str(i) for i in z["ids"]]
    X = z["X"].astype(np.float64)
    meta = json.loads(str(z["meta"]))
    if X.shape[0] != len(ids) or X.shape[1] != meta.get("dim"):
        raise ProbeError(f"特徵檔形狀 {X.shape} 與 meta 不符")
    return {i: X[k] for k, i in enumerate(ids)}, meta


def probe(feat: dict[str, np.ndarray], truth: dict[str, list[str]], folds: dict[str, int],
          ids: list[str]) -> dict[str, list[str]]:
    """每一折用其餘四折訓練、只預測這一折——直接沿用 B2 的 run_folds。"""
    missing = [i for i in ids if i not in feat]
    if missing:
        raise ProbeError(f"{len(missing)} 張評估域影像沒有特徵（例如 {missing[:5]}）——特徵檔要涵蓋整個域")
    classes = sorted({c for i in ids for c in truth[i]})
    return B.run_folds(feat, truth, classes, folds, ids)


def out_of_domain(feat: dict[str, np.ndarray], truth: dict[str, list[str]], in_ids: list[str],
                  ood_ids: list[str]) -> dict:
    """同一組權重丟進取像不合格的影像：§8.3 說的「分布外崩掉」在這裡先看一眼（與 B2 同一套）。"""
    classes = sorted({c for i in in_ids for c in truth[i]})
    Xtr, Xo = B.standardise(np.stack([feat[i] for i in in_ids]), np.stack([feat[i] for i in ood_ids]))
    per = {}
    for c in classes:
        y = np.array([1.0 if c in truth[i] else 0.0 for i in in_ids])
        if y.sum() == 0:
            continue
        w = B.fit_logreg(Xtr, y)
        p = 1.0 / (1.0 + np.exp(-np.clip(Xo @ w, -30, 30)))
        per[c] = dict(predicted=int((p >= 0.5).sum()),
                      truth_here=sum(1 for i in ood_ids if c in truth[i]),
                      tp=sum(1 for i, pi in zip(ood_ids, p) if pi >= 0.5 and c in truth[i]))
    return dict(n_out_of_domain=len(ood_ids), per_class=per)


def cmd_run(args: argparse.Namespace) -> int:
    feat, meta = load_features(Path(args.features))
    truth_doc = json.loads(B.TRUTH.read_text(encoding="utf-8"))
    truth = truth_doc["labels"]
    folds = json.loads(B.GROUPS.read_text(encoding="utf-8"))["folds"]
    intake = json.loads(B.INTAKE.read_text(encoding="utf-8"))["labels"]

    ids_all = sorted(truth, key=int)
    in_ids = [i for i in ids_all if intake.get(i) == "P" and i in folds]
    ids = in_ids if args.domain == "intake_P" else [i for i in ids_all if i in folds]

    pred = probe(feat, truth, folds, ids)
    doc = dict(
        model=f"凍結 ImageNet ResNet18 特徵（{meta['dim']} 維）+ 邏輯迴歸（純 numpy，與 B2 同一個）／域={args.domain}",
        note=f"特徵來自 {Path(args.features).name}（{meta['weights']}，權重 sha256[:16]={meta['weight_sha256_16']}，"
             f"{meta['input_px']} px）。分類器、標準化、群感知 5 折與 B2 完全相同，只差特徵。"
             "**這不是規格 §8.3 的重訓**——沒有反向傳播，是線性探針。",
        split="folds", predictions=pred)
    Path(args.out).write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")

    ood_ids = [i for i in ids_all if intake.get(i) != "P" and i in feat]
    if args.domain == "intake_P" and ood_ids:
        Path(args.out).with_suffix(".ood.json").write_text(
            json.dumps(out_of_domain(feat, truth, ids, ood_ids), ensure_ascii=False, indent=1) + "\n",
            encoding="utf-8")
    print(json.dumps(dict(images=len(ids), out=args.out, out_of_domain=len(ood_ids)), ensure_ascii=False))
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Mode B 線性探針（不需要 torch）")
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--features", default=str(FEATURES))
    r.add_argument("--out", required=True)
    r.add_argument("--domain", default="intake_P", choices=("intake_P", "all"))
    r.set_defaults(func=cmd_run)
    args = ap.parse_args(argv)
    try:
        return args.func(args)
    except ProbeError as e:
        print(f"探針拒跑：{e}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
