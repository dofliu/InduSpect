import 'dart:math' as math;
import 'dart:typed_data';

import 'blade_audio_decode.dart';
import 'blade_dsp.dart';
import 'blade_geometry_compare.dart';

/// 單片葉片（實際上是「通過順序第 i 位」）的聲學指標。
class BladeAcousticBlade {
  final int index;
  final int nPasses;

  /// 分析頻帶 RMS，dB **相對三片中位數**（絕對位準沒有意義：距離、風向、
  /// 手機麥克風增益每次都不同）
  final double bandLevelDb;

  /// 2–8 kHz / 0.4–8 kHz 能量比。侵蝕會把能量往高頻推
  final double highBandRatio;

  /// 最突出的窄頻峰頻率（無則 NaN）
  final double tonalFreqHz;

  /// 該峰高出本地頻譜基線多少 dB
  final double tonalProminenceDb;

  /// 該峰是否只在這片出現
  final bool tonalExclusive;

  const BladeAcousticBlade({
    required this.index,
    required this.nPasses,
    required this.bandLevelDb,
    required this.highBandRatio,
    required this.tonalFreqHz,
    required this.tonalProminenceDb,
    required this.tonalExclusive,
  });

  /// 葉片標籤 A/B/C。**是通過順序不是實際葉片編號**——除非有影片的六點鐘時刻
  /// 對齊過，音軌自己分不出哪一片是塔上標記的 1 號葉片。
  String get label => String.fromCharCode(65 + index);
}

/// 判定門檻。全部可覆寫，預設值與 `acoustics.py` 相同。
class BladeAcousticParams {
  /// 分析頻帶下限：避開風噪與機械低頻
  final double bandLoHz;

  /// 分析頻帶上限：避開手機麥克風的高頻滾降
  final double bandHiHz;

  /// 此頻率以下視為風噪／機械低頻主導區
  final double windBandHz;

  /// 「高頻占比」的分界
  final double highBandLoHz;
  final double minConfidence;
  final double minSnrDb;
  final double marginalSnrDb;
  final double maxWindDominance;
  final double tonalMinProminenceDb;
  final double levelNoiseFloorDb;
  final double highBandNoiseFloor;

  const BladeAcousticParams({
    this.bandLoHz = 400.0,
    this.bandHiHz = 8000.0,
    this.windBandHz = 200.0,
    this.highBandLoHz = 2000.0,
    this.minConfidence = 0.25,
    this.minSnrDb = 1.5,
    this.marginalSnrDb = 4.0,
    this.maxWindDominance = 0.97,
    this.tonalMinProminenceDb = 6.0,
    this.levelNoiseFloorDb = 0.8,
    this.highBandNoiseFloor = 0.02,
  });
}

/// 逐片聲音分析的結果。
class BladeAcousticResult {
  final int sampleRate;
  final double durationS;

  /// 葉片通過頻率（= rpm/60 × 3）
  final double bladePassHz;

  /// 轉子轉動頻率（1P）
  final double rotorHz;
  final double rpmFromAudio;

  /// 0–1，1P 與 3P 兩個 lag 的 ACF 較大者
  final double periodicityConfidence;

  /// 葉片通過頻率（3P）上的振幅調變深度
  final double amDepthDb;

  /// 1P / 3P 調變比。**描述量不是判定門檻**——合成資料實測顯示它在健康與
  /// 單片缺陷之間會重疊，真正可靠的判別是逐片位準互比
  final double asymmetryDb;

  /// 低頻能量占比
  final double windDominance;

  /// 包絡峰值相對中位數
  final double envelopeSnrDb;

  /// 三重守門（週期信賴度／訊噪比／風噪占比）都過才是 true。
  /// **false 時 `blades` 與 `comparisons` 是空的**，不是「全部正常」。
  final bool usable;
  final List<double> passTimesS;
  final List<BladeAcousticBlade> blades;
  final List<MetricComparison> comparisons;
  final List<String> notes;

