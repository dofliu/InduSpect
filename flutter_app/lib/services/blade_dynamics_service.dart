import 'dart:typed_data';

import 'blade_dsp.dart';
import 'blade_geometry_compare.dart';

/// 從影片抽出某個時刻的一幀，回傳可解碼的影像位元組（抽不到回 null）。
///
/// **這是動態層唯一缺的一塊，而且刻意留成注入點。** Flutter 沒有純 Dart 的
/// H.264／HEVC 解碼器，抽幀一定要走原生（Android `MediaMetadataRetriever`／
/// `MediaExtractor`＋`MediaCodec`，iOS `AVAssetImageGenerator`）。那是一段
/// 沒有實機就驗不了的 platform channel，所以這裡不押一個猜的實作——
/// 編排與判定邏輯全部用注入的抽幀器測到底，接上原生那天只要補這一個函式。
///
/// 詳見 `BLADE_INSPECTION_SPEC.md` §12「影片逐幀在 Flutter 端處理成本高」。
typedef BladeFrameExtractor = Future<Uint8List?> Function(
    String videoPath, double atSeconds);

/// 一幀的量測結果。
class BladeDynamicsFrame {
  final double atSeconds;

  /// 這一幀畫面裡**最接近正下方（270°）**那片葉片的葉尖半徑（px）。
  /// 抽不到幀、閘門拒收、或畫面裡沒有朝下的葉片時是 NaN。
  final double downTipRadiusPx;

  /// 該葉片軸線與 270° 的夾角。用來說明「這一幀有多接近六點鐘」。
  final double offFromSixOclockDeg;
  final bool decoded;
  final bool measured;

  const BladeDynamicsFrame({
    required this.atSeconds,
    required this.downTipRadiusPx,
    required this.offFromSixOclockDeg,
    required this.decoded,
    required this.measured,
  });
}

/// 動態層的結果。
class BladeDynamicsResult {
  final bool ok;

  /// 不能分析的原因（給使用者看的話）
  final List<String> reasons;
  final int framesRequested;
  final int framesDecoded;
  final int framesMeasured;
  final List<BladeDynamicsFrame> frames;

  /// 三片（依通過六點鐘的先後順序）的葉尖半徑中位數 px。
  /// **是通過順序不是實際葉片編號**，與聲音層同一個限制。
  final List<double> tipRadiusMedianPx;

  /// 三片半徑互比。`null` 表示樣本不足，不是「一致」。
  final MetricComparison? radiusComparison;
  final List<String> notes;

  const BladeDynamicsResult({
    required this.ok,
    this.reasons = const [],
    this.framesRequested = 0,
    this.framesDecoded = 0,
    this.framesMeasured = 0,
    this.frames = const [],
    this.tipRadiusMedianPx = const [],
    this.radiusComparison,
    this.notes = const [],
  });
}

/// 動態層（規格 §5.4 影片）。
///
/// **這一層刻意不是 `dynamics.py` 的逐行移植，而是它的結論步驟。** 原型那 424 行
/// 裡的三個輸出，兩個已經有更好的來源：
///
/// | 原型的輸出 | App 端誰負責 |
/// |---|---|
/// | 轉速（逐幀角度追蹤 + 回歸） | **聲音層**。包絡自相關量到的 rpm 在合成夾具上與真值差 0.1%，而且不必解一張幀 |
/// | 三片半徑一致性 | **幾何層**（Phase 2）。單張整機照就是三片剪影互比，影片只是多幀取中位 |
/// | 六點鐘取幀、轉向 | 只有這個需要真的解幀 |
///
/// 所以把逐幀角度追蹤整套搬過來，會是「跑不動、又跟已有的兩層重複」。這一層做的是
/// 影片**唯一多給的東西**：同一片葉片在多幀取中位，用來抵消風吹造成的擺動
/// （規格 §12 對「風吹葉片擺動被當變形」開的處方就是這個）。
///
/// 葉片標籤沿用聲音層的規則——依通過六點鐘的先後循環標記。這樣兩層講的「B 片」
/// 是同一片，報告上才對得起來。
class BladeDynamicsService {
  BladeDynamicsService._();

  static const int defaultBlades = 3;

  /// 只有軸線落在 270° ± 這個角度內，才算「這一幀有一片朝下」。
  /// 與 `dynamics.py::_down_length_from_mask` 的 25° 相同。
  static const double downWindowDeg = 25.0;

  /// 每片至少要有這麼多幀量到，才拿它的中位數去互比。
  /// 一幀就下結論等於把單幀雜訊當成葉片差異。
  static const int minFramesPerBlade = 2;

  /// 依葉片通過週期取樣時刻：每次通過六點鐘各取一幀。
  ///
  /// [periodS] 是**葉片通過週期**（聲音層的 `1 / bladePassHz`），[phaseS] 是第一次
  /// 通過的時刻。轉速由音軌來，這一層就不必自己從像素推——那正是原型最貴的一步。
  static List<double> sixOclockTimes({
    required double periodS,
    required double phaseS,
    required double durationS,
    int maxFrames = 9,
  }) {
    if (!periodS.isFinite || periodS <= 0 || !durationS.isFinite) return const [];
    final out = <double>[];
    final start = phaseS.isFinite ? phaseS : 0.0;
    final n = ((durationS - start) / periodS).ceil();
    for (var i = 0; i < n && out.length < maxFrames; i++) {
      final t = start + i * periodS;
      if (t < 0 || t >= durationS) continue;
      out.add(t);
    }
    return out;
  }

