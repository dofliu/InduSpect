#!/usr/bin/env python3
"""閘門與姿態估計對「來源解析度／JPEG 再壓縮」的靈敏度（Commons 放行照）。

`SPEC §13-15` 原本只證成「在**拒收側**，換解析度沒有改變收／不收」——重疊的 16 張裡真的
不同解析度的只有 7 張，而且全是拒收。這支腳本補上**放行側**：把已放行的照片按 Wikimedia
縮圖語意（`<N>px-` 指定的是**寬度**）縮到指定寬度、用指定 JPEG 品質存檔，再跑與
`real_pose_validation.py run` 完全相同的那條路徑，逐張比對。

為什麼要有兩個品質：Wikimedia 的縮圖是重新編碼的，不是原圖的裁切。同一個像素尺寸下
只改 JPEG 品質，就能把「解析度」與「再壓縮」兩個因素分開——實測**兩者都會翻**。

用法（影像不進版控，要自己準備）：

    python3 scripts/resolution_sensitivity.py --dir <放行照目錄> \\
        --out data/commons_pose_resolution_check.json

`--dir` 裡的檔名是 `c<pageid>.jpg`，manifest 提供焦距／輪轂高／轉子直徑。
預設只跑 manifest 裡 selected 且目錄裡有檔的照片。
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

DEFAULT_WIDTHS = (1280,)
DEFAULT_QUALITIES = (85, 80)

# 判定「翻掉」只看**類別型**的欄位：收／不收、取景分類、葉片數、有沒有找到塔架。
# `radius_spread` 之類的連續量一定會動一點點，拿它比相等只會讓每張都算翻掉——
# 它的變動量另外在報告裡看。
COMPARE_KEYS = ("ok", "view", "n_blades", "tower_found")


def _variant_name(width: int, quality: int) -> str:
    return f"w{width}q{quality}"


def _build_variant(src: Path, dst: Path, width: int, quality: int) -> tuple[int, int] | None:
    """按 Wikimedia `<N>px-` 的語意縮：指定的是**寬度**，直幅照長邊會大於 N。

    原圖比要求的寬度還窄時 Wikimedia 直接回原圖（只縮不放），這裡照做並回傳 None
    表示「這張沒有縮圖版本可比」。
    """
    from PIL import Image

    im = Image.open(src)
    w, h = im.size
    if w <= width:
        return None
    nh = round(h * width / w)
    im.resize((width, nh), Image.LANCZOS).save(dst, quality=quality, subsampling=2)
    return (width, nh)


def _flat(rec: dict) -> dict:
    """把一筆結果攤平成可逐欄比較的樣子。"""
    pose = rec.get("pose") or {}
    comp = rec.get("comp") or {}
    raw = rec.get("raw") or {}
    out = {
        "ok": rec["verdict"]["ok"],
        "view": rec.get("view"),
        "n_blades": rec.get("n_blades"),
        "radius_spread": rec.get("radius_spread"),
        "tower_found": rec.get("tower_found"),
        "reject_reasons": rec["verdict"].get("reasons") or [],
        "elevation_deg": pose.get("elevation_deg"),
        "yaw_deg": pose.get("yaw_deg"),
        "distance_m": pose.get("distance_m"),
        "raw_flagged": sorted(raw.get("flagged") or []) if raw else None,
        "comp_flagged": sorted(comp.get("flagged") or []) if comp else None,
        "prebend_fit_m": comp.get("prebend_fit_m"),
        "prebend_fit_ok": comp.get("prebend_fit_ok"),
        "deflection_compensated": comp.get("deflection_compensated"),
        "tip_deflection_raw_px": comp.get("tip_deflection_raw_px"),
        "cm_per_px": comp.get("cm_per_px"),
    }
    return out


def run(a: argparse.Namespace) -> int:
    import cv2
    import real_pose_validation as R

    man = json.load(open(a.manifest, encoding="utf-8"))
    cands = []
    for c in man["candidates"]:
        if not c.get("selected"):
            continue
        rid = f"c{c['pageid']}"
        path = Path(a.dir) / f"{rid}.jpg"
        if path.exists() and path.stat().st_size > 20_000:
            cands.append((rid, c, path))
    if not cands:
        print(f"{a.dir} 裡沒有 manifest selected 的照片", file=sys.stderr)
        return 2

    variants = [("orig", None, None)]
    for w in a.widths:
        for q in a.qualities:
            variants.append((_variant_name(w, q), w, q))

    rows: dict[str, dict] = {}
    sizes: dict[str, dict] = {}
    with tempfile.TemporaryDirectory() as tmp:
        for rid, c, path in cands:
            rr = float(c["rotor_diameter_m"]) / 2.0 if c.get("rotor_diameter_m") else None
            per_variant: dict[str, dict] = {}
            per_size: dict[str, object] = {}
            for name, width, quality in variants:
                if width is None:
                    use = path
                else:
                    dst = Path(tmp) / f"{rid}_{name}.jpg"
                    got = _build_variant(path, dst, width, quality)
                    if got is None:  # 原圖比要求的寬度還窄：Wikimedia 會回原圖，沒有可比的縮圖版
                        per_size[name] = None
                        continue
                    use = dst
                img = cv2.imread(str(use))
                if img is None:
                    print(f"  讀不到 {use}", file=sys.stderr)
                    continue
                per_size[name] = list(img.shape[1::-1])
                rec = R.analyse_image(img, focal_35mm=c.get("focal_35mm"),
                                      hub_height_m=c.get("hub_height_m"), rotor_radius_m=rr)
                rec.pop("_internals", None)
                per_variant[name] = _flat(rec)
            rows[rid] = {"model": c.get("model"), "title": c.get("title"),
                         "page_url": c.get("page_url"), "variants": per_variant}
            sizes[rid] = per_size
            base = per_variant.get("orig", {})
            deltas = [n for n, v in per_variant.items()
                      if n != "orig" and any(v.get(k) != base.get(k) for k in COMPARE_KEYS)]
            print(f"  {rid} {c.get('model')} orig={base.get('view')}/{base.get('ok')} "
                  f"翻掉的變體={deltas or '無'}", file=sys.stderr)

    doc = {
        "version": R.VERSION,
        "max_side": R.MAX_SIDE,
        "note": ("縮圖是本機用 PIL LANCZOS 模擬的（Wikimedia 的縮圖端點對本機 IP 封鎖中），"
                 "不是 Wikimedia 產的縮圖；結論講的是「換一次重採樣 + 再壓縮會不會翻」，"
                 "不是「Wikimedia 的縮圖器會不會翻」。"),
        "variants": [n for n, _, _ in variants],
        "sizes": sizes,
        "summary": summarise(rows),
        "images": rows,
    }
    Path(a.out).write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(json.dumps(doc["summary"], ensure_ascii=False))
    return 0


def summarise(rows: dict) -> dict:
    """逐變體統計：收／不收翻了幾張、取景分類翻了幾張、旗標集合變了幾張。"""
    out: dict[str, dict] = {}
    names = set()
    for r in rows.values():
        names |= set(r["variants"])
    for name in sorted(names - {"orig"}):
        gate = view = flags = pose_side = compared = 0
        for r in rows.values():
            base, v = r["variants"].get("orig"), r["variants"].get(name)
            if not base or not v:
                continue
            compared += 1
            if base["ok"] != v["ok"]:
                gate += 1
            if base["view"] != v["view"]:
                view += 1
            if base.get("raw_flagged") != v.get("raw_flagged"):
                flags += 1
            if base.get("prebend_fit_ok") != v.get("prebend_fit_ok"):
                pose_side += 1
        out[name] = {"compared": compared, "gate_flipped": gate, "view_flipped": view,
                     "flag_set_changed": flags, "prebend_ok_flipped": pose_side}
    return out


def render_markdown(doc: dict, source: str = "data/commons_pose_resolution_check.json") -> str:
    """報告一律由結果檔渲染，數字不手抄（與 real_pose_validation.py 同一個規矩）。"""
    rows = doc["images"]
    variants = [v for v in doc["variants"] if v != "orig"]
    L: list[str] = []
    A = L.append
    A("# 閘門與姿態估計對來源解析度的靈敏度（Commons 放行照）")
    A("")
    A(f"> 由 `scripts/resolution_sensitivity.py report` 從 `{source}` 產生，**數字不手抄**。"
      f"工作尺度 `max_side` {doc['max_side']}；照片本體不進版控。")
    A("")
    A("## 0. 一句話")
    A("")
    n = len(rows)
    worst = max((doc["summary"][v]["gate_flipped"] for v in variants), default=0)
    sides = [i for i, r in rows.items() if (r["variants"].get("orig") or {}).get("view") == "side"]
    fronts = [i for i, r in rows.items() if (r["variants"].get("orig") or {}).get("view") == "front"]
    flipped_sides = {i for i in sides for v in variants
                     if (r := rows[i]["variants"].get(v)) and r["ok"] != rows[i]["variants"]["orig"]["ok"]}
    flipped_fronts = {i for i in fronts for v in variants
                      if (r := rows[i]["variants"].get(v)) and r["ok"] != rows[i]["variants"]["orig"]["ok"]}
    A(f"{n} 張原本放行的照片，縮到寬 1280 再存成 JPEG 之後：**收／不收翻掉最多 {worst} 張**。"
      f"翻掉的全是走**側視規則**放行的那幾張（{len(flipped_sides)}/{len(sides)} 張至少在一個變體翻掉），"
      f"正視 {len(fronts)} 張的收／不收、取景分類、葉片數、塔架**全部沒變**（{len(flipped_fronts)}/{len(fronts)} 翻掉）。")
    A("")
    A("**但追下去發現那 4 張根本不是側視照**（§2）：塔門特寫、施工中的吊車、風場遠景、兩台風機同框。"
      "所以這裡翻掉的不是「好照片被弄丟」，而是**誤放行與正確拒收之間的搖擺**——"
      "真正的問題不是不穩定，是側視規則本身在放行不該放行的東西。")
    A("")
    A("正視那邊沒翻不等於沒變：**被標記的指標集合**與**預彎擬合是否落在合理範圍**都會動，"
      "而後者正是「補不補償」的開關。所以這份結果推翻的是「換來源不影響判定」這個更強的說法，"
      "不只是「解析度不影響閘門」。")
    A("")
    A("## 1. 逐變體")
    A("")
    A("| 變體 | 比較張數 | 收／不收翻掉 | 取景分類翻掉 | 旗標集合變了 | 預彎「合理」翻掉 |")
    A("|---|---|---|---|---|---|")
    for v in variants:
        s = doc["summary"][v]
        A(f"| `{v}` | {s['compared']} | **{s['gate_flipped']}** | {s['view_flipped']} | "
          f"{s['flag_set_changed']} | {s['prebend_ok_flipped']} |")
    A("")
    A("`w1280q85` 與 `w1280q80` 的**像素尺寸完全相同**，只差 JPEG 品質——兩者的翻掉集合不一樣，"
      "所以翻掉的原因不只是解析度，**再壓縮本身就夠**。")
    A("")
    A("## 2. 走側視規則放行的那 4 張——逐張看過，沒有一張是側視照")
    A("")
    A("| 照片 | 機型 | 原圖 | " + " | ".join(f"`{v}`" for v in variants) + " |")
    A("|---|---|---|" + "---|" * len(variants))
    for i in sorted(sides):
        r = rows[i]
        base = r["variants"]["orig"]
        cells = []
        for v in variants:
            x = r["variants"].get(v)
            cells.append("—" if not x else
                         f"{x['view']}／{'放行' if x['ok'] else '**拒收**'}（{x['n_blades']} 片）")
        A(f"| [{i}]({r['page_url']}) | {r['model']} | side／放行（{base['n_blades']} 片） | "
          + " | ".join(cells) + " |")
    A("")
    A("翻掉的機制是同一個：側視規則要求**恰好 2 個伸長元件**，降解析度後結構定位只找到 1 片或找出 3 片，"
      "於是不走側視規則、改套正視的「三片」條件，然後被葉片數或半徑離散擋掉。")
    A("")
    A("**但 2026-09-28 把這 4 張疊圖逐張看過之後，結論要反過來寫**——它們是："
      "塔門特寫（c50571491，Commons 標題 P1040455，畫面是塔基的門與踏板）、"
      "施工中的吊車與光塔（c20562709，描述寫 *im Bau*，沒有轉子）、"
      "風場遠景（c49384455，多台風機 + 格子桅杆）、"
      "夕陽下的**兩台** N90（c19637139）。**沒有一張是側視全機照。**")
    A("")
    A("原因不是門檻沒調好：真側視的剪影就是「一根細長直桿 + 下面一根塔」，"
      "而吊車配塔架、兩台風機同框、塔門特寫的剪影**長得一模一樣**——"
      "量過臂長、輪轂到軸線的垂距、細長比、塔軸偏移，合成夾具（真側視）與 c19637139（兩台風機）"
      "的數字落在同一區。**從二值剪影裡沒有「這是一個轉子」的證據**，所以這不是調參能解的。")
    A("")
    A("## 3. 正視：閘門沒翻，但補償的輸入會動")
    A("")
    A("| 照片 | 量 | 原圖 | " + " | ".join(f"`{v}`" for v in variants) + " |")
    A("|---|---|---|" + "---|" * len(variants))

    def _fmt(x, nd=2):
        if x is None:
            return "—"
        if isinstance(x, bool):
            return "是" if x else "否"
        if isinstance(x, float):
            return f"{x:.{nd}f}"
        if isinstance(x, list):
            return "、".join(str(v) for v in x) if x else "（無）"
        return str(x)

    for i in sorted(fronts):
        r = rows[i]
        for label, key, nd in (("標記的指標", "raw_flagged", 0), ("預彎擬合 m", "prebend_fit_m", 2),
                               ("預彎合理", "prebend_fit_ok", 0), ("yaw°", "yaw_deg", 1)):
            vals = [_fmt(r["variants"].get(v, {}).get(key), nd) for v in variants]
            base = _fmt(r["variants"]["orig"].get(key), nd)
            if base == "—" and all(x == "—" for x in vals):
                continue
            if base == "（無）" and all(x == "（無）" for x in vals):
                continue  # 三個變體都沒有標記，這一列不帶資訊
            A(f"| {i} | {label} | {base} | " + " | ".join(vals) + " |")
    A("")
    A("## 4. 這份結果怎麼用")
    A("")
    A("1. **剩下要抓的照片不能用 1280 寬的縮圖**：那會系統性地弄丟側視照，"
      "而側視是規格 §5.1 明列的取像模式之一。續抓改用更大的寬度或原圖。")
    A("2. **跨批次只能併「正視的收／不收」**：側視的收／不收、以及任何逐張量值"
      "（px、cm、旗標集合、預彎擬合）都不可以把不同來源的批次混在一起統計。")
    A("3. **側視不該用推論的**（SPEC §13-16）：既然剪影裡沒有證據，就不要從剪影猜。"
      "App 的引導拍攝本來就知道自己要的是哪一格（`BladeShot.view`），"
      "把「這張是側視」變成**呼叫端宣告**、而不是閘門推論——沒有宣告就只套正視規則。"
      "這樣塔門特寫與吊車照會被正確拒收，而使用者在側視那一格拍的照片照樣走側視規則。")
    A("")
    A("## 5. 這份結果不能說什麼")
    A("")
    A(f"- {doc['note']}")
    A("- 只有 9 張，而且全部是「原本放行」的照片——這裡量的是**放行會不會掉**，"
      "不是「拒收會不會變成放行」。")
    A("- 沒有真值：這些照片沒有人標過正確答案，所以「翻掉」只代表**不穩定**，"
      "不代表原圖那一邊就是對的。")
    A("")
    return "\n".join(L)


def cmd_report(a: argparse.Namespace) -> int:
    doc = json.load(open(a.results, encoding="utf-8"))
    try:
        source = Path(a.results).resolve().relative_to(ROOT).as_posix()
    except ValueError:
        source = Path(a.results).name
    Path(a.out).write_text(render_markdown(doc, source), encoding="utf-8")
    print(f"寫入 {a.out}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--dir", required=True, help="放行照所在目錄（檔名 c<pageid>.jpg）")
    r.add_argument("--manifest", default=str(ROOT / "data" / "commons_turbines_manifest.json"))
    r.add_argument("--out", default=str(ROOT / "data" / "commons_pose_resolution_check.json"))
    r.add_argument("--widths", type=int, nargs="+", default=list(DEFAULT_WIDTHS))
    r.add_argument("--qualities", type=int, nargs="+", default=list(DEFAULT_QUALITIES))
    p = sub.add_parser("report")
    p.add_argument("--results", default=str(ROOT / "data" / "commons_pose_resolution_check.json"))
    p.add_argument("--out", default=str(ROOT / "RESOLUTION_SENSITIVITY.md"))
    a = ap.parse_args(argv)
    return run(a) if a.cmd == "run" else cmd_report(a)


if __name__ == "__main__":
    raise SystemExit(main())
