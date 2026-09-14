#!/usr/bin/env python3
"""Mode B 正常結構普查用的接觸印樣產生器。

`CLOSEUP_HEALTHY_SET.md` 的 Pass 2 在 4×4、每格 460 px 的印樣上標**影像級存在**
（畫面裡有沒有分類表 §2 的正常結構、有沒有標註／前處理痕跡）。第一版只做了 192 張抽樣，
而評估協定的誤報歸因需要**逐張都有**才有鑑別力——656 張有誤報的影像裡 523 張落在「未普查」。

這支腳本把那個版面固定下來（第一版是臨時做的，沒有進版控，續做會對不上規格）：
每格 460 px、4×4、格上標影像編號，並輸出 `layout.json` 讓標記可以按位置對回編號。

**解析度就是它的限制**：460 px 的格子裡避雷接點可能只有幾個像素。第一版「L 與 v 各 0 張」
是「印樣上沒看到」不是「不存在」，續做沿用同一個版面，這個限制照樣成立、照樣要寫在報告裡。

用法：
    python scripts/closeup_survey_sheets.py <語料根目錄> <輸出目錄> [--only-unsurveyed] [--intake P]
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INTAKE = ROOT / "data" / "closeup_intake_wtb.json"
NS = ROOT / "data" / "closeup_normal_structures_wtb.json"

CELL = 460          # 每格邊長；第一版就是這個值，續做不可以改（改了標記不可比）
COLS = ROWS = 4
LABEL_H = 24


def select_ids(intake_code: str, only_unsurveyed: bool) -> list[int]:
    intake = json.loads(INTAKE.read_text(encoding="utf-8"))["labels"]
    ids = [int(k) for k, v in intake.items() if v == intake_code]
    if only_unsurveyed and NS.exists():
        done = set(json.loads(NS.read_text(encoding="utf-8"))["labels"])
        ids = [i for i in ids if str(i) not in done]
    return sorted(ids)


def make_sheets(dataset: Path, out: Path, ids: list[int]) -> list[dict]:
    import cv2
    import numpy as np

    out.mkdir(parents=True, exist_ok=True)
    per = COLS * ROWS
    layout = []
    for s in range((len(ids) + per - 1) // per):
        chunk = ids[s * per:(s + 1) * per]
        canvas = np.full((ROWS * (CELL + LABEL_H), COLS * CELL, 3), 20, np.uint8)
        for k, i in enumerate(chunk):
            img = cv2.imread(str(dataset / "JPEGImages" / f"{i}.jpg"))
            if img is None:
                continue
            r, c = divmod(k, COLS)
            y0 = r * (CELL + LABEL_H) + LABEL_H
            canvas[y0:y0 + CELL, c * CELL:(c + 1) * CELL] = cv2.resize(
                img, (CELL, CELL), interpolation=cv2.INTER_AREA)
            cv2.putText(canvas, f"{i}", (c * CELL + 6, y0 - 6),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 255), 2, cv2.LINE_AA)
        name = f"survey{s:02d}.jpg"
        cv2.imwrite(str(out / name), canvas, [cv2.IMWRITE_JPEG_QUALITY, 88])
        layout.append(dict(sheet=name, ids=chunk))
    (out / "layout.json").write_text(
        json.dumps(dict(cell_px=CELL, grid=[ROWS, COLS], sheets=layout), ensure_ascii=False, indent=1),
        encoding="utf-8")
    return layout


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("dataset")
    ap.add_argument("out")
    ap.add_argument("--intake", default="P", help="只收這個取像判定碼的影像（預設 P = §1.2 合格）")
    ap.add_argument("--only-unsurveyed", action="store_true", help="跳過已經普查過的")
    args = ap.parse_args(argv)
    ids = select_ids(args.intake, args.only_unsurveyed)
    layout = make_sheets(Path(args.dataset), Path(args.out), ids)
    print(json.dumps(dict(images=len(ids), sheets=len(layout), out=args.out), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
