"""產生影像基本運算的逐項對照參考值（給 Flutter 端的 `blade_image_ops.dart`）。

輸入全部是**由公式決定的小陣列**（不是影像檔），所以 Dart 端可以自己重建同樣的
輸入，夾具裡只存 Python 用 OpenCV 算出來的答案。這樣某個運算寫錯時，
會在它自己那一條測試紅掉，而不是變成整條管線最後對不上的一個數字。

改動任一運算的實作後要重跑：

    cd blade_prototype && python scripts/make_image_ops_fixture.py
"""
import json
import os

import cv2
import numpy as np

OUT = os.path.join(os.path.dirname(__file__), '..', '..',
                   'flutter_app', 'test', 'assets')


def ramp_plus_blobs(w, h, ch):
    """由座標決定的圖樣：斜坡 + 幾個方塊 + 一條細線。Dart 端用同一條公式重建。"""
    a = np.zeros((h, w, ch), np.uint8)
    for y in range(h):
        for x in range(w):
            for c in range(ch):
                v = (x * 3 + y * 5 + c * 17) % 200 + 20
                a[y, x, c] = v
    a[h // 4: h // 4 + 6, w // 4: w // 4 + 6] = 250      # 亮方塊
    a[h // 2: h // 2 + 4, w // 2: w // 2 + 10] = 5       # 暗方塊
    a[:, w - 3: w - 2] = 240                              # 細線（中值要抹掉它）
    return a


def line_and_hole_mask(w, h):
    m = np.zeros((h, w), np.uint8)
    m[2:h - 2, 3] = 255                    # 1 px 細線：close 不該把它變粗到消失
    m[4:12, 6:14] = 255                    # 方塊
    m[7:9, 9:11] = 0                       # 中間挖洞：close 要補起來
    m[h - 3, w - 3] = 255                  # 孤立點
    m[1, 1] = 255                          # 角落點（測邊界）
    return m


def three_blobs_mask(w, h):
    m = np.zeros((h, w), np.uint8)
    m[1:5, 1:5] = 255
    m[1:3, 6:12] = 255                     # 寬而矮
    m[8:14, 2:4] = 255
    m[10, 5] = 255                         # 孤立單點，離上一塊 2 px（測不可過度合併）
    return m


ref = {
    '_readme': [
        '影像基本運算的逐項對照參考值，由 blade_prototype 用 OpenCV 產生。',
        '輸入是公式決定的小陣列，Dart 端自行重建；此檔只存答案。',
        '改動實作後重跑 scripts/make_image_ops_fixture.py。',
    ],
}

# ---- 1. 大核中值（網格模式）
w, h, ch, k, step = 40, 32, 3, 11, 8
src = ramp_plus_blobs(w, h, ch)
full = cv2.medianBlur(src, k).astype(np.float32)
xs = list(range(0, w, step))
if xs[-1] != w - 1:
    xs.append(w - 1)
ys = list(range(0, h, step))
if ys[-1] != h - 1:
    ys.append(h - 1)
ref['median_grid'] = {
    'w': w, 'h': h, 'channels': ch, 'k': k, 'step': step,
    'grid_xs': xs, 'grid_ys': ys,
    # 網格點上的真中值（Dart 只算這些點，值必須一模一樣）
    'coarse': [[int(v) for v in full[y, x]] for y in ys for x in xs],
    # 內插後幾個取樣點
    'samples': {f'{x},{y}': None for x, y in
                [(0, 0), (w - 1, h - 1), (5, 5), (20, 16), (39, 3), (7, 31)]},
}
# 內插（與 Dart 同一套「真實網格座標」邏輯）
coarse = full[np.ix_(ys, xs)]
def interp(coarse, xs, ys, w, h):
    xs, ys = np.array(xs), np.array(ys)
    def wts(coords, n):
        idx = np.searchsorted(coords, np.arange(n), side='right') - 1
        idx = np.clip(idx, 0, len(coords) - 2)
        lo, hi = coords[idx], coords[idx + 1]
        return idx, ((np.arange(n) - lo) / np.maximum(hi - lo, 1)).astype(np.float32)
    ix, tx = wts(xs, w)
    iy, ty = wts(ys, h)
    top = coarse[iy][:, ix] * (1 - tx)[None, :, None] + coarse[iy][:, ix + 1] * tx[None, :, None]
    bot = coarse[iy + 1][:, ix] * (1 - tx)[None, :, None] + coarse[iy + 1][:, ix + 1] * tx[None, :, None]
    return (top * (1 - ty)[:, None, None] + bot * ty[:, None, None]).astype(np.float32)
field = interp(coarse, xs, ys, w, h)
ref['median_grid']['samples'] = {
    f'{x},{y}': [round(float(v), 4) for v in field[y, x]]
    for x, y in [(0, 0), (w - 1, h - 1), (5, 5), (20, 16), (39, 3), (7, 31)]
}

# ---- 2. 高斯
gw, gh, sigma = 20, 16, 0.8
g_src = np.zeros((gh, gw), np.float32)
for y in range(gh):
    for x in range(gw):
        g_src[y, x] = (x * 7 + y * 3) % 23
g_src[gh // 2, gw // 2] = 100.0
blur = cv2.GaussianBlur(g_src, (0, 0), sigma)
ref['gaussian'] = {
    'w': gw, 'h': gh, 'sigma': sigma,
    'ksize': int(round(sigma * 4 * 2 + 1)) | 1,
    'samples': {f'{x},{y}': round(float(blur[y, x]), 4) for x, y in
                [(0, 0), (gw - 1, gh - 1), (gw // 2, gh // 2),
                 (gw // 2 + 1, gh // 2), (3, 3), (19, 8)]},
    'sum_before': round(float(g_src.sum()), 3),
    'sum_after': round(float(blur.sum()), 3),
}

# ---- 3. 形態學閉運算
mw, mh = 20, 18
m = line_and_hole_mask(mw, mh)
kern = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
closed = cv2.morphologyEx(m, cv2.MORPH_CLOSE, kern)
ref['close_ellipse5'] = {
    'w': mw, 'h': mh,
    'in_on': int((m > 0).sum()),
    'out_on': int((closed > 0).sum()),
    'rows': [''.join('1' if v else '0' for v in row) for row in (closed > 0)],
}

# ---- 4. 連通元件
cw, chh = 16, 16
cm = three_blobs_mask(cw, chh)
n, lab, stats, _ = cv2.connectedComponentsWithStats(cm, connectivity=8)
comps = sorted(
    [{'area': int(stats[i, cv2.CC_STAT_AREA]),
      'left': int(stats[i, cv2.CC_STAT_LEFT]),
      'top': int(stats[i, cv2.CC_STAT_TOP]),
      'width': int(stats[i, cv2.CC_STAT_WIDTH]),
      'height': int(stats[i, cv2.CC_STAT_HEIGHT])} for i in range(1, n)],
    key=lambda d: (-d['area'], d['left'], d['top']))
ref['connected_components'] = {'w': cw, 'h': chh, 'count': int(n), 'components': comps}

# ---- 5. 距離變換
dw, dh = 24, 20
dm = np.zeros((dh, dw), np.uint8)
dm[4:16, 5:19] = 255
dm[9:11, 0:5] = 255            # 伸出去的細臂
dt = cv2.distanceTransform(dm, cv2.DIST_L2, 5)
ref['distance_transform'] = {
    'w': dw, 'h': dh,
    'max': round(float(dt.max()), 4),
    'argmax': [int(np.unravel_index(dt.argmax(), dt.shape)[1]),
               int(np.unravel_index(dt.argmax(), dt.shape)[0])],
    'samples': {f'{x},{y}': round(float(dt[y, x]), 4) for x, y in
                [(5, 4), (11, 9), (12, 10), (18, 15), (0, 9), (2, 10), (0, 0)]},
}

# ---- 6. OpenCV 8-bit Lab（色空間是整條管線的第一步，錯了每個數字都會偏）
probe = [(0, 0, 0), (255, 255, 255), (128, 128, 128), (200, 150, 90),
         (90, 150, 200), (236, 236, 236), (10, 40, 90), (255, 0, 0),
         (0, 255, 0), (0, 0, 255)]
lab_pairs = {}
for r, g, b in probe:
    bgr = np.array([[[b, g, r]]], np.uint8)
    lab_pairs[f'{r},{g},{b}'] = [int(v) for v in
                                 cv2.cvtColor(bgr, cv2.COLOR_BGR2Lab)[0, 0]]
ref['lab8'] = lab_pairs

with open(os.path.join(OUT, 'blade_image_ops_reference.json'), 'w',
          encoding='utf-8') as fh:
    json.dump(ref, fh, indent=1, ensure_ascii=False)
    fh.write('\n')
print(json.dumps({k: v for k, v in ref.items() if k != '_readme'},
                 indent=1, ensure_ascii=False))