  /// 抽指定時刻的幀 → 幾何管線 → 取朝下那片的葉尖半徑 → 依通過順序分成三片互比。
  ///
  /// [extract] 抽不到某一幀時該幀計為未解碼，**不中止整段分析**——影片尾端被截斷
  /// 是常見狀況，前面那些幀仍然是有效量測。
  static Future<BladeDynamicsResult> analyzeFrames({
    required String videoPath,
    required List<double> atSeconds,
    required BladeFrameExtractor extract,
    required BladeGeometryAnalyzer geometry,
    int nBlades = defaultBlades,
    double noiseFloorPx = 1.5,
  }) async {
    if (atSeconds.isEmpty) {
      return const BladeDynamicsResult(
        ok: false,
        reasons: ['沒有可取樣的時刻：需要先由音軌或轉速求出葉片通過週期'],
      );
    }
    final frames = <BladeDynamicsFrame>[];
    final notes = <String>[];
    var decoded = 0, measured = 0;

    for (final t in atSeconds) {
      Uint8List? bytes;
      try {
        bytes = await extract(videoPath, t);
      } catch (_) {
        bytes = null; // 抽幀失敗與抽不到同一處理：這一幀沒有，其他幀照算
      }
      if (bytes == null || bytes.isEmpty) {
        frames.add(BladeDynamicsFrame(
            atSeconds: t,
            downTipRadiusPx: double.nan,
            offFromSixOclockDeg: double.nan,
            decoded: false,
            measured: false));
        continue;
      }
      decoded++;
      final outcome = await geometry(bytes);
      if (!outcome.ok) {
        frames.add(BladeDynamicsFrame(
            atSeconds: t,
            downTipRadiusPx: double.nan,
            offFromSixOclockDeg: double.nan,
            decoded: true,
            measured: false));
        continue;
      }
      final down = _downBlade(outcome.profiles);
      if (down == null) {
        frames.add(BladeDynamicsFrame(
            atSeconds: t,
            downTipRadiusPx: double.nan,
            offFromSixOclockDeg: double.nan,
            decoded: true,
            measured: false));
        continue;
      }
      measured++;
      frames.add(BladeDynamicsFrame(
          atSeconds: t,
          downTipRadiusPx: down.radiusPx,
          offFromSixOclockDeg: down.offDeg,
          decoded: true,
          measured: true));
    }

    if (decoded == 0) {
      return BladeDynamicsResult(
        ok: false,
        reasons: ['這段影片抽不出任何一幀。請確認檔案完整，或改用整機照做幾何層分析'],
        framesRequested: atSeconds.length,
        frames: frames,
      );
    }
    if (measured == 0) {
      return BladeDynamicsResult(
        ok: false,
        reasons: ['抽到了 $decoded 幀，但沒有一幀量得出朝下的葉片'
            '（可能取景不含整台風機、或六點鐘時刻沒對準）'],
        framesRequested: atSeconds.length,
        framesDecoded: decoded,
        frames: frames,
      );
    }

    // 依**量到的先後順序**循環標記三片，與聲音層同一個規則
    final perBlade = List<List<double>>.generate(nBlades, (_) => <double>[]);
    var k = 0;
    for (final f in frames) {
      if (!f.measured) continue; // 缺測的幀不占標籤位置，否則後面全部錯位
      perBlade[k % nBlades].add(f.downTipRadiusPx);
      k++;
    }
    final medians = List<double>.generate(
        nBlades,
        (b) => perBlade[b].length >= minFramesPerBlade
            ? BladeDsp.median(perBlade[b])
            : double.nan);

    MetricComparison? cmp;
    final usable = medians.where((v) => v.isFinite).length;
    if (usable >= 2) {
      // 半徑的兩個方向都算異常（葉尖缺損會短、量測誤差會長），所以不限方向
      cmp = BladeGeometryCompare.compareMetric(
          'tip_radius_px', medians, noiseFloorPx * 2.0);
    } else {
      notes.add('每片至少要 $minFramesPerBlade 幀才取中位數，本段只有 $measured 幀'
          '量得出來，不足以做三片互比');
    }
    if (measured < atSeconds.length) {
      notes.add('要求 ${atSeconds.length} 幀，解出 $decoded 幀，量到 $measured 幀'
          '（缺測的幀不列入，也不以內插值充當量測）');
    }
    notes.add('葉片標籤依通過六點鐘的先後順序循環標記，非實際葉片編號'
        '——與聲音層同一個規則，兩層講的同一個字母是同一片');

    return BladeDynamicsResult(
      ok: true,
      framesRequested: atSeconds.length,
      framesDecoded: decoded,
      framesMeasured: measured,
      frames: frames,
      tipRadiusMedianPx: medians,
      radiusComparison: cmp,
      notes: notes,
    );
  }

  /// 畫面裡最接近正下方的那片葉片。超出 [downWindowDeg] 一律不算——
  /// 沒有葉片朝下時硬挑一片最接近的，量到的是別的東西。
  static _DownBlade? _downBlade(List<BladeProfile> profiles) {
    _DownBlade? best;
    for (final p in profiles) {
      final off = _wrapDeg(p.axisAngleDeg - 270.0).abs();
      if (off > downWindowDeg) continue;
      if (!p.radiusPx.isFinite) continue;
      if (best == null || off < best.offDeg) {
        best = _DownBlade(p.radiusPx, off);
      }
    }
    return best;
  }

  /// 角度差歸到 −180..180
  static double _wrapDeg(double a) {
    var v = (a + 180.0) % 360.0;
    if (v < 0) v += 360.0;
    return v - 180.0;
  }
}

class _DownBlade {
  final double radiusPx;
  final double offDeg;

  const _DownBlade(this.radiusPx, this.offDeg);
}