  const BladeAcousticResult({
    required this.sampleRate,
    required this.durationS,
    required this.bladePassHz,
    required this.rotorHz,
    required this.rpmFromAudio,
    required this.periodicityConfidence,
    required this.amDepthDb,
    required this.asymmetryDb,
    required this.windDominance,
    required this.envelopeSnrDb,
    required this.usable,
    this.passTimesS = const [],
    this.blades = const [],
    this.comparisons = const [],
    this.notes = const [],
  });

  MetricComparison? comparisonOf(String metric) {
    for (final c in comparisons) {
      if (c.metric == metric) return c;
    }
    return null;
  }

  /// 有沒有任何一片被標記（位準互比、高頻占比、或獨有哨音）
  bool get anyFlagged =>
      comparisons.any((c) => c.flagged) || blades.any((b) => b.tonalExclusive);
}

/// 頻譜減去中值濾波基線之後的**突出量**，以及對應的頻率軸。
///
/// 拆出來是因為它有兩個用途：找自己那根最突出的峰，以及讀**另一片在同一頻率上**
/// 的突出量。後者原本是在窄頻帶上重跑一次中值濾波，那是錯的（見
/// [BladeAcousticService.excessAtFrequency]）。
class BladeTonalExcess {
  final Float64List freqsHz;
  final Float64List excessDb;

  const BladeTonalExcess(this.freqsHz, this.excessDb);

  /// 頻帶內的 bin 數不足中值濾波所需時為 true。**要當成「量不出來」而不是
  /// 「沒有峰」**——這兩者混淆正是舊版獨有性複查失效的原因。
  bool get isEmpty => freqsHz.isEmpty;
}

/// 聲音層分析的注入點（測試不必進 isolate、也不必有真音檔）。
///
/// 收位元組而不是路徑：檔案讀取已經由 `BladeBytesLoader` 抽掉了，
/// 這一層只負責「位元組 → 結論」。
typedef BladeAcousticAnalyzer = Future<BladeAcousticResult> Function(
    Uint8List bytes);

/// 逐片聲音異常分析（規格 §5.4 音軌）。`acoustics.py` 的 Dart 對照實作。
///
/// **現場人員本來就是靠耳朵先發現葉片問題的**，這一層把它量化。物理依據：
///
/// - **前緣侵蝕 → 寬頻噪音上升**：表面變粗糙加厚紊流邊界層，後緣散射的寬頻噪音
///   跟著變大，能量集中在數百 Hz 到數 kHz。
/// - **後緣損傷／裂縫／破洞 → 窄頻哨音**：缺口形成空腔或邊緣音，頻譜上是一根細峰。
/// - **關鍵是「哪一片」**：三片每轉各通過觀測者一次，缺陷葉片的噪音是**以葉片通過
///   週期出現的**。把音軌依通過時刻切成三份互比就能指出是哪一片在叫；
///   這也是它與「整台風機都吵」「風噪很大」的分辨方式。
///
/// **風噪是這一層的頭號干擾**，所以三重守門（週期信賴度／包絡訊噪比／低頻占比）
/// 任一不過就回 `usable = false`，明確說「不可用」，而不是給一個看起來像數據的數字。
///
/// 一個已知限制（與 Python 相同，刻意沒有偷偷改掉）：`tonalExclusive` 的「只有這片
/// 有」複查，是在 ±3% 的窄頻帶上再跑一次 9 點中值濾波。在手機常見的取樣率下那個
/// 頻帶只有 4–5 個 bin，達不到中值濾波需要的 13 個，於是複查回 NaN、被當成「另兩片
/// 沒有」。所以它實際上等同「突出量 ≥ 6 dB」而不是真的驗過獨有性。要修得**兩邊
/// 一起改**並重跑夾具，那是演算法決策不是移植問題，記在 `BLADE_INSPECTION_SPEC.md` §13。
class BladeAcousticService {
  BladeAcousticService._();

