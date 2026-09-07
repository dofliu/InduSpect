import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 幾何層需要的影像基本運算——OpenCV 有、`package:image` 沒有的那些。
///
/// 全部對照 `blade_prototype/blade_proto/segmentation.py` 用到的 OpenCV 行為實作，
/// 包含邊界處理（`BORDER_REPLICATE`）與 Lab 的**8-bit 表示**。
///
/// **為什麼用 OpenCV 的 8-bit Lab，而不是表面層那個未縮放的 CIE Lab**：
/// 局部天空模型的 `min_scale = 1.2` 是這個空間裡的**絕對**下限，而大核中值必須跑在
/// uint8 上（直方圖法）。表面層可以用未縮放的 CIE Lab 是因為它的判據是比值；
/// 這裡不行，換空間等於悄悄改門檻。OpenCV 的定義：L ← L*×255/100、a ← a*+128、
/// b ← b*+128，全部四捨五入夾到 0–255。
class BladeImageOps {
  BladeImageOps._();

  // ------------------------------------------------------------ 解碼

  /// 安全解碼。**`img.decodeImage` 會丟例外，不是只回 null**——
  /// 位元組太短時它在 GIF 的格式嗅探裡就 `RangeError` 了（讀字串讀過界）。
  /// 現場的檔案可能被截斷、可能根本不是影像，而這條路徑的承諾是「明確失敗、
  /// 不丟例外」，所以解碼一定要包起來。
  static img.Image? safeDecode(Uint8List bytes) {
    if (bytes.length < 16) return null; // 連格式標頭都不夠
    try {
      return img.decodeImage(bytes);
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------ 色彩

  /// 影像 → OpenCV 相容的 8-bit Lab，交錯排列（L,a,b）。
  static Uint8List toLab8(img.Image im) {
    final w = im.width, h = im.height;
    final out = Uint8List(w * h * 3);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = im.getPixel(x, y);
        final lab = lab8OfRgb(p.r.toInt(), p.g.toInt(), p.b.toInt());
        final o = (y * w + x) * 3;
        out[o] = lab[0];
        out[o + 1] = lab[1];
        out[o + 2] = lab[2];
      }
    }
    return out;
  }

  /// 單一像素的 sRGB → OpenCV 8-bit Lab。公開是為了讓色空間換算本身可測——
  /// 它是整條管線的第一步，錯了之後每一個數字都會偏而且看不出原因。
  static List<int> lab8OfRgb(int r, int g, int b) {
    final lab = _cieLab(r.toDouble(), g.toDouble(), b.toDouble());
    return [
      _u8(lab[0] * 255.0 / 100.0),
      _u8(lab[1] + 128.0),
      _u8(lab[2] + 128.0),
    ];
  }

  /// sRGB（0–255）→ CIE Lab（D65 白點，L 0–100）
  static List<double> _cieLab(double r8, double g8, double b8) {
    double lin(double v) {
      final c = v / 255.0;
      return c <= 0.04045
          ? c / 12.92
          : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    }

    final r = lin(r8), g = lin(g8), b = lin(b8);
    final x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047;
    final y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    final z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883;
    double f(double t) =>
        t > 0.008856 ? math.pow(t, 1 / 3).toDouble() : 7.787 * t + 16 / 116;
    final fx = f(x), fy = f(y), fz = f(z);
    return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
  }

  static int _u8(double v) => v <= 0 ? 0 : (v >= 255 ? 255 : (v + 0.5).floor());

  // ------------------------------------------------------------ 縮放

  /// 等比縮到最長邊 <= [maxSide]，用盒狀平均（對應 `cv2.INTER_AREA`）。
  /// 已經夠小就原樣回傳——與 Python 的 `min(1.0, work_side / max(h, w))` 一致。
  static img.Image downscaleArea(img.Image src, int maxSide) {
    final longest = math.max(src.width, src.height);
    if (longest <= maxSide) return src;
    final s = maxSide / longest;
    return img.copyResize(
      src,
      width: math.max(8, (src.width * s).toInt()),
      height: math.max(8, (src.height * s).toInt()),
      interpolation: img.Interpolation.average,
    );
  }

