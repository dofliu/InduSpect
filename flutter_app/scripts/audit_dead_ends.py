#!/usr/bin/env python3
"""死角查核（CI 守門）：讀寫兩端有沒有都接上。

兩個檢查，對應四輪查核抓到五個已出貨缺口的共同形狀——
**讀的那端接好了、寫的那端沒接、讀那端沒測試所以看不出來**：

1. callers  — `lib/services/*.dart` 的每個 public 方法／getter，全 `lib/` 有沒有任何引用。
              零引用 = 寫好了沒人叫（deleteWtAsset、saveWtDetections 那一類）。
2. columns  — `database_service.dart` 每張表的每個欄位，在 models/ 與 DB 層以外
              有沒有人寫、有沒有人讀。只讀不寫 = 永遠是預設值（pendingShare、
              capture_points、turbine_state 那一類）；只寫不讀 = 存了沒人用。

守門的姿態是**保守**：寧可漏報，不可誤攔。常見名字（title / status / model）在
寫端會被同名 widget 參數灌高，那只會讓真缺口被蓋住，不會製造假警報。

新發現只有兩條路：修掉，或寫進 `scripts/audit_allowlist.json` **附理由**。
allowlist 裡的條目若已經不再是發現（問題修好了），一樣會紅——名單不准長霉。

用法（在 flutter_app/ 下）：
    python3 scripts/audit_dead_ends.py            # 守門模式：有未列名單的發現就 exit 1
    python3 scripts/audit_dead_ends.py --report   # 全部列出（含已列名單），exit 0
    python3 scripts/audit_dead_ends.py --check columns
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent  # flutter_app/
LIB = ROOT / "lib"
MODELS = LIB / "models"
SERVICES = LIB / "services"
DB_FILE = SERVICES / "database_service.dart"
ALLOWLIST = ROOT / "scripts" / "audit_allowlist.json"

# 由 DB 層自己維護、不需要業務程式碼讀寫的欄位
FRAMEWORK_COLUMNS = {"id", "created_at", "updated_at"}

# 由 allowlist 的 skip_files 填入：整檔屬隱藏功能、不納入 callers 檢查
SKIP_FILES: set[str] = set()

# 宣告行開頭若是這些字，不是方法回傳型別
NOT_A_TYPE = {
    "return", "await", "factory", "final", "const", "var", "late", "static",
    "if", "else", "for", "while", "switch", "case", "throw", "new", "typedef",
    "class", "enum", "extension", "mixin", "import", "export", "part",
}


# ────────────────────────────── 共用 ──────────────────────────────

def dart_files(root: Path) -> list[Path]:
    return sorted(p for p in root.rglob("*.dart"))


def strip_comments(src: str) -> str:
    """去掉 // 與 /// 註解（保留換行以維持行號）。字串裡的 // 極少，接受誤刪。"""
    out = []
    for line in src.split("\n"):
        i = line.find("//")
        out.append(line if i < 0 else line[:i])
    return "\n".join(out)


def load_sources(root: Path) -> dict[Path, str]:
    return {p: strip_comments(p.read_text(encoding="utf-8", errors="replace"))
            for p in dart_files(root)}


# ────────────────────────────── ① callers ──────────────────────────────

DECL_RE = re.compile(
    r"^\s{2}(?:static\s+)?"            # 類別成員縱深 2 格；static 可有可無
    r"([A-Za-z_(][^=;]*?)\s+"          # 回傳型別（允許泛型／record，不跨 = ;）
    r"(get\s+)?"                       # getter
    r"([a-z]\w*)\s*"                   # public 名稱
    r"(\(|=>|\{)",                     # 方法有 (；getter 是 => 或 {
    re.M,
)


