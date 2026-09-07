import 'dart:math' as math;
import 'dart:typed_data';

/// STFT 的輸出。`mag` 是**時間為主序**的展平陣列（`mag[ti * nFreq + fi]`）：
/// 兩個主要用途——逐幀的頻帶能量、以及選定幀的平均頻譜——都是「固定時間、掃頻率」，
/// 時間為主序時那是連續記憶體。
class BladeStft {
  final Float64List freqsHz;
  final Float64List timesS;
  final Float64List mag;
  final int nFreq;
  final int nTime;

  const BladeStft({
    required this.freqsHz,
    required this.timesS,
    required this.mag,
    required this.nFreq,
    required this.nTime,
  });

  double magAt(int fi, int ti) => mag[ti * nFreq + fi];
}

/// 聲音層要用、`package:image` 與 Dart 標準庫都沒有的數值運算。
///
/// 每一項都對照 `blade_prototype` 用的 scipy／numpy 函式，**而且是先在 Python 端
/// 把語意釘死之後才寫的**——STFT 的縮放、Savitzky–Golay 的邊緣處理、medfilt 的
/// 邊界填補各有好幾種說得通的慣例，猜錯不會報錯，只會讓最後一個數字對不上：
///
/// - `stft`：`scipy.signal.stft` 的預設（`boundary='zeros'`、`padded=True`、
///   週期性 Hann、除以 `window.sum()`），已對照到逐位相同
/// - `savgolSmooth`：`mode='interp'`——邊緣不補值，改對頭尾各 window 點擬合二次式
/// - `medianFilter`：`scipy.signal.medfilt` 的**零填補**（不是 REPLICATE）
/// - `percentile`：numpy 的 linear 方法
///
/// 幾何層的多項式擬合與中位數也搬到這裡，讓葉片模組只有一份這些數學。
class BladeDsp {
  BladeDsp._();

  /// 頻譜分析窗長（秒）。與 `acoustics.py::_spectrogram` 相同。
  static const double stftWindowS = 0.032;

  /// Savitzky–Golay 平滑的窗長上限（`acoustics.py` 對包絡用的就是 9 點二次）
  static const int savgolMaxWindow = 9;

  /// window 9 / order 2 的平滑係數 = [-21, 14, 39, 54, 59, 54, 39, 14, -21] / 231。
  /// 硬寫是刻意的：`acoustics.py` 只用這一組，而現推一次最小平方解只會多一處出錯點。
  static const List<double> savgol92 = [
    -21.0 / 231.0, 14.0 / 231.0, 39.0 / 231.0, 54.0 / 231.0, 59.0 / 231.0,
    54.0 / 231.0, 39.0 / 231.0, 14.0 / 231.0, -21.0 / 231.0,
  ];

  // ------------------------------------------------------------- 頻譜

  /// 分析窗長：`2^round(log2(max(64, winS * sr)))`，與 Python 相同。
  static int nperSegFor(int sampleRate, {double winS = stftWindowS}) {
    final v = math.max(64.0, winS * sampleRate);
    final e = (math.log(v) / math.ln2).round();
    return 1 << e;
  }

  /// 週期性 Hann（`get_window('hann', n, fftbins=True)`）：分母是 n 而不是 n−1。
  /// 用對稱版的話窗和會差一點，除以窗和之後每個 bin 都跟著偏。
  static Float64List hannPeriodic(int n) {
    final w = Float64List(n);
    for (var i = 0; i < n; i++) {
      w[i] = 0.5 - 0.5 * math.cos(2.0 * math.pi * i / n);
    }
    return w;
  }

  /// 原地基 2 FFT。`re`/`im` 長度必須是 2 的次方。
  static void fft(Float64List re, Float64List im) {
    final n = re.length;
    if (n <= 1) return;
    // 位元反轉重排
    for (var i = 1, j = 0; i < n; i++) {
      var bit = n >> 1;
      for (; (j & bit) != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        var t = re[i];
        re[i] = re[j];
        re[j] = t;
        t = im[i];
        im[i] = im[j];
        im[j] = t;
      }
    }
    for (var len = 2; len <= n; len <<= 1) {
      final ang = -2.0 * math.pi / len;
      final wr = math.cos(ang), wi = math.sin(ang);
      for (var i = 0; i < n; i += len) {
        var cr = 1.0, ci = 0.0;
        for (var k = 0; k < len ~/ 2; k++) {
          final ur = re[i + k], ui = im[i + k];
          final vr = re[i + k + len ~/ 2] * cr - im[i + k + len ~/ 2] * ci;
          final vi = re[i + k + len ~/ 2] * ci + im[i + k + len ~/ 2] * cr;
          re[i + k] = ur + vr;
          im[i + k] = ui + vi;
          re[i + k + len ~/ 2] = ur - vr;
          im[i + k + len ~/ 2] = ui - vi;
          final nr = cr * wr - ci * wi;
          ci = cr * wi + ci * wr;
          cr = nr;
        }
      }
    }
  }

