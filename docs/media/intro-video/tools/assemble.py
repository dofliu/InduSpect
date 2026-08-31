#!/usr/bin/env python3
"""以 ffmpeg 將投影片 PNG 合成為 180 秒 1080p 影片（含交叉淡入與緩慢推近）。

4K 來源 → 1080p 輸出，降採樣讓文字保持銳利。
"""

import subprocess
import sys
from pathlib import Path

import imageio_ffmpeg

# Playwright 內建 ffmpeg 是精簡版（只有 VP8/WebM，無 libx264/xfade/zoompan，
# 連 PNG 解碼都沒有）→ 改用 imageio-ffmpeg 提供的完整靜態版
FFMPEG = imageio_ffmpeg.get_ffmpeg_exe()
FRAMES = Path(sys.argv[1] if len(sys.argv) > 1 else "./frames")
OUT = Path(sys.argv[2] if len(sys.argv) > 2 else "./InduSpect_intro_3min.mp4")

FPS = 30
T = 0.6  # 交叉淡入秒數
# 每張投影片的「顯示秒數」，總和 = 180
DURATIONS = [12, 18, 18, 20, 20, 18, 16, 18, 18, 14, 8]

slides = sorted(FRAMES.glob("slide-*.png"))
assert slides, f"{FRAMES} 沒有投影片"
assert len(slides) == len(DURATIONS), f"投影片 {len(slides)} 張 ≠ 秒數表 {len(DURATIONS)} 筆"
n = len(slides)

# 鏈式 xfade：總長 = Σ L_i − (n−1)·T
# 令 L_i = d_i + T（最後一張 L = d），則總長 = Σd = 180，且第 k 次轉場 offset = Σ_{i≤k} d_i
lengths = [d + T for d in DURATIONS[:-1]] + [DURATIONS[-1]]

cmd = [FFMPEG, "-y"]
for path, L in zip(slides, lengths):
    cmd += ["-loop", "1", "-t", f"{L:.3f}", "-i", str(path)]

parts = []
for i, L in enumerate(lengths):
    frames = max(int(L * FPS), 2)
    # 緩慢推近 3.5%：來源 3840×2160 裁切後降採樣到 1080p，文字不會軟掉
    zoom_rate = 0.035 / frames
    parts.append(
        f"[{i}:v]fps={FPS},"
        f"zoompan=z='min(1+{zoom_rate:.8f}*on\\,1.035)'"
        f":x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=1920x1080,"
        f"setsar=1,format=yuv420p[v{i}]"
    )

prev = "v0"
cum = 0
for k in range(1, n):
    cum += DURATIONS[k - 1]
    out = f"x{k}"
    parts.append(
        f"[{prev}][v{k}]xfade=transition=fade:duration={T}:offset={cum}[{out}]"
    )
    prev = out

filtergraph = ";".join(parts)
cmd += [
    "-filter_complex", filtergraph,
    "-map", f"[{prev}]",
    "-r", str(FPS),
    "-c:v", "libx264",
    "-preset", "slow",
    # stillimage 針對投影片型內容最佳化；CRF 25 在 1080p 文字畫面仍銳利，
    # 檔案可壓到 30 MB 以下便於直接傳送
    "-tune", "stillimage",
    "-crf", "25",
    "-pix_fmt", "yuv420p",
    "-movflags", "+faststart",
    "-t", str(sum(DURATIONS)),  # 精確切齊 180 秒
    str(OUT),
]

print(f"投影片 {n} 張，預期總長 {sum(DURATIONS)} 秒 → {OUT}")
res = subprocess.run(cmd, capture_output=True, text=True)
if res.returncode != 0:
    print("FFMPEG 失敗：")
    print(res.stderr[-3000:])
    sys.exit(1)

# 驗證輸出長度
probe = subprocess.run(
    [FFMPEG, "-i", str(OUT)], capture_output=True, text=True
).stderr
for line in probe.splitlines():
    if "Duration" in line or "Stream #0" in line:
        print(" ", line.strip())
print(f"✓ 完成：{OUT}  ({OUT.stat().st_size / 1024 / 1024:.1f} MB)")