def public_members(path: Path, src: str) -> list[tuple[str, bool, int]]:
    """回傳 (name, is_getter, line_no)。跳過 @override / @visibleForTesting 與建構子。"""
    lines = src.split("\n")
    out = []
    for m in DECL_RE.finditer(src):
        rtype, getter, name, tail = m.group(1), m.group(2), m.group(3), m.group(4)
        first = rtype.split()[0].strip("(<")
        if first in NOT_A_TYPE:
            continue
        if not getter and tail != "(":
            continue  # `Type name =>` 不加 get 的不是方法（多半是 lambda 欄位）
        line_no = src.count("\n", 0, m.start()) + 1
        above = "\n".join(lines[max(0, line_no - 4): line_no - 1])
        if "@override" in above or "@visibleForTesting" in above:
            continue
        out.append((name, bool(getter), line_no))
    return out


def count_refs(name: str, src: str, exclude_decl_line: int | None) -> int:
    """在一份原始碼裡數對 name 的引用。呼叫、tear-off、屬性存取都算。"""
    if exclude_decl_line is not None:
        lines = src.split("\n")
        lines[exclude_decl_line - 1] = ""
        src = "\n".join(lines)
    return len(re.findall(r"(?<![\w$])" + re.escape(name) + r"(?![\w$])", src))


def check_callers(sources: dict[Path, str]) -> dict[str, str]:
    findings: dict[str, str] = {}
    for path in sorted(sources):
        if path.parent != SERVICES:
            continue
        if path.relative_to(ROOT).as_posix() in SKIP_FILES:
            continue
        src = sources[path]
        for name, is_getter, line_no in public_members(path, src):
            same_file = count_refs(name, src, line_no)
            others = sum(count_refs(name, s, None) for p, s in sources.items() if p != path)
            if same_file + others == 0:
                rel = path.relative_to(ROOT).as_posix()
                kind = "getter" if is_getter else "方法"
                findings[f"{rel}::{name}"] = f"{kind}零引用（L{line_no}）——寫好了沒人叫"
    return findings


# ────────────────────────────── ② columns ──────────────────────────────

TABLE_RE = re.compile(r"CREATE TABLE(?: IF NOT EXISTS)? (\w+)\s*\((.*?)\n\s*\)", re.S)


def tables(db_src: str) -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    for m in TABLE_RE.finditer(db_src):
        name, body = m.group(1), m.group(2)
        cols = []
        for raw in body.split("\n"):
            ln = raw.strip()
            if not ln or ln.startswith(("PRIMARY", "UNIQUE", "FOREIGN", "--", "CHECK")):
                continue
            cols.append(ln.split()[0].strip(","))
        merged = out.setdefault(name, [])
        for c in cols:
            if c not in merged:
                merged.append(c)
    return out


def camel(col: str) -> str:
    head, *rest = col.split("_")
    return head + "".join(p.capitalize() for p in rest)


def field_for(col: str, model_sources: dict[Path, str]) -> str | None:
    """欄位 → Dart 欄位名。先猜 camelCase 並驗證存在；不在就從 fromMap 反查。"""
    guess = camel(col)
    for src in model_sources.values():
        if re.search(r"\b" + re.escape(guess) + r"\b", src):
            return guess
    pat = re.compile(r"map\['" + re.escape(col) + r"'\]")
    for src in model_sources.values():
        m = pat.search(src)
        if not m:
            continue
        # 往回找最近的 `name:`，中間不能有深度 0 的逗號
        depth, i = 0, m.start() - 1
        while i >= 0:
            ch = src[i]
            if ch in ")]}":
                depth += 1
            elif ch in "([{":
                if depth == 0:
                    break
                depth -= 1
            elif ch == "," and depth == 0:
                break
            i -= 1
        seg = src[i + 1: m.start()]
        n = re.search(r"(\w+)\s*:", seg)
        if n:
            return n.group(1)
    return None


# 這些成員不算業務讀寫：toMap/toJson 被 DB 層叫、fromMap/fromJson 建物件、
# toString/hashCode/== 只是把欄位印出來或比對——任何地方一句 `.toString()` 都會命中，
# 若算進去等於把每個欄位都判成有人讀。
SERIALIZERS = {"toMap", "fromMap", "toJson", "fromJson", "copyWith",
               "toString", "hashCode", "props"}

