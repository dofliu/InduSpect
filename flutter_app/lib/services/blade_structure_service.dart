import 'dart:math' as math;
import 'dart:typed_data';

import 'blade_image_ops.dart';

/// 一片葉片的輸出（對照 `segmentation.py::BladeComponent`）
class BladeTip {
  final int area;
  final double tipX;
  final double tipY;
  final double tipRadiusPx;

  /// 數學慣例方位角（270° = 六點鐘）
  final double tipAngleDeg;

  /// 這片葉片的像素座標。幾何層（中心線、弦寬、彎曲）要用它們，
  /// 所以不能只留葉尖——與 Python 的 `BladeComponent` 一致。
  final Int32List xs;
  final Int32List ys;

  BladeTip({
    required this.area,
    required this.tipX,
    required this.tipY,
    required this.tipRadiusPx,
    required this.tipAngleDeg,
    required this.xs,
    required this.ys,
  });
}

/// 結構定位的結果（對照 `segmentation.py::TurbineStructure`）
class BladeStructure {
  final bool ok;
  final String? failure;
  final double hubX;
  final double hubY;
  final double hubRadiusPx;
  final bool hubRefined;
  final bool towerFound;

  /// 塔架軸相對垂直的偏差（正 = 順時鐘）；無塔架時 0
  final double towerAngleDeg;
  final double towerWidthPx;
  final List<BladeTip> blades;
  final List<String> notes;

  const BladeStructure({
    this.ok = true,
    this.failure,
    this.hubX = 0,
    this.hubY = 0,
    this.hubRadiusPx = 0,
    this.hubRefined = false,
    this.towerFound = false,
    this.towerAngleDeg = 0,
    this.towerWidthPx = 0,
    this.blades = const [],
    this.notes = const [],
  });

  factory BladeStructure.failed(String reason) =>
      BladeStructure(ok: false, failure: reason);

  /// 轉子半徑（葉尖到輪轂的最大距離）
  double get rotorRadiusPx =>
      blades.fold(0.0, (m, b) => math.max(m, b.tipRadiusPx));

  /// 三片葉尖半徑的離散度。同型三片必等長，所以這個量是「量到的是不是同一台」
  /// 最有鑑別力的判據（真實照片實測：唯一真正有效的拒收條件）。
  double? get tipRadiusSpread {
    if (blades.length < 2) return null;
    var lo = double.infinity, hi = 0.0;
    for (final b in blades) {
      lo = math.min(lo, b.tipRadiusPx);
      hi = math.max(hi, b.tipRadiusPx);
    }
    if (hi <= 0) return null;
    return (hi - lo) / hi;
  }
}

/// 遮罩上的一個元件（對照 `segmentation.py::_Comp`）
class _Arm {
  final Int32List xs;
  final Int32List ys;
  final bool touchesBottom;
  _Arm(this.xs, this.ys, this.touchesBottom);

  int get length => xs.length;

  double maxDistTo(double hx, double hy) {
    var m = 0.0;
    for (var i = 0; i < xs.length; i++) {
      final d = _hypot(xs[i] - hx, ys[i] - hy);
      if (d > m) m = d;
    }
    return m;
  }

  double minDistTo(double hx, double hy) {
    var m = double.infinity;
    for (var i = 0; i < xs.length; i++) {
      final d = _hypot(xs[i] - hx, ys[i] - hy);
      if (d < m) m = d;
    }
    return m;
  }

  int maxY() {
    var m = -1;
    for (final y in ys) {
      if (y > m) m = y;
    }
    return m;
  }
}

double _hypot(num dx, num dy) => math.sqrt(dx * dx + dy * dy);

/// PCA 主軸：(質心 x, 質心 y, 主軸 x, 主軸 y, 伸長比)
class _Axis {
  final double cx, cy, dx, dy, elong;
  const _Axis(this.cx, this.cy, this.dx, this.dy, this.elong);
}

/// 結構定位（規格 §5.3）：從分割遮罩找輪轂、塔架、葉片。
///
/// `blade_prototype/blade_proto/segmentation.py` 的 `find_structure` 及其 helper
/// 的 Dart 對照實作。每個門檻與停止條件都與 Python 相同——那些數字是在 75 張真實
/// 照片上調出來的，改一個就要重跑那份驗證。
class BladeStructureService {
  BladeStructureService._();

