#!/usr/bin/env python3
"""Mode B 評估協定的實作（B1）：一把固定的尺，讓不同模型的數字彼此可比。

規格 §6 把評估協定寫成四條不可退化的規則。這支腳本把那四條變成**程式會執行的東西**，
而不是報告裡的一段話：

1. **按葉片切不按照片切。** 切分一律來自 `closeup_blade_groups_wtb.json`（`folds`）。
   預測檔要自己宣告用的是哪一種切分；宣告與 `--split` 不符直接拒跑。
   允許評估按照片切的結果（那是拿來示範洩漏的），但報告會**蓋上洩漏印記**並附洩漏數字。
2. **主指標是逐類 recall，不是 accuracy。** 逐類表排第一，整體 accuracy 只在最後一節、
   標明「附註，不得當標題」。
3. **每類少於 30 張不報 P/R/F1。** 少於 30 的類別只列張數，數字位置寫「不報」。
   （Zhang 等人在 2 張上報 1.00/1.00，我們不重複這個做法。）
4. **誤報要分開報。** 分成「誤報在有正常結構的影像上」「在普查過、沒有正常結構的影像上」
   「未普查」三格——**不把未普查併進乾淨那一格**。健康照在這份語料是 0 張，
   §6 第 4 條的健康照誤報率**明講量不到**，不印 0。

另外兩件事也在這裡執行：低光照子集單獨報（§6 補充），以及**機制類彙總只在對照明確時才報**——
分類表的 `dataset_class_map` 顯示六類裡只有三類（crack／surface_injure／thunderstrike）對得上
單一機制類，其餘三類跨機制類，硬彙總只會產生一個不能跟基線論文比的數字。

用法：
    python scripts/closeup_eval.py truth <語料根目錄>          # 產出真值檔（只要做一次，已進版控）
    python scripts/closeup_eval.py subsets <語料根目錄>        # 低光照等子集旗標（同上）
    python scripts/closeup_eval.py template                    # 印出預測檔格式
    python scripts/closeup_eval.py nn-baseline <語料根目錄> --split folds --out preds.json
    python scripts/closeup_eval.py eval --predictions preds.json [--markdown report.md]
"""

from __future__ import annotations

import argparse
import collections
import csv
import json
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TRUTH = ROOT / "data" / "closeup_truth_wtb.json"
GROUPS = ROOT / "data" / "closeup_blade_groups_wtb.json"
SUBSETS = ROOT / "data" / "closeup_subsets_wtb.json"
NS = ROOT / "data" / "closeup_normal_structures_wtb.json"
INTAKE = ROOT / "data" / "closeup_intake_wtb.json"
TAXONOMY = ROOT / "data" / "closeup_taxonomy.json"

VERSION = "b1-2026-09-14"
MIN_PER_CLASS = 30          # §6 第 3 條
LOW_LIGHT_PERCENTILE = 20   # 語料自身亮度分布的第 20 百分位以下算低光照
ARTIFACT_CODES = "ath"      # 正常結構普查裡的痕跡碼：灰色塗抹／時間戳／人手工具


class EvalError(Exception):
    """拒跑。訊息要讓人知道下一步做什麼。"""


# --- 真值與子集（需要語料，各做一次）---------------------------------------

def cmd_truth(args: argparse.Namespace) -> int:
    ds = Path(args.dataset)
    labels, per_annotator = {}, {}
    for i in range(args.n):
        sets = []
        for sub in ("Annotations", "annotation_second_person"):
            p = ds / sub / f"{i}.xml"
            sets.append(sorted({o.find("name").text for o in ET.parse(p).getroot().findall("object")})
                        if p.exists() else [])
        # 真值取兩位標註者的聯集：漏掉一個真缺陷比多算一個嚴重（§6 的失效模式是裂縫被判成健康）
        labels[str(i)] = sorted(set(sets[0]) | set(sets[1]))
        per_annotator[str(i)] = dict(a=sets[0], b=sets[1])
    doc = dict(
        version=VERSION,
        source="Multiclass Dataset for Intelligent Detection of Wind Turbine Blade Defects Using "
               "Drone Imagery, figshare 10.6084/m9.figshare.30210175.v1, CC BY 4.0",
        note="影像級類別真值，由語料的兩位標註者 VOC 標註彙整。`labels` 取兩人聯集"
             "（漏檢比誤報嚴重）；`per_annotator` 保留各自的，因為兩人一致率 94.0% 是"
             "任何模型在這份語料上的可量測上限，分歧的影像上的分數要當雜訊看。"
             "**沒有健康照**：每張至少一個缺陷框。",
        classes=sorted({c for v in labels.values() for c in v}),
        labels=labels,
        per_annotator=per_annotator,
    )
    Path(args.out).write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    counts = collections.Counter(c for v in labels.values() for c in v)
    print(json.dumps(dict(images=len(labels), classes=dict(counts.most_common()),
                          images_with_no_class=sum(1 for v in labels.values() if not v)),
                     ensure_ascii=False, indent=1))
    return 0