  // ------------------------------------------------------------ 大核中值

  /// 網格座標：0, step, 2*step, … 並確保含最後一個索引。
  ///
  /// 末段通常較短是刻意的：少了最後一列，右／下邊緣就得靠外插。
  static Int32List gridCoords(int n, int step) {
    final xs = <int>[];
    for (var i = 0; i < n; i += step) {
      xs.add(i);
    }
    if (xs.isEmpty || xs.last != n - 1) xs.add(n - 1);
    if (xs.length == 1) xs.insert(0, 0);
    return Int32List.fromList(xs);
  }

  /// 大核中值場：**真 2D 中值，但只在 [step] 間隔的網格點上算**，再雙線性內插。
  ///
  /// 對照 `segmentation.py::_median_field`。逐像素版本手機跑不動——即使用
  /// Perreault 的雙層直方圖，每個輸出像素仍要把兩個行直方圖加減進核直方圖
  /// （約 544 次 bin 運算），1024×820×3 約 1.4G 次。只算網格點時，沿 x 每步只加減
  /// [step] 個 column，總量降到約 64M 次。
  ///
  /// 場本來就是低頻的（核邊長是工作尺度的 20%），所以網格化不是「近似中值」——
  /// 每個網格點上算的是**真正的**中值，只是中間的點用內插。真實照片實測代價：
  /// 設計範圍內 30 張的輪轂命中 23 → 22（step=16）。
  ///
  /// [src] 為交錯的多通道 uint8，邊界比照 `BORDER_REPLICATE`。
  static Float32List medianFieldGrid(
    Uint8List src,
    int w,
    int h,
    int channels,
    int k,
    int step,
  ) {
    final xs = gridCoords(w, step);
    final ys = gridCoords(h, step);
    final coarse = Float32List(ys.length * xs.length * channels);
    final r = k ~/ 2;
    final hist = Int32List(256);
    final need = (k * k + 1) ~/ 2; // 中位數：第 need 個（1-based）

    for (var c = 0; c < channels; c++) {
      for (var iy = 0; iy < ys.length; iy++) {
        final cy = ys[iy];
        // 每個網格列重建一次直方圖，之後沿 x 滑動
        hist.fillRange(0, 256, 0);
        for (var dy = -r; dy <= r; dy++) {
          final sy = _clamp(cy + dy, 0, h - 1);
          for (var dx = -r; dx <= r; dx++) {
            final sx = _clamp(xs[0] + dx, 0, w - 1);
            hist[src[(sy * w + sx) * channels + c]]++;
          }
        }
        coarse[(iy * xs.length + 0) * channels + c] =
            _medianOf(hist, need).toDouble();

        for (var ix = 1; ix < xs.length; ix++) {
          final prev = xs[ix - 1], cur = xs[ix];
          // 視窗由 [prev-r, prev+r] 移到 [cur-r, cur+r]：加右邊的欄、減左邊的欄
          for (var dy = -r; dy <= r; dy++) {
            final sy = _clamp(cy + dy, 0, h - 1);
            final row = sy * w;
            for (var x = prev + r + 1; x <= cur + r; x++) {
              hist[src[(row + _clamp(x, 0, w - 1)) * channels + c]]++;
            }
            for (var x = prev - r; x <= cur - r - 1; x++) {
              hist[src[(row + _clamp(x, 0, w - 1)) * channels + c]]--;
            }
          }
          coarse[(iy * xs.length + ix) * channels + c] =
              _medianOf(hist, need).toDouble();
        }
      }
    }
    return interpFromGrid(coarse, xs, ys, channels, w, h);
  }

  static int _medianOf(Int32List hist, int need) {
    var acc = 0;
    for (var v = 0; v < 256; v++) {
      acc += hist[v];
      if (acc >= need) return v;
    }
    return 255;
  }

