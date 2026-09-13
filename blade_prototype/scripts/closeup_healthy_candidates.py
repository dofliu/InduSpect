#!/usr/bin/env python3
"""從 Multiclass WTB 語料挖「健康候選」小圖，補 Mode B 一張健康照都沒有的缺口。

語料（figshare 10.6084/m9.figshare.30210175.v1，CC BY 4.0）1065 張每張都至少有一個缺陷框，
但**框外的區域**是兩位獨立標註者都沒有標的。這不等於「確認乾淨」——標註者只框他們要框的，
沒框的地方可能有沒被注意的缺陷。所以這支腳本產出的是**候選**，全部標 `unreviewed`，
要人看過才能升成 `healthy`（分類表判定順序第 7 條）。

做法：
1. 只用通過 §1.2 取像判定的影像（`data/closeup_intake_wtb.json` 的 `P`）。
2. 取兩位標註者的框**聯集**，往外擴 `--margin` px（缺陷邊緣模糊，框常畫小）。
3. 在影像上鋪 `--tile` × `--tile` 的網格，凡與擴框有交集的格子一律不要。
4. 每格記 HSV 平均與一個粗略的背景猜測（天空／植被／葉片樣），讓人先篩掉明顯不是葉片的。
   **這個猜測不是標籤**，只是排序用。

輸出 manifest + 一張隨機抽樣的接觸印樣（看一眼就知道挖出來的東西長什麼樣）。
影像本體不進版控。

用法：
    python scripts/closeup_healthy_candidates.py <語料根目錄> <輸出目錄> [--tile 256] [--margin 48]
"""

from __future__ import annotations

import argparse
import json
import random
import xml.etree.ElementTree as ET
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
INTAKE = ROOT / "data" / "closeup_intake_wtb.json"
NS = ROOT / "data" / "closeup_normal_structures_wtb.json"


def parse_boxes(xml_path: Path) -> list[tuple[str, tuple[int, int, int, int]]]:
    if not xml_path.exists():
        return []
    root = ET.parse(xml_path).getroot()
    out = []
    for o in root.findall("object"):
        bb = o.find("bndbox")
        box = tuple(int(float(bb.find(k).text)) for k in ("xmin", "ymin", "xmax", "ymax"))
        out.append((o.find("name").text, box))
    return out