  static const int defaultBlades = 3;

  /// 窄頻峰的基線用多少點的中值濾波（與 `acoustics.py` 的 `med_bins` 相同）
  static const int defaultTonalMedBins = 25;

  /// 短於這個長度不分析（與 Python 的 `sample_rate // 2` 相同）
  static bool tooShort(BladeAudioClip clip) =>
      clip.samples.length < clip.sampleRate ~/ 2;

  /// 位元組 → 結論。解不開或太短時回 `usable = false` 並把原因寫進 `notes`，
  /// **不丟例外**——現場的檔案什麼都有可能，而呼叫端要顯示的是「為什麼不能用」。
  static BladeAcousticResult analyzeBytes(
    Uint8List bytes, {
    double? rpm,
    int nBlades = defaultBlades,
    List<double>? passTimesHint,
    BladeAcousticParams params = const BladeAcousticParams(),
  }) {
    final decoded = BladeAudioDecode.decodeWav(bytes);
    final clip = decoded.clip;
    if (clip == null) return _unusable(0, 0.0, decoded.message);
    // 長度守門在 `analyzeSamples`（唯一必經的路），這裡不重複一份——
    // 同一個條件兩句話會漂移
    return analyzeSamples(clip,
        rpm: rpm,
        nBlades: nBlades,
        passTimesHint: passTimesHint,
        params: params);
  }

  static BladeAcousticResult _unusable(
          int sampleRate, double durationS, String why) =>
      BladeAcousticResult(
        sampleRate: sampleRate,
        durationS: durationS,
        bladePassHz: double.nan,
        rotorHz: double.nan,
        rpmFromAudio: double.nan,
        periodicityConfidence: 0.0,
        amDepthDb: double.nan,
        asymmetryDb: double.nan,
        windDominance: double.nan,
        envelopeSnrDb: double.nan,
        usable: false,
        notes: [why],
      );

