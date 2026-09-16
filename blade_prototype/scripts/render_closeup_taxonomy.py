#!/usr/bin/env python3
"""把 `data/closeup_taxonomy.json` 渲染成 `BLADE_CLOSEUP_TAXONOMY.md`。

單一來源的做法與 `backend/scripts/export_standards.py` 一樣：**JSON 是來源，markdown 是產物**。
改 JSON 後要重跑這支腳本，否則 `tests/test_closeup_taxonomy.py` 會紅。

用法：
    python scripts/render_closeup_taxonomy.py          # 寫檔
    python scripts/render_closeup_taxonomy.py --check  # 只比對，不寫（測試用）
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "blade_prototype" / "data" / "closeup_taxonomy.json"
OUT = ROOT / "BLADE_CLOSEUP_TAXONOMY.md"


def _cell(s: object) -> str:
    """markdown 表格的儲存格：把換行與管線字元處理掉，None 顯示成破折號。"""
    if s is None or s == "":
        return "—"
    return str(s).replace("|", "\\|").replace("\n", " ")


def _scale(v: object) -> str:
    """min_cm_per_px：這一類至少要多細的解析度才看得到。"""
    return "—" if v is None else f"≤ {v} cm/px"


def render(d: dict) -> str:
    L: list[str] = []
    add = L.append

    add("# Mode B 標註分類表（B0 產出）")
    add("")
    add(f"> 版本 `{d['version']}`。**本檔由 `blade_prototype/scripts/render_closeup_taxonomy.py` 產生，"
        f"不要手改。** 單一來源是 `blade_prototype/data/closeup_taxonomy.json`；"
        f"改完 JSON 要重跑腳本，否則 `tests/test_closeup_taxonomy.py` 會紅。")
    add(">")
    add(f"> 規格：[`{d['spec']}`]({d['spec']})。這張表是該規格 §10 的 B0 出口條件之一。")
    add("")
    add("這張表有兩個用途，缺一不可：")
    add("")
    add("1. **標註指引**——人拿著它標語料，B1 的評估腳本吃 §6 的紀錄格式。")
    add("2. **知識庫種子**——每個子類的「幾何規則」欄就是規格 §8.2 知識庫第 1 項的內容，"
        "`normal_structures` 就是第 2 項。寫這張表等於在建知識庫。")
    add("")
    add("---")
    add("")

    # --- 機制分類 ---
    add("## 1. 四個機制類（照片級標籤）")
    add("")
    add("| 類別 | 中文 | 定義 | 證據型態 | 嚴重度尺規 |")
    add("|---|---|---|---|---|")
    for c in d["classes"]:
        add(f"| `{c['id']}` | {c['name_zh']} | {_cell(c['definition'])} | "
            f"{_cell(c['evidence_type'])} | `{c['severity_scale']}` |")
    add("")
    add(f"**照片級標籤規則**：{d['photo_label_rule']}")
    add("")

    # --- 子類 ---
    for c in d["classes"]:
        add(f"### 1.{d['classes'].index(c) + 1} `{c['id']}` — {c['name_zh']}")
        add("")
        add("| 子類 | 中文 | 是否損傷 | 外觀 | **幾何規則** | 位置 | 需要的解析度 | 易混淆於 |")
        add("|---|---|---|---|---|---|---|---|")
        for s in c["subclasses"]:
            conf = "、".join(f"`{x}`" for x in s["confused_with"]) or "—"
            add(f"| `{s['id']}` | {s['name_zh']} | {'✓' if s['is_defect'] else '✗'} | "
                f"{_cell(s['appearance'])} | {_cell(s['geometric_rule'])} | {_cell(s['location'])} | "
                f"{_scale(s['min_cm_per_px'])} | {conf} |")
        add("")
        notes = [(s["id"], s["note"]) for s in c["subclasses"] if s.get("note")]
        for sid, note in notes:
            add(f"- **`{sid}`**：{note}")
        if notes:
            add("")

    # --- 正常結構 ---
    add("---")
    add("")
    add("## 2. 正常結構清單（報成缺陷就是誤報）")
    add("")
    add("規格 §6 第 4 條要求誤報分開報「在正常結構上」與「在乾淨表面上」。"
        "要做到這件事，正常結構必須被**正面標記**，不能只是「沒有缺陷標記」——"
        "否則誤報落在哪裡無從歸因。")
    add("")
    add("| 項目 | 中文 | 怎麼認 | 會被誤判成 |")
    add("|---|---|---|---|")
    for n in d["normal_structures"]:
        conf = "、".join(f"`{x}`" for x in n["confused_with"]) or "—"
        add(f"| `{n['id']}` | {n['name_zh']} | {_cell(n['recognise'])} | {conf} |")
    add("")
    for n in d["normal_structures"]:
        if n.get("note"):
            add(f"- **`{n['id']}`**：{n['note']}")
    add("")

    # --- 嚴重度 ---
    add("---")
    add("")
    add("## 3. 嚴重度尺規")
    add("")
    for key, sc in d["severity_scales"].items():
        add(f"### 3.{list(d['severity_scales']).index(key) + 1} `{key}`")
        add("")
        add(f"- 適用：{'、'.join(f'`{a}`' for a in sc['applies_to'])}")
        add(f"- 需要尺度：{'**是**' if sc['requires_scale'] else '否'}")
        add(f"- 來源：{sc['source']}")
        add("")
        if sc.get("verified_on"):
            add(f"- 核對日期：{sc['verified_on']}（{sc.get('source_url', '')}）")
        for k in ("verification_note", "track_required", "min_cm_per_px_rule"):
            if sc.get(k):
                add(f"- {sc[k]}")
        add("")

        def _levels_table(levels: list) -> None:
            has_thr = any("threshold" in lv for lv in levels)
            if has_thr:
                add("| 等級 | 原文名稱 | 損傷門檻 | 判準 | 可偵測 | 需要的解析度 |")
                add("|---|---|---|---|---|---|")
            else:
                add("| 等級 | 判準 | 可偵測 | 需要的解析度 |")
                add("|---|---|---|---|")
            for lv in levels:
                det = lv.get("detectable")
                det_s = "—" if det is None else ("✓" if det else "**✗**")
                if has_thr:
                    add(f"| {lv['level']} | {_cell(lv.get('title', ''))} | {_cell(lv.get('threshold', ''))} | "
                        f"{_cell(lv['criterion'])} | {det_s} | {_scale(lv.get('min_cm_per_px'))} |")
                else:
                    add(f"| {lv['level']} | {_cell(lv['criterion'])} | {det_s} | "
                        f"{_scale(lv.get('min_cm_per_px'))} |")
            add("")
            for lv in levels:
                if lv.get("note"):
                    add(f"- Level {lv['level']}：{lv['note']}")
            add("")

        if "tracks" in sc:
            for tk, tr in sc["tracks"].items():
                add(f"#### 軌別 `{tk}`：{tr['label']}")
                add("")
                _levels_table(tr["levels"])
        else:
            _levels_table(sc["levels"])
        if sc.get("open_item"):
            add("")
            add(f"> **未決**：{sc['open_item']}")
        add("")

    # --- 品質旗標 ---
    add("---")
    add("")
    add("## 4. 品質旗標")
    add("")
    add("| 旗標 | 判準 | 為什麼要記 |")
    add("|---|---|---|")
    for q in d["quality_flags"]:
        add(f"| `{q['id']}` | {_cell(q['criterion'])} | {_cell(q['why'])} |")
    add("")

    # --- 判定順序 ---
    add("---")
    add("")
    add("## 5. 判定順序（有衝突時由上而下）")
    add("")
    for r in d["decision_rules"]:
        add(f"{r['order']}. {r['rule']}")
    add("")

    # --- 公開語料對照 ---
    dm = d.get("dataset_class_map")
    if dm:
        add("---")
        add("")
        add("## 6. 公開語料的類別對照")
        add("")
        add(dm["note"])
        add("")
        for key, ds in dm.items():
            if key == "note":
                continue
            add(f"### 6.1 {ds['source']}")
            add("")
            add(f"- 授權：**{ds['licence']}**")
            add(f"- 規模：{ds['size']}")
            add("")
            add("| 它的類別 | 對到本表 | 注意 |")
            add("|---|---|---|")
            for c in ds["classes"]:
                ours = "、".join(f"`{x}`" for x in c["ours"])
                add(f"| `{c['their']}` | {ours} | {_cell(c['caveat'])} |")
            add("")
            add("**這份語料缺什麼**：")
            add("")
            for g in ds["gaps"]:
                add(f"- {g}")
            add("")
            sv = ds.get("normal_structure_survey")
            if sv:
                add(f"**正常結構普查**（{sv['sample']} 張抽樣）：{sv['note']}")
                add("")
                add("| 有出現 | 張數 |")
                add("|---|---|")
                for k, v in sv["present"].items():
                    add(f"| {k} | {v} |")
                add("")
                add("**沒出現**：" + "、".join(f"`{x}`" for x in sv["absent"]))
                add("")
                add("| 痕跡（不是葉片的東西，但模型會學到） | 張數 |")
                add("|---|---|")
                for k, v in sv["artifacts"].items():
                    add(f"| {k} | {v} |")
                add("")
                add(sv["finding"])
                add("")
            ia = ds["inter_annotator"]
            add(f"**標註者間一致度**：{ia['note']}")
            add("")
            add("| 量 | 值 |")
            add("|---|---|")
            add(f"| A 的標註框 | {ia['boxes_a']} |")
            add(f"| B 的標註框 | {ia['boxes_b']} |")
            add(f"| IoU ≥ 0.5 配對成功 | {ia['matched_iou_0_5']} |")
            add(f"| 定位一致率 | {ia['localisation_agreement'] * 100:.1f}% |")
            add(f"| 配對成功者的類別一致率 | **{ia['class_agreement_of_matched'] * 100:.1f}%** |")
            add(f"| Cohen's kappa | {ia['cohen_kappa']:.3f} |")
            add("")
            add(ia["disagreement_pairs"])
            add("")

    # --- 紀錄格式 ---
    add("---")
    add("")
    add("## 7. 紀錄格式")
    add("")
    add(d["record_schema"]["note"])
    add("")
    add("必填：" + "、".join(f"`{f}`" for f in d["record_schema"]["required"]))
    add("")
    add("| 欄位 | 內容 |")
    add("|---|---|")
    for k, v in d["record_schema"]["fields"].items():
        add(f"| `{k}` | {_cell(v)} |")
    add("")
    return "\n".join(L) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只比對不寫檔")
    args = ap.parse_args()
    text = render(json.loads(DATA.read_text(encoding="utf-8")))
    if args.check:
        cur = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
        if cur != text:
            print(f"{OUT} 與 {DATA.name} 不同步：請執行 "
                  f"`python blade_prototype/scripts/render_closeup_taxonomy.py`", file=sys.stderr)
            return 1
        print("同步")
        return 0
    OUT.write_text(text, encoding="utf-8")
    print(f"寫入 {OUT}（{len(text.splitlines())} 行）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
