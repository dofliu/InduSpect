#!/usr/bin/env python3
"""Mode B 的切分群組：把語料分成「不可拆到不同子集」的群，並量官方切分的洩漏。

規格 §6 第 1 條要求**按葉片切不按照片切**，但這份語料（figshare multiclass WTB）沒有
`blade_id` 也沒有 `flight_id`，B0 報告 §5.2 已經指出這一點。這支腳本補的就是那個缺口：
用影像重疊把同一次拍攝的照片連起來，連通分量就是「不可分開」的單位。

做法兩階段：
1. 全域描述子（4×4 空間格的 Lab 均值與標準差）取每張的前 K 個候選鄰居——只是縮小搜尋範圍。
2. ORB + RANSAC 相似變換，**內點數**是唯一的判定量。內點夠多代表兩張看到同一片實體表面。

四條不可退化的約定：

1. **群是「不可分開」不是「同一支葉片」。** 欄位叫 `split_group` 不叫 `blade_id`——
   像素重疊證明得了「同一次拍攝」，證明不了「同一支葉片」（也可能是同一台機的不同葉片）。
2. **寧可多合併不可漏合併。** 門檻取在穩定區的**低端**：漏掉一條連結會無聲洩漏並讓指標虛高，
   多合併只是少一點可切的資料，看得見也算得出來。
3. **這是下界。** 同一支葉片但畫面完全不重疊的兩張連不起來（除非有第三張把它們串上）。
   所以「群感知切分」是必要條件不是充分條件，B1 不可以把它當成洩漏已經解決。
4. **語料自己的 `train_val_test_split.txt` 不可用。** 它是 `random.shuffle` 按照片切，
   實測 test 有 63% 的影像在 train 裡有近重複。任何在它上面得到的準確率都是虛高的。

用法：
    python scripts/closeup_blade_groups.py build <語料根目錄> [--threshold 12] [--sweep]
    python scripts/closeup_blade_groups.py report            # 由已產出的 JSON 排成 Markdown
"""

from __future__ import annotations

import argparse
import collections
import csv
import json
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GROUPS = ROOT / "data" / "closeup_blade_groups_wtb.json"

VERSION = "b1-2026-09-14"
N_IMAGES = 1065
DEFAULT_THRESHOLD = 12      # 內點數；由下面的 sweep 與目視驗證定出來的
DEFAULT_K = 15              # 每張取幾個候選鄰居
WORK = 512                  # ORB 的工作尺度
SWEEP_THRESHOLDS = (8, 10, 12, 15, 20, 25, 30, 40)
TARGETS = (("train", 0.70), ("val", 0.15), ("test", 0.15))


# --- 純函式：分群、洩漏、切分（這些是被測的部分） -------------------------

def group_by_threshold(pairs: list[dict], n: int, threshold: int) -> dict[int, int]:
    """驗證過的配對做連通分量。回傳 影像 → 群代表。"""
    par = list(range(n))

    def find(x: int) -> int:
        while par[x] != x:
            par[x] = par[par[x]]
            x = par[x]
        return x

    for p in pairs:
        if p["inliers"] >= threshold:
            a, b = find(p["a"]), find(p["b"])
            if a != b:
                par[a] = b
    return {i: find(i) for i in range(n)}


def group_members(gid: dict[int, int]) -> dict[int, list[int]]:
    out: dict[int, list[int]] = collections.defaultdict(list)
    for i, r in sorted(gid.items()):
        out[r].append(i)
    return dict(out)


def leakage(gid: dict[int, int], split: dict[int, str], pairs: list[dict],
            threshold: int) -> dict:
    """一個切分洩漏多少：非 train 的影像裡，同群有 train 影像的比例。"""
    members = group_members(gid)
    out: dict = {}
    for sub in ("test", "val"):
        total = [i for i in split if split[i] == sub]
        bad = [i for i in total if any(split.get(j) == "train" for j in members[gid[i]] if j != i)]
        out[sub] = dict(with_train_near_duplicate=len(bad), total=len(total),
                        pct=round(100.0 * len(bad) / max(1, len(total)), 1))
    out["cross_train_test_pairs"] = sum(
        1 for p in pairs
        if p["inliers"] >= threshold and {split.get(p["a"]), split.get(p["b"])} == {"train", "test"})
    return out