  /// 分析已載入的音訊。
  ///
  /// [rpm] 由影片分析提供時，週期搜尋會收斂到 3/rev 附近（更穩）。
  /// [passTimesHint] 可傳影片的六點鐘時刻，用來把「通過順序」對齊到實際葉片編號。
  static BladeAcousticResult analyzeSamples(
    BladeAudioClip clip, {
    double? rpm,
    int nBlades = defaultBlades,
    List<double>? passTimesHint,
    BladeAcousticParams params = const BladeAcousticParams(),
  }) {
    final notes = <String>[];
    final n = clip.samples.length;
    // Python 在這裡是丟 `ValueError('音訊太短')`。這邊改成回 `usable = false`
    // 加一句原因：這一層的呼叫端是現場的分析流程，一段錄壞的音軌不該讓整個
    // 場次的分析中斷（照片與影片的結果還在）。**不是漏了守門，是刻意換了形式。**
    if (tooShort(clip)) {
      return _unusable(
          clip.sampleRate,
          clip.durationS,
          '音軌只有 ${clip.durationS.toStringAsFixed(1)} 秒（不足 0.5 秒），無法分析。'
          '要切分三片得涵蓋 2–3 圈轉動——12 rpm 約 15 秒');
    }
    // 平均值移除：手機麥克風常有 DC 偏移，不移除的話 bin 0 會吃掉大量能量，
    // 連帶把 wind_dominance 推高而誤判為風噪主導
    var mean = 0.0;
    for (final v in clip.samples) {
      mean += v;
    }
    mean /= n;
    final x = Float64List(n);
    for (var i = 0; i < n; i++) {
      x[i] = clip.samples[i] - mean;
    }

    final s = BladeDsp.stft(x, clip.sampleRate);
    final frameHz = s.nTime > 1
        ? 1.0 / BladeDsp.median(List<double>.generate(
            s.nTime - 1, (i) => s.timesS[i + 1] - s.timesS[i]))
        : 1.0;

    final band = BladeDsp.bandEnergy(s, params.bandLoHz, params.bandHiHz);
    final wind = BladeDsp.bandEnergy(s, 0.0, params.windBandHz);
    final total = BladeDsp.bandEnergy(s, 0.0, params.bandHiHz);
    final windSum = _sum(wind), totalSum = _sum(total);
    final windDominance = windSum / (totalSum + 1e-20);

    var env = Float64List(s.nTime);
    for (var i = 0; i < s.nTime; i++) {
      env[i] = math.sqrt(math.max(band[i], 0.0));
    }
    env = BladeDsp.savgolSmooth(env);
    final med = BladeDsp.median(env) + 1e-20;
    final snrDb =
        20.0 * _log10((BladeDsp.percentile(env, 98) + 1e-20) / med);

    final rot = _estimateRotation(env, frameHz, nBlades, rpm);
    final periodS = rot.periodS, rotS = rot.rotS;
    final fBp = periodS.isFinite && periodS > 0 ? 1.0 / periodS : double.nan;
    final fRot = rotS.isFinite && rotS > 0 ? 1.0 / rotS : double.nan;
    final rpmAudio = fRot.isFinite ? fRot * 60.0 : double.nan;
    final mBp = BladeDsp.modulationDepth(env, frameHz, fBp);
    final mRot = BladeDsp.modulationDepth(env, frameHz, fRot);
    final amDb = _ratioToDb(mBp);
    final asymDb = mBp.isFinite && mRot.isFinite
        ? 20.0 * _log10((mRot + 1e-6) / (mBp + 1e-6))
        : double.nan;

    var usable = true;
    if (!periodS.isFinite) {
      usable = false;
      notes.add('包絡找不到週期性，無法切分葉片（可能風噪過大或風機未轉動）');
    }
    if (rot.confidence < params.minConfidence) {
      usable = false;
      notes.add('轉動週期信賴度僅 ${rot.confidence.toStringAsFixed(2)}'
          '（門檻 ${params.minConfidence}）：包絡鎖不到 1P 或 3P，逐片比較不可信');
    }
    if (snrDb < params.minSnrDb) {
      usable = false;
      notes.add('包絡訊噪比僅 ${snrDb.toStringAsFixed(1)} dB'
          '（門檻 ${params.minSnrDb}）：葉片通過的起伏被雜訊淹沒');
    }
    if (usable && snrDb < params.marginalSnrDb) {
      // 不判為不可用：位準比較照做，但要說清楚只有較大的差異才抓得到。
      // 合成資料實測：包絡 SNR 約 5 dB 時 +3 dB 的侵蝕仍可標記，
      // 降到約 2 dB 時同樣的缺陷只量到 +1.3 dB，落在雜訊底以下被抑制。
      notes.add('包絡訊噪比 ${snrDb.toStringAsFixed(1)} dB 偏低'
          '（建議 ≥ ${params.marginalSnrDb.toStringAsFixed(0)} dB）：'
          '只有明顯的逐片差異抓得到，輕度侵蝕可能漏判；'
          '建議在較低風速、站到下風處並加防風罩重錄');
    }
    if (windDominance > params.maxWindDominance) {
      usable = false;
      notes.add('低於 ${params.windBandHz.toStringAsFixed(0)} Hz 的能量占 '
          '${(windDominance * 100).toStringAsFixed(0)}%：'
          '風噪主導，建議站到下風處並加防風罩重錄');
    }

    final blades = <BladeAcousticBlade>[];
    final comparisons = <MetricComparison>[];
    var passTimes = <double>[];

    if (usable) {
      // 相位以**轉子週期**為錨：三片的標籤在整段音軌內保持一致。
      // 只鎖葉片通過週期的話，標籤每轉可能整體位移一格，於是「B 片最吵」
      // 在前半段與後半段指的不是同一片。
      var phaseS = rotS.isFinite ? _passPhase(env, frameHz, rotS) : 0.0;
      if (periodS.isFinite && periodS > 0) phaseS = phaseS % periodS;
      // 對照 `np.arange(phase_s, duration_s, period_s)`：numpy 算的是 phase + i*period
      // 而**不是**逐次累加。累加會隨長度累積浮點誤差，長音軌上足以讓最後一次通過
      // 落在邊界的另一側，於是三片的通過次數與 Python 差一次。
      // 用計數形式也順便讓 period 為 0 時不可能無限迴圈。
      final nPass =
          periodS > 0 ? ((clip.durationS - phaseS) / periodS).ceil() : 0;
      for (var i = 0; i < nPass; i++) {
        final tp = phaseS + i * periodS;
        if (tp >= clip.durationS) break;
        passTimes.add(tp);
      }
      if (passTimesHint != null && passTimesHint.isNotEmpty) {
        // 以影片的六點鐘時刻對齊：讓最接近第一個 hint 的那次通過成為葉片 A
        final h = passTimesHint.first;
        var bestI = 0;
        var bestD = double.infinity;
        for (var i = 0; i < passTimes.length; i++) {
          final d = (passTimes[i] - h).abs();
          if (d < bestD) {
            bestD = d;
            bestI = i;
          }
        }
        final shift = bestI % nBlades;
        if (shift > 0 && shift < passTimes.length) {
          passTimes = passTimes.sublist(shift);
        }
        notes.add('葉片標籤已對齊影片的六點鐘時刻');
      } else {
        notes.add('葉片標籤 A/B/C 為通過觀測者的先後順序（循環），非實際葉片編號');
      }

      final half = periodS / (2.0 * nBlades); // 三片的視窗互不重疊
      final bladeFrames = List<List<int>>.generate(nBlades, (_) => <int>[]);
      for (var k = 0; k < passTimes.length; k++) {
        final tp = passTimes[k];
        for (var i = 0; i < s.nTime; i++) {
          if ((s.timesS[i] - tp).abs() <= half) bladeFrames[k % nBlades].add(i);
        }
      }

      const eps = 1e-20;
      final meanSpecs = <Float64List>[];
      final levels = <double>[];
      final ratios = <double>[];
      final tonalF = <double>[];
      final tonalP = <double>[];
      for (var b = 0; b < nBlades; b++) {
        final idx = bladeFrames[b];
        if (idx.length < 3) {
          meanSpecs.add(Float64List(s.nFreq)..fillRange(0, s.nFreq, double.nan));
          levels.add(double.nan);
          ratios.add(double.nan);
          tonalF.add(double.nan);
          tonalP.add(double.nan);
          continue;
        }
        final spec = BladeDsp.meanSpectrum(s, idx);
        meanSpecs.add(spec);
        var eBand = 0.0, eHigh = 0.0;
        for (var k = 0; k < s.nFreq; k++) {
          final fr = s.freqsHz[k];
          if (fr < params.bandLoHz || fr > params.bandHiHz) continue;
          final p = spec[k] * spec[k];
          eBand += p;
          if (fr >= params.highBandLoHz) eHigh += p;
        }
        levels.add(10.0 * _log10(eBand + eps));
        ratios.add(eHigh / (eBand + eps));
        final specDb = Float64List(s.nFreq);
        for (var k = 0; k < s.nFreq; k++) {
          specDb[k] = 20.0 * _log10(spec[k] + eps);
        }
        final peak = _tonalPeak(specDb, s.freqsHz, params.bandLoHz,
            params.bandHiHz, defaultTonalMedBins);
        tonalF.add(peak.freqHz);
        tonalP.add(peak.prominenceDb);
      }

      final finite = levels.where((v) => v.isFinite).toList();
      final ref = finite.isNotEmpty ? BladeDsp.median(finite) : 0.0;
      final relLevels = levels
          .map((v) => v.isFinite ? v - ref : double.nan)
          .toList(growable: false);

      for (var b = 0; b < nBlades; b++) {
        final tf = tonalF[b], tpDb = tonalP[b];
        var exclusive = false;
        if (tf.isFinite && tpDb.isFinite && tpDb >= params.tonalMinProminenceDb) {
          final others = <double>[];
          for (var o = 0; o < nBlades; o++) {
            if (o == b) continue;
            if (!meanSpecs[o].any((v) => v.isFinite)) continue;
            final od = Float64List(s.nFreq);
            for (var k = 0; k < s.nFreq; k++) {
              od[k] = 20.0 * _log10(meanSpecs[o][k] + eps);
            }
            // 讀另一片在**同一個頻率**上的突出量（全頻帶基線，不重跑窄頻中值）
            final op = excessAtFrequency(
                od, s.freqsHz, tf, params.bandLoHz, params.bandHiHz);
            others.add(op.isFinite ? op : 0.0);
          }
          exclusive = others.isNotEmpty &&
              tpDb - others.reduce(math.max) >=
                  params.tonalMinProminenceDb / 2.0;
        }
        var nPasses = 0;
        for (var k = 0; k < passTimes.length; k++) {
          if (k % nBlades == b) nPasses++;
        }
        blades.add(BladeAcousticBlade(
          index: b,
          nPasses: nPasses,
          bandLevelDb: relLevels[b],
          highBandRatio: ratios[b],
          tonalFreqHz: tf,
          tonalProminenceDb: tpDb,
          tonalExclusive: exclusive,
        ));
      }

      // **方向性**：只有「比另兩片吵／高頻更多」才是缺陷徵兆。不限方向的話
      // 最安靜的那片會被標成侵蝕——結論剛好反過來。
      if (relLevels.where((v) => v.isFinite).length >= 2) {
        comparisons.add(BladeGeometryCompare.compareMetric(
            'band_level_db', relLevels, params.levelNoiseFloorDb,
            direction: MetricDirection.high));
      }
      if (ratios.where((v) => v.isFinite).length >= 2) {
        comparisons.add(BladeGeometryCompare.compareMetric(
            'high_band_ratio', ratios, params.highBandNoiseFloor,
            direction: MetricDirection.high));
      }
    }

    return BladeAcousticResult(
      sampleRate: clip.sampleRate,
      durationS: clip.durationS,
      bladePassHz: fBp,
      rotorHz: fRot,
      rpmFromAudio: rpmAudio,
      periodicityConfidence: rot.confidence,
      amDepthDb: amDb,
      asymmetryDb: asymDb,
      windDominance: windDominance,
      envelopeSnrDb: snrDb,
      usable: usable,
      passTimesS: passTimes,
      blades: blades,
      comparisons: comparisons,
      notes: notes,
    );
  }