  /// 依**真實網格座標**做雙線性內插回 (h, w, channels)，交錯排列。
  ///
  /// 不用等距假設：`gridCoords` 的最後一段通常較短，等距內插會在右／下邊緣偏掉。
  static Float32List interpFromGrid(
    Float32List coarse,
    Int32List xs,
    Int32List ys,
    int channels,
    int w,
    int h,
  ) {
    final ix = Int32List(w), iy = Int32List(h);
    final tx = Float32List(w), ty = Float32List(h);
    _weights(xs, w, ix, tx);
    _weights(ys, h, iy, ty);

    final out = Float32List(w * h * channels);
    final cw = xs.length;
    for (var y = 0; y < h; y++) {
      final y0 = iy[y], fy = ty[y];
      for (var x = 0; x < w; x++) {
        final x0 = ix[x], fx = tx[x];
        final o = (y * w + x) * channels;
        final a = (y0 * cw + x0) * channels;
        final b = (y0 * cw + x0 + 1) * channels;
        final cc = ((y0 + 1) * cw + x0) * channels;
        final d = ((y0 + 1) * cw + x0 + 1) * channels;
        for (var c = 0; c < channels; c++) {
          final top = coarse[a + c] * (1 - fx) + coarse[b + c] * fx;
          final bot = coarse[cc + c] * (1 - fx) + coarse[d + c] * fx;
          out[o + c] = top * (1 - fy) + bot * fy;
        }
      }
    }
    return out;
  }

  static void _weights(Int32List coords, int n, Int32List idx, Float32List t) {
    var j = 0;
    for (var i = 0; i < n; i++) {
      while (j + 2 < coords.length && coords[j + 1] <= i) {
        j++;
      }
      final lo = coords[j], hi = coords[j + 1];
      idx[i] = j;
      t[i] = (i - lo) / math.max(hi - lo, 1);
    }
  }

  // ------------------------------------------------------------ 高斯