def bg_guess(tile_bgr: np.ndarray) -> tuple[str, list[float]]:
    """粗略猜這格是什麼。只是排序用，不是標籤。"""
    hsv = cv2.cvtColor(tile_bgr, cv2.COLOR_BGR2HSV)
    h, s, v = (float(x) for x in hsv.reshape(-1, 3).mean(axis=0))
    gray_std = float(cv2.cvtColor(tile_bgr, cv2.COLOR_BGR2GRAY).std())
    # 幾乎沒有紋理的格子不是可用的表面：過曝的天空／白牆、前處理的平塗灰塊都落在這裡。
    # 第一版沒有這條，抽 64 格 blade_like 目視約四成是這種東西。
    if gray_std < 4.0:
        return "flat_or_blank", [h, s, v]
    if s > 60 and 90 <= h <= 130:
        return "sky_like", [h, s, v]
    if s > 50 and 35 <= h <= 85:
        return "vegetation_like", [h, s, v]
    if s > 80 and (h < 12 or h > 165):
        return "red_marking_like", [h, s, v]
    if v < 60:
        return "dark", [h, s, v]
    if s < 45 and 120 < v < 245:
        return "blade_like", [h, s, v]
    return "other", [h, s, v]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("dataset", help="語料根目錄（含 Annotations/ annotation_second_person/ JPEGImages/）")
    ap.add_argument("out", help="輸出目錄")
    ap.add_argument("--tile", type=int, default=256)
    ap.add_argument("--margin", type=int, default=48)
    ap.add_argument("--sheet-n", type=int, default=64, help="接觸印樣抽幾格")
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()

    ds = Path(args.dataset)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    intake = json.loads(INTAKE.read_text(encoding="utf-8"))["labels"]
    ns = json.loads(NS.read_text(encoding="utf-8"))["labels"] if NS.exists() else {}
    passing = sorted(int(k) for k, v in intake.items() if v == "P")

    tiles: list[dict] = []
    per_image = {}
    for i in passing:
        img_path = ds / "JPEGImages" / f"{i}.jpg"
        img = cv2.imread(str(img_path))
        if img is None:
            continue
        H, W = img.shape[:2]
        boxes = parse_boxes(ds / "Annotations" / f"{i}.xml") + parse_boxes(ds / "annotation_second_person" / f"{i}.xml")
        blocked = np.zeros((H, W), np.uint8)
        for _, (x1, y1, x2, y2) in boxes:
            cv2.rectangle(blocked, (max(0, x1 - args.margin), max(0, y1 - args.margin)),
                          (min(W - 1, x2 + args.margin), min(H - 1, y2 + args.margin)), 255, -1)
        dist = cv2.distanceTransform(255 - blocked, cv2.DIST_L2, 5) if blocked.any() else None
        n_here = 0
        for y in range(0, H - args.tile + 1, args.tile):
            for x in range(0, W - args.tile + 1, args.tile):
                if blocked[y:y + args.tile, x:x + args.tile].any():
                    continue
                tile = img[y:y + args.tile, x:x + args.tile]
                guess, hsv = bg_guess(tile)
                d = float(dist[y:y + args.tile, x:x + args.tile].min()) if dist is not None else float("inf")
                tiles.append(dict(
                    image=f"{i}.jpg", x=x, y=y, w=args.tile, h=args.tile,
                    min_dist_to_dilated_box_px=round(d, 1) if d != float("inf") else None,
                    both_annotators_clear=True, bg_guess=guess,
                    hsv_mean=[round(v, 1) for v in hsv],
                    image_artifact_tags=ns.get(str(i), None),
                    human_status="unreviewed", annotator=None,
                ))
                n_here += 1
        per_image[i] = n_here

    # --- 摘要 ---
    from collections import Counter
    by_guess = Counter(t["bg_guess"] for t in tiles)
    summary = dict(
        source="Multiclass Dataset for Intelligent Detection of Wind Turbine Blade Defects Using Drone Imagery, "
               "figshare 10.6084/m9.figshare.30210175.v1, CC BY 4.0",
        note="全部為候選（unreviewed）。兩位標註者都沒框 ≠ 確認乾淨；升成 healthy 要人看過（分類表判定順序第 7 條）。",
        tile=args.tile, margin=args.margin,
        images_considered=len(passing), images_with_any_tile=sum(1 for v in per_image.values() if v),
        n_tiles=len(tiles), by_bg_guess=dict(by_guess.most_common()),
        blade_like_tiles=by_guess.get("blade_like", 0),
        blade_like_from_images_without_artifact_tags=sum(
            1 for t in tiles if t["bg_guess"] == "blade_like" and not (t["image_artifact_tags"] or "")),
    )
    json.dump(dict(summary=summary, tiles=tiles), open(out / "healthy_candidates.json", "w", encoding="utf-8"),
              indent=1, ensure_ascii=False)

    # --- 接觸印樣：只抽 blade_like，人看一眼就知道挖到什麼 ---
    rng = random.Random(args.seed)
    pool = [t for t in tiles if t["bg_guess"] == "blade_like"]
    pick = rng.sample(pool, min(args.sheet_n, len(pool)))
    cols = 8
    side = 200
    rows = (len(pick) + cols - 1) // cols
    sheet = np.full((rows * (side + 20), cols * side, 3), 25, np.uint8)
    for k, t in enumerate(pick):
        img = cv2.imread(str(ds / "JPEGImages" / t["image"]))
        tile = cv2.resize(img[t["y"]:t["y"] + t["h"], t["x"]:t["x"] + t["w"]], (side, side), interpolation=cv2.INTER_AREA)
        r, c = divmod(k, cols)
        y0 = r * (side + 20) + 20
        sheet[y0:y0 + side, c * side:(c + 1) * side] = tile
        cv2.putText(sheet, f"{t['image'][:-4]}@{t['x']},{t['y']}", (c * side + 3, y0 - 5),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.42, (0, 255, 255), 1, cv2.LINE_AA)
    cv2.imwrite(str(out / "healthy_candidates_sheet.jpg"), sheet, [cv2.IMWRITE_JPEG_QUALITY, 82])

    print(json.dumps(summary, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