  // ------------------------------------------------------- 私有

  /// 求轉子週期與葉片通過週期。對照 `acoustics.py::_estimate_rotation`。
  ///
  /// 兩個要處理的糾纏：
  ///
  /// 1. **ACF 的諧波歧義**：三片一致時包絡以葉片通過週期重複，ACF 在 T_bp、
  ///    2T_bp、3T_bp 都有高峰，最大值落在哪一個不一定。所以找到峰之後要判斷它是
  ///    基頻還是諧波——用「1/nBlades 處還有沒有明顯的峰」來判。
  /// 2. **單片異常會把主週期從 3P 推到 1P**：三片一樣時 3P 主導，有一片特別吵時
  ///    1P 冒出來。所以信賴度取兩個 lag 的 ACF **較大者**——任一站得住就代表鎖到了
  ///    轉動，不能因為 3P 弱就判不可用，那正是我們要找的不對稱。
  static _Rotation _estimateRotation(
      Float64List env, double frameHz, int nBlades, double? expectRpm) {
    final ac = BladeDsp.autocorrNormalized(env);
    if (!ac.any((v) => v != 0.0)) {
      return const _Rotation(double.nan, double.nan, 0.0);
    }
    int lo, hi;
    if (expectRpm != null && expectRpm > 0) {
      final rotLag = frameHz * 60.0 / expectRpm;
      lo = (rotLag * 0.8).toInt();
      hi = (rotLag * 1.25).ceil();
    } else {
      // 轉子週期 1–10 秒（6–60 rpm）；下界用 T_bp 尺度，讓基頻也落在窗內
      lo = (frameHz * 0.5).toInt();
      hi = (frameHz * 10.0).toInt();
    }
    lo = math.max(2, lo);
    hi = math.min(ac.length - 2, hi);
    if (hi <= lo + 1) return const _Rotation(double.nan, double.nan, 0.0);
    var argmax = lo;
    for (var i = lo; i <= hi; i++) {
      if (ac[i] > ac[argmax]) argmax = i;
    }
    final k = BladeDsp.refinePeak(ac, argmax);

    // 找到的峰是轉子週期還是葉片通過週期？看 k/nBlades 處是否也有實質的峰
    final sub = k / nBlades;
    final acK = BladeDsp.valueAtLag(ac, k);
    final acSub = BladeDsp.valueAtLag(ac, sub);
    double rotLagF, bpLagF;
    if (sub >= 2 && acSub >= math.max(0.15, 0.30 * acK)) {
      rotLagF = k; // k 是轉子週期（3P 的整數倍）
      bpLagF = sub;
    } else {
      rotLagF = k * nBlades;
      bpLagF = k;
    }
    if (rotLagF > ac.length - 2) {
      // 音軌太短，涵蓋不到一整圈：仍可用 T_bp，轉速由 T_bp 推算
      rotLagF = bpLagF * nBlades;
    }
    final conf = math.max(BladeDsp.valueAtLag(ac, bpLagF),
        BladeDsp.valueAtLag(ac, math.min(rotLagF, (ac.length - 2).toDouble())));
    return _Rotation(rotLagF / frameHz, bpLagF / frameHz,
        conf.clamp(0.0, 1.0));
  }

