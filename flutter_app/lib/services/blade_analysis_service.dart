import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../models/wt_capture_session.dart';
import '../models/wt_detection.dart';
import 'blade_ai_service.dart';
import 'blade_surface_service.dart';

/// 讀檔注入點（測試用假的、正式走 `dart:io`）
typedef BladeBytesLoader = Future<Uint8List> Function(String path);

/// 前緣侵蝕的判定門檻。
///
/// **單一來源**：數值與 `blade_prototype/blade_proto/report.py::_surface_section`
/// 一致（5.0 / 2.0 / 1.5）。原型改門檻時這裡要一起改——兩邊算的是同一個量
/// （同一張照片內前緣 rms ÷ 後緣 rms），所以不能各自漂移。
///
/// 為什麼是比值而不是絕對值：前緣受風砂雨水沖蝕會變粗糙、後緣不會，
/// 同一張照片內互比就不需要絕對校準，也不受相機、距離、光線影響。
class BladeSurfaceTriage {
  BladeSurfaceTriage._();

  static const double criticalRatio = 5.0;
  static const double seriousRatio = 2.0;
  static const double watchRatio = 1.5;

  /// 超過門檻才回 severity；沒超過回 null（= 這次沒有發現，不是「合格」）
  static int? severityFor(double? ratio) {
    if (ratio == null || ratio.isNaN) return null;
    if (ratio >= criticalRatio) return 5;
    if (ratio >= seriousRatio) return 4;
    if (ratio >= watchRatio) return 2;
    return null;
  }

  static String verdictText(double? ratio) {
    // 算不出比值時**不能**說「前後緣相當」——那是一句沒有依據的話
    if (ratio == null || ratio.isNaN) return '無法計算前後緣比，本張不作侵蝕判定';
    final s = severityFor(ratio);
    if (s == null) return '前後緣粗糙度相當，本次未見明顯侵蝕';
    if (s >= 5) return '前緣粗糙度為後緣 5 倍以上，疑似重度侵蝕';
    if (s >= 4) return '前緣粗糙度明顯高於後緣，疑似侵蝕';
    return '前緣粗糙度略高，建議下次複拍比對';
  }
}

/// 一次分析的產出。
///
/// 分成兩層是刻意的：`detections` 全部進資料庫（含未超門檻的量測值，
/// 下次複拍要比對趨勢就靠它），但只有 `reportable` 進報告——把「比值 0.93、
/// 未超門檻」印成一列「待判定」會讓報告看起來有懸而未決的事項，那是反向的誤導。
class BladeAnalysisOutcome {
  final List<WtDetection> detections;

  /// 每一張照片發生了什麼（跳過、失敗、量到多少）。會寫進報告的摘要，
  /// 所以「有幾張沒分析」在報告上看得到，不會靜靜消失。
  final List<String> notes;

  /// 實際跑完演算法的照片數
  final int analyzedCount;

  /// 沒有納入分析的照片數（未過品質閘門、非分區段照、分割失敗）
  final int skippedCount;

  const BladeAnalysisOutcome({
    required this.detections,
    required this.notes,
    required this.analyzedCount,
    required this.skippedCount,
  });

  List<WtDetection> get reportable =>
      detections.where((d) => d.severity != null).toList();

  /// 還有 AI 解讀等著聯網後補跑
  bool get hasPendingAi =>
      detections.any((d) => d.source == WtDetectionSource.geminiOfflinePending);

  /// 報告摘要。**明講這次跑了哪一層、沒跑哪一層**——只寫「未檢出異常」
  /// 會讓人以為整支葉片都查過了，實際上幾何層與動態層的 Dart 移植還沒做。
  String buildSummary() {
    final lines = <String>[
      '本次分析範圍：表面層（前緣輪廓粗糙度）。'
          '幾何層（三片互比）與動態層（轉速、葉尖偏移）尚未在 App 端實作，'
          '本次**未進行**這兩層的分析——照片已保存，可日後補跑。',
    ];
    if (notes.isNotEmpty) lines.add(notes.join('\n'));
    if (hasPendingAi) {
      lines.add('部分 AI 解讀因無網路尚未完成，已排入佇列；'
          '報告中該項只有演算法量到的數值。');
    }
    return lines.join('\n\n');
  }
}

/// 葉片分析的編排層（規格 §5.2 / §6）。
///
/// 職責只有編排：挑出能分析的照片、呼叫演算法、套門檻、送 AI 解讀、
/// 把結果變成 `WtDetection`。**畫面不做這些判斷**——門檻與「AI 能不能推翻
/// 演算法」這種事寫在畫面裡就沒辦法測。
class BladeAnalysisService {
  BladeAnalysisService._();