def cmd_subsets(args: argparse.Namespace) -> int:
    import cv2
    import numpy as np

    ds = Path(args.dataset)
    ns = json.loads(NS.read_text(encoding="utf-8"))["labels"] if NS.exists() else {}
    v_mean = {}
    for i in range(args.n):
        img = cv2.imread(str(ds / "JPEGImages" / f"{i}.jpg"))
        if img is None:
            continue
        v_mean[str(i)] = float(cv2.cvtColor(img, cv2.COLOR_BGR2HSV)[:, :, 2].mean())
    cut = float(np.percentile(list(v_mean.values()), LOW_LIGHT_PERCENTILE))
    doc = dict(
        version=VERSION,
        note=f"子集旗標。`low_light` 的定義是**可重現的量**不是人的印象：HSV 的 V 通道全圖均值 "
             f"低於語料自身分布的第 {LOW_LIGHT_PERCENTILE} 百分位（= {cut:.1f}／255）。"
             f"`annotation_artifact` 來自 192 張正常結構普查的痕跡碼（{ARTIFACT_CODES}），"
             f"**只有那 192 張知道**，其餘是 null（未普查），不可以當成「沒有痕跡」。",
        low_light_cut=round(cut, 2),
        low_light={k: (v < cut) for k, v in v_mean.items()},
        brightness_v_mean={k: round(v, 2) for k, v in v_mean.items()},
        annotation_artifact={k: (any(ch in ns[k] for ch in ARTIFACT_CODES) if k in ns else None)
                             for k in v_mean},
    )
    Path(args.out).write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(json.dumps(dict(low_light_cut=doc["low_light_cut"],
                          low_light=sum(1 for v in doc["low_light"].values() if v),
                          artifact_surveyed=sum(1 for v in doc["annotation_artifact"].values() if v is not None),
                          artifact_true=sum(1 for v in doc["annotation_artifact"].values() if v)),
                     ensure_ascii=False, indent=1))
    return 0


# --- 評估核心（純函式，不碰檔案）------------------------------------------

def per_class_counts(truth: dict[str, list[str]], pred: dict[str, list[str]],
                     classes: list[str], ids: list[str]) -> dict[str, dict]:
    """多標籤逐類計數。一張影像可以同時屬於多個類別，所以不是方陣混淆。"""
    out = {}
    for c in classes:
        tp = sum(1 for i in ids if c in truth[i] and c in pred.get(i, []))
        fn = sum(1 for i in ids if c in truth[i] and c not in pred.get(i, []))
        fp = sum(1 for i in ids if c not in truth[i] and c in pred.get(i, []))
        out[c] = dict(n_truth=tp + fn, tp=tp, fn=fn, fp=fp)
    return out


def rate(num: int, den: int) -> float | None:
    return None if den == 0 else num / den


def metrics_with_floor(counts: dict[str, dict], floor: int = MIN_PER_CLASS) -> dict[str, dict]:
    """§6 第 3 條：少於 floor 張的類別不給 P/R/F1，位置留白並註明原因。"""
    out = {}
    for c, k in counts.items():
        enough = k["n_truth"] >= floor
        recall = rate(k["tp"], k["tp"] + k["fn"])
        precision = rate(k["tp"], k["tp"] + k["fp"])
        f1 = None
        if recall is not None and precision is not None and (recall + precision) > 0:
            f1 = 2 * recall * precision / (recall + precision)
        out[c] = dict(**k, reportable=enough,
                      recall=recall if enough else None,
                      precision=precision if enough else None,
                      f1=f1 if enough else None,
                      suppressed_reason=None if enough else f"n = {k['n_truth']} < {floor}")
    return out