STRING_LIT_RE = re.compile(r"'(?:[^'\\\n]|\\.)*'|\"(?:[^\"\\\n]|\\.)*\"")


def strip_strings(body: str) -> str:
    """把字串字面值挖空——`'field: $field'` 這種插值標籤不是寫入。"""
    return STRING_LIT_RE.sub("''", body)

MEMBER_RE = re.compile(
    r"^\s{2}(?:static\s+)?(?:[A-Za-z_(][^=;]*?)\s+(?:get\s+)?([a-zA-Z]\w*)\s*(\(|=>|\{)", re.M)


def member_bodies(src: str) -> dict[str, str]:
    """model 檔裡每個成員 → 它的本體文字（{…} 或 => …;）。給欄位讀寫的追蹤用。"""
    out: dict[str, str] = {}
    for m in MEMBER_RE.finditer(src):
        name, tail = m.group(1), m.group(2)
        i = m.end() - 1
        if tail == "(":
            # 跳過參數列，找到 { 或 =>
            depth, j = 0, i
            while j < len(src):
                if src[j] == "(":
                    depth += 1
                elif src[j] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            rest = src[j + 1:]
            k = re.match(r"\s*(?:async\*?\s*)?(\{|=>)", rest)
            if not k:
                continue  # 抽象宣告或建構子初始化列表，略過
            i = j + 1 + k.end() - 1
            tail = k.group(1)
        if tail == "{":
            depth, j = 0, i
            while j < len(src):
                if src[j] == "{":
                    depth += 1
                elif src[j] == "}":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            body = src[i:j + 1]
        else:  # =>
            j = src.find(";", i)
            body = src[i:j if j > 0 else len(src)]
        out[name] = body
    return out


def field_accessors(field: str, model_sources: dict[Path, str]) -> tuple[set[str], set[str]]:
    """哪些 model 成員會寫這個欄位、哪些會讀——含一層以上的轉呼叫（到不動點為止）。"""
    f = re.escape(field)
    writes_direct = re.compile(r"(?<![\w.])" + f + r"\s*:(?!:)|\b" + f + r"\s*=(?!=)")
    reads_direct = re.compile(r"\b" + f + r"\b")
    writers: set[str] = set()
    readers: set[str] = set()
    for src in model_sources.values():
        # 建構子（首字大寫）不算：業務端直接建構已由 `field:` 具名參數樣式數到，
        # 而初始化列表 `: field = field ?? []` 會讓每個欄位都看起來有人寫
        bodies = {n: strip_strings(b) for n, b in member_bodies(src).items()
                  if n not in SERIALIZERS and not n[0].isupper()}
        for name, body in bodies.items():
            if writes_direct.search(body):
                writers.add(name)
            if reads_direct.search(body):
                readers.add(name)
        # 轉呼叫：成員本體裡叫到 writer/reader 的，也算 writer/reader
        changed = True
        while changed:
            changed = False
            for name, body in bodies.items():
                for other in list(writers):
                    if name not in writers and re.search(r"\b" + re.escape(other) + r"\s*\(", body):
                        writers.add(name); changed = True
                for other in list(readers):
                    if name not in readers and re.search(r"\b" + re.escape(other) + r"\s*\(", body):
                        readers.add(name); changed = True
    # copyWith 本體會同時「讀舊值、寫新值」，但它只是搬運；業務端用 copyWith(field: …)
    # 已由直接寫入的 `field:` 樣式數到，不另算成員
    writers.discard("copyWith"); readers.discard("copyWith")
    return writers, readers