  /// 在一個週期內掃相位，取包絡同步平均最大者（= 葉片通過的時刻）。
  static double _passPhase(Float64List env, double frameHz, double periodS) {
    final t = periodS * frameHz;
    final n = env.length;
    var bestPhi = 0.0, bestVal = double.negativeInfinity;
    for (var q = 0; q < 24; q++) {
      final phi = q * t / 24.0;
      // 對照 `np.arange(phi, n - 1, T)`：不是迭代累加，而是 phi + i*T
      final count = ((n - 1 - phi) / t).ceil();
      if (count <= 0) continue;
      var acc = 0.0;
      var used = 0;
      for (var i = 0; i < count; i++) {
        final idx = BladeDsp.roundHalfEven(phi + i * t);
        if (idx < 0 || idx >= n) continue;
        acc += env[idx];
        used++;
      }
      if (used == 0) continue;
      final v = acc / used;
      if (v > bestVal) {
        bestVal = v;
        bestPhi = phi;
      }
    }
    return bestPhi / frameHz;
  }

  /// 頻譜減去中值濾波基線 → 突出量。對照 `acoustics.py::_tonal_excess`。
  static BladeTonalExcess tonalExcess(
      Float64List specDb, Float64List freqs, double lo, double hi,
      {int medBins = defaultTonalMedBins}) {
    final sel = <int>[];
    for (var k = 0; k < freqs.length; k++) {
      if (freqs[k] >= lo && freqs[k] <= hi) sel.add(k);
    }
    if (sel.length < medBins + 4) {
      return BladeTonalExcess(Float64List(0), Float64List(0));
    }
    final fs = Float64List(sel.length);
    final ss = Float64List(sel.length);
    for (var i = 0; i < sel.length; i++) {
      fs[i] = freqs[sel[i]];
      ss[i] = specDb[sel[i]];
    }
    final baseline =
        BladeDsp.medianFilter(ss, medBins.isOdd ? medBins : medBins + 1);
    final excess = Float64List(sel.length);
    for (var i = 0; i < sel.length; i++) {
      excess[i] = ss[i] - baseline[i];
    }
    return BladeTonalExcess(fs, excess);
  }