  /// 從分割遮罩找結構。
  ///
  /// [horizonY]：地平線列。真實影像上這是最重要的一個參數——地面/植被進入遮罩後，
  /// 距離變換最厚處會落在地面，輪轂初估與塔軸偵測會整個歪掉，而且地面殘塊會被當成
  /// 第四片葉片。
  static BladeStructure findStructure(
    Uint8List maskIn,
    int w,
    int h, {
    int? horizonY,
    int maxBlades = 3,
    double minBladeAreaFrac = 2e-4,
    int nIter = 4,
    bool refine = true,
  }) {
    final notes = <String>[];
    var mask = maskIn;
    if (horizonY != null && horizonY > 0 && horizonY < h) {
      mask = Uint8List.fromList(maskIn);
      for (var y = horizonY; y < h; y++) {
        mask.fillRange(y * w, y * w + w, 0);
      }
      notes.add('只用地平線（第 $horizonY 列）以上做結構定位');
    }

    var top = h, bottom = -1;
    for (var y = 0; y < h; y++) {
      final row = y * w;
      for (var x = 0; x < w; x++) {
        if (mask[row + x] != 0) {
          if (y < top) top = y;
          if (y > bottom) bottom = y;
          break;
        }
      }
    }
    if (bottom < 0) return BladeStructure.failed('遮罩為空，無法定位結構');

    final dt = BladeImageOps.distanceTransform(mask, w, h);
    double dtAt(double px, double py) {
      final x = px.round(), y = py.round();
      if (x < 0 || x >= w || y < 0 || y >= h) return 0.0;
      return dt[y * w + x];
    }

    final init = _initialHub(
        mask, w, h, dt, (top + 0.65 * (bottom - top)).toInt());
    var hubX = init.hubX, hubY = init.hubY;
    final peak = init.peak;
    var hubR = peak;
    final towerAxis = init.towerAxis;
    final minArea = (minBladeAreaFrac * w * h).toInt();

    var refined = false;
    for (var it = 0; it < (refine ? nIter : 0); it++) {
      final split =
          _splitComponents(mask, w, h, hubX, hubY, hubR, minArea, towerAxis);
      final cls =
          _classify(split.comps, hubX, hubY, hubR, maxBlades, split.tower);

      final axes = <_Axis>[];
      for (final c in cls.blades) {
        final a = _bladeAxis(c, hubX, hubY, c.maxDistTo(hubX, hubY));
        if (a != null) axes.add(a);
      }
      // 正視時塔架軸也過輪轂；側視塔架在機艙中心下方、與葉片平行 → 只在不平行時採用。
      // 另要求塔架軸近垂直（<5°）：葉片與塔架重疊時合併元件的軸會歪掉。
      final td = cls.towerDir;
      if (cls.tower != null &&
          td != null &&
          axes.isNotEmpty &&
          _axisAngleBetween(td.dx, td.dy, 0, 1) < 5.0 &&
          axes.every((a) => _axisAngleBetween(td.dx, td.dy, a.dx, a.dy) > 25.0)) {
        var sx = 0.0, sy = 0.0;
        final t = cls.tower!;
        for (var i = 0; i < t.length; i++) {
          sx += t.xs[i];
          sy += t.ys[i];
        }
        axes.add(_Axis(sx / t.length, sy / t.length, td.dx, td.dy, td.elong));
      }
      if (axes.isEmpty) {
        notes.add('找不到任何伸長元件，輪轂保留初估');
        break;
      }

      var maxPair = 0.0;
      for (var i = 0; i < axes.length; i++) {
        for (var j = i + 1; j < axes.length; j++) {
          final a = _axisAngleBetween(
              axes[i].dx, axes[i].dy, axes[j].dx, axes[j].dy);
          if (a > maxPair) maxPair = a;
        }
      }
      double nx, ny;
      if (axes.length >= 2 && maxPair > 25.0) {
        final p = _lsIntersection(axes);
        nx = p[0];
        ny = p[1];
      } else {
        _Arm? big;
        for (final c in cls.blades) {
          if (big == null || c.length > big.length) big = c;
        }
        final a = big == null
            ? null
            : _bladeAxis(big, hubX, hubY, big.maxDistTo(hubX, hubY));
        if (a == null) break;
        // 側視：葉片軸線共線，輪轂投影到主葉片軸線
        final t = (hubX - a.cx) * a.dx + (hubY - a.cy) * a.dy;
        nx = a.cx + a.dx * t;
        ny = a.cy + a.dy * t;
        if (it == 0) notes.add('葉片軸線共線（側視），輪轂投影到主葉片軸線');
      }

      final moved = _hypot(nx - hubX, ny - hubY);
      // 允許的移動距離以**轉子半徑**為尺規，不是 hubR。hubR 量的是機艙在遮罩裡的
      // 厚度，會隨天空模型的鬆緊而變，拿它當尺規會把側視合法的投影也擋掉。
      // 保留 4×peak 當下限，所以這條只會放寬、不會變嚴。
      var rotorR = 0.0;
      for (final c in cls.blades) {
        rotorR = math.max(rotorR, c.maxDistTo(hubX, hubY));
      }
      final limit = math.max(4.0 * peak, 0.15 * rotorR);
      if (nx < 0 || nx >= w || ny < 0 || ny >= h || moved > limit) {
        notes.add('輪轂精修移動 ${moved.toStringAsFixed(0)} px 超過上限 '
            '${limit.toStringAsFixed(0)} px，保留前一估計');
        break;
      }
      hubX = nx;
      hubY = ny;
      hubR = math.max(dtAt(hubX, hubY), peak); // 圓盤只用來切開葉根，寧大勿小
      refined = true;
      if (moved < 0.5) break;
    }

    final split =
        _splitComponents(mask, w, h, hubX, hubY, hubR, minArea, towerAxis);
    final cls =
        _classify(split.comps, hubX, hubY, hubR, maxBlades, split.tower);

    var towerAngle = 0.0, towerWidth = 0.0;
    if (cls.tower != null && cls.towerDir != null) {
      final d = cls.towerDir!;
      final ax = d.dy > 0 ? d : _Axis(d.cx, d.cy, -d.dx, -d.dy, d.elong);
      towerAngle = math.atan2(ax.dx, ax.dy) * 180.0 / math.pi;
      towerWidth = _medianRowWidth(cls.tower!);
    } else {
      notes.add('未找到塔架元件（畫面可能未含塔架，或塔架被亮天空吃掉）');
    }

    final out = <BladeTip>[];
    for (final c in cls.blades) {
      var j = 0, best = -1.0;
      for (var i = 0; i < c.length; i++) {
        final d = _hypot(c.xs[i] - hubX, c.ys[i] - hubY);
        if (d > best) {
          best = d;
          j = i;
        }
      }
      out.add(BladeTip(
        area: c.length,
        tipX: c.xs[j].toDouble(),
        tipY: c.ys[j].toDouble(),
        tipRadiusPx: best,
        tipAngleDeg: _angleDeg(c.xs[j] - hubX, c.ys[j] - hubY),
        xs: c.xs,
        ys: c.ys,
      ));
    }
    out.sort((a, b) => a.tipAngleDeg.compareTo(b.tipAngleDeg));

    return BladeStructure(
      hubX: hubX,
      hubY: hubY,
      hubRadiusPx: hubR,
      hubRefined: refined,
      towerFound: cls.tower != null,
      towerAngleDeg: towerAngle,
      towerWidthPx: towerWidth,
      blades: out,
      notes: notes,
    );
  }