def cooccurrence(truth: dict[str, list[str]], pred: dict[str, list[str]],
                 classes: list[str], ids: list[str]) -> dict[str, dict[str, int]]:
    """真實類 × 預測類的共現（多標籤下取代方陣混淆矩陣）。"""
    m = {t: {p: 0 for p in classes} for t in classes}
    for i in ids:
        for t in truth[i]:
            for p in pred.get(i, []):
                m[t][p] += 1
    return m


def false_positive_breakdown(truth: dict[str, list[str]], pred: dict[str, list[str]],
                             ids: list[str], artifact: dict[str, bool | None],
                             normal_structure: dict[str, str]) -> dict:
    """§6 第 4 條：誤報要分開報，而且**未普查不可以併進乾淨那一格**。"""
    buckets = dict(on_normal_structure=0, on_surveyed_without_normal_structure=0, not_surveyed=0)
    for i in ids:
        wrong = [c for c in pred.get(i, []) if c not in truth[i]]
        if not wrong:
            continue
        codes = normal_structure.get(i)
        if codes is None:
            buckets["not_surveyed"] += 1
        elif any(ch not in ARTIFACT_CODES + "T" for ch in codes):
            buckets["on_normal_structure"] += 1
        else:
            buckets["on_surveyed_without_normal_structure"] += 1
    healthy = [i for i in ids if not truth[i]]
    return dict(images_with_any_false_positive=sum(buckets.values()), buckets=buckets,
                healthy_images=len(healthy),
                healthy_false_positive_rate=None if not healthy else
                sum(1 for i in healthy if pred.get(i)) / len(healthy),
                note=("健康照 0 張——§6 第 4 條要的「誤報在乾淨表面上」在這份語料量不到。"
                      "不印 0，因為 0 會被讀成「沒有誤報」。") if not healthy else None)


def subset_metrics(truth: dict[str, list[str]], pred: dict[str, list[str]], classes: list[str],
                   ids: list[str], flags: dict[str, bool | None], name: str) -> dict:
    """子集切出來各算一次。null（未判定）自成一格，不併進任何一邊。"""
    out = {}
    for label, sel in (("yes", [i for i in ids if flags.get(i) is True]),
                       ("no", [i for i in ids if flags.get(i) is False]),
                       ("unknown", [i for i in ids if flags.get(i) is None])):
        if not sel:
            continue
        out[label] = dict(n_images=len(sel),
                          classes=metrics_with_floor(per_class_counts(truth, pred, classes, sel)))
    return dict(subset=name, groups=out)


def split_is_group_respecting(assign: dict[str, str | int], gid: dict[str, int]) -> tuple[bool, list[int]]:
    by_group: dict[int, set] = collections.defaultdict(set)
    for i, part in assign.items():
        by_group[gid[i]].add(part)
    bad = sorted(g for g, parts in by_group.items() if len(parts) > 1)
    return (not bad), bad


def unambiguous_mechanism_map(taxonomy: dict, dataset_key: str = "multiclass_wtb") -> dict[str, str]:
    """只收「語料類別 → 單一機制類」對得上的；跨機制類的不收。

    分類表明寫 craze／hide_craze／corrosion 各自跨兩個機制類，硬彙總會產生一個
    不能跟基線論文比的數字。
    """
    out = {}
    for row in taxonomy["dataset_class_map"][dataset_key]["classes"]:
        mechanisms = {o.split("/", 1)[0] for o in row["ours"]}
        if len(mechanisms) == 1:
            out[row["their"]] = mechanisms.pop()
    return out