def propose_split(gid: dict[int, int], targets=TARGETS) -> dict[int, str]:
    """群感知切分：整群一起走。大群先放，放進「離目標最遠」的子集。

    確定性（大小相同時用群代表排序），所以同一份群組檔永遠得到同一個切分。
    """
    members = group_members(gid)
    n = sum(len(v) for v in members.values())
    quota = {name: frac * n for name, frac in targets}
    have = {name: 0 for name, _ in targets}
    assign: dict[int, str] = {}
    for rep in sorted(members, key=lambda r: (-len(members[r]), r)):
        name = max(quota, key=lambda k: quota[k] - have[k])
        for i in members[rep]:
            assign[i] = name
        have[name] += len(members[rep])
    return assign


def propose_folds(gid: dict[int, int], classes: dict[int, list[str]], k: int = 5) -> dict[int, int]:
    """群感知 K 折：整群一起走，並讓稀有類別盡量平均散開。

    為什麼是 K 折不是單一切分：整群一起走之後，單一切分的 test 只剩 9 張 thunderstrike、
    15 張 craze，低於規格 §6 第 3 條的「每類少於 30 張不報 P/R/F1」。K 折讓每張影像
    在某一折當過一次 test，逐類的測試張數回到全語料的數量，那條規則才執行得下去。
    """
    members = group_members(gid)
    all_classes = sorted({c for v in classes.values() for c in v})
    target = {c: sum(1 for i in classes if c in classes[i]) / k for c in all_classes}
    have: list[collections.Counter] = [collections.Counter() for _ in range(k)]
    sizes = [0] * k
    assign: dict[int, int] = {}
    for rep in sorted(members, key=lambda r: (-len(members[r]), r)):
        g_cls = collections.Counter(c for i in members[rep] for c in classes.get(i, []))

        def cost(f: int) -> tuple[float, int, int]:
            worst = max(((have[f][c] + g_cls[c]) / target[c] for c in all_classes if target[c]),
                        default=0.0)
            return (round(worst, 6), sizes[f], f)

        f = min(range(k), key=cost)
        for i in members[rep]:
            assign[i] = f
        have[f].update(g_cls)
        sizes[f] += len(members[rep])
    return assign


def sweep(pairs: list[dict], n: int, thresholds=SWEEP_THRESHOLDS) -> list[dict]:
    """門檻掃描。低門檻會串連成一團（假邊），高門檻開始漏掉真的配對——中間的平台才是結構。"""
    rows = []
    for t in thresholds:
        gid = group_by_threshold(pairs, n, t)
        members = group_members(gid)
        sizes = [len(v) for v in members.values()]
        rows.append(dict(threshold=t, groups=len(members), largest=max(sizes),
                         in_multi=sum(s for s in sizes if s > 1),
                         singletons=sum(1 for s in sizes if s == 1),
                         edges=sum(1 for p in pairs if p["inliers"] >= t)))
    return rows


# --- 影像端：描述子與幾何驗證（需要語料與 OpenCV） ------------------------