  static Future<Uint8List> _readFile(String path) => File(path).readAsBytes();

  /// 分析一個拍攝場次。
  ///
  /// [useAi] 為 false（或 AI 呼叫失敗）時，演算法的結果照樣留下來，
  /// AI 解讀標記為待補——離線是常態，不是錯誤。
  /// 不收 `WtAsset`：表面層的判據是**同一張照片內前後緣互比**，不需要任何
  /// 資產尺寸；硬要把轉子直徑換算成 cm/px 會產出看起來精確的假數據。
  /// 幾何層（要 px → m）之後再加這個參數。
  static Future<BladeAnalysisOutcome> analyzeSession({
    required WtCaptureSession session,
    bool useAi = true,
    BladeBytesLoader? loadBytes,
    BladeImageAnalyzer? analyzer,
    BladeSurfaceAnalyzer? surface,
  }) async {
    final read = loadBytes ?? _readFile;
    final run = surface ?? BladeSurfaceService.analyze;
    final detections = <WtDetection>[];
    final notes = <String>[];
    var analyzed = 0, skipped = 0;

    var notPhoto = 0, notSegment = 0, notUsable = 0;
    for (final m in session.media) {
      if (m.kind != WtMediaKind.photo) {
        notPhoto++;
        continue;
      }
      if (m.view != WtMediaView.segment) {
        notSegment++;
        continue;
      }
      // 品質閘門沒過（或還沒分析過）的照片一律不進演算法。
      // `qualityOk` 未分析時是 null，這裡刻意用 `!= true` 而不是 `== false`：
      // 「沒驗過」不能當成「驗過了」。
      if (m.qualityOk != true) {
        notUsable++;
        continue;
      }

      Uint8List bytes;
      try {
        bytes = await read(m.path);
      } catch (_) {
        skipped++;
        notes.add('${_shortPath(m.path)}：讀不到檔案，未納入分析。');
        continue;
      }

      final result = await run(
        bytes,
        params: BladeSurfaceParams(leadingEdge: m.leadingEdge),
      );

      if (!result.ok) {
        skipped++;
        notes.add('${_shortPath(m.path)}：${result.failure ?? '分析失敗'}');
        continue;
      }
      analyzed++;

      if (m.leadingEdge == null) {
        // 前緣在畫面哪一側是拍攝者才知道的事，演算法猜不出來。
        // 沒指定就只有兩條邊的絕對粗糙度，沒有可靠的判據。
        notes.add('${_shortPath(m.path)}：未指定前緣在畫面哪一側，'
            '無法計算前後緣比，本張只保留兩側粗糙度數值。');
      }

      final ratio = result.leOverTeRmsRatio;
      final severity = BladeSurfaceTriage.severityFor(ratio);
      final metrics = _metricsOf(result);
      final zone = _zoneKey(m);

      // 比值算不出來時上面那筆「未指定前緣」的說明已經講完了，不再補一句
      if (severity == null && ratio != null) {
        notes.add('${_shortPath(m.path)}：${BladeSurfaceTriage.verdictText(ratio)}'
            '（前緣/後緣 rms 比 ${ratio.toStringAsFixed(2)}）。');
      }

      final detectionId = _detectionId(session.sessionId, m.path);
      // 演算法自己的判定文字兩條路都要留住——離線時報告上不能只有一個等級
      final algoNote = severity == null ? null : BladeSurfaceTriage.verdictText(ratio);
      WtDetection algoDetection(WtDetectionSource source) => WtDetection(
            detectionId: detectionId,
            sessionId: session.sessionId,
            layer: WtLayer.surface,
            blade: m.bladePosition,
            zone: zone,
            defectClass: severity == null ? 'none' : 'leading_edge_erosion',
            severity: severity,
            metricJson: metrics,
            mediaPath: m.path,
            source: source,
            aiDescription: algoNote,
          );

      // 未超門檻的不送 AI：AI 的成本與額度要花在有東西可看的照片上，
      // 而且「演算法沒量到、AI 說有」在這個尺度上不可信（§5.5）。
      if (severity == null) {
        detections.add(algoDetection(WtDetectionSource.algorithm));
        continue;
      }
      if (!useAi) {
        detections.add(algoDetection(WtDetectionSource.geminiOfflinePending));
        continue;
      }
      final base = algoDetection(WtDetectionSource.algorithm);

      try {
        final ai = await BladeAiService.interpret(
          detectionId: base.detectionId,
          sessionId: base.sessionId,
          imageBytes: bytes,
          zoneLabel: _zoneLabel(m),
          bladeLabel: m.bladePosition,
          zone: zone,
          mediaPath: m.path,
          algorithmMetrics: metrics,
          zoom: m.zoom,
          analyzer: analyzer,
        );
        detections.add(_merge(base, ai));
      } catch (_) {
        // 離線／額度用盡／回應壞掉：演算法的結果不能因此消失
        detections.add(algoDetection(WtDetectionSource.geminiOfflinePending));
      }
    }

    skipped += notUsable + notSegment;
    if (notUsable > 0) {
      notes.add('$notUsable 張照片未通過拍攝品質閘門，未納入分析（數值不可採信，'
          '不是判定為正常）。');
    }
    if (notSegment > 0) {
      notes.add('$notSegment 張整機／塔架照已保存，但整轉子幾何分析尚未在 App 端實作，'
          '本次未分析。');
    }
    if (notPhoto > 0) {
      notes.add('$notPhoto 段影片已保存，動態層分析尚未在 App 端實作，本次未分析。');
    }

    return BladeAnalysisOutcome(
      detections: detections,
      notes: notes,
      analyzedCount: analyzed,
      skippedCount: skipped,
    );
  }