  /// 可分離高斯模糊。核大小由 sigma 決定，與 `cv2.GaussianBlur(..., (0,0), s)`
  /// 一致：`ksize = round(s * 4 * 2 + 1) | 1`（OpenCV 對 float 影像用 ×4）。
  ///
  /// 邊界用 **BORDER_REFLECT_101**（OpenCV 的預設），不是 clamp——
  /// clamp 在外圈幾個像素上會與 Python 差開，而那正是遮罩邊界所在，
  /// 對照驗證會一直有一條對不上又找不到原因的殘差。
  static Float32List gaussianBlur(
      Float32List src, int w, int h, double sigma) {
    if (sigma <= 0) return Float32List.fromList(src);
    var k = (sigma * 4.0 * 2.0 + 1.0).round();
    if (k.isEven) k += 1;
    final r = k ~/ 2;
    final kernel = Float64List(k);
    var sum = 0.0;
    for (var i = 0; i < k; i++) {
      final d = i - r;
      kernel[i] = math.exp(-(d * d) / (2 * sigma * sigma));
      sum += kernel[i];
    }
    for (var i = 0; i < k; i++) {
      kernel[i] /= sum;
    }

    final tmp = Float32List(w * h);
    for (var y = 0; y < h; y++) {
      final row = y * w;
      for (var x = 0; x < w; x++) {
        var acc = 0.0;
        for (var i = 0; i < k; i++) {
          acc += kernel[i] * src[row + _reflect101(x + i - r, w)];
        }
        tmp[row + x] = acc;
      }
    }
    final out = Float32List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var acc = 0.0;
        for (var i = 0; i < k; i++) {
          acc += kernel[i] * tmp[_reflect101(y + i - r, h) * w + x];
        }
        out[y * w + x] = acc;
      }
    }
    return out;
  }

  // ------------------------------------------------------------ 形態學

  /// 5×5 橢圓核的閉運算（膨脹後侵蝕），對應
  /// `cv2.morphologyEx(MORPH_CLOSE, getStructuringElement(MORPH_ELLIPSE, (5,5)))`。
  ///
  /// **只做 close，不做 open**：遠距／側視的葉尖只有 1–2 px 厚，open 會把它吃掉
  /// 讓葉尖半徑忽長忽短（Python 端同一個決定，見 `_clean_mask`）。
  static Uint8List closeEllipse5(Uint8List mask, int w, int h) {
    // OpenCV 的 ELLIPSE 5×5：四角挖掉
    const offs = <int>[
      -2, -1, 0, 1, 2, // dy = -2 → dx 只有 0；下面用表列
    ];
    // dy → dx 範圍（OpenCV getStructuringElement(ELLIPSE,(5,5)) 實際樣態）
    const dxSpan = <int>[0, 2, 2, 2, 0];
    final dil = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var on = false;
        for (var dy = -2; dy <= 2 && !on; dy++) {
          final span = dxSpan[dy + 2];
          final sy = y + dy;
          if (sy < 0 || sy >= h) continue;
          for (var dx = -span; dx <= span; dx++) {
            final sx = x + dx;
            if (sx < 0 || sx >= w) continue;
            if (mask[sy * w + sx] != 0) {
              on = true;
              break;
            }
          }
        }
        dil[y * w + x] = on ? 255 : 0;
      }
    }
    final out = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var all = true;
        for (var dy = -2; dy <= 2 && all; dy++) {
          final span = dxSpan[dy + 2];
          final sy = y + dy;
          for (var dx = -span; dx <= span; dx++) {
            final sx = x + dx;
            // 界外視為前景（等同 BORDER_REPLICATE 的保守側），與 OpenCV 預設一致
            if (sy < 0 || sy >= h || sx < 0 || sx >= w) continue;
            if (dil[sy * w + sx] == 0) {
              all = false;
              break;
            }
          }
        }
        out[y * w + x] = all ? 255 : 0;
      }
    }
    // offs 只是為了讓核的形狀寫在程式裡看得見，不參與運算
    assert(offs.length == 5);
    return out;
  }

  // ------------------------------------------------------------ 連通元件

  /// 8-連通元件標記 + 統計，對應 `cv2.connectedComponentsWithStats`。
  /// 標籤 0 是背景，元件從 1 開始（與 OpenCV 一致，但**編號順序不保證相同**）。
  static ConnectedComponents connectedComponents(
      Uint8List mask, int w, int h) {
    final labels = Int32List(w * h);
    final stats = <ComponentStats>[
      const ComponentStats(area: 0, left: 0, top: 0, width: 0, height: 0),
    ];
    final stack = Int32List(w * h);
    var next = 0;
    for (var i = 0; i < mask.length; i++) {
      if (mask[i] == 0 || labels[i] != 0) continue;
      next++;
      var sp = 0;
      stack[sp++] = i;
      labels[i] = next;
      var area = 0, minX = w, maxX = -1, minY = h, maxY = -1;
      while (sp > 0) {
        final p = stack[--sp];
        final px = p % w, py = p ~/ w;
        area++;
        if (px < minX) minX = px;
        if (px > maxX) maxX = px;
        if (py < minY) minY = py;
        if (py > maxY) maxY = py;
        for (var dy = -1; dy <= 1; dy++) {
          final ny = py + dy;
          if (ny < 0 || ny >= h) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final nx = px + dx;
            if (nx < 0 || nx >= w) continue;
            final q = ny * w + nx;
            if (mask[q] != 0 && labels[q] == 0) {
              labels[q] = next;
              stack[sp++] = q;
            }
          }
        }
      }
      stats.add(ComponentStats(
        area: area,
        left: minX,
        top: minY,
        width: maxX - minX + 1,
        height: maxY - minY + 1,
      ));
    }
    return ConnectedComponents(labels: labels, stats: stats, count: next + 1);
  }

  // ------------------------------------------------------------ 距離變換

  /// 距離變換（前景到最近背景），對照 `cv2.distanceTransform(mask, DIST_L2, 5)`。
  ///
  /// **刻意用 OpenCV 的 5×5 chamfer 近似，而不是精確歐氏距離變換。**
  /// chamfer 有約 2% 的各向異性誤差，精確 EDT（Felzenszwalb 下包絡法）沒有——
  /// 但 Python 原型用的是 chamfer，而輪轂是靠「距離變換的最大值」定位的，
  /// 兩邊用不同的距離就對照不起來。要換的話兩邊要一起換並重跑真實語料。
  ///
  /// 係數與 OpenCV 相同：水平/垂直 1.0、對角 1.4、長跳 2.1969（`DIST_L2` + mask 5）。
  static Float32List distanceTransform(Uint8List mask, int w, int h) {
    const hv = 1.0, diag = 1.4, long = 2.1969;
    const big = 1e10;
    // 上下各留 2 列邊界（OpenCV 的 BORDER=2），邊界填大值
    const b = 2;
    final tw = w + 2 * b, th = h + 2 * b;
    final t = Float32List(tw * th);
    for (var i = 0; i < t.length; i++) {
      t[i] = big;
    }
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (mask[y * w + x] == 0) t[(y + b) * tw + (x + b)] = 0;
      }
    }

    // 前向：左上 → 右下
    for (var y = b; y < h + b; y++) {
      for (var x = b; x < w + b; x++) {
        final o = y * tw + x;
        if (t[o] == 0) continue;
        var v = t[o - tw - 2] + long; // (y-1, x-2)
        var c = t[o - 2 * tw - 1] + long; // (y-2, x-1)
        if (c < v) v = c;
        c = t[o - 2 * tw + 1] + long; // (y-2, x+1)
        if (c < v) v = c;
        c = t[o - tw + 2] + long; // (y-1, x+2)
        if (c < v) v = c;
        c = t[o - tw - 1] + diag;
        if (c < v) v = c;
        c = t[o - tw + 1] + diag;
        if (c < v) v = c;
        c = t[o - tw] + hv;
        if (c < v) v = c;
        c = t[o - 1] + hv;
        if (c < v) v = c;
        if (v < t[o]) t[o] = v;
      }
    }
    // 後向：右下 → 左上（鏡像的同一組鄰居）
    for (var y = h + b - 1; y >= b; y--) {
      for (var x = w + b - 1; x >= b; x--) {
        final o = y * tw + x;
        if (t[o] == 0) continue;
        var v = t[o];
        var c = t[o + tw + 2] + long;
        if (c < v) v = c;
        c = t[o + 2 * tw + 1] + long;
        if (c < v) v = c;
        c = t[o + 2 * tw - 1] + long;
        if (c < v) v = c;
        c = t[o + tw - 2] + long;
        if (c < v) v = c;
        c = t[o + tw + 1] + diag;
        if (c < v) v = c;
        c = t[o + tw - 1] + diag;
        if (c < v) v = c;
        c = t[o + tw] + hv;
        if (c < v) v = c;
        c = t[o + 1] + hv;
        if (c < v) v = c;
        t[o] = v;
      }
    }

    final out = Float32List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        out[y * w + x] = t[(y + b) * tw + (x + b)];
      }
    }
    return out;
  }

  static int _clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

  /// BORDER_REFLECT_101：邊界像素不重複（…c b | a b c d | c b…）。
  /// 這是 OpenCV 濾波的預設邊界，`medianBlur` 例外（那個用 REPLICATE）。
  static int _reflect101(int i, int n) {
    if (n == 1) return 0;
    var v = i;
    while (v < 0 || v >= n) {
      if (v < 0) {
        v = -v;
      } else {
        v = 2 * (n - 1) - v;
      }
    }
    return v;
  }
}

class ComponentStats {
  final int area;
  final int left;
  final int top;
  final int width;
  final int height;
  const ComponentStats({
    required this.area,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });
}

class ConnectedComponents {
  final Int32List labels;
  final List<ComponentStats> stats;

  /// 含背景，與 OpenCV 的回傳一致
  final int count;
  const ConnectedComponents({
    required this.labels,
    required this.stats,
    required this.count,
  });
}