def evaluate(truth_doc: dict, pred_doc: dict, groups_doc: dict, subsets_doc: dict,
             ns_doc: dict, taxonomy: dict, split: str, intake_doc: dict | None = None,
             domain: str = "intake_P") -> dict:
    truth = truth_doc["labels"]
    classes = truth_doc["classes"]
    preds_raw = pred_doc["predictions"]
    pred = {k: (sorted(v) if isinstance(v, list) else sorted(v)) for k, v in preds_raw.items()}

    unknown_ids = sorted(set(pred) - set(truth))
    if unknown_ids:
        raise EvalError(f"預測檔有真值裡沒有的影像 id：{unknown_ids[:5]}（共 {len(unknown_ids)}）")
    unknown_cls = sorted({c for v in pred.values() for c in v} - set(classes))
    if unknown_cls:
        raise EvalError(f"預測檔有未知類別：{unknown_cls}。允許的是 {classes}")
    declared = pred_doc.get("split")
    if declared != split:
        raise EvalError(f"預測檔宣告的切分是「{declared}」，這次跑的是「{split}」。"
                        "同一份預測不可以換一種切分重算——那會把訓練過的影像當成測試。")

    # 評估域：Mode B 的輸入定義是 §1.2 取像合格的影像。在整機照上評估沒有意義
    # （那是 Mode A 的輸入），而且它們也沒有被正常結構普查覆蓋。
    intake = (intake_doc or {}).get("labels", {})
    if domain == "intake_P":
        if not intake:
            raise EvalError("--domain intake_P 需要 data/closeup_intake_wtb.json")
        in_domain = {k for k, v in intake.items() if v == "P"}
        domain_note = f"取像合格 P（{len(in_domain)} 張）——Mode B 的輸入定義（§1.2）"
    elif domain == "all":
        in_domain = set(truth)
        domain_note = f"全語料（{len(in_domain)} 張，含整機照）——只用來對照，不是 Mode B 的輸入域"
    else:
        raise EvalError(f"不認得的評估域：{domain}")

    gid = {k: v for k, v in groups_doc["groups"].items()}
    if split == "folds":
        assign = {k: v for k, v in groups_doc["folds"].items()}
        ids = sorted(truth, key=int)              # 每張都在某一折當過 test，全部匯總
        eval_note = "群感知 5 折匯總：每張影像在它當 test 的那一折被預測一次。"
    elif split == "proposed":
        assign = {k: v for k, v in groups_doc["proposed_split"].items()}
        ids = sorted((i for i in truth if assign[i] == "test"), key=int)
        eval_note = "群感知單一切分的 test。"
    elif split == "official":
        assign = pred_doc.get("official_split") or {}
        if not assign:
            raise EvalError("用 official 切分要在預測檔附 `official_split`（語料的 train_val_test_split.txt）")
        ids = sorted((i for i in truth if assign.get(i) == "test"), key=int)
        eval_note = "語料自己附的按照片切（僅供示範洩漏，不得當成有效結果）。"
    else:
        raise EvalError(f"不認得的切分：{split}")

    ids = [i for i in ids if i in in_domain]
    ok, bad_groups = split_is_group_respecting({i: assign[i] for i in assign if i in gid}, gid)
    missing = [i for i in ids if i not in pred]
    artifact = subsets_doc.get("annotation_artifact", {})
    low_light = subsets_doc.get("low_light", {})
    ns_labels = ns_doc.get("labels", {})

    counts = per_class_counts(truth, pred, classes, ids)
    per_class = metrics_with_floor(counts)
    mech_map = unambiguous_mechanism_map(taxonomy)

    # 逐折 recall 的離散度：單一折走運的話，這裡會看得出來
    per_fold_recall = {}
    if split == "folds":
        for c in classes:
            vals = []
            for f in sorted({assign[i] for i in ids}):
                sel = [i for i in ids if assign[i] == f]
                k = per_class_counts(truth, pred, [c], sel)[c]
                r = rate(k["tp"], k["tp"] + k["fn"])
                if r is not None:
                    vals.append(round(r, 4))
            if vals:
                per_fold_recall[c] = dict(min=min(vals), max=max(vals), per_fold=vals)

    exact = sum(1 for i in ids if set(pred.get(i, [])) == set(truth[i]))
    return dict(
        version=VERSION,
        model=pred_doc.get("model", "（未命名）"),
        domain=domain,
        domain_note=domain_note,
        split=split,
        split_note=eval_note,
        split_is_group_respecting=ok,
        leaking_groups=bad_groups[:10],
        leakage_warning=(None if ok else
                         "**這個切分把同一個 split_group 拆到了不同子集**，訓練與測試共享同一次拍攝的"
                         "照片。下面所有數字都是虛高的，只能當洩漏示範，不得當成模型表現。"),
        n_images_evaluated=len(ids),
        n_missing_predictions=len(missing),
        coverage_note=(f"{len(missing)} 張沒有預測，一律當成「什麼都沒預測」計入 FN。"
                       if missing else "每張都有預測。"),
        primary_metric="per_class_recall",
        per_class=per_class,
        per_fold_recall=per_fold_recall,
        cooccurrence=cooccurrence(truth, pred, classes, ids),
        false_positives=false_positive_breakdown(truth, pred, ids, artifact, ns_labels),
        subsets=[subset_metrics(truth, pred, classes, ids, low_light, "low_light"),
                 subset_metrics(truth, pred, classes, ids, artifact, "annotation_artifact")],
        mechanism_rollup=dict(
            mapped={k: v for k, v in mech_map.items()},
            unmapped=[c for c in classes if c not in mech_map],
            note="只有對照明確的類別能彙總到機制類；其餘跨機制類，硬彙總的數字不能跟基線論文比。"),
        footnote_accuracy=dict(
            exact_match=rate(exact, len(ids)),
            caveat="附註，不得當標題。整體 accuracy 會被多數類蓋過去——"
                   "基線論文 94.55% 的整體準確率底下是 structural recall 0.5。"),
        upper_bound_note=f"兩位標註者的類別一致率 94.0%（kappa 0.897）是這份語料的可量測上限，"
                         f"超過它的分數是在報雜訊。",
    )