  /// 把已定位風機的元件拿掉，在剩下的遮罩上再找一次轉子。
  ///
  /// 回答的是「畫面裡有沒有**第二個轉子**」，不是「有沒有第二個色塊」。這個區別是
  /// 量出來的：單看「不屬於已定位結構的最大元件」完全分不開單台與多台照片，
  /// 因為那個量被地面、樹線、遠景農田主導。回傳 (第二個轉子的葉尖半徑, 臂數)。
  static List<double> findSecondRotor(
    Uint8List mask,
    int w,
    int h,
    BladeStructure structure, {
    int? horizonY,
    int minPixels = 200,
  }) {
    final rest = Uint8List.fromList(mask);
    if (horizonY != null && horizonY > 0 && horizonY < h) {
      for (var y = horizonY; y < h; y++) {
        rest.fillRange(y * w, y * w + w, 0);
      }
    }
    final cc = BladeImageOps.connectedComponents(rest, w, h);
    final own = <int>{};
    for (final b in structure.blades) {
      final x = b.tipX.round(), y = b.tipY.round();
      if (x >= 0 && x < w && y >= 0 && y < h) own.add(cc.labels[y * w + x]);
    }
    final hx = structure.hubX.round(), hy = structure.hubY.round();
    if (hx >= 0 && hx < w && hy >= 0 && hy < h) {
      own.add(cc.labels[hy * w + hx]);
    }
    own.remove(0);
    var left = 0;
    for (var i = 0; i < rest.length; i++) {
      if (own.contains(cc.labels[i])) {
        rest[i] = 0;
      } else if (rest[i] != 0) {
        left++;
      }
    }
    if (left < minPixels) return [0.0, 0.0];
    final st2 = findStructure(rest, w, h);
    if (!st2.ok) return [0.0, 0.0];
    return [st2.rotorRadiusPx, st2.blades.length.toDouble()];
  }

  // ------------------------------------------------------- 幾何 helper

  static _Axis _pcaAxis(Int32List xs, Int32List ys) {
    final n = xs.length;
    var mx = 0.0, my = 0.0;
    for (var i = 0; i < n; i++) {
      mx += xs[i];
      my += ys[i];
    }
    mx /= n;
    my /= n;
    var sxx = 0.0, sxy = 0.0, syy = 0.0;
    for (var i = 0; i < n; i++) {
      final dx = xs[i] - mx, dy = ys[i] - my;
      sxx += dx * dx;
      sxy += dx * dy;
      syy += dy * dy;
    }
    // 2×2 對稱矩陣的特徵值（閉式解，等價於 Python 的 SVD 奇異值平方）
    final tr = sxx + syy;
    final det = sxx * syy - sxy * sxy;
    final disc = math.max(tr * tr / 4 - det, 0.0);
    final l1 = tr / 2 + math.sqrt(disc);
    final l2 = tr / 2 - math.sqrt(disc);
    double vx, vy;
    if (sxy.abs() > 1e-12) {
      vx = l1 - syy;
      vy = sxy;
    } else {
      vx = sxx >= syy ? 1.0 : 0.0;
      vy = sxx >= syy ? 0.0 : 1.0;
    }
    final norm = _hypot(vx, vy);
    if (norm > 0) {
      vx /= norm;
      vy /= norm;
    }
    // elong = sqrt(λ1/λ2)：與 Python 的 sv[0]/sv[1] 相同（sv² = λ）
    final elong = math.sqrt(l1 / math.max(l2, 1e-12));
    return _Axis(mx, my, vx, vy, elong);
  }