def check_columns(sources: dict[Path, str]) -> dict[str, str]:
    findings: dict[str, str] = {}
    db_src = sources[DB_FILE]
    model_sources = {p: s for p, s in sources.items() if p.parent == MODELS}
    business = {p: s for p, s in sources.items()
                if p.parent != MODELS and p != DB_FILE}

    for table, cols in tables(db_src).items():
        for col in cols:
            if col in FRAMEWORK_COLUMNS:
                continue
            field = field_for(col, model_sources)
            key = f"{table}.{col}"
            if field is None:
                findings[key] = "對不到 model 欄位（改名了？fromMap 沒讀它？）"
                continue
            f = re.escape(field)
            writer_methods, reader_methods = field_accessors(field, model_sources)
            writes = reads = 0
            for src in business.values():
                writes += len(re.findall(r"\." + f + r"\s*=(?!=)", src))       # x.field = …
                writes += len(re.findall(r"(?<![\w.])" + f + r":\s", src))      # Ctor(field: …)
                reads += len(re.findall(r"\." + f + r"\b(?!\s*=(?!=))", src))  # x.field
                for m in writer_methods:                                        # x.writerMethod(
                    writes += len(re.findall(r"\." + re.escape(m) + r"\s*\(", src))
                for m in reader_methods:                                        # x.readerMethod(
                    reads += len(re.findall(r"\." + re.escape(m) + r"\b", src))
            if writes == 0 and reads == 0:
                findings[key] = f"欄位 `{field}` 在 lib/ 完全沒人碰"
            elif writes == 0:
                findings[key] = f"欄位 `{field}` 只讀不寫——永遠是預設值"
            elif reads == 0:
                findings[key] = f"欄位 `{field}` 只寫不讀——存了沒人用"
    return findings


# ────────────────────────────── 主流程 ──────────────────────────────

def load_allowlist(path: Path) -> dict[str, dict[str, str]]:
    if not path.exists():
        return {"callers": {}, "columns": {}, "skip_files": {}}
    data = json.loads(path.read_text(encoding="utf-8"))
    for k in ("callers", "columns", "skip_files"):
        data.setdefault(k, {})
        if not isinstance(data[k], dict):
            sys.exit(f"allowlist 的 {k} 必須是 {{id: 理由}} 的物件")
        for ident, reason in data[k].items():
            if not isinstance(reason, str) or len(reason.strip()) < 8:
                sys.exit(f"allowlist 條目 {ident!r} 要有理由（至少一句話）")
    return data


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", choices=["callers", "columns", "all"], default="all")
    ap.add_argument("--report", action="store_true", help="全部列出（含已列名單），不當守門")
    ap.add_argument("--allowlist", type=Path, default=ALLOWLIST)
    args = ap.parse_args()

    sources = load_sources(LIB)
    allow = load_allowlist(args.allowlist)

    failed = False
    SKIP_FILES.update(allow["skip_files"])
    for rel in allow["skip_files"]:
        if not (ROOT / rel).exists():
            failed = True
            print(f"   ✗ allowlist 過期：skip_files 的 {rel} 已不存在，請移除")
    if allow["skip_files"]:
        print(f"── skip_files: {len(allow['skip_files'])} 個檔案整檔放行（隱藏功能）")
        if args.report:
            for rel, why in allow["skip_files"].items():
                print(f"   {rel}  {why}")
        print()

    checks = {"callers": check_callers, "columns": check_columns}
    if args.check != "all":
        checks = {args.check: checks[args.check]}

    for kind, fn in checks.items():
        findings = fn(sources)
        listed = allow.get(kind, {})
        new = {k: v for k, v in findings.items() if k not in listed}
        stale = [k for k in listed if k not in findings]

        print(f"── {kind}: {len(findings)} 個發現，{len(findings) - len(new)} 個已列名單，{len(new)} 個新的")
        if args.report:
            for k in sorted(findings):
                tag = "（已列名單）" if k in listed else "  ← 新"
                print(f"   {k}  {findings[k]}{tag}")
        else:
            for k in sorted(new):
                print(f"   ✗ {k}  {findings[k]}")
                print(f'       要放行就在 scripts/audit_allowlist.json 的 "{kind}" 加：  "{k}": "<理由>",')
        if new:
            failed = True
        for k in stale:
            failed = True
            print(f"   ✗ allowlist 過期：{k} 已經不是發現（問題修好了？請把它從名單移除）")
        print()

    if args.report:
        return 0
    if failed:
        print("死角查核未通過：新發現要修掉或附理由列名單；過期條目要移除。", file=sys.stderr)
        return 1
    print("死角查核通過。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
