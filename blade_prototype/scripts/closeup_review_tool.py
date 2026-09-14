#!/usr/bin/env python3
"""Mode B 人工複核工具：把第一版標記變成可被人簽核的東西。

`CLOSEUP_HEALTHY_SET.md` 產出的三份東西全部是**單一標註者（模型）的第一版、沒有人複核過**：
約 1,200 格健康候選（`unreviewed`）、6 張 `x`（陰影／反光）要在全解析度複核、19 個概略框（`pending`）。
在有人看過並簽名之前，它們一筆都不能進訓練集或測試集（分類表判定順序第 7 條）。

這支腳本做的是**讓那件事可以被執行**：

    build   從語料與 manifest 產一份離線複核工作區（切圖 + 單檔 HTML，鍵盤操作，可中斷續做）
    ingest  把人匯出的決策併進版控中的決策檔，並在併入前擋掉不合格的簽核
    status  報「還差多少」，以及哪些決策因為候選重新產生而失效

四條不可退化的約定（每一條都有測試守）：

1. **升格一定要人名。** `healthy`／`confirmed` 只能由人給。`annotator` 長得像模型
   （`claude*`／`gpt*`／`model*`／空的）一律拒絕整批匯入——第一版標記的 `claude-first-pass`
   不可以經由這條路變成簽核。
2. **跳過 ≠ 乾淨。** 沒決策的、按 s 跳過的都不寫進決策檔，維持 `unreviewed`。
   「兩位標註者都沒框」本來就不等於確認乾淨，複核工具不可以把「沒看」再變成一次「沒問題」。
3. **不得在縮圖上簽核。** 每筆決策記下當下的顯示倍率 `view_scale`（顯示 px ÷ 原圖 px），
   倍率 < 1.0 的**升格**在匯入時被擋下。來由是 654 那張：印樣上看成硬邊陰影，
   全解析度看是葉片與天空的邊界。
4. **決策綁在像素上。** `item_id` 是 queue 與座標的雜湊；候選用不同 `--tile/--margin` 重新產生後，
   對不上的決策會被 `status` 列為失效，不會被默默套到別的像素上。

用法：

    python scripts/closeup_review_tool.py build <語料根目錄> <工作區目錄> [--manifest out/healthy_candidates.json]
    # 用瀏覽器開 <工作區目錄>/review.html，做完按「匯出決策」
    python scripts/closeup_review_tool.py ingest <下載的 decisions.json> --items <工作區目錄>/items.json --annotator "你的名字"
    python scripts/closeup_review_tool.py status --items <工作區目錄>/items.json
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import random
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INTAKE = ROOT / "data" / "closeup_intake_wtb.json"
NS = ROOT / "data" / "closeup_normal_structures_wtb.json"
BOXES = ROOT / "data" / "closeup_normal_structure_boxes_wtb.json"
DECISIONS = ROOT / "data" / "closeup_review_decisions.json"
FIRSTPASS = ROOT / "data" / "closeup_healthy_firstpass_wtb.json"

DECISIONS_VERSION = "b1-2026-09-14"

# 看起來像模型或沒填的標註者名字。第一版標記用的 claude-first-pass 就在這裡被擋住。
MODEL_ANNOTATOR = re.compile(r"^\s*$|claude|gpt|gemini|llm|model|bot|auto|first[-_]?pass", re.I)

# 每個佇列宣告「yes 是什麼意思」，以及 no 的理由碼。
QUEUES: dict[str, dict] = {
    "healthy": dict(
        title="健康候選格",
        question="這 256 px 是葉片表面，而且看起來乾淨嗎？",
        yes_label="是葉片表面且乾淨",
        yes_status="healthy",
        reasons={
            "not_blade": "不是葉片表面（天空／地景／工具）",
            "has_defect": "是葉片表面，但有疑似缺陷",
            "unusable": "判不了（過曝／模糊／被塗抹）",
        },
        note="兩位標註者都沒框 ≠ 確認乾淨。這裡的 yes 才是 healthy 的唯一來源。",
    ),
    "ns_recheck": dict(
        title="x（陰影／反光）全解析度複核",
        question="Pass 2 在印樣上標的 shadow_and_specular，在全解析度上成立嗎？",
        yes_label="標記正確（確實是陰影／反光）",
        yes_status="confirmed",
        reasons={
            "not_shadow": "不是陰影／反光，是別的東西",
            "is_defect": "其實是缺陷",
            "boundary": "是葉片與背景的邊界（654 那類）",
        },
        note="654 已知判錯並改過；其餘 6 張沒重看過。",
    ),
    "boxes": dict(
        title="概略框複核",
        question="這個框的位置與類別都對嗎？",
        yes_label="位置與類別都對",
        yes_status="confirmed",
        reasons={
            "wrong_kind": "類別錯",
            "bad_box": "框的位置或範圍錯",
            "not_present": "畫面裡沒有這個東西",
        },
        note="框是概略的（approx=true），簽核代表「可用作起點」不是「像素級精確」。",
    ),
}

DECISION_VALUES = ("yes", "no", "uncertain")
STATUS_OF_DECISION = {"no": "rejected", "uncertain": "uncertain"}


def item_id(queue: str, image: str, region: tuple[int, int, int, int], extra: str = "") -> str:
    """決策的身分。座標變了就是另一筆，不會被默默沿用。"""
    key = f"{queue}|{image}|{region[0]},{region[1]},{region[2]},{region[3]}|{extra}"
    return hashlib.sha1(key.encode("utf-8")).hexdigest()[:16]


def fingerprint(items: list[dict]) -> str:
    """整份工作區的指紋，讓匯入知道決策是對哪一批候選做的。"""
    h = hashlib.sha1()
    for it in items:
        h.update(it["item_id"].encode("ascii"))
    return h.hexdigest()[:16]


def _now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


# --------------------------------------------------------------------------
# build
# --------------------------------------------------------------------------

def collect_healthy_items(manifest: dict, bg: set[str], limit: int | None, seed: int) -> list[dict]:
    tiles = [t for t in manifest["tiles"] if t["bg_guess"] in bg]
    # 排序穩定（影像編號、座標），限量時才隨機抽，否則每次 build 的順序一樣，續做才接得上。
    tiles.sort(key=lambda t: (int(t["image"].removesuffix(".jpg")), t["y"], t["x"]))
    if limit is not None and len(tiles) > limit:
        tiles = sorted(random.Random(seed).sample(tiles, limit),
                       key=lambda t: (int(t["image"].removesuffix(".jpg")), t["y"], t["x"]))
    out = []
    for t in tiles:
        region = (t["x"], t["y"], t["w"], t["h"])
        out.append(dict(
            item_id=item_id("healthy", t["image"], region),
            queue="healthy", image=t["image"], region=list(region),
            bg_guess=t["bg_guess"], artifact_tags=t.get("image_artifact_tags") or "",
            caption=f"{t['image']} @{t['x']},{t['y']}｜bg_guess={t['bg_guess']}"
                    f"{'｜影像帶痕跡 ' + t['image_artifact_tags'] if t.get('image_artifact_tags') else ''}",
            overlay=None,
        ))
    return out


def apply_firstpass_prior(items: list[dict], firstpass: dict) -> dict:
    """第一遍標記只做兩件事：把先驗掛上去、把最可能是葉片表面的排前面。

    它**不寫任何決策**——`claude-first-pass` 在 MODEL_ANNOTATOR 黑名單裡，本來就進不了決策檔。
    這裡刻意只碰順序與顯示欄位，讓「誰有權說 healthy」不因為有了先驗而改變。
    """
    prior = {t["item_id"]: t["code"] for t in firstpass["tiles"]}
    rank = firstpass["meta"].get("priority") or {}
    hit = 0
    for it in items:
        if it["queue"] != "healthy":
            continue
        code = prior.get(it["item_id"])
        if code is None:
            continue
        hit += 1
        it["prior"] = code
        it["prior_annotator"] = firstpass["meta"]["annotator"]
        it["caption"] += f"｜第一遍 {code}（{firstpass['meta']['vocabulary'].get(code, '')}，未複核）"
    order = {id(it): i for i, it in enumerate(items)}
    items.sort(key=lambda it: (it["queue"] != "healthy",
                               rank.get(it.get("prior"), len(rank)),
                               order[id(it)]))
    return dict(matched=hit, missing=sum(1 for it in items
                                         if it["queue"] == "healthy" and "prior" not in it))


def collect_ns_recheck_items(ns: dict) -> list[dict]:
    out = []
    for idx, codes in sorted(ns["labels"].items(), key=lambda kv: int(kv[0])):
        if "x" not in codes:
            continue
        image = f"{idx}.jpg"
        # 整張看，region 由 build 時的實際尺寸補上。
        out.append(dict(item_id=None, queue="ns_recheck", image=image, region=None,
                        caption=f"{image}｜Pass 2 代碼「{codes}」，其中 x = shadow_and_specular",
                        overlay=None))
    return out


def collect_box_items(boxes: dict) -> list[dict]:
    out = []
    for b in boxes["boxes"]:
        if b["bbox"] is None:
            continue
        x1, y1, x2, y2 = b["bbox"]
        out.append(dict(item_id=None, queue="boxes", image=b["image"], region=None,
                        bbox=[x1, y1, x2, y2], kind=b["kind"],
                        caption=f"{b['image']}｜{b['kind']}｜{b.get('note', '')}",
                        overlay=None))
    return out


def build(args: argparse.Namespace) -> int:
    import cv2  # 只有 build 需要 OpenCV；ingest／status 在沒有語料的機器上也要能跑

    ds = Path(args.dataset)
    out = Path(args.out)
    (out / "crops").mkdir(parents=True, exist_ok=True)
    (out / "context").mkdir(parents=True, exist_ok=True)

    queues = list(QUEUES) if args.queue == "all" else [args.queue]
    items: list[dict] = []

    if "healthy" in queues:
        manifest_path = Path(args.manifest) if args.manifest else None
        if manifest_path is None or not manifest_path.exists():
            raise SystemExit("healthy 佇列需要 --manifest 指向 closeup_healthy_candidates.py 的 healthy_candidates.json")
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        items += collect_healthy_items(manifest, set(args.bg.split(",")), args.limit, args.seed)
    if "ns_recheck" in queues:
        items += collect_ns_recheck_items(json.loads(NS.read_text(encoding="utf-8")))
    if "boxes" in queues:
        items += collect_box_items(json.loads(BOXES.read_text(encoding="utf-8")))

    prior_stats = None
    fp_path = Path(args.firstpass) if args.firstpass else FIRSTPASS
    if not args.no_firstpass and fp_path.exists():
        prior_stats = apply_firstpass_prior(items, json.loads(fp_path.read_text(encoding="utf-8")))
        prior_stats["source"] = str(fp_path)

    kept: list[dict] = []
    contexts: set[str] = set()
    for it in items:
        src = ds / "JPEGImages" / it["image"]
        img = cv2.imread(str(src))
        if img is None:
            continue
        H, W = img.shape[:2]
        if it["queue"] == "healthy":
            x, y, w, h = it["region"]
        elif it["queue"] == "ns_recheck":
            x, y, w, h = 0, 0, W, H
            it["region"] = [x, y, w, h]
        else:  # boxes：框外擴 15% 當上下文，但決策綁的是框本身的座標
            x1, y1, x2, y2 = it["bbox"]
            pad = int(0.15 * max(x2 - x1, y2 - y1))
            x, y = max(0, x1 - pad), max(0, y1 - pad)
            w, h = min(W, x2 + pad) - x, min(H, y2 + pad) - y
            it["region"] = [x1, y1, x2 - x1, y2 - y1]
            it["overlay"] = [x1 - x, y1 - y, x2 - x1, y2 - y1]  # 相對切圖的框，HTML 用來畫
        it["item_id"] = item_id(it["queue"], it["image"], tuple(it["region"]),
                                it.get("kind", ""))
        crop = img[y:y + h, x:x + w]
        if crop.size == 0:
            continue
        it["crop"] = f"crops/{it['item_id']}.jpg"
        it["crop_size"] = [int(crop.shape[1]), int(crop.shape[0])]
        cv2.imwrite(str(out / it["crop"]), crop, [cv2.IMWRITE_JPEG_QUALITY, 94])

        # 上下文：整張縮到長邊 512，HTML 在上面畫出這一格的位置。
        ctx_name = f"context/{it['image'].removesuffix('.jpg')}.jpg"
        if it["image"] not in contexts:
            scale = 512.0 / max(H, W)
            ctx = cv2.resize(img, (max(1, int(W * scale)), max(1, int(H * scale))), interpolation=cv2.INTER_AREA)
            cv2.imwrite(str(out / ctx_name), ctx, [cv2.IMWRITE_JPEG_QUALITY, 82])
            contexts.add(it["image"])
        it["context"] = ctx_name
        it["context_scale"] = round(512.0 / max(H, W), 6)
        it["image_size"] = [int(W), int(H)]
        it.pop("bbox", None)
        kept.append(it)

    meta = dict(
        version=DECISIONS_VERSION,
        built_at=_now(),
        dataset=str(ds),
        queues={q: QUEUES[q] for q in queues},
        n_items=len(kept),
        fingerprint=fingerprint(kept),
        firstpass=prior_stats,
        note="決策要經 ingest 才進版控。跳過的不寫。升格要人名、要 1:1。"
             "第一遍標記只排順序，不是決策。",
    )
    (out / "items.json").write_text(json.dumps(dict(meta=meta, items=kept), ensure_ascii=False, indent=1),
                                    encoding="utf-8")
    html = _render_html(meta, kept)
    (out / "review.html").write_text(html, encoding="utf-8")

    by_queue: dict[str, int] = {}
    for it in kept:
        by_queue[it["queue"]] = by_queue.get(it["queue"], 0) + 1
    print(json.dumps(dict(out=str(out), n_items=len(kept), by_queue=by_queue,
                          fingerprint=meta["fingerprint"],
                          open=f"file://{(out / 'review.html').resolve()}"),
                     ensure_ascii=False, indent=1))
    return 0


def _render_html(meta: dict, items: list[dict]) -> str:
    tpl = (Path(__file__).parent / "closeup_review_tool.html").read_text(encoding="utf-8")
    return (tpl
            .replace("/*__META__*/null", json.dumps(meta, ensure_ascii=False))
            .replace("/*__ITEMS__*/null", json.dumps(items, ensure_ascii=False)))


# --------------------------------------------------------------------------
# ingest
# --------------------------------------------------------------------------

class IngestError(Exception):
    pass


def validate_annotator(name: str | None) -> str:
    if name is None or MODEL_ANNOTATOR.match(name or ""):
        raise IngestError(
            f"annotator「{name}」看起來不是人。升格一定要人名——第一版標記是 claude-first-pass，"
            "不可以經由匯入變成簽核。")
    return name.strip()


def merge_decisions(existing: dict, exported: dict, items_index: dict[str, dict],
                    annotator: str, *, items_fp: str) -> tuple[dict, dict]:
    """把一批匯出的決策併進決策檔。回傳 (新的決策檔, 統計)。

    擋下三種東西：認不得的 item_id、縮圖上做的升格、非決策值。跳過的本來就不會出現在匯出裡。
    """
    entries = {e["item_id"]: e for e in existing.get("entries", [])}
    stats = dict(accepted=0, updated=0, rejected_unknown_item=0, rejected_low_scale=0, skipped_no_decision=0)
    for row in exported.get("decisions", []):
        iid = row.get("item_id")
        it = items_index.get(iid)
        if it is None:
            stats["rejected_unknown_item"] += 1
            continue
        decision = row.get("decision")
        if decision not in DECISION_VALUES:
            stats["skipped_no_decision"] += 1
            continue
        scale = float(row.get("view_scale") or 0.0)
        status = QUEUES[it["queue"]]["yes_status"] if decision == "yes" else STATUS_OF_DECISION[decision]
        if decision == "yes" and scale < 1.0:
            # 654 的教訓寫成規則：縮圖上看到的不算數。
            stats["rejected_low_scale"] += 1
            continue
        reason = row.get("reason") or None
        if reason is not None and reason not in QUEUES[it["queue"]]["reasons"]:
            reason = None
        prev = entries.get(iid)
        entry = dict(
            item_id=iid, queue=it["queue"], image=it["image"], region=it["region"],
            decision=decision, human_status=status, reason=reason,
            annotator=annotator, decided_at=row.get("decided_at") or _now(),
            view_scale=round(scale, 3), items_fingerprint=items_fp,
            revision=(prev["revision"] + 1) if prev else 1,
        )
        entries[iid] = entry
        stats["updated" if prev else "accepted"] += 1

    merged = dict(existing)
    merged["version"] = DECISIONS_VERSION
    merged["updated_at"] = _now()
    merged["entries"] = [entries[k] for k in sorted(entries)]
    return merged, stats


def _empty_decisions() -> dict:
    return dict(
        version=DECISIONS_VERSION,
        note="Mode B 人工複核的決策。由 scripts/closeup_review_tool.py ingest 寫入，"
             "每一筆都帶簽核人與當下的顯示倍率。沒有決策的候選維持 unreviewed——跳過不等於乾淨。",
        rules=[
            "healthy／confirmed 只能由人給；annotator 長得像模型的整批拒絕。",
            "跳過與未看的不寫進來。",
            "顯示倍率 < 1.0 的升格不收（654：印樣上判錯過）。",
            "item_id 綁座標；候選重新產生後對不上的由 status 列為失效，不會被沿用。",
        ],
        entries=[],
    )


def load_decisions(path: Path) -> dict:
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return _empty_decisions()


def ingest(args: argparse.Namespace) -> int:
    items_doc = json.loads(Path(args.items).read_text(encoding="utf-8"))
    index = {it["item_id"]: it for it in items_doc["items"]}
    out_path = Path(args.decisions_file)
    doc = load_decisions(out_path)
    total = dict(accepted=0, updated=0, rejected_unknown_item=0, rejected_low_scale=0, skipped_no_decision=0)
    for p in args.exported:
        exported = json.loads(Path(p).read_text(encoding="utf-8"))
        annotator = validate_annotator(args.annotator or exported.get("annotator"))
        doc, stats = merge_decisions(doc, exported, index, annotator,
                                     items_fp=items_doc["meta"]["fingerprint"])
        for k, v in stats.items():
            total[k] += v
    if not args.dry_run:
        out_path.write_text(json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf-8")
    total["entries_total"] = len(doc["entries"])
    print(json.dumps(total, ensure_ascii=False, indent=1))
    return 0


# --------------------------------------------------------------------------
# status
# --------------------------------------------------------------------------

def summarise_status(items_doc: dict | None, decisions: dict) -> dict:
    from collections import Counter
    entries = decisions.get("entries", [])
    by_status = Counter(e["human_status"] for e in entries)
    by_queue = Counter(e["queue"] for e in entries)
    out = dict(
        entries=len(entries),
        by_human_status=dict(by_status.most_common()),
        by_queue=dict(by_queue.most_common()),
        annotators=sorted({e["annotator"] for e in entries}),
    )
    if items_doc is not None:
        index = {it["item_id"] for it in items_doc["items"]}
        q_total = Counter(it["queue"] for it in items_doc["items"])
        decided = Counter(e["queue"] for e in entries if e["item_id"] in index)
        out["remaining"] = {q: q_total[q] - decided.get(q, 0) for q in sorted(q_total)}
        out["stale_entries"] = sorted(e["item_id"] for e in entries if e["item_id"] not in index)
        # 有第一遍先驗時，「還差多少」照先驗拆開：先看完 b 才是把最可能有用的那批看完。
        done = {e["item_id"] for e in entries}
        priors = [it for it in items_doc["items"] if it.get("prior")]
        if priors:
            left = Counter(it["prior"] for it in priors if it["item_id"] not in done)
            out["remaining_by_prior"] = {c: left.get(c, 0)
                                         for c in sorted({it["prior"] for it in priors})}
    return out


def status(args: argparse.Namespace) -> int:
    items_doc = json.loads(Path(args.items).read_text(encoding="utf-8")) if args.items else None
    decisions = load_decisions(Path(args.decisions_file))
    summary = summarise_status(items_doc, decisions)
    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=1))
        return 0
    print(f"決策 {summary['entries']} 筆，簽核人 {summary['annotators'] or '（無）'}")
    for k, v in summary["by_human_status"].items():
        print(f"  {k}: {v}")
    if "remaining" in summary:
        print("還沒看的：")
        for q, n in summary["remaining"].items():
            print(f"  {q}: {n}")
        if summary.get("remaining_by_prior"):
            per = "、".join(f"{c} {n}" for c, n in summary["remaining_by_prior"].items())
            print(f"  （healthy 依第一遍先驗，未複核：{per}）")
        if summary["stale_entries"]:
            print(f"失效決策（候選已重新產生，對不上像素）：{len(summary['stale_entries'])} 筆")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Mode B 人工複核工作區")
    sub = ap.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build", help="產離線複核工作區")
    b.add_argument("dataset", help="語料根目錄（含 JPEGImages/）")
    b.add_argument("out", help="工作區輸出目錄")
    b.add_argument("--manifest", help="healthy_candidates.json（healthy 佇列需要）")
    b.add_argument("--queue", default="all", choices=list(QUEUES) + ["all"])
    b.add_argument("--bg", default="blade_like", help="healthy 佇列要哪些 bg_guess，逗號分隔")
    b.add_argument("--limit", type=int, default=None, help="healthy 佇列最多幾格")
    b.add_argument("--seed", type=int, default=7)
    b.add_argument("--firstpass", default=None,
                   help="第一遍標記檔（預設 data/closeup_healthy_firstpass_wtb.json，只用來排序）")
    b.add_argument("--no-firstpass", action="store_true", help="不套第一遍先驗，照座標順序排")
    b.set_defaults(func=build)

    i = sub.add_parser("ingest", help="把匯出的決策併進版控中的決策檔")
    i.add_argument("exported", nargs="+", help="瀏覽器匯出的 decisions.json")
    i.add_argument("--items", required=True, help="工作區的 items.json")
    i.add_argument("--annotator", default=None, help="簽核人姓名（覆蓋匯出檔裡的）")
    i.add_argument("--decisions-file", default=str(DECISIONS))
    i.add_argument("--dry-run", action="store_true")
    i.set_defaults(func=ingest)

    s = sub.add_parser("status", help="還差多少")
    s.add_argument("--items", default=None)
    s.add_argument("--decisions-file", default=str(DECISIONS))
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=status)

    args = ap.parse_args(argv)
    try:
        return args.func(args)
    except IngestError as e:
        print(f"匯入被擋下：{e}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