  /// 多條直線的最小平方交點：min Σ‖(I − d dᵀ)(x − p)‖²
  static List<double> _lsIntersection(List<_Axis> axes) {
    var a11 = 0.0, a12 = 0.0, a22 = 0.0, b1 = 0.0, b2 = 0.0;
    for (final a in axes) {
      final n = _hypot(a.dx, a.dy);
      if (n <= 0) continue;
      final dx = a.dx / n, dy = a.dy / n;
      final p11 = 1 - dx * dx, p12 = -dx * dy, p22 = 1 - dy * dy;
      a11 += p11;
      a12 += p12;
      a22 += p22;
      b1 += p11 * a.cx + p12 * a.cy;
      b2 += p12 * a.cx + p22 * a.cy;
    }
    a11 += 1e-9;
    a22 += 1e-9;
    final det = a11 * a22 - a12 * a12;
    if (det.abs() < 1e-12) return [axes.first.cx, axes.first.cy];
    return [(b1 * a22 - a12 * b2) / det, (a11 * b2 - a12 * b1) / det];
  }

  /// 影像向量 → 數學慣例方位角（y 向下所以取負），0–360
  static double _angleDeg(double dx, double dy) {
    var a = math.atan2(-dy, dx) * 180.0 / math.pi;
    a %= 360.0;
    if (a < 0) a += 360.0;
    return a;
  }

  /// 兩條**無向**軸線的夾角（0–90°）
  static double _axisAngleBetween(double ax, double ay, double bx, double by) {
    final na = _hypot(ax, ay), nb = _hypot(bx, by);
    final c = ((ax * bx + ay * by).abs() / (na * nb + 1e-12)).clamp(-1.0, 1.0);
    return math.acos(c) * 180.0 / math.pi;
  }

  static double _medianRowWidth(_Arm c) {
    final byRow = <int, List<int>>{};
    for (var i = 0; i < c.length; i++) {
      (byRow[c.ys[i]] ??= []).add(c.xs[i]);
    }
    final rows = byRow.keys.toList()..sort();
    final step = math.max(1, rows.length ~/ 40);
    final widths = <double>[];
    for (var i = 0; i < rows.length; i += step) {
      final xsRow = byRow[rows[i]]!;
      var lo = xsRow.first, hi = xsRow.first;
      for (final x in xsRow) {
        if (x < lo) lo = x;
        if (x > hi) hi = x;
      }
      widths.add((hi - lo + 1).toDouble());
    }
    widths.sort();
    return widths.isEmpty ? 0.0 : widths[widths.length ~/ 2];
  }

  /// 葉片軸線。預設用內段 0.15–0.55 R：葉尖偏移 ∝ t²，內段受彎曲影響小，
  /// 軸線較準地過輪轂。
  static _Axis? _bladeAxis(_Arm c, double hx, double hy, double rmax,
      {double lo = 0.15, double hi = 0.55}) {
    final xs = <int>[], ys = <int>[];
    for (var i = 0; i < c.length; i++) {
      final d = _hypot(c.xs[i] - hx, c.ys[i] - hy);
      if (d > lo * rmax && d < hi * rmax) {
        xs.add(c.xs[i]);
        ys.add(c.ys[i]);
      }
    }
    if (xs.length < 20) return null;
    return _pcaAxis(Int32List.fromList(xs), Int32List.fromList(ys));
  }
}

/// `_splitComponents` 的回傳
class _SplitResult {
  final List<_Arm> comps;
  final _Arm? tower;
  const _SplitResult(this.comps, this.tower);
}

/// `_classify` 的回傳
class _ClassifyResult {
  final _Arm? tower;
  final _Axis? towerDir;
  final List<_Arm> blades;
  const _ClassifyResult(this.tower, this.towerDir, this.blades);
}

/// 塔軸：x = a·y + b，寬 tw
class _TowerAxis {
  final double a, b, tw;
  const _TowerAxis(this.a, this.b, this.tw);
}

class _InitialHub {
  final double hubX, hubY, peak;
  final _TowerAxis? towerAxis;
  const _InitialHub(this.hubX, this.hubY, this.peak, this.towerAxis);
}

// --------------------------------------------------------- 私有實作
//
// 以下是 `segmentation.py` 對應私有函式的逐一對照實作，寫成 library 層級的
// 私有函式（而不是塞進 class）——它們互相呼叫，而且與 `BladeStructureService`
// 的公開介面無關。命名保持與 Python 一致，方便兩邊對讀。