  /// 窄頻峰：突出量最大處。
  static _TonalPeak _tonalPeak(Float64List specDb, Float64List freqs, double lo,
      double hi, int medBins) {
    final e = tonalExcess(specDb, freqs, lo, hi, medBins: medBins);
    if (e.isEmpty) return const _TonalPeak(double.nan, double.nan);
    var bestI = 0;
    var bestV = -double.infinity;
    for (var i = 0; i < e.excessDb.length; i++) {
      if (e.excessDb[i] > bestV) {
        bestV = e.excessDb[i];
        bestI = i;
      }
    }
    return _TonalPeak(e.freqsHz[bestI], bestV);
  }

  /// **指定頻率**上的突出量（取最近的 bin）。用於「這根峰是不是只有這片有」。
  ///
  /// 原本的做法是在 ±3% 的窄頻帶上**再跑一次**中值濾波。那是錯的：手機常見取樣率下
  /// ±3% 只有 4–5 個 bin（48 kHz / nperseg 2048 → bin 間距 23 Hz，1800 Hz 的 ±3%
  /// 是 108 Hz），達不到 9 點中值濾波要求的 13 個 bin，於是一律回 NaN 而被呼叫端
  /// 當成「另兩片在這個頻率沒有東西」。結果 `tonalExclusive` 退化成「突出量
  /// ≥ 6 dB」，**完全沒有驗過獨有性**——三片同時有的哨音（鋸齒尾緣等設計特徵、
  /// 路過的車輛、地面的發電機）會被報成單片缺陷，於是有人去拆錯的葉片。
  ///
  /// 全頻帶的基線本來就為了找自己的峰算過一次，直接讀那個頻率上的值就好。
  /// 合成音軌實測（`blade_prototype`）：三片同頻哨音由舊做法的 3 片誤判成獨有降到
  /// 0 片、兩片同頻由 2 片降到 0 片，而單片哨音仍然抓得到。
  static double excessAtFrequency(
      Float64List specDb, Float64List freqs, double freq, double lo, double hi,
      {int medBins = defaultTonalMedBins}) {
    final e = tonalExcess(specDb, freqs, lo, hi, medBins: medBins);
    if (e.isEmpty || !freq.isFinite) return double.nan;
    var bestI = 0;
    var bestD = double.infinity;
    for (var i = 0; i < e.freqsHz.length; i++) {
      final d = (e.freqsHz[i] - freq).abs();
      if (d < bestD) {
        bestD = d;
        bestI = i;
      }
    }
    return e.excessDb[bestI];
  }

  /// 調變比例 → 峰谷差 dB
  static double _ratioToDb(double ratio) {
    if (!ratio.isFinite) return double.nan;
    final r = ratio.clamp(0.0, 0.999);
    return 20.0 * _log10((1.0 + r) / (1.0 - r));
  }

  static double _log10(double v) => math.log(v) / math.ln10;

  static double _sum(Float64List a) {
    var acc = 0.0;
    for (final v in a) {
      acc += v;
    }
    return acc;
  }
}

class _Rotation {
  final double rotS;
  final double periodS;
  final double confidence;

  const _Rotation(this.rotS, this.periodS, this.confidence);
}

class _TonalPeak {
  final double freqHz;
  final double prominenceDb;

  const _TonalPeak(this.freqHz, this.prominenceDb);
}