  /// 合併演算法與 AI 的判斷。
  ///
  /// **演算法的 severity 是下限，AI 只能往上加。** 理由：severity 來自量到的
  /// 數值，AI 看的是同一張照片的縮圖，沒有理由推翻量測；但 AI 可能看到量測沒有
  /// 涵蓋的東西（LEP 整片翻起、雷擊燒痕），那時它可以把等級拉高。
  /// AI 認為是正常結構時**不刪掉這筆發現**，把它的理由寫進描述交給人工判斷——
  /// 篩檢工具寧可多留一筆待確認，不要少留一筆。
  static WtDetection _merge(WtDetection algo, WtDetection ai) {
    final severity = algo.severity == null
        ? ai.severity
        : (ai.severity == null
            ? algo.severity
            : math.max(algo.severity!, ai.severity!));
    final aiClass = ai.defectClass;
    final ruledOut = ai.metricJson['normal_structure_ruled_out'];
    final saysNormal = aiClass == 'none' || aiClass == null;
    final description = saysNormal
        ? 'AI 認為這可能不是缺陷${ruledOut == null ? '' : '（$ruledOut）'}，'
            '但演算法量到的數值已超過門檻，仍列為待人工確認。'
            '${ai.aiDescription ?? ''}'
        : (ai.aiDescription ?? algo.aiDescription);
    return WtDetection(
      detectionId: algo.detectionId,
      sessionId: algo.sessionId,
      layer: algo.layer,
      blade: algo.blade,
      zone: algo.zone,
      // AI 說 none 時保留演算法的分類，不要讓一筆發現變成「未分類」
      defectClass: saysNormal ? algo.defectClass : aiClass,
      severity: severity,
      confidence: ai.confidence,
      metricJson: {...algo.metricJson, ...ai.metricJson},
      mediaPath: algo.mediaPath,
      source: WtDetectionSource.gemini,
      aiDescription: description,
    );
  }

  static Map<String, dynamic> _metricsOf(BladeSurfaceAnalysis r) {
    final le = r.leadingEdgeRoughness;
    final m = <String, dynamic>{
      'median_thickness_px': r.medianThicknessPx,
      'axis_angle_deg': r.axisAngleDeg,
    };
    final ratio = r.leOverTeRmsRatio;
    if (ratio != null) m['le_over_te_rms_ratio'] = ratio;
    if (le != null) {
      m['rms_px'] = le.rmsPx;
      if (le.rmsCm != null) m['rms_cm'] = le.rmsCm;
      m['inward_p95_px'] = le.inwardP95Px;
      m['pit_count'] = le.pitCount;
      m['high_freq_ratio'] = le.highFreqRatio;
      m['n_samples'] = le.nSamples;
      m['zone_rms_px'] = le.zoneRmsPx;
    }
    final te = r.trailingEdgeRoughness;
    if (te != null) m['te_rms_px'] = te.rmsPx;
    return m;
  }

  static String? _zoneKey(WtMedia m) {
    final z = m.zone;
    if (z == null) return null;
    final le = m.leadingEdge;
    if (le == null) return z;
    return '${z}_LE';
  }

  static String _zoneLabel(WtMedia m) {
    const names = {'root': '根部段', 'mid': '中段', 'tip': '葉尖段'};
    final z = names[m.zone] ?? m.zone ?? '未指定區段';
    if (m.leadingEdge == null) return z;
    return '$z前緣（前緣在畫面${m.leadingEdge == 'top' ? '上' : '下'}緣）';
  }

  /// 同一張照片重跑要覆蓋原本那筆，所以 id 由 session + 檔名決定，不用隨機值。
  static String _detectionId(String sessionId, String path) =>
      'surf-$sessionId-${p.basename(path)}';

  static String _shortPath(String path) => p.basename(path);
}