/// 移除輪轂圓盤後取連通元件。已知塔軸時先把塔架帶挖出來直接當塔架：
/// 雲塊把垂掛葉片和塔架橋接在一起時，角度直方圖切不開（夾角只有幾度），
/// 用幾何帶切最可靠。
_SplitResult _splitComponents(Uint8List mask, int w, int h, double hubX,
    double hubY, double hubR, int minArea, _TowerAxis? towerAxis) {
  final core = Uint8List.fromList(mask);
  final rad = (1.6 * hubR).toInt() + 1;
  final cx = hubX.round(), cy = hubY.round();
  for (var y = math.max(0, cy - rad); y <= math.min(h - 1, cy + rad); y++) {
    final dy = y - cy;
    final dx = (rad * rad - dy * dy);
    if (dx < 0) continue;
    final span = math.sqrt(dx).floor();
    final lo = math.max(0, cx - span), hi = math.min(w - 1, cx + span);
    for (var x = lo; x <= hi; x++) {
      core[y * w + x] = 0;
    }
  }

  _Arm? tower;
  if (towerAxis != null) {
    final tx = <int>[], ty = <int>[];
    // Python 是 `yy > hub[1] + hub_r`（嚴格大於），最小整數列因此是 floor+1
    final yMin = (hubY + hubR).floor() + 1;
    for (var y = math.max(0, yMin); y < h; y++) {
      final axisX = towerAxis.a * y + towerAxis.b;
      for (var x = 0; x < w; x++) {
        if (core[y * w + x] == 0) continue;
        if ((x - axisX).abs() <= 0.6 * towerAxis.tw) {
          tx.add(x);
          ty.add(y);
        }
      }
    }
    if (tx.length >= minArea) {
      var maxY = -1;
      for (final y in ty) {
        if (y > maxY) maxY = y;
      }
      tower = _Arm(Int32List.fromList(tx), Int32List.fromList(ty),
          maxY >= h - 2);
      for (var i = 0; i < tx.length; i++) {
        core[ty[i] * w + tx[i]] = 0;
      }
    }
  }

  final cc = BladeImageOps.connectedComponents(core, w, h);
  final buckets = <int, List<int>>{};
  for (var i = 0; i < core.length; i++) {
    final l = cc.labels[i];
    if (l == 0) continue;
    (buckets[l] ??= []).add(i);
  }
  final comps = <_Arm>[];
  buckets.forEach((label, idx) {
    if (idx.length < minArea) return;
    final xs = Int32List(idx.length), ys = Int32List(idx.length);
    for (var i = 0; i < idx.length; i++) {
      xs[i] = idx[i] % w;
      ys[i] = idx[i] ~/ w;
    }
    final s = cc.stats[label];
    final c = _Arm(xs, ys, s.top + s.height >= h - 2);
    // 沒接在輪轂上（雲、鳥、遠處物件）
    if (c.minDistTo(hubX, hubY) > 3.0 * hubR) return;
    comps.addAll(_splitByAngle(c, hubX, hubY, hubR));
  });
  return _SplitResult(comps, tower);
}

/// 一個元件內若有多條「臂」（葉片/塔架在輪轂附近黏在一起），用對輪轂的角度直方圖拆開。
///
/// 只用固定半徑帶（6–14 hubR）的像素建直方圖：每條臂在帶內的像素數只和臂寬成正比，
/// 不會被很長的塔架壓過細短的葉片，讓 8% 門檻切不開夾角小的臂。
List<_Arm> _splitByAngle(_Arm comp, double hubX, double hubY, double hubR,
    {int minPixels = 30}) {
  final n = comp.length;
  final ang = Float64List(n);
  final d = Float64List(n);
  for (var i = 0; i < n; i++) {
    final dx = comp.xs[i] - hubX, dy = comp.ys[i] - hubY;
    d[i] = _hypot(dx, dy);
    var a = math.atan2(-dy, dx) * 180.0 / math.pi;
    a %= 360.0;
    if (a < 0) a += 360.0;
    ang[i] = a;
  }
  var band = List<bool>.generate(n, (i) => d[i] > 6.0 * hubR && d[i] < 14.0 * hubR);
  var count = band.where((b) => b).length;
  if (count < 50) {
    band = List<bool>.generate(n, (i) => d[i] > 6.0 * hubR);
    count = band.where((b) => b).length;
  }
  if (count < 50) return [comp];

  final hist = Float64List(360);
  for (var i = 0; i < n; i++) {
    if (band[i]) hist[ang[i].toInt() % 360] += 1;
  }
  // 環狀 5 點平均
  final sm = Float64List(360);
  var smMax = 0.0;
  for (var i = 0; i < 360; i++) {
    var s = 0.0;
    for (var j = -2; j <= 2; j++) {
      s += hist[(i + j + 360) % 360];
    }
    sm[i] = s / 5.0;
    if (sm[i] > smMax) smMax = sm[i];
  }
  final on = List<bool>.generate(360, (i) => sm[i] > 0.08 * smMax);
  if (on.every((b) => b) || !on.any((b) => b)) return [comp];

  // 從某個 off 位置開始掃，保證不切到臂中間
  var start = 0;
  for (var i = 0; i < 360; i++) {
    if (!on[i]) {
      start = i;
      break;
    }
  }
  final runs = <List<int>>[]; // [起始角, 結束角]
  var i2 = 0;
  while (i2 < 360) {
    final j = (start + i2) % 360;
    if (on[j]) {
      final a = j;
      var len = 0;
      while (len < 360 && on[(start + i2) % 360]) {
        i2++;
        len++;
      }
      runs.add([a, (a + len - 1) % 360]);
    } else {
      i2++;
    }
  }
  if (runs.length <= 1) return [comp];

  final centers = runs
      .map((r) => ((r[0] + (((r[1] - r[0]) % 360 + 360) % 360) / 2.0) % 360))
      .toList();
  final label = List<int>.filled(n, -1);
  for (var r = 0; r < runs.length; r++) {
    final a = runs[r][0];
    final span = (((runs[r][1] - a) % 360) + 360) % 360;
    for (var i = 0; i < n; i++) {
      final rel = (((ang[i] - a) % 360) + 360) % 360;
      if (rel <= span) label[i] = r;
    }
  }
  for (var i = 0; i < n; i++) {
    if (label[i] >= 0) continue;
    var best = 0, bestD = double.infinity;
    for (var r = 0; r < centers.length; r++) {
      final diff = ((((ang[i] - centers[r] + 180.0) % 360) + 360) % 360) - 180.0;
      final ad = diff.abs();
      if (ad < bestD) {
        bestD = ad;
        best = r;
      }
    }
    label[i] = best;
  }

  final compMaxY = comp.maxY();
  final parts = <_Arm>[];
  for (var r = 0; r < runs.length; r++) {
    final xs = <int>[], ys = <int>[];
    for (var i = 0; i < n; i++) {
      if (label[i] == r) {
        xs.add(comp.xs[i]);
        ys.add(comp.ys[i]);
      }
    }
    if (xs.length < minPixels) continue;
    var maxY = -1;
    for (final y in ys) {
      if (y > maxY) maxY = y;
    }
    parts.add(_Arm(Int32List.fromList(xs), Int32List.fromList(ys),
        comp.touchesBottom && maxY >= compMaxY - 1));
  }
  return parts.length >= 2 ? parts : [comp];
}