  /// 幅值頻譜圖，對照 `scipy.signal.stft(..., window='hann', noverlap=nper//2)` 的預設。
  ///
  /// 三個容易寫錯而且不會報錯的地方，都與 Python 對照過：
  /// ①前後各補 `nper/2` 個零（`boundary='zeros'`）；②再補到能整除 hop（`padded=True`）；
  /// ③除以窗和（`scaling='spectrum'`）。
  static BladeStft stft(Float64List x, int sampleRate, {double winS = stftWindowS}) {
    final nper = nperSegFor(sampleRate, winS: winS);
    final hop = nper ~/ 2;
    final win = hannPeriodic(nper);
    var winSum = 0.0;
    for (final v in win) {
      winSum += v;
    }

    // boundary='zeros' + padded=True
    var padded = x.length + 2 * hop;
    final rem = (padded - nper) % hop;
    if (rem != 0) padded += hop - rem;
    final xp = Float64List(padded);
    for (var i = 0; i < x.length; i++) {
      xp[hop + i] = x[i];
    }

    final nSeg = (padded - nper) ~/ hop + 1;
    final nFreq = nper ~/ 2 + 1;
    final mag = Float64List(nSeg * nFreq);
    final re = Float64List(nper), im = Float64List(nper);
    for (var s = 0; s < nSeg; s++) {
      final off = s * hop;
      for (var i = 0; i < nper; i++) {
        re[i] = xp[off + i] * win[i];
        im[i] = 0.0;
      }
      fft(re, im);
      final base = s * nFreq;
      for (var k = 0; k < nFreq; k++) {
        mag[base + k] = math.sqrt(re[k] * re[k] + im[k] * im[k]) / winSum;
      }
    }
    final freqs = Float64List(nFreq);
    for (var k = 0; k < nFreq; k++) {
      freqs[k] = k * sampleRate / nper;
    }
    final times = Float64List(nSeg);
    for (var s = 0; s < nSeg; s++) {
      times[s] = s * hop / sampleRate;
    }
    return BladeStft(
        freqsHz: freqs, timesS: times, mag: mag, nFreq: nFreq, nTime: nSeg);
  }

  /// 逐幀的頻帶能量（幅值平方和）。頻帶內沒有 bin 時回全 0，與 Python 相同。
  static Float64List bandEnergy(BladeStft s, double lo, double hi) {
    final out = Float64List(s.nTime);
    var any = false;
    for (var k = 0; k < s.nFreq; k++) {
      if (s.freqsHz[k] >= lo && s.freqsHz[k] <= hi) {
        any = true;
        break;
      }
    }
    if (!any) return out;
    for (var t = 0; t < s.nTime; t++) {
      final base = t * s.nFreq;
      var acc = 0.0;
      for (var k = 0; k < s.nFreq; k++) {
        if (s.freqsHz[k] < lo || s.freqsHz[k] > hi) continue;
        final v = s.mag[base + k];
        acc += v * v;
      }
      out[t] = acc;
    }
    return out;
  }

  /// 選定幀的平均頻譜（`S[:, idx].mean(axis=1)`）。`idx` 為空時回全 NaN。
  static Float64List meanSpectrum(BladeStft s, List<int> idx) {
    final out = Float64List(s.nFreq);
    if (idx.isEmpty) {
      for (var k = 0; k < s.nFreq; k++) {
        out[k] = double.nan;
      }
      return out;
    }
    for (final t in idx) {
      final base = t * s.nFreq;
      for (var k = 0; k < s.nFreq; k++) {
        out[k] += s.mag[base + k];
      }
    }
    for (var k = 0; k < s.nFreq; k++) {
      out[k] /= idx.length;
    }
    return out;
  }