# --- Markdown 排版 --------------------------------------------------------

def _fmt(x: float | None) -> str:
    return "—" if x is None else f"{x:.3f}"


def render_markdown(r: dict) -> str:
    L: list[str] = [f"# Mode B 評估報告：{r['model']}", ""]
    if r["leakage_warning"]:
        L += [f"> ⚠️ {r['leakage_warning']}", ""]
    L += [f"評估域：{r['domain_note']}", "",
          f"切分：`{r['split']}`——{r['split_note']}　評估 {r['n_images_evaluated']} 張。"
          f"{r['coverage_note']}", "",
          "## 1. 逐類 recall（主指標）", "",
          "| 類別 | 真值張數 | recall | precision | F1 | TP | FN | FP |", "|---|---|---|---|---|---|---|---|"]
    for c, m in sorted(r["per_class"].items(), key=lambda kv: -kv[1]["n_truth"]):
        if m["reportable"]:
            L.append(f"| `{c}` | {m['n_truth']} | **{_fmt(m['recall'])}** | {_fmt(m['precision'])} | "
                     f"{_fmt(m['f1'])} | {m['tp']} | {m['fn']} | {m['fp']} |")
        else:
            L.append(f"| `{c}` | {m['n_truth']} | 不報 | 不報 | 不報 | {m['tp']} | {m['fn']} | {m['fp']} |")
    L += ["", f"「不報」= §6 第 3 條：少於 {MIN_PER_CLASS} 張不給 P/R/F1，只列張數。", ""]

    if r["per_fold_recall"]:
        L += ["逐折 recall 的範圍（單一折走運會在這裡露出來）：", "",
              "| 類別 | 最低 | 最高 | 逐折 |", "|---|---|---|---|"]
        for c, v in sorted(r["per_fold_recall"].items()):
            L.append(f"| `{c}` | {v['min']:.3f} | {v['max']:.3f} | {', '.join(f'{x:.2f}' for x in v['per_fold'])} |")
        L.append("")

    L += ["## 2. 真實類 × 預測類共現", "", "多標籤，不是方陣混淆矩陣：一張影像可以同時屬於多類。", ""]
    classes = sorted(r["cooccurrence"])
    L += ["| 真實＼預測 | " + " | ".join(f"`{c}`" for c in classes) + " |",
          "|---" * (len(classes) + 1) + "|"]
    for t in classes:
        L.append(f"| `{t}` | " + " | ".join(str(r["cooccurrence"][t][p]) for p in classes) + " |")

    fp = r["false_positives"]
    L += ["", "## 3. 誤報分項（§6 第 4 條）", "",
          f"有誤報的影像 {fp['images_with_any_false_positive']} 張：", "",
          "| 落在哪裡 | 張數 |", "|---|---|",
          f"| 有正常結構的影像上 | {fp['buckets']['on_normal_structure']} |",
          f"| 普查過、沒有正常結構的影像上 | {fp['buckets']['on_surveyed_without_normal_structure']} |",
          f"| **未普查**（不可併進上一格） | {fp['buckets']['not_surveyed']} |", ""]
    if fp["note"]:
        L += [fp["note"], ""]
    else:
        L += [f"健康照 {fp['healthy_images']} 張，其中 "
              f"{_fmt(fp['healthy_false_positive_rate'])} 有誤報。", ""]

    for k, sub in enumerate(r["subsets"], start=1):
        L += [f"## 4.{k} 子集：`{sub['subset']}`", "", "| 子集 | 張數 | " +
              " | ".join(f"`{c}` recall" for c in classes) + " |", "|---" * (len(classes) + 2) + "|"]
        for label, g in sub["groups"].items():
            cells = []
            for c in classes:
                m = g["classes"][c]
                cells.append(_fmt(m["recall"]) if m["reportable"] else f"不報({m['n_truth']})")
            L.append(f"| {label} | {g['n_images']} | " + " | ".join(cells) + " |")
        L.append("")

    mr = r["mechanism_rollup"]
    L += ["## 5. 機制類彙總的可行性", "",
          f"對得上單一機制類：{', '.join(f'`{k}`→{v}' for k, v in mr['mapped'].items()) or '（無）'}", "",
          f"跨機制類、**不彙總**：{', '.join(f'`{c}`' for c in mr['unmapped']) or '（無）'}", "",
          mr["note"], "",
          "## 6. 附註", "",
          f"- 完全命中率（exact match）{_fmt(r['footnote_accuracy']['exact_match'])}。"
          f"{r['footnote_accuracy']['caveat']}",
          f"- {r['upper_bound_note']}"]
    return "\n".join(L)