/// 分類塔架／葉片。
///
/// 塔架：伸長、軸線近垂直（<20°）、質心在輪轂下方；碰底邊者優先（取最寬），
/// 否則取往下延伸最遠者。葉片：其餘伸長元件（elong > 2.5）且葉尖半徑 > 4 hubR，
/// 依面積取前 maxBlades。
_ClassifyResult _classify(List<_Arm> comps, double hubX, double hubY,
    double hubR, int maxBlades, _Arm? givenTower) {
  final axes = <_Axis>[];
  final rmax = <double>[];
  for (final c in comps) {
    axes.add(BladeStructureService._pcaAxis(c.xs, c.ys));
    rmax.add(c.maxDistTo(hubX, hubY));
  }

  _Arm? tower;
  _Axis? towerDir;
  if (givenTower != null) {
    tower = givenTower;
    towerDir = BladeStructureService._pcaAxis(tower.xs, tower.ys);
  } else {
    final cands = <int>[];
    for (var i = 0; i < comps.length; i++) {
      final a = axes[i];
      if (a.elong > 2.5 &&
          a.cy > hubY &&
          BladeStructureService._axisAngleBetween(a.dx, a.dy, 0, 1) < 20.0) {
        cands.add(i);
      }
    }
    if (cands.isNotEmpty) {
      final bottom = cands.where((i) => comps[i].touchesBottom).toList();
      if (bottom.isNotEmpty) {
        var best = bottom.first, bestW = -1.0;
        for (final i in bottom) {
          final wd = BladeStructureService._medianRowWidth(comps[i]);
          if (wd > bestW) {
            bestW = wd;
            best = i;
          }
        }
        tower = comps[best];
        towerDir = axes[best];
      } else {
        var best = cands.first, bestY = -1;
        for (final i in cands) {
          final my = comps[i].maxY();
          if (my > bestY) {
            bestY = my;
            best = i;
          }
        }
        tower = comps[best];
        towerDir = axes[best];
      }
    }
  }

  final blades = <_Arm>[];
  for (var i = 0; i < comps.length; i++) {
    if (identical(comps[i], tower)) continue;
    if (axes[i].elong > 2.5 && rmax[i] > 4.0 * hubR) blades.add(comps[i]);
  }
  blades.sort((a, b) => b.length.compareTo(a.length));
  return _ClassifyResult(
      tower, towerDir, blades.take(maxBlades).toList());
}

/// 以 p 為圓心取樣一圈，數「與圓心連通的遮罩區域」由 0→1 的次數 = 從該點伸出去的臂數。
///
/// 只看與圓心連通的區域：否則塔架上的點會把旁邊經過的垂掛葉片也算成臂。
int _countArms(Uint8List mask, int w, int h, double px, double py,
    double radius, {int n = 96}) {
  final x0 = px.round(), y0 = py.round();
  final r = radius.ceil() + 2;
  final xa = math.max(0, x0 - r), xb = math.min(w, x0 + r + 1);
  final ya = math.max(0, y0 - r), yb = math.min(h, y0 + r + 1);
  final cw = xb - xa, chh = yb - ya;
  if (cw <= 0 || chh <= 0) return 0;
  final cx = x0 - xa, cy = y0 - ya;
  if (cy < 0 || cy >= chh || cx < 0 || cx >= cw) return 0;
  final crop = Uint8List(cw * chh);
  final lim = (radius + 1.5) * (radius + 1.5);
  for (var y = 0; y < chh; y++) {
    for (var x = 0; x < cw; x++) {
      final gx = xa + x, gy = ya + y;
      final dx = gx - x0, dy = gy - y0;
      if (dx * dx + dy * dy > lim) continue;
      crop[y * cw + x] = mask[gy * w + gx] != 0 ? 255 : 0;
    }
  }
  if (crop[cy * cw + cx] == 0) return 0;
  final cc = BladeImageOps.connectedComponents(crop, cw, chh);
  final own = cc.labels[cy * cw + cx];
  final ring = List<bool>.filled(n, false);
  for (var i = 0; i < n; i++) {
    final th = 2 * math.pi * i / n;
    final sx = (cx + radius * math.cos(th)).round();
    final sy = (cy + radius * math.sin(th)).round();
    if (sx < 0 || sx >= cw || sy < 0 || sy >= chh) continue;
    ring[i] = cc.labels[sy * cw + sx] == own;
  }
  var arms = 0;
  for (var i = 0; i < n; i++) {
    if (ring[i] && !ring[(i - 1 + n) % n]) arms++;
  }
  return arms;
}