  // ------------------------------------------------------------- 週期性

  /// 正規化自相關（lag 0 = 1）。全為 0 時回全 0（不是 NaN），與 Python 相同。
  static Float64List autocorrNormalized(Float64List env) {
    final n = env.length;
    final out = Float64List(n);
    if (n == 0) return out;
    var mean = 0.0;
    for (final v in env) {
      mean += v;
    }
    mean /= n;
    final e = Float64List(n);
    var nonZero = false;
    for (var i = 0; i < n; i++) {
      e[i] = env[i] - mean;
      if (e[i] != 0.0) nonZero = true;
    }
    if (!nonZero) return out;
    for (var lag = 0; lag < n; lag++) {
      var acc = 0.0;
      for (var i = 0; i + lag < n; i++) {
        acc += e[i] * e[i + lag];
      }
      out[lag] = acc;
    }
    final z = out[0] + 1e-12;
    for (var lag = 0; lag < n; lag++) {
      out[lag] /= z;
    }
    return out;
  }

  /// 拋物線精修峰位置（可能非整數）。對照 `acoustics.py::_refine_peak`。
  static double refinePeak(Float64List ac, int k) {
    if (k > 0 && k < ac.length - 1) {
      final y0 = ac[k - 1], y1 = ac[k], y2 = ac[k + 1];
      final denom = y0 - 2 * y1 + y2;
      if (denom != 0) return k + 0.5 * (y0 - y2) / denom;
    }
    return k.toDouble();
  }

  /// 線性內插取值。超出範圍回 0（與 Python 的 `_at_lag` 相同，不是 NaN）。
  static double valueAtLag(Float64List ac, double lag) {
    if (lag < 0 || lag >= ac.length - 1) return 0.0;
    final i = lag.floor();
    final w = lag - i;
    return ac[i] * (1 - w) + ac[i + 1] * w;
  }

  /// 指定頻率上的振幅調變分量（相對包絡均值的比例）。
  /// 對照 `acoustics.py::_mod_depth`——單一頻率的 DFT，不是整段 FFT 取一個 bin
  /// （頻率通常落在 bin 之間）。
  static double modulationDepth(Float64List env, double frameHz, double freq) {
    if (!freq.isFinite || freq <= 0 || env.length < 8) return double.nan;
    var mean = 0.0;
    for (final v in env) {
      mean += v;
    }
    mean /= env.length;
    if (mean <= 0) return double.nan;
    var sr = 0.0, si = 0.0;
    for (var i = 0; i < env.length; i++) {
      final ang = -2.0 * math.pi * freq * i / frameHz;
      sr += env[i] * math.cos(ang);
      si += env[i] * math.sin(ang);
    }
    final c = 2.0 * math.sqrt(sr * sr + si * si) / env.length;
    return c / mean;
  }

  // ------------------------------------------------------------- 濾波

  /// Savitzky–Golay 平滑，窗 = `min(n ~/ 2 * 2 - 1, 9)`、二次、`mode='interp'`。
  /// 邊緣各 (w−1)/2 點**不補值**，改對頭尾各 w 點擬合二次式後求值——
  /// 補值會把包絡兩端拉平，而包絡兩端正是週期性偵測要看的地方。
  static Float64List savgolSmooth(Float64List y) {
    final n = y.length;
    if (n < 11) return Float64List.fromList(y);
    // Python 是 `min(len(env)//2*2-1, 9)`，而它被 `len(env) >= 11` 守著：
    // n = 11 時就已經是 9，再長也被 min 夾在 9。所以窗長恆為 9，
    // 不留「其他窗長」的分支——那條路永遠走不到，卻會看起來像測過了。
    const w = savgolMaxWindow;
    const half = (w - 1) ~/ 2;
    final out = Float64List(n);
    const c = savgol92;
    for (var i = half; i < n - half; i++) {
      var acc = 0.0;
      for (var j = 0; j < w; j++) {
        acc += c[j] * y[i - half + j];
      }
      out[i] = acc;
    }
    final xs = Float64List(w);
    for (var i = 0; i < w; i++) {
      xs[i] = i.toDouble();
    }
    final keep = List<bool>.filled(w, true);
    final left = polyfit(xs, List<double>.generate(w, (i) => y[i]), keep, 2);
    for (var i = 0; i < half; i++) {
      out[i] = polyval(left, i.toDouble());
    }
    final right =
        polyfit(xs, List<double>.generate(w, (i) => y[n - w + i]), keep, 2);
    for (var i = 0; i < half; i++) {
      out[n - half + i] = polyval(right, (w - half + i).toDouble());
    }
    return out;
  }


