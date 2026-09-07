import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/services/blade_image_ops.dart';

/// 影像基本運算逐項對照 OpenCV（參考值由
/// `blade_prototype/scripts/make_image_ops_fixture.py` 產生）。
///
/// **為什麼要逐項對照**：幾何層是把 1000 多行 Python 移植成 Dart，而這個環境沒有
/// Flutter SDK，寫錯一個符號不會有任何徵兆——只會變成「最後那個數字對不上」。
/// 每個運算各有一條測試，錯誤就會在它發生的那一層紅掉。
///
/// 輸入全部由公式重建（不是影像檔），與產生器同一條公式。
void main() {
  late Map<String, dynamic> ref;

  setUpAll(() {
    ref = jsonDecode(
      File('test/assets/blade_image_ops_reference.json').readAsStringSync(),
    ) as Map<String, dynamic>;
  });

  /// 與 `make_image_ops_fixture.py::ramp_plus_blobs` 同一條公式
  Uint8List rampPlusBlobs(int w, int h, int ch) {
    final a = Uint8List(w * h * ch);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        for (var c = 0; c < ch; c++) {
          a[(y * w + x) * ch + c] = (x * 3 + y * 5 + c * 17) % 200 + 20;
        }
      }
    }
    void fill(int y0, int y1, int x0, int x1, int v) {
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          for (var c = 0; c < ch; c++) {
            a[(y * w + x) * ch + c] = v;
          }
        }
      }
    }

    fill(h ~/ 4, h ~/ 4 + 6, w ~/ 4, w ~/ 4 + 6, 250);
    fill(h ~/ 2, h ~/ 2 + 4, w ~/ 2, w ~/ 2 + 10, 5);
    fill(0, h, w - 3, w - 2, 240);
    return a;
  }

  group('大核中值（網格模式）', () {
    test('網格座標與 Python 完全一致，且一定含最後一個索引', () {
      final m = ref['median_grid'] as Map<String, dynamic>;
      final w = m['w'] as int, h = m['h'] as int, step = m['step'] as int;
      expect(BladeImageOps.gridCoords(w, step).toList(),
          (m['grid_xs'] as List).cast<int>());
      expect(BladeImageOps.gridCoords(h, step).toList(),
          (m['grid_ys'] as List).cast<int>());
    });

    test('網格點上的中值與 OpenCV 逐位相同（不是近似）', () {
      final m = ref['median_grid'] as Map<String, dynamic>;
      final w = m['w'] as int,
          h = m['h'] as int,
          ch = m['channels'] as int,
          k = m['k'] as int,
          step = m['step'] as int;
      final src = rampPlusBlobs(w, h, ch);
      final field = BladeImageOps.medianFieldGrid(src, w, h, ch, k, step);

      final xs = (m['grid_xs'] as List).cast<int>();
      final ys = (m['grid_ys'] as List).cast<int>();
      final coarse = (m['coarse'] as List).cast<List<dynamic>>();
      var i = 0;
      for (final y in ys) {
        for (final x in xs) {
          for (var c = 0; c < ch; c++) {
            expect(field[(y * w + x) * ch + c],
                closeTo((coarse[i][c] as num).toDouble(), 1e-6),
                reason: '網格點 ($x,$y) 通道 $c');
          }
          i++;
        }
      }
    });

    test('內插後的取樣點與 Python 一致（真實網格座標，不是等距假設）', () {
      final m = ref['median_grid'] as Map<String, dynamic>;
      final w = m['w'] as int,
          h = m['h'] as int,
          ch = m['channels'] as int,
          k = m['k'] as int,
          step = m['step'] as int;
      final field =
          BladeImageOps.medianFieldGrid(rampPlusBlobs(w, h, ch), w, h, ch, k, step);
      (m['samples'] as Map<String, dynamic>).forEach((key, expected) {
        final parts = key.split(',');
        final x = int.parse(parts[0]), y = int.parse(parts[1]);
        final want = (expected as List).cast<num>();
        for (var c = 0; c < ch; c++) {
          expect(field[(y * w + x) * ch + c],
              closeTo(want[c].toDouble(), 2e-3),
              reason: '($x,$y) 通道 $c');
        }
      });
    });

    test('細線被抹掉、大方塊留著——中值核的整個用途', () {
      final m = ref['median_grid'] as Map<String, dynamic>;
      final w = m['w'] as int, h = m['h'] as int, ch = m['channels'] as int;
      final k = m['k'] as int, step = m['step'] as int;
      final src = rampPlusBlobs(w, h, ch);
      final field = BladeImageOps.medianFieldGrid(src, w, h, ch, k, step);
      // 細線（寬 1 px < 核 11）：背景不該跟著跳到 240
      final lineX = w - 3, lineY = h ~/ 2 - 5;
      expect(field[(lineY * w + lineX) * ch], lessThan(200),
          reason: '比核窄的結構要被抹掉，否則殘差就沒了');
      // 亮方塊 6×6 也比核窄，同樣該被抹掉
      final bx = w ~/ 4 + 2, by = h ~/ 4 + 2;
      expect(field[(by * w + bx) * ch], lessThan(240));
    });
  });

  test('高斯模糊：邊界用 REFLECT_101，與 OpenCV 逐點相符', () {
    final g = ref['gaussian'] as Map<String, dynamic>;
    final w = g['w'] as int, h = g['h'] as int;
    final sigma = (g['sigma'] as num).toDouble();
    final src = Float32List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        src[y * w + x] = ((x * 7 + y * 3) % 23).toDouble();
      }
    }
    src[(h ~/ 2) * w + w ~/ 2] = 100.0;
    final out = BladeImageOps.gaussianBlur(src, w, h, sigma);

    (g['samples'] as Map<String, dynamic>).forEach((key, expected) {
      final parts = key.split(',');
      final x = int.parse(parts[0]), y = int.parse(parts[1]);
      expect(out[y * w + x], closeTo((expected as num).toDouble(), 5e-3),
          reason: '($x,$y)');
    });
    var sum = 0.0;
    for (final v in out) {
      sum += v;
    }
    expect(sum, closeTo((g['sum_after'] as num).toDouble(), 0.05),
        reason: 'clamp 邊界會讓總和偏掉，REFLECT_101 才對得上');
  });

  test('5×5 橢圓閉運算：逐像素與 OpenCV 相同（含四角挖掉的形狀）', () {
    final c = ref['close_ellipse5'] as Map<String, dynamic>;
    final w = c['w'] as int, h = c['h'] as int;
    final m = Uint8List(w * h);
    for (var y = 2; y < h - 2; y++) {
      m[y * w + 3] = 255;
    }
    for (var y = 4; y < 12; y++) {
      for (var x = 6; x < 14; x++) {
        m[y * w + x] = 255;
      }
    }
    for (var y = 7; y < 9; y++) {
      for (var x = 9; x < 11; x++) {
        m[y * w + x] = 0;
      }
    }
    m[(h - 3) * w + (w - 3)] = 255;
    m[1 * w + 1] = 255;

    expect(m.where((v) => v > 0).length, c['in_on'] as int,
        reason: '夾具的輸入必須與產生器一致');

    final out = BladeImageOps.closeEllipse5(m, w, h);
    final rows = (c['rows'] as List).cast<String>();
    for (var y = 0; y < h; y++) {
      final got = List.generate(w, (x) => out[y * w + x] > 0 ? '1' : '0').join();
      expect(got, rows[y], reason: '第 $y 列');
    }
    expect(out.where((v) => v > 0).length, c['out_on'] as int);
  });

  test('8-連通元件：面積與外接框與 OpenCV 相同，孤立點不被合併', () {
    final c = ref['connected_components'] as Map<String, dynamic>;
    final w = c['w'] as int, h = c['h'] as int;
    final m = Uint8List(w * h);
    void fill(int y0, int y1, int x0, int x1) {
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          m[y * w + x] = 255;
        }
      }
    }

    fill(1, 5, 1, 5);
    fill(1, 3, 6, 12);
    fill(8, 14, 2, 4);
    m[10 * w + 5] = 255;

    final cc = BladeImageOps.connectedComponents(m, w, h);
    expect(cc.count, c['count'] as int, reason: '含背景的元件數');

    final got = cc.stats.skip(1).toList()
      ..sort((a, b) {
        final byArea = b.area.compareTo(a.area);
        if (byArea != 0) return byArea;
        final byLeft = a.left.compareTo(b.left);
        return byLeft != 0 ? byLeft : a.top.compareTo(b.top);
      });
    final want = (c['components'] as List).cast<Map<String, dynamic>>();
    expect(got.length, want.length);
    for (var i = 0; i < want.length; i++) {
      expect(got[i].area, want[i]['area'], reason: '元件 $i 面積');
      expect(got[i].left, want[i]['left'], reason: '元件 $i left');
      expect(got[i].top, want[i]['top'], reason: '元件 $i top');
      expect(got[i].width, want[i]['width'], reason: '元件 $i width');
      expect(got[i].height, want[i]['height'], reason: '元件 $i height');
    }
  });

  test('距離變換：與 OpenCV 的 5×5 chamfer 相同（含最大值的位置）', () {
    final d = ref['distance_transform'] as Map<String, dynamic>;
    final w = d['w'] as int, h = d['h'] as int;
    final m = Uint8List(w * h);
    for (var y = 4; y < 16; y++) {
      for (var x = 5; x < 19; x++) {
        m[y * w + x] = 255;
      }
    }
    for (var y = 9; y < 11; y++) {
      for (var x = 0; x < 5; x++) {
        m[y * w + x] = 255;
      }
    }

    final dt = BladeImageOps.distanceTransform(m, w, h);
    var max = 0.0, argX = 0, argY = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (dt[y * w + x] > max) {
          max = dt[y * w + x];
          argX = x;
          argY = y;
        }
      }
    }
    expect(max, closeTo((d['max'] as num).toDouble(), 1e-3));
    // 輪轂是靠這個最大值定位的，位置錯了整條管線就錯了
    final wantArg = (d['argmax'] as List).cast<int>();
    expect([argX, argY], wantArg);

    (d['samples'] as Map<String, dynamic>).forEach((key, expected) {
      final parts = key.split(',');
      final x = int.parse(parts[0]), y = int.parse(parts[1]);
      expect(dt[y * w + x], closeTo((expected as num).toDouble(), 1e-3),
          reason: '($x,$y)');
    });
  });

  group('OpenCV 相容的 8-bit Lab', () {
    test('十組 RGB 與 cv2.cvtColor(BGR2Lab) 相同（容差 ±1 量化）', () {
      final pairs = ref['lab8'] as Map<String, dynamic>;
      expect(pairs, isNotEmpty);
      pairs.forEach((rgb, expected) {
        final p = rgb.split(',').map(int.parse).toList();
        final got = BladeImageOps.lab8OfRgb(p[0], p[1], p[2]);
        final want = (expected as List).cast<int>();
        for (var c = 0; c < 3; c++) {
          expect(got[c], closeTo(want[c], 1),
              reason: 'RGB($rgb) 通道 $c：Dart ${got[c]} vs OpenCV ${want[c]}');
        }
      });
    });

    test('L 縮到 0–255 而不是 CIE 的 0–100——換錯空間等於悄悄改門檻', () {
      expect(BladeImageOps.lab8OfRgb(255, 255, 255)[0], 255);
      expect(BladeImageOps.lab8OfRgb(0, 0, 0)[0], 0);
      // 中灰的 L* 約 53.6，若沒縮放會是 54 而不是 137
      expect(BladeImageOps.lab8OfRgb(128, 128, 128)[0], greaterThan(120));
    });
  });
}
