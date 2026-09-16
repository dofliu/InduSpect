#!/usr/bin/env python3
"""凍結 ImageNet ResNet18 的 512 維特徵——**全 repo 唯一 import torch 的檔案**。

它只做一件事：把每張影像變成一個向量存起來（`data/closeup_features_resnet18_wtb.npz`）。
之後的線性探針（`closeup_probe.py`）與評估都**不需要 torch、不需要語料本體**，
跟真值／切分／子集已進版控的做法一致。

為什麼要這一步：B2 的 123 維手工特徵與 1-NN 打平（0.308 vs 0.344），一度被讀成
「語料沒訊號」。凍結特徵 + 同一個 numpy 邏輯迴歸就能推翻或坐實那個解讀——
差的只是特徵，分類器、切分、評估全部不變，所以比得出來。

決定性：eval 模式、不做增強、固定 224 px INTER_AREA、固定 ImageNet 正規化；
同一份權重檔重跑逐位元相同。權重雜湊寫進 npz 的 meta，換權重會被測試抓到。

用法：
    pip install -r requirements-cnn.txt
    python scripts/closeup_features_cnn.py <語料根目錄> [--out data/closeup_features_resnet18_wtb.npz]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT = ROOT / "data" / "closeup_features_resnet18_wtb.npz"
INPUT_PX = 224
MEAN = np.array([0.485, 0.456, 0.406], np.float32)
STD = np.array([0.229, 0.224, 0.225], np.float32)


def _preprocess(bgr: np.ndarray) -> np.ndarray:
    import cv2

    im = cv2.resize(bgr, (INPUT_PX, INPUT_PX), interpolation=cv2.INTER_AREA)[:, :, ::-1]
    im = im.astype(np.float32) / 255.0
    return ((im - MEAN) / STD).transpose(2, 0, 1).copy()


def extract(dataset: Path, ids: list[str], batch: int = 32) -> tuple[dict[str, np.ndarray], dict]:
    import cv2
    import torch
    import torchvision

    weights = torchvision.models.ResNet18_Weights.IMAGENET1K_V1
    model = torchvision.models.resnet18(weights=weights)
    model.fc = torch.nn.Identity()
    model.eval()
    torch.set_grad_enabled(False)

    # 權重雜湊：換了權重、特徵就不是同一組東西，要看得出來
    sd = model.state_dict()
    h = hashlib.sha256()
    for k in sorted(sd):
        h.update(k.encode())
        h.update(sd[k].cpu().numpy().tobytes())
    weight_sha = h.hexdigest()[:16]

    feats: dict[str, np.ndarray] = {}
    buf: list[np.ndarray] = []
    keys: list[str] = []

    def flush() -> None:
        if not buf:
            return
        v = model(torch.from_numpy(np.stack(buf))).numpy()
        for k, f in zip(keys, v):
            feats[k] = f.astype(np.float32)
        buf.clear()
        keys.clear()

    missing = []
    for i in ids:
        img = cv2.imread(str(dataset / "JPEGImages" / f"{i}.jpg"))
        if img is None:
            missing.append(i)
            continue
        buf.append(_preprocess(img))
        keys.append(i)
        if len(buf) == batch:
            flush()
    flush()

    meta = dict(
        model="torchvision resnet18",
        weights=str(weights),
        weight_sha256_16=weight_sha,
        input_px=INPUT_PX,
        dim=512,
        torch=torch.__version__,
        torchvision=torchvision.__version__,
        n=len(feats),
        missing=missing,
    )
    return feats, meta


def save(feats: dict[str, np.ndarray], meta: dict, out: Path) -> None:
    ids = sorted(feats, key=int)
    X = np.stack([feats[i] for i in ids]).astype(np.float16)  # 1065×512 → 約 1 MB，進版控
    np.savez_compressed(out, ids=np.array(ids), X=X, meta=json.dumps(meta, ensure_ascii=False))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("dataset")
    ap.add_argument("--out", default=str(DEFAULT_OUT))
    ap.add_argument("--n", type=int, default=1065, help="影像編號 0..n-1")
    args = ap.parse_args(argv)

    t0 = time.time()
    feats, meta = extract(Path(args.dataset), [str(i) for i in range(args.n)])
    meta["seconds"] = round(time.time() - t0, 1)
    save(feats, meta, Path(args.out))
    print(json.dumps(dict(out=args.out, **{k: meta[k] for k in ("n", "dim", "weight_sha256_16", "seconds")},
                          missing=len(meta["missing"])), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