# --- 1-NN 基線（示範洩漏用）------------------------------------------------

def cmd_nn_baseline(args: argparse.Namespace) -> int:
    """最近鄰「模型」：把最像的訓練影像的類別抄過來。

    它不是要當一個好模型，是要量**記憶有多好用**。同一支葉片的照片若橫跨訓練與測試，
    抄鄰居就會拿到高分——這正是按照片切會獎勵的行為。
    """
    import cv2
    import numpy as np

    ds = Path(args.dataset)
    truth = json.loads(TRUTH.read_text(encoding="utf-8"))["labels"]
    groups = json.loads(GROUPS.read_text(encoding="utf-8"))
    feats = {}
    for i in range(args.n):
        img = cv2.imread(str(ds / "JPEGImages" / f"{i}.jpg"))
        if img is None:
            continue
        lab = cv2.cvtColor(cv2.resize(img, (128, 128), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2LAB)
        cells = []
        for r in range(4):
            for c in range(4):
                blk = lab[r * 32:(r + 1) * 32, c * 32:(c + 1) * 32].reshape(-1, 3)
                cells += [blk.mean(axis=0), blk.std(axis=0)]
        feats[str(i)] = np.concatenate(cells).astype(np.float32)

    ids = sorted(feats, key=int)
    F = np.stack([feats[i] for i in ids])
    F = (F - F.mean(0)) / (F.std(0) + 1e-6)
    d2 = ((F[:, None, :] - F[None, :, :]) ** 2).sum(-1)
    np.fill_diagonal(d2, np.inf)
    pos = {i: k for k, i in enumerate(ids)}

    official = {}
    if args.split == "official":
        official = {r["ImageID"].removesuffix(".jpg"): r["Subset"]
                    for r in csv.DictReader((ds / "train_val_test_split.txt").open())}
        train_of = {i: [j for j in ids if official.get(j) == "train"] for i in ids}
        targets = [i for i in ids if official.get(i) == "test"]
    else:
        folds = groups["folds"]
        train_of = {i: [j for j in ids if folds[j] != folds[i]] for i in ids}
        targets = list(ids)

    predictions = {}
    for i in targets:
        pool = train_of[i]
        j = min(pool, key=lambda t: d2[pos[i], pos[t]])
        predictions[i] = truth[j]
    doc = dict(model=f"1-NN（Lab 格描述子，抄最近訓練影像的類別）／split={args.split}",
               note="不是一個好模型，是用來量「記憶有多好用」。同一支葉片橫跨訓練與測試時，"
                    "抄鄰居就會拿到高分——按照片切獎勵的正是這個。",
               split=args.split, predictions=predictions)
    if official:
        doc["official_split"] = official
    Path(args.out).write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(json.dumps(dict(out=args.out, split=args.split, predicted=len(predictions)), ensure_ascii=False))
    return 0


def cmd_leakage_demo(args: argparse.Namespace) -> int:
    """把「洩漏讓分數虛高多少」量成數字。

    只變一個變數：同一組 test（語料官方的 161 張）、同一個 1-NN、同一組描述子，
    差別只在訓練池裡**有沒有同一個 split_group 的照片**。差多少就是洩漏值多少分。
    """
    import cv2
    import numpy as np

    ds = Path(args.dataset)
    truth_doc = json.loads(TRUTH.read_text(encoding="utf-8"))
    truth, classes = truth_doc["labels"], truth_doc["classes"]
    groups = json.loads(GROUPS.read_text(encoding="utf-8"))["groups"]
    official = {r["ImageID"].removesuffix(".jpg"): r["Subset"]
                for r in csv.DictReader((ds / "train_val_test_split.txt").open())}

    feats = {}
    for i in range(args.n):
        img = cv2.imread(str(ds / "JPEGImages" / f"{i}.jpg"))
        if img is None:
            continue
        lab = cv2.cvtColor(cv2.resize(img, (128, 128), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2LAB)
        cells = []
        for r in range(4):
            for c in range(4):
                blk = lab[r * 32:(r + 1) * 32, c * 32:(c + 1) * 32].reshape(-1, 3)
                cells += [blk.mean(axis=0), blk.std(axis=0)]
        feats[str(i)] = np.concatenate(cells).astype(np.float32)

    ids = sorted(feats, key=int)
    F = np.stack([feats[i] for i in ids])
    F = (F - F.mean(0)) / (F.std(0) + 1e-6)
    d2 = ((F[:, None, :] - F[None, :, :]) ** 2).sum(-1)
    np.fill_diagonal(d2, np.inf)
    pos = {i: k for k, i in enumerate(ids)}

    test = [i for i in ids if official.get(i) == "test"]
    train = [i for i in ids if official.get(i) == "train"]
    variants = {}
    for name, allow_same_group in (("with_leak", True), ("without_leak", False)):
        pred = {}
        for i in test:
            pool = [j for j in train if allow_same_group or groups[j] != groups[i]]
            pred[i] = truth[min(pool, key=lambda t: d2[pos[i], pos[t]])]
        variants[name] = metrics_with_floor(per_class_counts(truth, pred, classes, test))

    rows, deltas = [], []
    for c in sorted(classes, key=lambda c: -variants["with_leak"][c]["n_truth"]):
        a, b = variants["with_leak"][c], variants["without_leak"][c]
        if a["reportable"]:
            rows.append(dict(cls=c, n=a["n_truth"], with_leak=round(a["recall"], 3),
                             without_leak=round(b["recall"], 3),
                             delta=round(a["recall"] - b["recall"], 3)))
            deltas.append(a["recall"] - b["recall"])
        else:
            rows.append(dict(cls=c, n=a["n_truth"], with_leak=None, without_leak=None, delta=None))
    same_group_available = sum(1 for i in test if any(groups[j] == groups[i] for j in train))
    out = dict(
        test_images=len(test), train_images=len(train),
        test_images_with_same_group_in_train=same_group_available,
        note="同一組 test、同一個 1-NN，只差訓練池裡有沒有同群照片。差值就是洩漏值多少分。",
        per_class=rows,
        mean_recall_delta=round(sum(deltas) / len(deltas), 3) if deltas else None)
    if args.out:
        Path(args.out).write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(json.dumps(out, ensure_ascii=False, indent=1))
    return 0


# --- 指令 -----------------------------------------------------------------

TEMPLATE = {
    "model": "你的模型名稱／版本",
    "note": "選填：怎麼跑的、用了哪些知識庫",
    "split": "folds",
    "predictions": {"0": ["craze"], "1": [], "2": ["surface_injure", "corrosion"]},
}


def cmd_template(args: argparse.Namespace) -> int:
    print(json.dumps(TEMPLATE, ensure_ascii=False, indent=1))
    print("\n# 說明：predictions 的鍵是影像編號（字串，0–1064），值是預測到的類別清單（可為空）。")
    print("# split 必填，且要跟跑評估時的 --split 一致：folds（群感知 5 折，正式用這個）／")
    print("# proposed（群感知單一切分）／official（語料自己的按照片切，只用來示範洩漏，要附 official_split）。")
    return 0


def cmd_eval(args: argparse.Namespace) -> int:
    pred_doc = json.loads(Path(args.predictions).read_text(encoding="utf-8"))
    result = evaluate(
        json.loads(Path(args.truth).read_text(encoding="utf-8")),
        pred_doc,
        json.loads(Path(args.groups).read_text(encoding="utf-8")),
        json.loads(Path(args.subsets).read_text(encoding="utf-8")) if Path(args.subsets).exists() else {},
        json.loads(NS.read_text(encoding="utf-8")) if NS.exists() else {},
        json.loads(Path(args.taxonomy).read_text(encoding="utf-8")),
        split=args.split or pred_doc.get("split"),
        intake_doc=json.loads(INTAKE.read_text(encoding="utf-8")) if INTAKE.exists() else None,
        domain=args.domain,
    )
    md = render_markdown(result)
    if args.markdown:
        Path(args.markdown).write_text(md + "\n", encoding="utf-8")
    if args.json:
        Path(args.json).write_text(json.dumps(result, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(md)
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Mode B 評估協定（B1）")
    sub = ap.add_subparsers(dest="cmd", required=True)

    t = sub.add_parser("truth", help="由語料標註產出影像級真值檔")
    t.add_argument("dataset")
    t.add_argument("--out", default=str(TRUTH))
    t.add_argument("--n", type=int, default=1065)
    t.set_defaults(func=cmd_truth)

    s = sub.add_parser("subsets", help="低光照等子集旗標")
    s.add_argument("dataset")
    s.add_argument("--out", default=str(SUBSETS))
    s.add_argument("--n", type=int, default=1065)
    s.set_defaults(func=cmd_subsets)

    tp = sub.add_parser("template", help="印出預測檔格式")
    tp.set_defaults(func=cmd_template)

    nn = sub.add_parser("nn-baseline", help="1-NN 基線（示範洩漏）")
    nn.add_argument("dataset")
    nn.add_argument("--split", default="folds", choices=("folds", "official"))
    nn.add_argument("--out", required=True)
    nn.add_argument("--n", type=int, default=1065)
    nn.set_defaults(func=cmd_nn_baseline)

    ld = sub.add_parser("leakage-demo", help="量洩漏讓分數虛高多少（配對實驗）")
    ld.add_argument("dataset")
    ld.add_argument("--out", default=None)
    ld.add_argument("--n", type=int, default=1065)
    ld.set_defaults(func=cmd_leakage_demo)

    e = sub.add_parser("eval", help="跑評估")
    e.add_argument("--predictions", required=True)
    e.add_argument("--truth", default=str(TRUTH))
    e.add_argument("--groups", default=str(GROUPS))
    e.add_argument("--subsets", default=str(SUBSETS))
    e.add_argument("--taxonomy", default=str(TAXONOMY))
    e.add_argument("--split", default=None, choices=("folds", "proposed", "official"))
    e.add_argument("--domain", default="intake_P", choices=("intake_P", "all"),
                   help="評估域。預設只評 §1.2 取像合格的影像（Mode B 的輸入定義）")
    e.add_argument("--markdown", default=None)
    e.add_argument("--json", default=None)
    e.set_defaults(func=cmd_eval)

    args = ap.parse_args(argv)
    try:
        return args.func(args)
    except EvalError as exc:
        print(f"拒跑：{exc}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
