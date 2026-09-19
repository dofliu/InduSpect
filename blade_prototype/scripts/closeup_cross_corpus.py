#!/usr/bin/env python3
"""Mode B 跨語料驗證（B3）：把 wtb 語料上訓好的**取像探針**（P／W／T）與**缺陷探針**丟到兩個沒看過的語料上。

到目前為止 Mode B 的每個數字都來自同一份 1,065 張的 wtb 語料（群感知 5 折）。同一份語料再怎麼切，
都量不到「換一台無人機、換一個風場、換一套標註者」會掉多少。這支腳本做的是最便宜的一種跨語料檢查：
**分類器不重訓**，wtb 上訓好就直接用，看它在別人的照片上說什麼。

兩份外部語料（都不進版控，影像與特徵留在 scratchpad）：

- **WTBs2025**（figshare 10.6084/m9.figshare.28876406，CC0）：9 類 7,544 張。Roboflow 匝出：全部重採樣成
  640×640、含增強副本、EXIF 剝掉、沒有健康照。類別與 wtb 的六類**不是同一套**，所以缺陷探針只能做
  「粗對照的命中率」（對照表在 `data/closeup_taxonomy.json` 的 `dataset_class_map.wtbs2025`），不是評估。
- **sees-innovation/windturbinedataset-cleaned**（Hugging Face，**授權未標**）：6 類 1,855 張 1024×680，
  Blade／FullTurbine／Hub／Mast／Nacelle／Van。這裡只拿它當取像探針的**乾淨負樣本**：Van 與 Nacelle 被判成
  近身葉片照就是閘門放錯人進來；只算數字、不進版控。

輸入（scratchpad）：外部語料的凍結 ResNet18 特徵（`closeup_features_cnn.extract_paths`，與 wtb 同一個函式）
與 Mode A 幾何 jsonl（`blade_proto.intake.intake_geometry`）。訓練資料全在版控裡：
`closeup_features_resnet18_wtb.npz` + `closeup_intake_wtb.json` + `closeup_truth_wtb.json`。

輸出：`data/closeup_cross_corpus.json`（逐張，不含影像）+ `CROSS_CORPUS_VALIDATION.md`（`report`）。

用法：
    python scripts/closeup_cross_corpus.py run \\
        --corpus wtbs2025=<scratch>/wtbs2025_resnet18.npz:<scratch>/wtbs2025_geometry.jsonl \\
        --corpus hf_sees=<scratch>/hf_resnet18.npz:<scratch>/hf_geometry.jsonl \\
        --out data/closeup_cross_corpus.json
    python scripts/closeup_cross_corpus.py report --results data/closeup_cross_corpus.json --out CROSS_CORPUS_VALIDATION.md
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import closeup_baseline as B  # noqa: E402  純 numpy
from closeup_intake_gate import MERGE, PROBE_CLASSES  # noqa: E402
from closeup_probe import load_features  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
FEATURES_WTB = ROOT / "data" / "closeup_features_resnet18_wtb.npz"
TAXONOMY = ROOT / "data" / "closeup_taxonomy.json"
OUT = ROOT / "data" / "closeup_cross_corpus.json"
VERSION = "b3-2026-09-19"
DEFECT_THRESHOLD = 0.5   # 與 closeup_probe.out_of_domain 相同
DOMAIN_FOLDS = 5

# 外部語料的描述與「應該被判成什麼」。expected 是**依類別名的常識**，不是逐張真值——WTBs2025 的類別
# 全是缺陷類（取像碼未知，所以 None）；HF 那份的 Blade 依定義是近身葉片、Hub／Mast 是輪轂塔架入鏡（W）、
# Nacelle 是機艙特寫（T）、Van 根本不是風機（N → T）。
CORPORA = {
    "wtbs2025": {
        "name": "WTBs2025",
        "source": "figshare 10.6084/m9.figshare.28876406（CC0 1.0）",
        "note": "9 類 7,544 張；Roboflow 匝出 640×640、含增強副本、無 EXIF、無健康照",
        "expected_intake": None,
        "defect_transfer": True,
    },
    "hf_sees": {
        "name": "sees-innovation/windturbinedataset-cleaned",
        "source": "Hugging Face（授權未標，只算數字不進版控）",
        "note": "6 類 1,855 張 1024×680，無 EXIF",
        "expected_intake": {"Blade": "P", "FullTurbine": "W", "Hub": "W", "Mast": "W", "Nacelle": "T", "Van": "T"},
        "defect_transfer": False,
    },
}


class CrossCorpusError(Exception):
    pass


# Mode A 正視放行（= 硬拒收）在外部語料上只出現個位數，每一張都人工看過（疊圖在 scratchpad）。
# 這裡記的是「為什麼會放行」，報告只印結果檔裡真的出現的那些 id；id 換了就不印，不會留下過期的話。
HARD_REJECT_REVIEW = {
    "erosion/4465": "近身照被誤判：葉片沿展向填滿畫面，葉片本體 + 它在地面上的影子被拆成三條臂、輪轂落在葉片中段——硬拒收錯了",
    "erosion/5213": "近身照被誤判：一條葉片斜跨整片農田，結構定位在葉片中段找到「輪轂」、兩端當兩片、田埕當第三片——硬拒收錯了",
    "pinholes/2019": "葉尖填滿前景、**背景還有一台完整的風機**：Mode A 定位到的是背景那台。依 §1.2 這張是近身照，硬拒收錯了；"
                     "「畫面裡有整機」≠「這是整機照」",
    "FullTurbine/1502": "無人機在輪轂高度拍的風場，最近那台三片對天空、其餘在遠處——確實是整機照，硬拒收對",
    "Blade/0407": "葉根 + 輪轂 + 機艙對天空的仰拍，葉片沒有填滿畫面——依 §1.2 屬 W，硬拒收對",
}


def reason_bucket(reason: str) -> str:
    """「三片葉尖半徑差 39%（上限 15%）：請等轉子轉開」→「三片葉尖半徑差 N%（…）」。"""
    head = reason.split("：")[0]
    head = re.sub(r"\d+(\.\d+)?", "N", head)
    return re.sub(r"（[^）]*）", "（…）", head)


def geometry_reasons(geom: dict[str, dict]) -> dict[str, dict[str, int]]:
    """每個類別的 Mode A 拒收原因分桶（同一張可有多條）。整機照語料（HF FullTurbine）靠這個看閘門為什麼拒收。"""
    out: dict[str, Counter] = defaultdict(Counter)
    for key, g in geom.items():
        cls = key.split("/")[0]
        if g.get("error"):
            out[cls]["Mode A 例外（…）"] += 1
            continue
        if not g.get("mode_a_ok"):
            for r in g.get("mode_a_reasons", []):
                out[cls][reason_bucket(r)] += 1
    return {c: dict(v.most_common()) for c, v in sorted(out.items())}


# ---------------------------------------------------------------- 訓練（wtb 全部，不切折）


def _sigmoid(z: np.ndarray) -> np.ndarray:
    return 1.0 / (1.0 + np.exp(-np.clip(z, -30, 30)))


def train_intake_probe(feat: dict[str, np.ndarray], intake: dict[str, str]) -> tuple[np.ndarray, np.ndarray]:
    """P／W／T 三個一對多邏輯迴歸，wtb 全部有標記的影像一起訓（跨語料不需要留折）。
    回傳 (訓練特徵矩陣, 權重 3×513)——標準化參數要從訓練矩陣重算，所以矩陣一起回。"""
    ids = sorted((i for i in intake if i in feat), key=int)
    if len(ids) < 100:
        raise CrossCorpusError(f"wtb 取像標記只有 {len(ids)} 張對得上特徵")
    X = np.stack([feat[i] for i in ids])
    y = [MERGE.get(intake[i], intake[i]) for i in ids]
    Xz, _ = B.standardise(X, X[:1])
    W = np.stack([B.fit_logreg(Xz, np.array([1.0 if t == c else 0.0 for t in y])) for c in PROBE_CLASSES])
    return X, W


def train_defect_probe(feat: dict[str, np.ndarray], truth: dict[str, list[str]], intake: dict[str, str]
                       ) -> tuple[np.ndarray, list[str], np.ndarray]:
    """六類一對多，只用取像合格（P）的 wtb 影像——與線性探針的評估域相同。"""
    ids = sorted((i for i in truth if intake.get(i) == "P" and i in feat), key=int)
    classes = sorted({c for i in ids for c in truth[i]})
    X = np.stack([feat[i] for i in ids])
    Xz, _ = B.standardise(X, X[:1])
    W = np.stack([B.fit_logreg(Xz, np.array([1.0 if c in truth[i] else 0.0 for i in ids])) for c in classes])
    return X, classes, W


def apply_probe(Xtrain: np.ndarray, W: np.ndarray, Xother: np.ndarray) -> np.ndarray:
    """用訓練矩陣的 μ／σ 標準化外部特徵，回傳每類的機率（n × k）。"""
    _, Xz = B.standardise(Xtrain, Xother)
    return _sigmoid(Xz @ W.T)


# ---------------------------------------------------------------- 域差


def domain_gap(Xa: np.ndarray, Xb: np.ndarray, folds: int = DOMAIN_FOLDS) -> dict:
    """兩個語料分得開嗎：邏輯迴歸判「是 A 還是 B」的 k 折平衡準確率（決定性的輪流切分，無隨機）。
    接近 0.5 = 同一個分布；接近 1.0 = 一眼分得出來，任何跨語料數字都是在域移之下量的。
    另附最近鄰餘弦：B 的每張到 A 最像那張的餘弦中位數，對照 A 內部留一的同一個量。"""
    X = np.vstack([Xa, Xb])
    y = np.r_[np.zeros(len(Xa)), np.ones(len(Xb))]
    idx = np.arange(len(X))
    tp = tn = fp = fn = 0
    for f in range(folds):
        te = idx % folds == f
        Xz_tr, Xz_te = B.standardise(X[~te], X[te])
        w = B.fit_logreg(Xz_tr, y[~te])
        pred = (Xz_te @ w) >= 0
        tp += int(np.sum(pred & (y[te] == 1)))
        tn += int(np.sum(~pred & (y[te] == 0)))
        fp += int(np.sum(pred & (y[te] == 0)))
        fn += int(np.sum(~pred & (y[te] == 1)))
    bal = 0.5 * (tp / max(tp + fn, 1) + tn / max(tn + fp, 1))

    def unit(M: np.ndarray) -> np.ndarray:
        return M / (np.linalg.norm(M, axis=1, keepdims=True) + 1e-9)

    Ua, Ub = unit(Xa), unit(Xb)
    cross = (Ub @ Ua.T).max(axis=1)
    within = Ua @ Ua.T
    np.fill_diagonal(within, -1.0)
    return {
        "n_a": int(len(Xa)), "n_b": int(len(Xb)), "folds": folds,
        "balanced_accuracy": round(float(bal), 4),
        "nn_cosine_b_to_a_median": round(float(np.median(cross)), 4),
        "nn_cosine_a_within_median": round(float(np.median(within.max(axis=1))), 4),
    }


# ---------------------------------------------------------------- 逐張 → 列


def _short_id(key: str) -> str:
    """`erosion/2181_jpg.rf.<hash>.jpg` → `erosion/2181`；`Blade/0000.jpg` → `Blade/0000`。"""
    cls, _, name = key.partition("/")
    name = re.sub(r"\.rf\.[0-9a-f]+", "", name)
    name = re.sub(r"\.(jpg|jpeg|png)$", "", name, flags=re.I)
    name = re.sub(r"_(jpg|jpeg|png)$", "", name, flags=re.I)
    return f"{cls}/{name}"


def geom_code(g: dict | None) -> str:
    if g is None:
        return "missing"
    if g.get("error"):
        return "error"
    if g.get("mode_a_ok"):
        return "front" if g.get("mode_a_view") == "front" else "side"
    return "reject"


def load_geometry(path: Path) -> dict[str, dict]:
    out = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if line.strip():
            d = json.loads(line)
            out[d["id"]] = d
    return out


def build_rows(corpus: str, feat: dict[str, np.ndarray], geom: dict[str, dict], intake_probs: np.ndarray,
               defect: tuple[list[str], np.ndarray] | None, keys: list[str]) -> list[dict]:
    rows = []
    for n, k in enumerate(keys):
        p = intake_probs[n]
        row = {
            "id": _short_id(k), "class": k.split("/")[0],
            "probe": PROBE_CLASSES[int(np.argmax(p))],
            "p": [round(float(v), 3) for v in p],
            "geom": geom_code(geom.get(k)),
        }
        if defect is not None:
            classes, probs = defect
            q = probs[n]
            row["defect_top"] = classes[int(np.argmax(q))]
            row["defect_top_p"] = round(float(q.max()), 3)
            row["defect_set"] = [c for c, v in zip(classes, q) if v >= DEFECT_THRESHOLD]
        rows.append(row)
    return rows


# ---------------------------------------------------------------- 逐張列的欄式打包（7,544 列的 JSON 從 1.5 MB 壓到幾百 KB）

GEOM_CODES = {"front": "f", "side": "s", "reject": "r", "error": "e", "missing": "m"}
_GEOM_BACK = {v: k for k, v in GEOM_CODES.items()}


def pack_rows(rows: list[dict], defect_classes: list[str]) -> dict:
    """列 → 欄。探針碼與幾何碼各一個字元一列，機率取三位小數，缺陷集合用位元遮罩。"""
    out: dict = {
        "n": len(rows),
        "ids": [r["id"] for r in rows],
        "probe": "".join(r["probe"] for r in rows),
        "geom": "".join(GEOM_CODES[r["geom"]] for r in rows),
        "p": [round(float(v), 3) for r in rows for v in r["p"]],
    }
    if rows and "defect_top" in rows[0]:
        idx = {c: i for i, c in enumerate(defect_classes)}
        out["defect_top"] = [idx[r["defect_top"]] for r in rows]
        out["defect_top_p"] = [round(float(r["defect_top_p"]), 3) for r in rows]
        out["defect_set"] = [sum(1 << idx[c] for c in r["defect_set"]) for r in rows]
    return out


def unpack_rows(packed: dict, defect_classes: list[str]) -> list[dict]:
    n = packed["n"]
    rows = []
    for k in range(n):
        rid = packed["ids"][k]
        row = {"id": rid, "class": rid.split("/")[0], "probe": packed["probe"][k],
               "p": packed["p"][3 * k: 3 * k + 3], "geom": _GEOM_BACK[packed["geom"][k]]}
        if "defect_top" in packed:
            mask = packed["defect_set"][k]
            row["defect_top"] = defect_classes[packed["defect_top"][k]]
            row["defect_top_p"] = packed["defect_top_p"][k]
            row["defect_set"] = [c for i, c in enumerate(defect_classes) if mask >> i & 1]
        rows.append(row)
    return rows


def rows_of(doc: dict, key: str) -> list[dict]:
    c = doc["corpora"][key]
    if "rows" in c:
        return c["rows"]
    return unpack_rows(c["rows_packed"], doc["defect_classes"])


# ---------------------------------------------------------------- 統計（報告與測試都只吃這個）


def _rate(n: int, d: int) -> float | None:
    return None if d == 0 else round(n / d, 4)


def summarise_intake(rows: list[dict], expected: dict[str, str] | None) -> dict:
    per: dict[str, dict] = {}
    for cls in sorted({r["class"] for r in rows}):
        rs = [r for r in rows if r["class"] == cls]
        probe = Counter(r["probe"] for r in rs)
        geom = Counter(r["geom"] for r in rs)
        d = {
            "n": len(rs),
            "probe": {c: probe.get(c, 0) for c in PROBE_CLASSES},
            "p_rate": _rate(probe.get("P", 0), len(rs)),
            "geom": {c: geom.get(c, 0) for c in ("front", "side", "reject", "error", "missing")},
            "hard_reject_whole_turbine": geom.get("front", 0),   # Mode A 正視放行 = 整機照 = 硬拒收
        }
        if expected and cls in expected:
            d["expected"] = expected[cls]
            d["agree_rate"] = _rate(probe.get(expected[cls], 0), len(rs))
        per[cls] = d
    total = len(rows)
    out = {"n": total, "per_class": per,
           "probe_total": {c: sum(1 for r in rows if r["probe"] == c) for c in PROBE_CLASSES},
           "hard_reject_total": sum(1 for r in rows if r["geom"] == "front"),
           "side_pass_total": sum(1 for r in rows if r["geom"] == "side")}
    if expected:
        neg = [r for r in rows if expected.get(r["class"]) in ("W", "T")]
        pos = [r for r in rows if expected.get(r["class"]) == "P"]
        out["false_accept_p_on_non_blade"] = {"n": len(neg), "as_P": sum(1 for r in neg if r["probe"] == "P"),
                                              "rate": _rate(sum(1 for r in neg if r["probe"] == "P"), len(neg))}
        out["blade_as_P"] = {"n": len(pos), "as_P": sum(1 for r in pos if r["probe"] == "P"),
                             "rate": _rate(sum(1 for r in pos if r["probe"] == "P"), len(pos))}
    return out


def summarise_defect(rows: list[dict], class_map: dict[str, list[str]], defect_classes: list[str]) -> dict:
    """粗對照命中率：外部類別 → 期望的 wtb 類集合；命中 = argmax 落在集合裡。
    對照一個不用學的基準——**邊際率**：如果預測與真類無關，命中率就等於期望集合在全體預測裡的占比。
    lift = 命中率 ÷ 邊際率；≈ 1 表示探針在這份語料上等於亂猜。"""
    rows = [r for r in rows if "defect_top" in r]
    marg = Counter(r["defect_top"] for r in rows)
    n_all = len(rows)
    per: dict[str, dict] = {}
    hit_total = exp_total = 0
    for cls in sorted({r["class"] for r in rows}):
        rs = [r for r in rows if r["class"] == cls]
        dist = Counter(r["defect_top"] for r in rs)
        exp = class_map.get(cls)
        d = {"n": len(rs), "argmax": {c: dist.get(c, 0) for c in defect_classes},
             "none_above_threshold": sum(1 for r in rs if not r["defect_set"]),
             "expected_wtb": exp}
        if exp:
            hits = sum(1 for r in rs if r["defect_top"] in exp)
            marg_rate = sum(marg.get(c, 0) for c in exp) / max(n_all, 1)
            d["hit_rate"] = _rate(hits, len(rs))
            d["marginal_rate"] = round(marg_rate, 4)
            d["lift"] = None if marg_rate == 0 else round(hits / len(rs) / marg_rate, 2)
            rs_p = [r for r in rs if r["probe"] == "P"]
            d["hit_rate_probe_P"] = _rate(sum(1 for r in rs_p if r["defect_top"] in exp), len(rs_p))
            hit_total += hits
            exp_total += len(rs)
        per[cls] = d
    return {"n": n_all, "threshold": DEFECT_THRESHOLD, "marginal": {c: marg.get(c, 0) for c in defect_classes},
            "per_class": per, "mapped_hit_rate": _rate(hit_total, exp_total), "mapped_n": exp_total,
            "none_above_threshold_total": sum(1 for r in rows if not r["defect_set"])}


def summarise(doc: dict) -> dict:
    tax_map = doc.get("class_map", {})
    out = {}
    for key, c in doc["corpora"].items():
        rows = rows_of(doc, key)
        s = {"intake": summarise_intake(rows, CORPORA[key]["expected_intake"])}
        if CORPORA[key]["defect_transfer"]:
            s["defect"] = summarise_defect(rows, tax_map, doc["defect_classes"])
        s["domain_gap"] = c.get("domain_gap")
        s["geom_reasons"] = c.get("geom_reasons", {})
        s["hard_rejects"] = sorted(r["id"] for r in rows if r["geom"] == "front")
        out[key] = s
    return out


# ---------------------------------------------------------------- 報告


def _table(headers: list[str], body: list[list]) -> str:
    lines = ["| " + " | ".join(headers) + " |", "|" + "---|" * len(headers)]
    lines += ["| " + " | ".join("—" if c is None else str(c) for c in row) + " |" for row in body]
    return "\n".join(lines)


def _pct(x: float | None) -> str:
    return "—" if x is None else f"{x * 100:.1f}%"


def render_markdown(doc: dict) -> str:
    S = summarise(doc)
    L: list[str] = []
    L.append("# Mode B 跨語料驗證（B3）\n")
    L.append(f"> 版本 `{doc['version']}`。由 `scripts/closeup_cross_corpus.py report` 從 `data/closeup_cross_corpus.json` 產生，"
             "**數字不手抄**。分類器在 wtb 語料上訓好**不重訓**，直接丟到兩份沒看過的語料。外部語料的影像與特徵不進版控。\n")
    w, h = S["wtbs2025"], S.get("hf_sees")
    L.append("## 0. 一句話\n")
    line = (f"取像探針在 WTBs2025 的 {w['intake']['n']} 張缺陷照上判 P **{_pct(w['intake']['probe_total']['P'] / w['intake']['n'])}**、"
            f"Mode A 正視硬規則誤觸 **{w['intake']['hard_reject_total']}** 張（側視放行 {w['intake']['side_pass_total']}）。")
    if h:
        fa, bp = h["intake"]["false_accept_p_on_non_blade"], h["intake"]["blade_as_P"]
        line += (f" 乾淨負樣本（Hub／Mast／Nacelle／Van/FullTurbine，{fa['n']} 張）被判成近身葉片照 **{fa['as_P']}** 張（{_pct(fa['rate'])}）；"
                 f"Blade {bp['n']} 張判 P {_pct(bp['rate'])}。")
    if "defect" in w:
        d = w["defect"]
        line += (f" 缺陷探針粗對照命中率 **{_pct(d['mapped_hit_rate'])}**（{d['mapped_n']} 張有對照），"
                 f"{_pct(d['none_above_threshold_total'] / max(d['n'], 1))} 的照片沒有任何一類過 {d['threshold']}。")
    g = w.get("domain_gap")
    if g:
        line += f" 域分類器把 wtb 與 WTBs2025 分開的平衡準確率 **{g['balanced_accuracy']:.3f}**——兩份語料一眼就分得出來。"
    L.append(line + "\n")
    L.append("## 1. 語料\n")
    L.append(_table(["鍵", "名稱", "來源", "備註", "張數"],
                    [[k, CORPORA[k]["name"], CORPORA[k]["source"], CORPORA[k]["note"], S[k]["intake"]["n"]] for k in S]))
    L.append("")
    L.append("訓練資料：wtb 語料（figshare 30210175，CC BY 4.0）全部 1,065 張的取像標記訓取像探針；取像合格的 839 張訓缺陷探針。"
             "特徵都是凍結 ImageNet ResNet18 512 維（`closeup_features_cnn.extract_paths`，外部語料與 wtb 走同一個函式）。\n")
    for key in S:
        c = S[key]
        L.append(f"## 2. 取像探針：{CORPORA[key]['name']}\n")
        hdr = ["類別", "張數", "P", "W", "T", "P 率", "期望", "Mode A 正視放行（硬拒收）", "側視放行", "例外"]
        body = []
        for cls, d in c["intake"]["per_class"].items():
            body.append([cls, d["n"], d["probe"]["P"], d["probe"]["W"], d["probe"]["T"], _pct(d["p_rate"]),
                         d.get("expected", "?"), d["geom"]["front"], d["geom"]["side"], d["geom"]["error"]])
        L.append(_table(hdr, body))
        L.append("")
        if "false_accept_p_on_non_blade" in c["intake"]:
            fa, bp = c["intake"]["false_accept_p_on_non_blade"], c["intake"]["blade_as_P"]
            L.append(f"- **非葉片類被判 P（閘門放錯人）：{fa['as_P']}/{fa['n']}（{_pct(fa['rate'])}）**。")
            L.append(f"- Blade 類判 P：{bp['as_P']}/{bp['n']}（{_pct(bp['rate'])}）——Blade 裡混有葉根＋輪轂入鏡的照片，依 §1.2 那些本來就該是 W，所以這不是 100% 的目標。\n")
        if c.get("domain_gap"):
            g = c["domain_gap"]
            L.append(f"域差（wtb 取像合格 {g['n_a']} 張 vs 本語料 {g['n_b']} 張）：{g['folds']} 折域分類器平衡準確率 **{g['balanced_accuracy']:.3f}**；"
                     f"本語料到 wtb 最近鄰餘弦中位 {g['nn_cosine_b_to_a_median']:.3f}，wtb 內部留一 {g['nn_cosine_a_within_median']:.3f}。\n")
        if c.get("hard_rejects"):
            L.append("Mode A 正視放行（硬拒收）逐張，人工看過疊圖：\n")
            for rid in c["hard_rejects"]:
                L.append(f"- `{rid}`：{HARD_REJECT_REVIEW.get(rid, '（未人工複核）')}")
            L.append("")
        gr = c.get("geom_reasons") or {}
        show = [cls for cls in gr if CORPORA[key]["expected_intake"] and CORPORA[key]["expected_intake"].get(cls) == "W"]
        if show:
            L.append("Mode A 閘門對「應該是整機照」那幾類的拒收原因（同一張可有多條）：\n")
            cols = sorted({b for cls in show for b in gr[cls]})
            L.append(_table(["類別"] + cols, [[cls] + [gr[cls].get(b, 0) for b in cols] for cls in show]))
            L.append("")
    if "defect" in w:
        d = w["defect"]
        L.append("## 3. 缺陷探針的粗對照（WTBs2025）\n")
        L.append("WTBs2025 的 9 類與 wtb 的 6 類**不是同一套**，這裡只能問「探針的 argmax 落在對照表期望的 wtb 類裡的比例」，"
                 "對照表在 `data/closeup_taxonomy.json` 的 `dataset_class_map.wtbs2025`。基準是**邊際率**（若預測與真類無關的命中率），"
                 "lift ≈ 1 就是亂猜。**這不是 §6 的評估**：沒有按葉片切、沒有健康照、類別定義不同。\n")
        hdr = ["WTBs2025 類", "張數", "期望 wtb 類"] + doc["defect_classes"] + ["無一類過門檻", "命中率", "邊際率", "lift", "命中率（只算判 P 的）"]
        body = []
        for cls, x in d["per_class"].items():
            body.append([cls, x["n"], "、".join(x["expected_wtb"]) if x["expected_wtb"] else "（汙染，無對應）"]
                        + [x["argmax"][c] for c in doc["defect_classes"]]
                        + [x["none_above_threshold"], _pct(x.get("hit_rate")), _pct(x.get("marginal_rate")),
                           "—" if x.get("lift") is None else f"{x['lift']:.2f}", _pct(x.get("hit_rate_probe_P"))])
        L.append(_table(hdr, body))
        L.append("")
        L.append(f"全體 argmax 邊際分布：" + "、".join(f"{c} {n}" for c, n in d["marginal"].items()) + "。\n")
    L.append("## 4. 結論（由數字產生）\n")
    L += conclusions(S)
    L.append("")
    L.append("## 5. 讀法\n")
    L.append("- 取像探針學的是 wtb 語料的**取景碼**，不是弦向占比（A3 就寫明它是建議性的）。它在別人的照片上判 P 的比例，"
             "只說明「這份語料的取景像不像 wtb 的 P」，不等於這些照片符合 §1.2。")
    L.append("- Mode A 正視硬規則在近身照上誤觸 0 才是對的；側視放行是 SPEC §13-13 記錄過的漏洞（葉片被裂縫或反光切成上下兩段 + 假塔架），"
             "這裡量的是它在外部語料上的出現率。")
    L.append("- 缺陷探針的 lift 是唯一能跨語料看的數：它高於 1 只說明探針帶著一點跨語料的訊號，離「可用」還遠；"
             "要正式評估得先把 WTBs2025 的類別逐張重標成本表的子類、按原始檔名分群、補健康照。")
    L.append("")
    return "\n".join(L)


def conclusions(S: dict) -> list[str]:
    """把數字翻成結論的規則寫在這裡，不手寫在報告裡：數字變了、句子跟著變。"""
    out = []
    w = S["wtbs2025"]["intake"]
    h = S.get("hf_sees", {}).get("intake")
    if h:
        fa, bp = h["false_accept_p_on_non_blade"], h["blade_as_P"]
        ft = h["per_class"].get("FullTurbine", {})
        if fa["rate"] is not None and fa["rate"] >= 0.2:
            out.append(f"- **取像探針不能當閘門。** 乾淨負樣本 {fa['n']} 張有 {_pct(fa['rate'])} 被判成近身葉片照"
                       f"（Van {h['per_class']['Van']['probe']['P']}/{h['per_class']['Van']['n']}、"
                       f"Nacelle {h['per_class']['Nacelle']['probe']['P']}/{h['per_class']['Nacelle']['n']}、"
                       f"Hub {h['per_class']['Hub']['probe']['P']}/{h['per_class']['Hub']['n']}）。它在 wtb 上學到的 P 其實是「不是整機遠景」，"
                       "換一份語料就只剩這一個分辨力。A3 寫的「建議性」要升級成「不得單獨拒收或放行」。")
        else:
            out.append(f"- 取像探針在乾淨負樣本上放錯 {_pct(fa['rate'])}，在可接受範圍。")
        if ft and ft.get("agree_rate") is not None:
            out.append(f"- 探針唯一跨語料成立的是 **W（整機入鏡）**：FullTurbine {ft['probe']['W']}/{ft['n']} 判 W（{_pct(ft['agree_rate'])}）；"
                       f"Blade 判 P {_pct(bp['rate'])}。")
    out.append(f"- **Mode A 正視硬規則**在 {w['n']} 張近身缺陷照上誤觸 {w['hard_reject_total']} 張"
               f"（{w['hard_reject_total'] / max(w['n'], 1) * 100:.2f}%），每張都人工看過（§2）。誤觸的兩種樣式：背景有一台完整風機、"
               "一條葉片 + 影子被拆成三臂。側視規則放行 "
               f"{w['side_pass_total']} 張（{_pct(w['side_pass_total'] / max(w['n'], 1))}）"
               + (f"、HF Blade {h['per_class']['Blade']['geom']['side']}/{h['per_class']['Blade']['n']}" if h else "")
               + "——SPEC §13-13 的漏洞在外部語料上的出現率。")
    if "defect" in S["wtbs2025"]:
        d = S["wtbs2025"]["defect"]
        lifts = {c: x["lift"] for c, x in d["per_class"].items() if x.get("lift") is not None}
        high = {c: v for c, v in lifts.items() if v >= 2.0}
        near = {c: v for c, v in lifts.items() if v < 1.3}
        out.append(f"- **缺陷探針跨語料幾乎等於亂猜**：{len(lifts)} 個有對照的類別裡 lift < 1.3 的有 {len(near)} 個"
                   f"（{', '.join(f'{c} {v:.2f}' for c, v in near.items())}）"
                   + (f"；只有 {', '.join(f'{c} {v:.1f}' for c, v in high.items())} 明顯高於 1" if high else "")
                   + f"。同一個探針在 wtb 群感知 5 折的平均逐類 recall 是 0.632（`CLOSEUP_EVAL_PROTOCOL.md` §3.7）——"
                   "**§8.3 說的「分布外崩掉」不是猜測，是量到的**。")
    gaps = {k: S[k]["domain_gap"]["balanced_accuracy"] for k in S if S[k].get("domain_gap")}
    if gaps:
        out.append("- 域分類器平衡準確率 " + "、".join(f"{k} **{v:.3f}**" for k, v in gaps.items())
                   + "：兩份外部語料與 wtb 在凍結特徵空間裡一眼就分得出來，上面所有跨語料數字都是在這個域移之下量的。")
    return out


# ---------------------------------------------------------------- CLI


def _parse_corpus(spec: str) -> tuple[str, Path, Path]:
    key, _, rest = spec.partition("=")
    feats, _, geom = rest.partition(":")
    if key not in CORPORA or not feats or not geom:
        raise CrossCorpusError(f"--corpus 格式是 <鍵>=<特徵 npz>:<幾何 jsonl>，鍵限 {sorted(CORPORA)}：{spec}")
    return key, Path(feats), Path(geom)


def cmd_run(a: argparse.Namespace) -> int:
    feat_wtb, meta_wtb = load_features(Path(a.features))
    intake = json.loads(B.INTAKE.read_text(encoding="utf-8"))["labels"]
    truth = json.loads(B.TRUTH.read_text(encoding="utf-8"))["labels"]
    tax = json.loads(TAXONOMY.read_text(encoding="utf-8"))
    class_map = {row["their"]: row["wtb_equivalent"] for row in tax["dataset_class_map"]["wtbs2025"]["classes"]}

    Xi, Wi = train_intake_probe(feat_wtb, intake)
    Xd, defect_classes, Wd = train_defect_probe(feat_wtb, truth, intake)
    doc = {"version": VERSION, "wtb_features": {"weight_sha256_16": meta_wtb["weight_sha256_16"], "n": meta_wtb["n"]},
           "intake_train_n": int(len(Xi)), "defect_train_n": int(len(Xd)), "defect_classes": defect_classes,
           "class_map": class_map, "corpora": {}}
    for spec in a.corpus:
        key, fpath, gpath = _parse_corpus(spec)
        feat, meta = load_features(fpath)
        if meta.get("weight_sha256_16") != meta_wtb["weight_sha256_16"]:
            raise CrossCorpusError(f"{key} 的特徵權重雜湊 {meta.get('weight_sha256_16')} 與 wtb 的不同，不能比")
        geom = load_geometry(gpath)
        keys = sorted(feat)
        X = np.stack([feat[k] for k in keys])
        probs = apply_probe(Xi, Wi, X)
        defect = (defect_classes, apply_probe(Xd, Wd, X)) if CORPORA[key]["defect_transfer"] else None
        rows = build_rows(key, feat, geom, probs, defect, keys)
        gap = domain_gap(Xd, X)
        doc["corpora"][key] = {"n": len(rows), "feature_meta": {k: meta.get(k) for k in ("n", "seconds", "weight_sha256_16")},
                               "domain_gap": gap, "geom_reasons": geometry_reasons(geom),
                               "rows_packed": pack_rows(rows, defect_classes)}
        print(f"{key}: {len(rows)} 張，探針 {Counter(r['probe'] for r in rows)}，幾何 {Counter(r['geom'] for r in rows)}，"
              f"域分類 {gap['balanced_accuracy']}", file=sys.stderr)
    doc["summary"] = summarise(doc)
    Path(a.out).write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    print(json.dumps({k: {"n": v["intake"]["n"], "P": v["intake"]["probe_total"]["P"], "hard": v["intake"]["hard_reject_total"]}
                      for k, v in doc["summary"].items()}, ensure_ascii=False))
    return 0


def cmd_report(a: argparse.Namespace) -> int:
    doc = json.loads(Path(a.results).read_text(encoding="utf-8"))
    Path(a.out).write_text(render_markdown(doc), encoding="utf-8")
    print(f"寫入 {a.out}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--features", default=str(FEATURES_WTB))
    r.add_argument("--corpus", action="append", required=True)
    r.add_argument("--out", default=str(OUT))
    r.set_defaults(func=cmd_run)
    p = sub.add_parser("report")
    p.add_argument("--results", default=str(OUT))
    p.add_argument("--out", default=str(ROOT / "CROSS_CORPUS_VALIDATION.md"))
    p.set_defaults(func=cmd_report)
    a = ap.parse_args(argv)
    try:
        return a.func(a)
    except CrossCorpusError as e:
        print(f"拒跑：{e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