def verify_pairs(dataset: Path, n: int, k: int) -> list[dict]:
    import cv2
    import numpy as np

    grey, feats = {}, {}
    for i in range(n):
        img = cv2.imread(str(dataset / "JPEGImages" / f"{i}.jpg"))
        if img is None:
            continue
        grey[i] = cv2.cvtColor(cv2.resize(img, (WORK, WORK), interpolation=cv2.INTER_AREA),
                               cv2.COLOR_BGR2GRAY)
        lab = cv2.cvtColor(cv2.resize(img, (128, 128), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2LAB)
        cells = []
        for r in range(4):
            for c in range(4):
                blk = lab[r * 32:(r + 1) * 32, c * 32:(c + 1) * 32].reshape(-1, 3)
                cells += [blk.mean(axis=0), blk.std(axis=0)]
        feats[i] = np.concatenate(cells).astype(np.float32)

    ids = sorted(grey)
    F = np.stack([feats[i] for i in ids])
    F = (F - F.mean(0)) / (F.std(0) + 1e-6)
    d2 = ((F[:, None, :] - F[None, :, :]) ** 2).sum(-1)
    np.fill_diagonal(d2, np.inf)
    nbr = np.argsort(d2, axis=1)[:, :k]

    orb = cv2.ORB_create(nfeatures=800)
    kpdes = {i: orb.detectAndCompute(grey[i], None) for i in ids}
    bf = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True)

    pairs, seen = [], set()
    for a_idx, i in enumerate(ids):
        for b_idx in nbr[a_idx]:
            j = ids[b_idx]
            key = (min(i, j), max(i, j))
            if key in seen:
                continue
            seen.add(key)
            (kp1, des1), (kp2, des2) = kpdes[i], kpdes[j]
            if des1 is None or des2 is None or len(kp1) < 10 or len(kp2) < 10:
                continue
            m = bf.match(des1, des2)
            if len(m) < 8:
                continue
            src = np.float32([kp1[x.queryIdx].pt for x in m]).reshape(-1, 1, 2)
            dst = np.float32([kp2[x.trainIdx].pt for x in m]).reshape(-1, 1, 2)
            _, inl = cv2.estimateAffinePartial2D(src, dst, method=cv2.RANSAC,
                                                 ransacReprojThreshold=4.0)
            n_in = int(inl.sum()) if inl is not None else 0
            if n_in >= min(SWEEP_THRESHOLDS):     # 低於掃描下限的對留著也沒用
                pairs.append(dict(a=key[0], b=key[1], matches=len(m), inliers=n_in,
                                  ratio=round(n_in / len(m), 4)))
    return sorted(pairs, key=lambda p: (p["a"], p["b"]))


def read_official_split(dataset: Path) -> dict[int, str]:
    p = dataset / "train_val_test_split.txt"
    return {int(r["ImageID"].removesuffix(".jpg")): r["Subset"] for r in csv.DictReader(p.open())}


def read_classes(dataset: Path, n: int) -> dict[int, list[str]]:
    out = {}
    for i in range(n):
        p = dataset / "Annotations" / f"{i}.xml"
        out[i] = sorted({o.find("name").text for o in ET.parse(p).getroot().findall("object")}) \
            if p.exists() else []
    return out


# --- 指令 -----------------------------------------------------------------

def cmd_build(args: argparse.Namespace) -> int:
    ds = Path(args.dataset)
    pairs = verify_pairs(ds, args.n, args.k)
    gid = group_by_threshold(pairs, args.n, args.threshold)
    members = group_members(gid)
    official = read_official_split(ds)
    classes = read_classes(ds, args.n)
    proposed = propose_split(gid)
    folds = propose_folds(gid, classes, args.folds)
    fold_class_counts = {}
    for f in range(args.folds):
        cc = collections.Counter(c for i, ff in folds.items() if ff == f for c in classes[i])
        fold_class_counts[str(f)] = dict(size=sum(1 for ff in folds.values() if ff == f), **cc)

    # 群代表重新編號成 0..G-1，讓檔案讀起來是人看得懂的
    order = {rep: k for k, rep in enumerate(sorted(members, key=lambda r: (-len(members[r]), r)))}
    groups = {str(i): order[gid[i]] for i in range(args.n)}
    sizes = collections.Counter(order[r] for r in gid.values())

    same_class = sum(1 for v in members.values()
                     if len(v) > 1 and len({tuple(classes[i]) for i in v}) == 1)
    n_multi = sum(1 for v in members.values() if len(v) > 1)

    doc = dict(
        version=VERSION,
        source="Multiclass Dataset for Intelligent Detection of Wind Turbine Blade Defects Using "
               "Drone Imagery, figshare 10.6084/m9.figshare.30210175.v1, CC BY 4.0",
        note="`split_group` 是「不可拆到不同子集」的單位，**不是** blade_id——像素重疊證明得了同一次拍攝，"
             "證明不了同一支葉片。這是下界：畫面完全不重疊的同葉片照片連不起來。切分一律用這個檔，"
             "不要用語料附的 train_val_test_split.txt（見 leakage_official_split）。",
        method=dict(
            stage1="4×4 空間格的 Lab 均值與標準差，標準化後取前 K 個候選鄰居（只縮小搜尋範圍）",
            stage2="ORB(800) + BFMatcher(crossCheck) + estimateAffinePartial2D RANSAC，內點數為判定量",
            k=args.k, work_scale=WORK, ransac_reproj_px=4.0),
        threshold=dict(
            inliers=args.threshold,
            chosen_because="掃描顯示 12–40 之間群結構穩定（最大群 25→19），"
                           "低於 12 會因假邊串連失控（thr=8 時 889 張黏成一群）。"
                           "取穩定區低端：漏合併會無聲洩漏，多合併只是少一點可切的資料。",
            sweep=sweep(pairs, args.n)),
        counts=dict(images=args.n, groups=len(members), largest=max(sizes.values()),
                    multi_image_groups=n_multi,
                    images_in_multi_image_groups=sum(s for s in sizes.values() if s > 1),
                    singletons=sum(1 for s in sizes.values() if s == 1),
                    verified_pairs=sum(1 for p in pairs if p["inliers"] >= args.threshold),
                    multi_image_groups_with_one_class=same_class),
        leakage_official_split=leakage(gid, official, pairs, args.threshold),
        proposed_split_note="群整群一起走的 70/15/15。確定性：同一份群組檔永遠得到同一個切分。"
                            "**但這個切分的 test 撐不起 §6 第 3 條**（thunderstrike 只剩個位數），"
                            "報逐類指標請改用下面的 K 折。",
        proposed_split_counts=dict(collections.Counter(proposed.values())),
        folds_note=f"群感知 {args.folds} 折（整群一起走，稀有類別盡量散開）。每張影像在某一折當過一次 "
                   "test，逐類的測試張數因此回到全語料的數量，§6 第 3 條（每類 ≥ 30 才報 P/R/F1）才執行得下去。",
        folds_class_counts=fold_class_counts,
        groups=groups,
        proposed_split={str(i): proposed[i] for i in range(args.n)},
        folds={str(i): folds[i] for i in range(args.n)},
    )
    out = Path(args.out)
    out.write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(json.dumps({k: v for k, v in doc.items()
                      if k in ("counts", "leakage_official_split", "proposed_split_counts",
                               "folds_class_counts")},
                     ensure_ascii=False, indent=1))
    return 0


