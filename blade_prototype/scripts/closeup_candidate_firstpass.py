#!/usr/bin/env python3
"""健康候選格的第一遍目視標記：把 1,842 格從「一堆候選」變成「排好的隊」。

`CLOSEUP_HEALTHY_SET.md` §4 挖出 1,842 格 `blade_like` 候選，能說的只有「64 格抽樣裡約 64%
真的是葉片表面」。這支腳本把 `closeup_candidate_sheets.py` 產的接觸印樣逐格看過的結果收成版控檔，
於是「還差多少」與「先看哪一格」都有依據。

**這一遍不是簽核。** 三條不可退化：

1. `annotator` 一律 `claude-first-pass`、`human_status` 一律 `unreviewed`。
   這個名字正好落在 `closeup_review_tool.MODEL_ANNOTATOR` 的黑名單裡——它進不了決策檔。
2. 它只改變**順序與先驗**。`closeup_review_tool.py build --firstpass` 拿它排佇列，
   不寫任何決策；誰有權說 healthy 沒有變。
3. 身分綁像素：每格的 `item_id` 用與複核工具 `healthy` 佇列相同的雜湊算，
   候選重新產生後對不上的會在 `verify` 被點名，不會被默默沿用。

標記字母（封閉字彙，不在表內的直接拒收）：

| 碼 | 意思 |
|----|------|
| `b` | 葉片表面（這一格幾乎都是漆面，是複核要先看的） |
| `e` | 葉片與背景的邊界（含葉片，但不是純表面） |
| `n` | 不是葉片（天空／地景／器材／文字浮水印） |
| `u` | 判不了（過曝／全平／模糊／被塗抹） |

用法：
    python scripts/closeup_candidate_firstpass.py pack <layout.json> <標記目錄> [--out data/...json]
    python scripts/closeup_candidate_firstpass.py verify [--firstpass ...] [--manifest ...]
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from closeup_review_tool import MODEL_ANNOTATOR, item_id  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
FIRSTPASS = ROOT / "data" / "closeup_healthy_firstpass_wtb.json"

ANNOTATOR = "claude-first-pass"
FIRSTPASS_VERSION = "b1-2026-09-14"

VOCAB = {
    "b": "葉片表面（幾乎整格都是漆面）",
    "e": "葉片與背景的邊界（含葉片但不是純表面）",
    "n": "不是葉片（天空／地景／器材／文字浮水印）",
    "u": "判不了（過曝／全平／模糊／被塗抹）",
}

# 複核佇列的排序：最可能是乾淨葉片表面的先看。這是先驗不是結論。
PRIORITY = {"b": 0, "e": 1, "u": 2, "n": 3}

RULES = [
    "這一遍不是簽核：annotator 一律 claude-first-pass、human_status 一律 unreviewed。",
    "claude-first-pass 落在 closeup_review_tool.MODEL_ANNOTATOR 黑名單裡，匯入會整批被擋。",
    "它只改變順序與先驗；healthy 仍然只能由人在複核工具裡給。",
    "item_id 與 healthy 佇列同一套雜湊，候選重新產生後對不上的由 verify 點名。",
]


class FirstPassError(Exception):
    """標記檔本身不成立時丟出來——寧可不寫，不要寫一份對不上的。"""


def _now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def read_codes(path: Path) -> str:
    """一張印樣的標記：任意換行／空白都不算，只留字母。"""
    raw = "".join(path.read_text(encoding="utf-8").split())
    bad = sorted({c for c in raw if c not in VOCAB})
    if bad:
        raise FirstPassError(f"{path.name} 有不在字彙表裡的碼：{''.join(bad)}")
    return raw


def pack(layout: dict, labels: dict[str, str]) -> dict:
    """把每張印樣的碼串接回格子座標。數量對不上就整份拒收。"""
    tiles: list[dict] = []
    for sheet in layout["sheets"]:
        name = sheet["sheet"]
        stem = name.removesuffix(".jpg")
        key = "c" + stem.removeprefix("cand")
        if key not in labels:
            raise FirstPassError(f"{name} 沒有對應的標記檔（預期 {key}.txt）")
        codes = labels[key]
        if len(codes) != len(sheet["tiles"]):
            raise FirstPassError(
                f"{name} 的標記有 {len(codes)} 格，印樣是 {len(sheet['tiles'])} 格——對不上就不寫")
        for code, t in zip(codes, sheet["tiles"]):
            region = (t["x"], t["y"], t["w"], t["h"])
            tiles.append(dict(
                item_id=item_id("healthy", t["image"], region),
                image=t["image"], x=t["x"], y=t["y"], w=t["w"], h=t["h"],
                split_group=t.get("split_group"),
                code=code, sheet=name, slot=t["slot"],
            ))
    extra = sorted(set(labels) - {"c" + s["sheet"].removesuffix(".jpg").removeprefix("cand")
                                  for s in layout["sheets"]})
    if extra:
        raise FirstPassError(f"標記目錄有印樣裡沒有的檔：{', '.join(extra)}")

    counts = Counter(t["code"] for t in tiles)
    if not MODEL_ANNOTATOR.search(ANNOTATOR):  # 自我對帳：名字若哪天不再被擋，這份檔就不該產出
        raise FirstPassError("annotator 沒有被複核工具的模型名規則擋住——這份標記會有機會變成簽核")
    return dict(
        meta=dict(
            version=FIRSTPASS_VERSION,
            annotator=ANNOTATOR,
            human_status="unreviewed",
            generated_at=_now(),
            grid=layout.get("grid"), tile_px=layout.get("tile_px"),
            sheets=len(layout["sheets"]), n_tiles=len(tiles),
            vocabulary=VOCAB,
            counts={k: counts.get(k, 0) for k in VOCAB},
            blade_surface_fraction=round(counts.get("b", 0) / max(1, len(tiles)), 4),
            blade_present_fraction=round((counts.get("b", 0) + counts.get("e", 0)) / max(1, len(tiles)), 4),
            priority=PRIORITY,
            rules=RULES,
        ),
        tiles=tiles,
    )


def load_firstpass(path: Path = FIRSTPASS) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def prior_index(doc: dict) -> dict[str, str]:
    """item_id → 碼。複核工具拿它排序，對不上的格子沒有先驗，排在同碼最後。"""
    return {t["item_id"]: t["code"] for t in doc["tiles"]}


def verify(doc: dict, manifest: dict | None) -> dict:
    """對帳：碼合法、數量一致、身分與 healthy 佇列算得出來的一樣、涵蓋率。"""
    problems: list[str] = []
    if doc["meta"]["annotator"] != ANNOTATOR or doc["meta"]["human_status"] != "unreviewed":
        problems.append("meta 的 annotator／human_status 被改過")
    seen: set[str] = set()
    for t in doc["tiles"]:
        if t["code"] not in VOCAB:
            problems.append(f"{t['item_id']} 的碼 {t['code']} 不在字彙表")
        if item_id("healthy", t["image"], (t["x"], t["y"], t["w"], t["h"])) != t["item_id"]:
            problems.append(f"{t['item_id']} 的身分與座標對不上")
        if t["item_id"] in seen:
            problems.append(f"{t['item_id']} 重複")
        seen.add(t["item_id"])

    out = dict(n_tiles=len(doc["tiles"]), counts=doc["meta"]["counts"], problems=problems)
    if manifest is not None:
        cand = {item_id("healthy", t["image"], (t["x"], t["y"], t["w"], t["h"]))
                for t in manifest["tiles"] if t["bg_guess"] == "blade_like"}
        out["candidates"] = len(cand)
        out["covered"] = len(seen & cand)
        out["stale"] = sorted(seen - cand)[:20]
        out["unlabelled"] = len(cand - seen)
        if seen - cand:
            problems.append(f"有 {len(seen - cand)} 格對不上現在的候選（候選重新產生過）")
    return out


def cmd_pack(args: argparse.Namespace) -> int:
    layout = json.loads(Path(args.layout).read_text(encoding="utf-8"))
    label_dir = Path(args.labels)
    labels = {p.stem: read_codes(p) for p in sorted(label_dir.glob("*.txt"))}
    if not labels:
        raise FirstPassError(f"{label_dir} 沒有標記檔")
    doc = pack(layout, labels)
    Path(args.out).write_text(json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(dict(out=args.out, **{k: doc["meta"][k]
                                           for k in ("n_tiles", "counts", "blade_surface_fraction",
                                                     "blade_present_fraction")}), ensure_ascii=False))
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    doc = load_firstpass(Path(args.firstpass))
    manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8")) if args.manifest else None
    out = verify(doc, manifest)
    print(json.dumps(out, ensure_ascii=False, indent=1))
    return 1 if out["problems"] else 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Mode B 健康候選格第一遍標記（不是簽核）")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("pack", help="印樣標記 → 版控檔")
    p.add_argument("layout", help="closeup_candidate_sheets.py 產的 layout.json")
    p.add_argument("labels", help="每張印樣一個 .txt，內容是 48 個碼")
    p.add_argument("--out", default=str(FIRSTPASS))
    p.set_defaults(func=cmd_pack)

    v = sub.add_parser("verify", help="對帳：碼、身分、涵蓋率")
    v.add_argument("--firstpass", default=str(FIRSTPASS))
    v.add_argument("--manifest", default=None, help="healthy_candidates.json，比對候選是否重新產生過")
    v.set_defaults(func=cmd_verify)

    args = ap.parse_args(argv)
    try:
        return args.func(args)
    except FirstPassError as e:
        print(f"標記檔被擋下：{e}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
