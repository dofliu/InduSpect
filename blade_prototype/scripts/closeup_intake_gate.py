#!/usr/bin/env python3
"""Mode B 取像閘門（§1.2）程式化：兩層、一個輸出檔、一份誠實的數字。

第一層（幾何，`blade_proto/intake.py`）：整張照片丟進 Mode A，**放行就是整機照 → 硬拒收**。
第二層（外觀探針）：凍結 ResNet18 特徵（`data/closeup_features_resnet18_wtb.npz`）+ B2 同一個
numpy 邏輯迴歸，一對多判 P／W／T（N 只有 2 張，併進「非近身」），群感知 5 折。**它學的是
1,065 張單一標註者的取景標記**，輸出的是「像不像近身照」加一個拒收理由（W：整機入鏡；
T：葉片太細），不是量出來的弦向占比——所以它是**建議性判定**，量不到 §1.2 的那個 1/3。

為什麼不直接量前景占比：實測 Mode A 的分割在近身照上量不出來（局部天空模型把填滿畫面的
葉片當背景），單一門檻平衡準確率 0.5–0.7，見 `CLOSEUP_INTAKE_GATE.md` §2。

用法：
    python scripts/closeup_intake_gate.py run --dataset <語料根目錄> --out data/closeup_intake_gate_wtb.json
    python scripts/closeup_intake_gate.py run --out ...            # 沒有語料本體：只跑探針、幾何欄位留空
    python scripts/closeup_intake_gate.py report [--gate data/closeup_intake_gate_wtb.json]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import closeup_baseline as B  # noqa: E402
from closeup_probe import load_features  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
FEATURES = ROOT / "data" / "closeup_features_resnet18_wtb.npz"
GATE = ROOT / "data" / "closeup_intake_gate_wtb.json"
VERSION = "a3-2026-09-16"

# 探針的類別：N（非葉片）只有 2 張，任何學習器都學不到；併進 T 當「不是近身照的其他原因」。
PROBE_CLASSES = ("P", "W", "T")
MERGE = {"N": "T"}


class IntakeGateError(Exception):
    pass


# ---------------------------------------------------------------- 探針


def probe_classes(intake: dict[str, str], folds: dict[str, int],
                  feat: dict[str, np.ndarray]) -> dict[str, dict]:
    """每一折用其餘四折訓練、只預測這一折。回傳每張的三類分數與 argmax。

    與 B2／線性探針只差兩件事：類別是取景碼不是缺陷類；輸出用 argmax 不用 0.5 門檻
    （取景碼互斥，一張照片只能有一個）。"""
    ids = sorted((i for i in intake if i in folds and i in feat), key=int)
    truth = {i: MERGE.get(intake[i], intake[i]) for i in ids}
    out: dict[str, dict] = {}
    for f in sorted({folds[i] for i in ids}):
        tr = [i for i in ids if folds[i] != f]
        te = [i for i in ids if folds[i] == f]
        Xtr, Xte = B.standardise(np.stack([feat[i] for i in tr]), np.stack([feat[i] for i in te]))
        scores = np.zeros((len(te), len(PROBE_CLASSES)))
        for k, c in enumerate(PROBE_CLASSES):
            y = np.array([1.0 if truth[i] == c else 0.0 for i in tr])
            if y.sum() == 0:
                scores[:, k] = -np.inf
                continue
            w = B.fit_logreg(Xtr, y)
            scores[:, k] = np.clip(Xte @ w, -30, 30)
        for i, row in zip(te, scores):
            p = 1.0 / (1.0 + np.exp(-row))
            out[i] = {
                "truth": truth[i],
                "probe": PROBE_CLASSES[int(np.argmax(row))],
                "p_P": round(float(p[0]), 4),
                "p_W": round(float(p[1]), 4),
                "p_T": round(float(p[2]), 4),
                "fold": int(folds[i]),
            }
    return out


# ---------------------------------------------------------------- 幾何


def geometry_for(dataset: Path, ids: list[str]) -> dict[str, dict]:
    import cv2  # 只有帶語料跑時才需要
    from blade_proto.intake import intake_geometry

    out: dict[str, dict] = {}
    for n, i in enumerate(ids):
        path = dataset / "JPEGImages" / f"{i}.jpg"
        img = cv2.imread(str(path))
        if img is None:
            raise IntakeGateError(f"讀不到 {path}")
        out[i] = intake_geometry(img).to_dict()
        if (n + 1) % 100 == 0:
            print(f"  幾何 {n + 1}/{len(ids)}", file=sys.stderr)
    return out


# ---------------------------------------------------------------- 合併判定與統計


def decide(probe: dict, geom: dict | None) -> tuple[str, str]:
    """最終判定與理由。幾何硬規則優先：Mode A 放行的一定是整機照。"""
    if geom and geom.get("reject_as_whole_turbine"):
        return "W", "Mode A 拍攝閘門以正視規則放行：這是一張可用的整機照，請走 Mode A"
    c = probe["probe"]
    if c == "P":
        return "P", "外觀探針判為近身照（建議性；未量弦向占比）"
    if c == "W":
        return "W", "外觀探針判為整機入鏡（輪轂／塔架可見），Mode B 拒收"
    return "T", "外觀探針判為葉片太細或非葉片（展向遠視／機艙特寫），請靠近到弦向 ≥ 1/3 畫面"


def confusion(rows: dict[str, dict], key: str) -> dict[str, dict[str, int]]:
    m: dict[str, dict[str, int]] = {c: {d: 0 for d in PROBE_CLASSES} for c in PROBE_CLASSES}
    for r in rows.values():
        m[r["truth_merged"]][r[key]] += 1
    return m


def balanced_accuracy_p(rows: dict[str, dict], key: str) -> float:
    """P 對非 P 的平衡準確率——閘門真正在做的二元決定。"""
    tp = sum(1 for r in rows.values() if r["truth_merged"] == "P" and r[key] == "P")
    p = sum(1 for r in rows.values() if r["truth_merged"] == "P")
    tn = sum(1 for r in rows.values() if r["truth_merged"] != "P" and r[key] != "P")
    n = sum(1 for r in rows.values() if r["truth_merged"] != "P")
    return round(0.5 * (tp / p + tn / n), 4) if p and n else float("nan")


def summarise(rows: dict[str, dict], has_geometry: bool) -> dict:
    per_class = {}
    for c in PROBE_CLASSES:
        tot = [r for r in rows.values() if r["truth_merged"] == c]
        hit = [r for r in tot if r["decision"] == c]
        per_class[c] = {"n": len(tot), "recall": round(len(hit) / len(tot), 4) if tot else None}
    s = {
        "n": len(rows),
        "per_class_recall": per_class,
        "confusion_probe": confusion(rows, "probe"),
        "confusion_final": confusion(rows, "decision"),
        "balanced_accuracy_P_probe": balanced_accuracy_p(rows, "probe"),
        "balanced_accuracy_P_final": balanced_accuracy_p(rows, "decision"),
        "false_accept": sorted((i for i, r in rows.items() if r["truth_merged"] != "P" and r["decision"] == "P"), key=int),
        "false_reject": sorted((i for i, r in rows.items() if r["truth_merged"] == "P" and r["decision"] != "P"), key=int),
    }
    if has_geometry:
        mode_a_ok = sorted((i for i, r in rows.items() if r["geometry"]["mode_a_ok"]), key=int)
        s["mode_a_ok"] = mode_a_ok
        s["mode_a_ok_by_truth"] = {c: sum(1 for i in mode_a_ok if rows[i]["truth_merged"] == c) for c in PROBE_CLASSES}
        s["mode_a_ok_by_view"] = {v: sum(1 for i in mode_a_ok if rows[i]["geometry"]["mode_a_view"] == v) for v in ("front", "side")}
        # Mode A 放行但真值是 P：Mode A 閘門在近身照上的誤放行，逐張留下當回歸案例（實測全是側視規則）
        s["mode_a_leaks_into_P"] = [i for i in mode_a_ok if rows[i]["truth_merged"] == "P"]
        s["mode_a_leaks_into_P_by_view"] = {v: sum(1 for i in s["mode_a_leaks_into_P"] if rows[i]["geometry"]["mode_a_view"] == v) for v in ("front", "side")}
        s["hard_rejects"] = sorted((i for i, r in rows.items() if r["geometry"]["reject_as_whole_turbine"]), key=int)
        s["geometry_errors"] = sum(1 for r in rows.values() if r["geometry"].get("error"))
        s["mask_frac_quantiles_by_truth"] = {
            c: [round(float(q), 4) for q in np.percentile(
                [r["geometry"]["mask_frac"] for r in rows.values() if r["truth_merged"] == c], [10, 50, 90])]
            for c in PROBE_CLASSES
        }
    return s


def build(dataset: Path | None, features: Path = FEATURES) -> dict:
    intake_doc = json.loads(B.INTAKE.read_text(encoding="utf-8"))
    intake = intake_doc["labels"]
    folds = json.loads(B.GROUPS.read_text(encoding="utf-8"))["folds"]
    feat, meta = load_features(features)
    probe = probe_classes(intake, folds, feat)
    missing = sorted(set(intake) - set(probe), key=int)
    if missing:
        raise IntakeGateError(f"{len(missing)} 張沒有探針結果（例如 {missing[:5]}）")
    ids = sorted(probe, key=int)
    geom = geometry_for(dataset, ids) if dataset else None
    rows: dict[str, dict] = {}
    for i in ids:
        g = geom[i] if geom else None
        decision, reason = decide(probe[i], g)
        rows[i] = {
            "truth": intake[i],
            "truth_merged": MERGE.get(intake[i], intake[i]),
            **{k: v for k, v in probe[i].items() if k != "truth"},
            "decision": decision,
            "reason": reason,
        }
        if g is not None:
            rows[i]["geometry"] = g
    return {
        "version": VERSION,
        "source": intake_doc["source"],
        "note": (
            "Mode B 取像閘門（§1.2）在全語料 1,065 張上的逐張結果。真值是 closeup_intake_wtb.json 的"
            "單一標註者取景碼（N 併入 T）。probe = 凍結 ResNet18 特徵 + numpy 邏輯迴歸一對多、群感知 5 折、"
            "argmax；geometry = 整張丟進 Mode A（分割→結構定位→拍攝閘門），**正視**放行才是硬拒收——側視放行在近身照上"
            "會誤觸（8/839 張 P 被兩段垂直葉片 + 假塔架放行），交給探針。"
            "**探針是建議性判定**：它學的是取景標記不是量弦向占比，§1.2 的 1/3 這個數字它量不到。"
        ),
        "classes": {"P": "近身合格", "W": "整機入鏡（Mode A 放行者為硬規則）", "T": "葉片太細／非葉片（含 N）"},
        "features": meta,
        "geometry_included": geom is not None,
        "summary": summarise(rows, geom is not None),
        "images": rows,
    }


# ---------------------------------------------------------------- 報告


def render_markdown(doc: dict) -> str:
    s = doc["summary"]
    L = [f"# Mode B 取像閘門逐張結果（{doc['version']}）", "",
         f"n = {s['n']}；P 對非 P 平衡準確率：探針 {s['balanced_accuracy_P_probe']}、加幾何硬規則 {s['balanced_accuracy_P_final']}", "",
         "| 真值 | n | recall（最終） |", "|---|---:|---:|"]
    for c, v in s["per_class_recall"].items():
        L.append(f"| {c} | {v['n']} | {v['recall']} |")
    L += ["", "混淆（列 = 真值、欄 = 最終判定）", "", "| | P | W | T |", "|---|---:|---:|---:|"]
    for c in PROBE_CLASSES:
        row = s["confusion_final"][c]
        L.append(f"| {c} | {row['P']} | {row['W']} | {row['T']} |")
    L += ["", f"誤放行（非 P 判成 P）{len(s['false_accept'])} 張；誤拒收（P 判成非 P）{len(s['false_reject'])} 張"]
    if doc["geometry_included"]:
        L += ["", f"Mode A 放行 {len(s['mode_a_ok'])} 張：依真值 {s['mode_a_ok_by_truth']}、依視角 {s['mode_a_ok_by_view']}；"
              f"其中真值是 P 的（Mode A 漏進近身照）：{s['mode_a_leaks_into_P']}，依視角 {s['mode_a_leaks_into_P_by_view']}",
              f"硬拒收（正視放行）{len(s['hard_rejects'])} 張：{s['hard_rejects']}",
              f"分割前景占比 10/50/90 百分位：{s['mask_frac_quantiles_by_truth']}",
              f"Mode A 例外 {s['geometry_errors']} 張"]
    return "\n".join(L) + "\n"


def cmd_run(args: argparse.Namespace) -> int:
    doc = build(Path(args.dataset) if args.dataset else None, Path(args.features))
    Path(args.out).write_text(json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf-8")
    print(render_markdown(doc))
    return 0


def cmd_report(args: argparse.Namespace) -> int:
    print(render_markdown(json.loads(Path(args.gate).read_text(encoding="utf-8"))))
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--dataset", default=None)
    r.add_argument("--features", default=str(FEATURES))
    r.add_argument("--out", required=True)
    r.set_defaults(fn=cmd_run)
    p = sub.add_parser("report")
    p.add_argument("--gate", default=str(GATE))
    p.set_defaults(fn=cmd_report)
    args = ap.parse_args(argv)
    try:
        return args.fn(args)
    except IntakeGateError as exc:
        print(f"錯誤：{exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
