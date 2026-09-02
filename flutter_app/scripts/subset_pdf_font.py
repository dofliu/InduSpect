"""產生 PDF 報告內嵌字型子集：assets/fonts/NotoSansTC-Regular-subset.ttf

來源：Google Fonts 的 Noto Sans TC 可變字型（SIL Open Font License 1.1，見 assets/fonts/OFL.txt）
處理：固定 wght=400 → 子集化為 Big5 全部可解碼字元 + Latin/希臘/標點/單位符號
      → 移除 hinting 與 GSUB/GPOS 等版面表（PDF 嵌入用不到），約 12 MB → 4.9 MB。

用法（需 `pip install fonttools brotli`）：
    curl -L -o /tmp/NotoSansTC.ttf \
      "https://raw.githubusercontent.com/google/fonts/main/ofl/notosanstc/NotoSansTC%5Bwght%5D.ttf"
    python flutter_app/scripts/subset_pdf_font.py /tmp/NotoSansTC.ttf

`pdf` 套件輸出時會再依實際用到的字元做二次子集，所以 PDF 檔案本身不會包含整個 4.9 MB。
若報告出現「□」缺字，代表該字不在 Big5 範圍，可在 EXTRA_RANGES 補上區段後重新產生。
"""

import sys
from pathlib import Path

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

OUT = Path(__file__).resolve().parent.parent / "assets" / "fonts" / "NotoSansTC-Regular-subset.ttf"

EXTRA_RANGES = [
    (0x20, 0x7E), (0xA0, 0xFF),            # ASCII、Latin-1（° ± µ ×）
    (0x370, 0x3FF),                        # 希臘字母（Ω μ）
    (0x2000, 0x206F), (0x2070, 0x209F),    # 一般標點、上下標
    (0x20A0, 0x20CF), (0x2100, 0x214F),    # 貨幣、字母式符號（℃ ℉ №）
    (0x2150, 0x218F), (0x2190, 0x21FF),    # 數字形式、箭頭（→）
    (0x2200, 0x22FF), (0x2460, 0x24FF),    # 數學運算子（≥ ≤ ≈）、帶圈數字
    (0x2500, 0x257F), (0x25A0, 0x25FF),    # 製表符、幾何圖形
    (0x2600, 0x26FF), (0x2700, 0x27BF),    # 雜項符號、裝飾符號（✓ ✗ ⚠）
    (0x3000, 0x303F), (0x3040, 0x30FF),    # CJK 標點、假名
    (0xFE30, 0xFE4F), (0xFF00, 0xFFEF),    # 直排標點、全形字元
]


def big5_chars() -> set[str]:
    chars: set[str] = set()
    for hi in range(0xA1, 0xFA):
        for lo in list(range(0x40, 0x7F)) + list(range(0xA1, 0xFF)):
            try:
                chars.add(bytes([hi, lo]).decode("big5"))
            except UnicodeDecodeError:
                pass
    return chars


def main(src: str) -> None:
    variable = TTFont(src)
    static = instancer.instantiateVariableFont(variable, {"wght": 400}, inplace=False)

    chars = big5_chars()
    for a, b in EXTRA_RANGES:
        chars.update(chr(cp) for cp in range(a, b + 1))
    print(f"字元數：{len(chars)}")

    opts = subset.Options()
    opts.layout_features = []
    opts.drop_tables += ["BASE", "STAT", "vhea", "vmtx", "GDEF", "GPOS", "GSUB"]
    opts.name_IDs = ["*"]
    opts.notdef_outline = True
    opts.recalc_bounds = True
    opts.hinting = False
    opts.desubroutinize = True

    subsetter = subset.Subsetter(opts)
    subsetter.populate(text="".join(sorted(chars)))
    subsetter.subset(static)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    static.save(str(OUT))
    print(f"已輸出 {OUT}（{OUT.stat().st_size / 1024 / 1024:.1f} MB，{static['maxp'].numGlyphs} glyphs）")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("用法：python subset_pdf_font.py <NotoSansTC[wght].ttf>")
    main(sys.argv[1])