/// 從遮罩下方 30% 的列找塔架：逐列取連續段、依中心 x 串成軌跡，
/// 選最垂直且覆蓋夠多列的軌跡。葉片斜著穿過下方列時中心 x 會隨 y 線性漂移，
/// 塔架則近乎不動，所以用斜率挑。
_TowerAxis? _towerAxisFromBottom(Uint8List mask, int w, int h) {
  var top = h, bottom = -1;
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      if (mask[row + x] != 0) {
        if (y < top) top = y;
        if (y > bottom) bottom = y;
        break;
      }
    }
  }
  if (bottom < 0) return null;
  final y0 = (bottom - 0.3 * (bottom - top)).toInt();
  final step = math.max(1, (bottom - y0) ~/ 60);
  final rows = <int>[];
  for (var y = y0; y <= bottom; y += step) {
    rows.add(y);
  }
  final tracks = <List<List<double>>>[]; // 每軌：[[x...],[y...],[w...]]
  for (final y in rows) {
    final row = y * w;
    var x = 0;
    while (x < w) {
      if (mask[row + x] == 0) {
        x++;
        continue;
      }
      final s = x;
      while (x < w && mask[row + x] != 0) {
        x++;
      }
      final e = x; // [s, e)
      final ccx = (s + e - 1) / 2.0;
      final wd = (e - s).toDouble();
      var joined = false;
      for (final t in tracks) {
        if (t[1].last != y &&
            (t[0].last - ccx).abs() < math.max(1.5 * wd, 15.0)) {
          t[0].add(ccx);
          t[1].add(y.toDouble());
          t[2].add(wd);
          joined = true;
          break;
        }
      }
      if (!joined) {
        tracks.add([
          [ccx],
          [y.toDouble()],
          [wd]
        ]);
      }
    }
  }
  final cands =
      tracks.where((t) => t[1].length >= 0.6 * rows.length).toList();
  if (cands.isEmpty) return null;

  List<double> fitLine(List<double> ys, List<double> xs) {
    final n = ys.length;
    var sy = 0.0, sx = 0.0, syy = 0.0, syx = 0.0;
    for (var i = 0; i < n; i++) {
      sy += ys[i];
      sx += xs[i];
      syy += ys[i] * ys[i];
      syx += ys[i] * xs[i];
    }
    final den = n * syy - sy * sy;
    if (den.abs() < 1e-12) return [0.0, sx / n];
    final a = (n * syx - sy * sx) / den;
    return [a, (sx - a * sy) / n];
  }

  List<List<double>>? best;
  var bestSlope = double.infinity;
  for (final t in cands) {
    final s = fitLine(t[1], t[0])[0].abs();
    if (s < bestSlope) {
      bestSlope = s;
      best = t;
    }
  }
  if (best == null || bestSlope > 0.35) return null; // 超過 ~20° 就不像塔架
  final ab = fitLine(best[1], best[0]);
  final widths = List<double>.from(best[2])..sort();
  return _TowerAxis(ab[0], ab[1], widths[widths.length ~/ 2]);
}

/// 沿塔軸往上走，取「臂數 ≥ 3 的連續區段」最上端當輪轂/機艙位置。
///
/// 停止條件是「軸線離開遮罩超過 3 步」，不是「連續 3 步不合格」：六點鐘葉片貼著
/// 塔架時，塔身中段會出現零星的 3 臂點，之後又掉回 2 臂——用「不合格就停」會讓
/// 走訪停在塔身中央。離開遮罩才停，就只會停在機艙上方。
_InitialHub? _initialHubTowerFirst(
    Uint8List mask, int w, int h, Float32List dt) {
  final axis = _towerAxisFromBottom(mask, w, h);
  if (axis == null) return null;
  var top = h, bottom = -1;
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      if (mask[row + x] != 0) {
        if (y < top) top = y;
        if (y > bottom) bottom = y;
        break;
      }
    }
  }
  if (bottom < 0) return null;
  // 轉子在框內時輪轂上下都還有結構，不可能落在整體高度的最下緣；
  // 落在下緣代表走訪停在塔身或地平線殘渣上，回 null 讓呼叫端改用 DT + 臂數法。
  final yLimit = top + 0.75 * (bottom - top);
  final step = math.max(2, (axis.tw / 2).toInt());
  double? bestX, bestY, bestR;
  var gap = 0;
  var segPeak = 0.0;
  for (var y = h - 1; y > top; y -= step) {
    final x = axis.a * y + axis.b;
    final xi = x.round();
    final onMask = xi >= 0 && xi < w && mask[y * w + xi] != 0;
    if (onMask) {
      final r = dt[y * w + xi];
      if (r > segPeak) segPeak = r;
      // DT 門檻：tw 是塔基寬度、塔架往上收窄，所以下限只用 0.2×tw；
      // 另要求不低於沿軸最大 DT 的 60%，讓終點停在輪轂/機艙「中心」而非上緣薄處
      if (r >= math.max(0.2 * axis.tw, 0.6 * segPeak) &&
          _countArms(mask, w, h, x, y.toDouble(), math.max(4.0 * r, 12.0)) >= 3) {
        bestX = x;
        bestY = y.toDouble();
        bestR = r;
      }
    }
    if (bestX != null) {
      gap = onMask ? 0 : gap + 1;
      if (gap > 3) break;
    }
  }
  if (bestX == null || bestY! > yLimit) return null;
  return _InitialHub(bestX, bestY, bestR!, axis);
}

