#!/usr/bin/env python3
"""健康候選格的接觸印樣：第一遍目視要看的東西，一頁 48 格。

`CLOSEUP_HEALTHY_SET.md` §4 從框外挖出 1,842 格 `blade_like` 候選，但「約 64% 真的是葉片表面」
是 64 格抽樣的推估。把它變成逐格的答案，人複核時就只要看已經排好的隊，而不是從 6,880 格開始。

**這一遍不是簽核**：產出的標記 annotator 一律 `claude-first-pass`、`human_status` 一律 `unreviewed`，
`closeup_review_tool.py` 的匯入照樣拒絕模型名。它只改變**順序與先驗**，不改變誰有權說 healthy。

格子以原尺寸（256 px）排列，不縮放——縮了就看不出紋理，也就回到 654 那個錯誤。

用法：
    python scripts/closeup_candidate_sheets.py <語料根目錄> <manifest> <輸出目錄> [--bg blade_like]
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

COLS, ROWS = 8, 6          # 一頁 48 格
LABEL_H = 22


def main(argv: list[str] | None = None) -> int:
    import cv2
    import numpy as np

    ap = argparse.ArgumentParser()
    ap.add_argument("dataset")
    ap.add_argument("manifest")
    ap.add_argument("out")
    ap.add_argument("--bg", default="blade_like")
    args = ap.parse_args(argv)

    tiles = [t for t in json.loads(Path(args.manifest).read_text(encoding="utf-8"))["tiles"]
             if t["bg_guess"] in args.bg.split(",")]
    tiles.sort(key=lambda t: (int(t["image"].removesuffix(".jpg")), t["y"], t["x"]))
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    per = COLS * ROWS
    side = tiles[0]["w"]
    layout = []
    cache: dict[str, "np.ndarray"] = {}
    for s in range((len(tiles) + per - 1) // per):
        chunk = tiles[s * per:(s + 1) * per]
        canvas = np.full((ROWS * (side + LABEL_H), COLS * side, 3), 20, np.uint8)
        for k, t in enumerate(chunk):
            if t["image"] not in cache:
                cache.clear()
                cache[t["image"]] = cv2.imread(str(Path(args.dataset) / "JPEGImages" / t["image"]))
            img = cache[t["image"]]
            if img is None:
                continue
            r, c = divmod(k, COLS)
            y0 = r * (side + LABEL_H) + LABEL_H
            canvas[y0:y0 + side, c * side:(c + 1) * side] = img[t["y"]:t["y"] + t["h"],
                                                                t["x"]:t["x"] + t["w"]]
            cv2.putText(canvas, f"{k + 1}", (c * side + 4, y0 - 5),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 2, cv2.LINE_AA)
        name = f"cand{s:02d}.jpg"
        cv2.imwrite(str(out / name), canvas, [cv2.IMWRITE_JPEG_QUALITY, 92])
        layout.append(dict(sheet=name, tiles=[dict(slot=k + 1, image=t["image"], x=t["x"], y=t["y"],
                                                   w=t["w"], h=t["h"], split_group=t.get("split_group"))
                                              for k, t in enumerate(chunk)]))
    (out / "layout.json").write_text(json.dumps(dict(grid=[ROWS, COLS], tile_px=side, sheets=layout),
                                                ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(dict(tiles=len(tiles), sheets=len(layout), out=str(out)), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