def render_markdown(doc: dict) -> str:
    c, lk = doc["counts"], doc["leakage_official_split"]
    lines = ["| 門檻（內點數） | 邊 | 群數 | 最大群 | 在多張群裡的影像 | 孤立 |", "|---|---|---|---|---|---|"]
    for r in doc["threshold"]["sweep"]:
        mark = " ←採用" if r["threshold"] == doc["threshold"]["inliers"] else ""
        lines.append(f"| **{r['threshold']}**{mark} | {r['edges']} | {r['groups']} | {r['largest']} | "
                     f"{r['in_multi']} | {r['singletons']} |")
    lines += ["", f"採用門檻 {doc['threshold']['inliers']}：{c['groups']} 群、最大 {c['largest']} 張、"
                  f"{c['images_in_multi_image_groups']}/{c['images']} 張落在多張群裡"
                  f"（{100*c['images_in_multi_image_groups']/c['images']:.0f}%）。", "",
              "| 語料附的官方切分 | 洩漏 |", "|---|---|",
              f"| test 影像在 train 有近重複 | **{lk['test']['with_train_near_duplicate']}/"
              f"{lk['test']['total']} = {lk['test']['pct']}%** |",
              f"| val 影像在 train 有近重複 | {lk['val']['with_train_near_duplicate']}/"
              f"{lk['val']['total']} = {lk['val']['pct']}% |",
              f"| 跨 train/test 的已驗證近重複對 | {lk['cross_train_test_pairs']} |"]
    return "\n".join(lines)


def cmd_report(args: argparse.Namespace) -> int:
    print(render_markdown(json.loads(Path(args.groups).read_text(encoding="utf-8"))))
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Mode B 切分群組")
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("dataset")
    b.add_argument("--out", default=str(GROUPS))
    b.add_argument("--threshold", type=int, default=DEFAULT_THRESHOLD)
    b.add_argument("--k", type=int, default=DEFAULT_K)
    b.add_argument("--n", type=int, default=N_IMAGES)
    b.add_argument("--folds", type=int, default=5)
    b.set_defaults(func=cmd_build)
    r = sub.add_parser("report")
    r.add_argument("--groups", default=str(GROUPS))
    r.set_defaults(func=cmd_report)
    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