/// 輪轂初估：先試「塔架優先」（沿塔軸找分叉），失敗才用「DT 局部極大值 + 臂數」。
///
/// 臂數法只在最大連通元件內找（排除獨立雲塊）；輪轂 3–4 臂、塔架/葉片中段 2 臂。
_InitialHub _initialHub(
    Uint8List mask, int w, int h, Float32List dt, int yCut) {
  final tf = _initialHubTowerFirst(mask, w, h, dt);
  if (tf != null) return tf;

  final largest = _largestComponentMask(mask, w, h);
  final band = Float32List(w * h);
  var peak = 0.0;
  for (var y = 0; y < math.min(yCut, h); y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      if (largest[i] == 0) continue;
      band[i] = dt[i];
      if (band[i] > peak) peak = band[i];
    }
  }
  final dil = _maxFilter(band, w, h, 15);
  final cand = <int>[];
  for (var i = 0; i < band.length; i++) {
    if (band[i] >= dil[i] - 1e-6 && band[i] >= 0.4 * peak && band[i] > 0) {
      cand.add(i);
    }
  }
  cand.sort((a, b) => band[b].compareTo(band[a]));

  final pickedX = <double>[], pickedY = <double>[], pickedR = <double>[];
  final pickedArms = <int>[];
  for (final i in cand) {
    final px = (i % w).toDouble(), py = (i ~/ w).toDouble();
    final r = band[i];
    var tooClose = false;
    for (var j = 0; j < pickedX.length; j++) {
      if (_hypot(px - pickedX[j], py - pickedY[j]) <
          3.0 * math.max(r, pickedR[j])) {
        tooClose = true;
        break;
      }
    }
    if (tooClose) continue;
    pickedX.add(px);
    pickedY.add(py);
    pickedR.add(r);
    pickedArms.add(_countArms(mask, w, h, px, py, math.max(4.0 * r, 12.0)));
    if (pickedX.length >= 12) break;
  }
  if (pickedX.isEmpty) {
    // 理論上走不到（遮罩非空就有局部極大值），但不能讓它丟例外
    var bi = 0;
    for (var i = 1; i < dt.length; i++) {
      if (dt[i] > dt[bi]) bi = i;
    }
    return _InitialHub(
        (bi % w).toDouble(), (bi ~/ w).toDouble(), dt[bi], null);
  }
  var best = 0;
  for (var i = 1; i < pickedX.length; i++) {
    if (pickedArms[i] > pickedArms[best] ||
        (pickedArms[i] == pickedArms[best] && pickedR[i] > pickedR[best])) {
      best = i;
    }
  }
  return _InitialHub(pickedX[best], pickedY[best], pickedR[best], null);
}

Uint8List _largestComponentMask(Uint8List mask, int w, int h) {
  final cc = BladeImageOps.connectedComponents(mask, w, h);
  if (cc.count <= 2) return mask;
  var best = 1;
  for (var i = 2; i < cc.count; i++) {
    if (cc.stats[i].area > cc.stats[best].area) best = i;
  }
  final out = Uint8List(w * h);
  for (var i = 0; i < out.length; i++) {
    out[i] = cc.labels[i] == best ? 255 : 0;
  }
  return out;
}

/// 方形核的最大值濾波（對照 `cv2.dilate(band, ones((k,k)))`）。
/// 可分離：先列後行，各取滑動最大值。
Float32List _maxFilter(Float32List src, int w, int h, int k) {
  final r = k ~/ 2;
  final tmp = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      var m = src[row + x];
      final lo = math.max(0, x - r), hi = math.min(w - 1, x + r);
      for (var i = lo; i <= hi; i++) {
        if (src[row + i] > m) m = src[row + i];
      }
      tmp[row + x] = m;
    }
  }
  final out = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    final lo = math.max(0, y - r), hi = math.min(h - 1, y + r);
    for (var x = 0; x < w; x++) {
      var m = tmp[y * w + x];
      for (var i = lo; i <= hi; i++) {
        if (tmp[i * w + x] > m) m = tmp[i * w + x];
      }
      out[y * w + x] = m;
    }
  }
  return out;
}