  /// 中值濾波，**零填補**（`scipy.signal.medfilt` 的行為）。
  /// 用 REPLICATE 的話頻譜兩端的基線會被端點值拉住，突出量跟著偏。
  static Float64List medianFilter(Float64List y, int k) {
    final n = y.length;
    final out = Float64List(n);
    if (n == 0) return out;
    final kk = k.isOdd ? k : k + 1;
    final half = kk ~/ 2;
    final buf = Float64List(kk);
    for (var i = 0; i < n; i++) {
      for (var j = 0; j < kk; j++) {
        final idx = i - half + j;
        buf[j] = (idx >= 0 && idx < n) ? y[idx] : 0.0;
      }
      final s = Float64List.fromList(buf)..sort();
      out[i] = s[half]; // kk 已強制為奇數，中位數就是正中間那個
    }
    return out;
  }

  // ------------------------------------------------------------- 統計

  /// numpy 的 linear 方法。
  static double percentile(List<double> a, double q) {
    if (a.isEmpty) return double.nan;
    final s = Float64List.fromList(a)..sort();
    final pos = (q / 100.0) * (s.length - 1);
    final i = pos.floor(), f = pos - i;
    if (i + 1 >= s.length) return s[s.length - 1];
    return s[i] * (1 - f) + s[i + 1] * f;
  }

  static double median(List<double> v) {
    if (v.isEmpty) return double.nan;
    final s = List<double>.from(v)..sort();
    final n = s.length;
    return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2.0;
  }

  /// numpy 的 `round`：**半數取偶**（Dart 的 `.round()` 是半數遠離零）。
  /// 只在剛好落在 .5 時有差，但那會變成整整一幀的偏移。
  static int roundHalfEven(double v) {
    final f = v.floor();
    final diff = v - f;
    if (diff > 0.5) return f + 1;
    if (diff < 0.5) return f;
    return f.isEven ? f : f + 1;
  }

  /// 正規方程 + 高斯消去的多項式擬合。係數由高次到低次（numpy 順序）。
  static List<double> polyfit(
      Float64List x, List<double> y, List<bool> keep, int deg) {
    final m = deg + 1;
    final a = List<List<double>>.generate(m, (_) => List<double>.filled(m, 0.0));
    final b = List<double>.filled(m, 0.0);
    for (var i = 0; i < y.length; i++) {
      if (!keep[i] || y[i].isNaN) continue;
      final pw = List<double>.filled(m, 1.0);
      for (var j = 1; j < m; j++) {
        pw[j] = pw[j - 1] * x[i];
      }
      for (var r = 0; r < m; r++) {
        for (var c = 0; c < m; c++) {
          a[r][c] += pw[r] * pw[c];
        }
        b[r] += pw[r] * y[i];
      }
    }
    for (var col = 0; col < m; col++) {
      var piv = col;
      for (var r = col + 1; r < m; r++) {
        if (a[r][col].abs() > a[piv][col].abs()) piv = r;
      }
      if (a[piv][col].abs() < 1e-12) continue;
      if (piv != col) {
        final tr = a[piv];
        a[piv] = a[col];
        a[col] = tr;
        final tb = b[piv];
        b[piv] = b[col];
        b[col] = tb;
      }
      for (var r = col + 1; r < m; r++) {
        final f = a[r][col] / a[col][col];
        if (f == 0) continue;
        for (var c = col; c < m; c++) {
          a[r][c] -= f * a[col][c];
        }
        b[r] -= f * b[col];
      }
    }
    final sol = List<double>.filled(m, 0.0);
    for (var r = m - 1; r >= 0; r--) {
      var s = b[r];
      for (var c = r + 1; c < m; c++) {
        s -= a[r][c] * sol[c];
      }
      sol[r] = a[r][r].abs() < 1e-12 ? 0.0 : s / a[r][r];
    }
    return sol.reversed.toList();
  }

  static double polyval(List<double> coeffs, double x) {
    var v = 0.0;
    for (final c in coeffs) {
      v = v * x + c;
    }
    return v;
  }
}
