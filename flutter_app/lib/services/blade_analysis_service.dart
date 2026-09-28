import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:path/path.dart' as p;

import '../models/wt_capture_session.dart';
import '../models/wt_detection.dart';
import 'ai/ai_backend.dart';
import 'blade_acoustic_service.dart';
import 'blade_ai_service.dart';
import 'blade_dynamics_service.dart';
import 'blade_geometry_compare.dart';
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

  /// 這次**實際跑過**的層。摘要要據實說哪一層沒跑，而「沒跑」有三種很不一樣的
  /// 原因（沒拍那種素材／拍了但不能用／功能還沒接上），不能都寫成「未實作」。
  /// 從 `detections` 反推做不到：一層跑完而且沒發現，是不會留下任何偵測的。
  final Set<WtLayer> layersRun;

  const BladeAnalysisOutcome({
    required this.detections,
    required this.notes,
    required this.analyzedCount,
    required this.skippedCount,
    this.layersRun = const {},
  });

  List<WtDetection> get reportable =>
      detections.where((d) => d.severity != null).toList();

  /// 還有 AI 解讀等著聯網後補跑
  bool get hasPendingAi =>
      detections.any((d) => d.source == WtDetectionSource.geminiOfflinePending);

  /// 報告摘要。**明講這次跑了哪一層、沒跑哪一層**——只寫「未檢出異常」
  /// 會讓人以為整支葉片都查過了。
  String buildSummary() {
    const names = {
      WtLayer.surface: '表面層（前緣輪廓粗糙度）',
      WtLayer.geometry: '幾何層（三片剪影互比）',
      WtLayer.dynamic_: '動態層（音軌逐片噪音、轉速）',
    };
    final ran = names.entries
        .where((e) => layersRun.contains(e.key))
        .map((e) => e.value)
        .toList();
    final missing = names.entries
        .where((e) => !layersRun.contains(e.key))
        .map((e) => e.value)
        .toList();
    final lines = <String>[
      ran.isEmpty
          ? '本次沒有任何一層完成分析。這**不代表葉片正常**，只代表沒有可用的素材。'
          : '本次分析範圍：${ran.join('、')}。'
              '${missing.isEmpty ? '' : '${missing.join('、')}本次**未進行**'
                  '（缺對應素材，或素材未通過品質閘門）——'
                  '沒進行不等於沒問題。'}',
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

  /// isolate 入口。像素運算不能擋 UI thread——幾何層一張圖約幾百毫秒。
  /// 帶著型錄轉子半徑一起過去：isolate 只能收一個參數，所以包成 record。
  static BladeGeometryOutcome _geometryIsolate(_GeometryJob job) =>
      runGeometryPipeline(job.bytes,
          rotorRadiusM: job.rotorRadiusM,
          hubHeightM: job.hubHeightM,
          expectedView: job.expectedView);

  /// 預設的幾何層分析器（進 isolate）；測試注入的 [BladeGeometryAnalyzer] 取代它。
  static Future<BladeGeometryOutcome> _defaultGeometry(Uint8List bytes,
          {double? rotorRadiusM, double? hubHeightM, String? expectedView}) =>
      compute(
          _geometryIsolate,
          (
            bytes: bytes,
            rotorRadiusM: rotorRadiusM,
            hubHeightM: hubHeightM,
            expectedView: expectedView
          ));

  /// isolate 入口。一段 30 秒 48 kHz 的音軌約 6 千萬次浮點運算（STFT 為主），
  /// 在手機上是幾百毫秒——不到幾何層那麼貴，但足以讓畫面掉幀。
  static BladeAcousticResult _acousticIsolate(Uint8List bytes) =>
      BladeAcousticService.analyzeBytes(bytes);

  /// 分析一個拍攝場次。
  ///
  /// [useAi] 為 false（或 AI 呼叫失敗）時，演算法的結果照樣留下來，
  /// AI 解讀標記為待補——離線是常態，不是錯誤。
  /// 不收整個 `WtAsset`，只收 [rotorRadiusM]（型錄轉子半徑，公尺）：表面層的判據是
  /// **同一張照片內前後緣互比**，不需要任何資產尺寸；只有幾何層（整機照）拿它把
  /// px 換成 cm——由三片量到的葉長中位數反推尺度，判定仍在 px 上做。沒有型錄
  /// 直徑就沒有 cm 值，**不猜尺度**。[hubHeightM]（輪轂高度）加上照片 EXIF 的焦距讓
  /// 幾何層估相機站位並補償透視（`OFFAXIS_SENSITIVITY.md`）；估不出來就不補，報告改口。
  ///
  /// [aiSource] 說 [analyzer] 是誰：雲端（預設）或裝置端 VLM（Tier 1b）。裝置端的解讀
  /// 一律標「離線初判」、**來源仍是 `geminiOfflinePending`**——它是初判不是終判，連線後
  /// 補跑佇列會拿雲端結果覆核；覆核時演算法的等級才是下限，不是端側抬上去的那個。
  static Future<BladeAnalysisOutcome> analyzeSession({
    required WtCaptureSession session,
    bool useAi = true,
    double? rotorRadiusM,
    double? hubHeightM,
    AiSource aiSource = AiSource.cloud,
    BladeBytesLoader? loadBytes,
    BladeImageAnalyzer? analyzer,
    BladeSurfaceAnalyzer? surface,
    BladeGeometryAnalyzer? geometry,
    BladeAcousticAnalyzer? acoustic,
    BladeFrameExtractor? frameExtractor,
  }) async {
    final read = loadBytes ?? _readFile;
    final run = surface ?? BladeSurfaceService.analyze;
    final detections = <WtDetection>[];
    final notes = <String>[];
    var analyzed = 0, skipped = 0;
    var localJudged = 0;
    final layersRun = <WtLayer>{};

    var notSegment = 0, notUsable = 0;
    final geometryMedia = <WtMedia>[];
    final audioMedia = <WtMedia>[];
    final videoMedia = <WtMedia>[];
    for (final m in session.media) {
      if (m.kind == WtMediaKind.audio) {
        audioMedia.add(m);
        continue;
      }
      if (m.kind == WtMediaKind.video) {
        videoMedia.add(m);
        continue;
      }
      if (m.view != WtMediaView.segment) {
        // 正視／側視全機照走幾何層（三片剪影互比）
        if (m.view == WtMediaView.front || m.view == WtMediaView.side) {
          geometryMedia.add(m);
        } else {
          notSegment++;
        }
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
      layersRun.add(WtLayer.surface);

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
        detections.add(mergeAlgorithmAndAi(base, ai, aiSource: aiSource));
        if (aiSource == AiSource.localLlm) localJudged++;
      } catch (_) {
        // 離線／額度用盡／回應壞掉：演算法的結果不能因此消失
        detections.add(algoDetection(WtDetectionSource.geminiOfflinePending));
      }
    }
    if (localJudged > 0) {
      notes.add('$localJudged 筆 AI 解讀由**裝置端模型**產生（離線初判），'
          '連線後會由雲端 AI 覆核；覆核前請以演算法數值與人工確認為準。');
    }

    // 幾何層：整機照的三片剪影互比
    for (final m in geometryMedia) {
      if (m.qualityOk != true) {
        notUsable++;
        continue;
      }
      final r = await _analyzeGeometry(m, session.sessionId, read, notes,
          geometry: geometry, rotorRadiusM: rotorRadiusM, hubHeightM: hubHeightM);
      if (r == null) {
        skipped++;
      } else {
        analyzed++;
        layersRun.add(WtLayer.geometry);
        detections.addAll(r);
      }
    }

    // 動態層。**音軌先跑**：它量到的葉片通過週期就是影片要在哪些時刻抽幀的依據，
    // 反過來的話影片得自己從像素推轉速——那是原型裡最貴的一步，而音軌已經免費給了。
    BladeAcousticResult? acousticResult;
    for (final m in audioMedia) {
      Uint8List bytes;
      try {
        bytes = await read(m.path);
      } catch (_) {
        skipped++;
        notes.add('${_shortPath(m.path)}：讀不到音檔，未納入分析。');
        continue;
      }
      final r = acoustic == null
          ? await compute(_acousticIsolate, bytes)
          : await acoustic(bytes);
      acousticResult ??= r.usable ? r : null;
      final det = _acousticDetections(r, m, session.sessionId, notes);
      if (r.usable) {
        analyzed++;
        layersRun.add(WtLayer.dynamic_);
      } else {
        skipped++;
      }
      detections.addAll(det);
    }

    for (final m in videoMedia) {
      if (frameExtractor == null) {
        skipped++;
        // 測試釘住的是「裝置端抽幀尚未接上」這句：不是「未實作」——原生實作
        // 已有（Android `BladeVideoFrames`），只是這個平台／這次呼叫沒接上
        notes.add('${_shortPath(m.path)}：影片已保存，但**裝置端抽幀尚未接上**'
            '（目前僅 Android 有原生實作；Flutter 沒有純 Dart 的 H.264 解碼器）。'
            '轉速已由音軌取得；三片剪影互比請用整機照。');
        continue;
      }
      if (acousticResult == null) {
        skipped++;
        notes.add('${_shortPath(m.path)}：沒有可用的音軌，因此不知道葉片通過週期，'
            '無法決定在哪些時刻抽幀。動態層本次未進行。');
        continue;
      }
      final periodS = 1.0 / acousticResult.bladePassHz;
      final times = BladeDynamicsService.sixOclockTimes(
        periodS: periodS,
        phaseS: acousticResult.passTimesS.isEmpty
            ? 0.0
            : acousticResult.passTimesS.first,
        durationS: acousticResult.durationS,
      );
      final r = await BladeDynamicsService.analyzeFrames(
        videoPath: m.path,
        atSeconds: times,
        extract: frameExtractor,
        // 影片幀不傳型錄半徑：多幀互比只看 px 的一致性
        geometry: geometry ?? _defaultGeometry,
      );
      notes.addAll(r.notes.map((n) => '${_shortPath(m.path)}（影片）：$n'));
      if (!r.ok) {
        skipped++;
        notes.add('${_shortPath(m.path)}（影片）：${r.reasons.join('；')}');
        continue;
      }
      analyzed++;
      layersRun.add(WtLayer.dynamic_);
      detections.addAll(_dynamicsDetections(r, m, session.sessionId));
    }

    skipped += notUsable + notSegment;
    if (notUsable > 0) {
      notes.add('$notUsable 張照片未通過拍攝品質閘門，未納入分析（數值不可採信，'
          '不是判定為正常）。');
    }
    if (notSegment > 0) {
      notes.add('$notSegment 張其他視角的照片已保存，但沒有對應的分析層，本次未分析。');
    }

    return BladeAnalysisOutcome(
      detections: detections,
      notes: notes,
      analyzedCount: analyzed,
      skippedCount: skipped,
      layersRun: layersRun,
    );
  }

  /// 幾何層：一張整機照 → 三片剪影互比。
  ///
  /// **拍攝閘門在互比之前**（`BladeStructureGate`）。這個順序是整個幾何層能不能用的
  /// 關鍵：定位錯誤時 `findStructure` 一樣會回傳一個三葉結構、互比一樣會吐出數字，
  /// 而那組數字自洽但完全錯。閘門不過就只留重拍指示，不產生任何幾何結論。
  static Future<List<WtDetection>?> _analyzeGeometry(
    WtMedia m,
    String sessionId,
    BladeBytesLoader read,
    List<String> notes, {
    BladeGeometryAnalyzer? geometry,
    double? rotorRadiusM,
    double? hubHeightM,
  }) async {
    Uint8List bytes;
    try {
      bytes = await read(m.path);
    } catch (_) {
      notes.add('${_shortPath(m.path)}：讀不到檔案，未納入幾何分析。');
      return null;
    }
    // 側視是宣告制：這張媒體被登記成哪一格，就照哪一格的規則判。
    // 從剪影推論側視會把塔門特寫、施工吊車、風場遠景、兩台風機同框都放行
    // （`blade_prototype/RESOLUTION_SENSITIVITY.md` §2），所以只信呼叫端的宣告。
    final result = await (geometry ?? _defaultGeometry)(bytes,
        rotorRadiusM: rotorRadiusM,
        hubHeightM: hubHeightM,
        expectedView: m.view == WtMediaView.side ? 'side' : 'front');

    if (!result.ok) {
      notes.add('${_shortPath(m.path)}（整機照）：${result.reasons.join('；')}');
      // 閘門拒收也是一筆要進報告的發現——現場需要知道「這張不能用」
      return [
        WtDetection(
          detectionId: 'geo-$sessionId-${p.basename(m.path)}',
          sessionId: sessionId,
          layer: WtLayer.geometry,
          defectClass: 'capture_quality',
          severity: null,
          metricJson: result.metrics,
          mediaPath: m.path,
          source: WtDetectionSource.algorithm,
          aiDescription: result.reasons.join('；'),
        )
      ];
    }
    for (final wmsg in result.warnings) {
      notes.add('${_shortPath(m.path)}（整機照）：$wmsg');
    }

    // 正視照的透視：補了就說補了多少，沒補就說這個數值不是缺陷量。
    final isSide = result.metrics['view'] == 'side';
    final compensated = result.metrics['perspective_compensated'] == true;
    final poseJson = result.metrics['pose'];
    final perspectiveClause = isSide
        ? ''
        : compensated
            ? _compensationClause(result.metrics)
            : '（正視照三片互比含透視分量：站位未驗證，此數值不是缺陷量，僅供近距離複檢參考）';
    if (!isSide && result.comparisons.isNotEmpty) {
      if (compensated) {
        notes.add('${_shortPath(m.path)}（整機照）：已依估計站位補償透視'
            '${_poseSummary(poseJson)}，預彎擬合 '
            '${(result.metrics['prebend_fit_m'] as num?)?.toStringAsFixed(1) ?? '—'} m'
            '${result.metrics['compensation_note'] != null ? '；${result.metrics['compensation_note']}' : ''}。');
      } else {
        final why = result.metrics['pose_note'];
        notes.add('${_shortPath(m.path)}（整機照）：無法估相機站位'
            '${why is String && why.isNotEmpty ? '（$why）' : ''}，三片互比**未補償透視**——'
            '正視照的葉尖偏移含透視分量，不是缺陷量。要補償請在資產填輪轂高度與轉子直徑，'
            '並用會寫 EXIF 焦距的相機 App 拍。');
      }
    }

    final out = <WtDetection>[];
    for (final c in result.comparisons) {
      if (!c.flagged) continue;
      final idx = c.outlierIndex;
      final cm = c.outlierDeviationCm;
      out.add(WtDetection(
        detectionId: 'geo-$sessionId-${p.basename(m.path)}-${c.metric}',
        sessionId: sessionId,
        layer: WtLayer.geometry,
        blade: idx >= 0 && idx < 3 ? ['A', 'B', 'C'][idx] : null,
        defectClass: c.metric == 'tip_deflection_px'
            ? 'tip_deflection'
            : 'blade_mismatch',
        // 三片互比只給「警告」級：它指出的是「這片與另兩片不一樣」，
        // 而不一樣的原因可能是變形，也可能是那一片剛好被雲遮住一段。
        // 要升級成不合格得靠近距離複檢，不是靠這張照片。
        severity: 2,
        confidence: null,
        metricJson: {
          ...result.metrics,
          '${c.metric}_values': c.values,
          '${c.metric}_deviation': c.outlierDeviation,
          '${c.metric}_z': c.z,
          if (c.metric == 'tip_deflection_px')
            'tip_deflection_px': c.outlierDeviation,
          // 有型錄轉子直徑時才有 cm 值（`result.metrics['cm_per_px']` 說明是怎麼換的）。
          // 這是幾何層第一個跨次可比的量：px 隨站位改變，cm 不會。
          if (cm != null) '${c.metric}_deviation_cm': cm,
          if (cm != null && c.metric == 'tip_deflection_px')
            'tip_deflection_cm': cm,
        },
        mediaPath: m.path,
        source: WtDetectionSource.algorithm,
        aiDescription: '三片互比：${_metricLabel(c.metric)}與另兩片差 '
            '${c.outlierDeviation.abs().toStringAsFixed(1)} px'
            '${cm == null ? '' : '（約 ${cm.abs().toStringAsFixed(0)} cm）'}'
            '（另兩片彼此差 ${c.othersSpread.abs().toStringAsFixed(1)} px，'
            'z = ${c.z.toStringAsFixed(1)}）$perspectiveClause',
      ));
    }
    if (out.isEmpty) {
      if (result.metrics['view'] == 'side') {
        // 側視只量垂掛葉片的彎曲，不做三片互比；單幀值含預彎，所以只記數字不判定。
        // 現階段沒有跨次基線的資料模型，先寫進摘要備註，不產生發現、不進趨勢。
        final defl = result.metrics['hanging_tip_deflection_px'];
        final deflCm = result.metrics['hanging_tip_deflection_cm'];
        notes.add('${_shortPath(m.path)}（整機照，側視）：只量垂掛葉片的 flapwise 彎曲'
            '（葉尖偏移 ${defl is num ? defl.toStringAsFixed(1) : '—'} px'
            '${deflCm is num ? '，約 ${deflCm.toStringAsFixed(0)} cm' : ''}，含預彎），'
            '不做三片互比；要與同一台的基線比對才有意義。');
      } else {
        notes.add('${_shortPath(m.path)}（整機照）：三片剪影互比未見離群'
            '（${result.comparisons.length} 個量都在雜訊範圍內'
            '${compensated ? '，已補償透視' : ''}）。');
      }
    }
    return out;
  }

  static String _poseSummary(dynamic poseJson) {
    if (poseJson is! Map) return '';
    final el = poseJson['elevation_deg'], yaw = poseJson['yaw_deg'];
    if (el is! num || yaw is! num) return '';
    return '（仰角 ${el.toStringAsFixed(0)}°、偏軸 ${yaw.toStringAsFixed(0)}°，'
        '由輪轂高度、型錄直徑與照片焦距估得；偏軸為粗估）';
  }

  /// 已補償的發現：寫補了多少，原始三片值也留在字面上。
  static String _compensationClause(Map<String, dynamic> metrics) {
    final raw = metrics['tip_deflection_raw_px'];
    final rawText = raw is List
        ? '；原始三片葉尖偏移 ${raw.map((v) => v is num ? v.toStringAsFixed(1) : '—').join('／')} px'
        : '';
    return '（已依估計站位補償透視${_poseSummary(metrics['pose'])}$rawText）';
  }

  /// 聲音層的偵測。
  ///
  /// **不可用時也產生一筆**（`audio_unusable`，無 severity）：現場需要知道
  /// 「這段錄音不能用、為什麼、下次怎麼錄」，而不是在報告上什麼都看不到——
  /// 那會被讀成「聲音沒問題」。
  static List<WtDetection> _acousticDetections(BladeAcousticResult r, WtMedia m,
      String sessionId, List<String> notes) {
    final base = 'aco-$sessionId-${p.basename(m.path)}';
    final shared = <String, dynamic>{
      'rpm_from_audio': r.rpmFromAudio,
      'blade_pass_hz': r.bladePassHz,
      'periodicity_confidence': r.periodicityConfidence,
      'envelope_snr_db': r.envelopeSnrDb,
      'wind_dominance': r.windDominance,
      'am_depth_db': r.amDepthDb,
      'asymmetry_db': r.asymmetryDb,
    };
    notes.addAll(r.notes.map((n) => '${_shortPath(m.path)}（音軌）：$n'));

    if (!r.usable) {
      return [
        WtDetection(
          detectionId: '$base-unusable',
          sessionId: sessionId,
          layer: WtLayer.dynamic_,
          defectClass: 'audio_unusable',
          severity: null,
          metricJson: shared,
          mediaPath: m.path,
          source: WtDetectionSource.algorithm,
          aiDescription: r.notes.join('；'),
        )
      ];
    }
    if (r.rpmFromAudio.isFinite) {
      notes.add('${_shortPath(m.path)}（音軌）：量到轉速 '
          '${r.rpmFromAudio.toStringAsFixed(1)} rpm'
          '（週期信賴度 ${r.periodicityConfidence.toStringAsFixed(2)}）。');
    }

    final out = <WtDetection>[];
    for (final c in r.comparisons) {
      if (!c.flagged) continue;
      final idx = c.outlierIndex;
      final label = idx >= 0 && idx < 3 ? ['A', 'B', 'C'][idx] : null;
      final hf = c.metric == 'high_band_ratio';
      out.add(WtDetection(
        detectionId: '$base-${c.metric}',
        sessionId: sessionId,
        layer: WtLayer.dynamic_,
        blade: label,
        defectClass: hf ? 'blade_noise_hf' : 'blade_noise',
        // 警告級，不給不合格。理由與幾何層相同：它指出的是「這一片與另兩片不一樣」。
        // 聲音還多一層不確定——路過的車輛、鳥、發電機都會落在某一片的視窗裡。
        severity: 2,
        metricJson: {
          ...shared,
          '${c.metric}_values': c.values,
          '${c.metric}_deviation': c.outlierDeviation,
          '${c.metric}_z': c.z,
        },
        mediaPath: m.path,
        source: WtDetectionSource.algorithm,
        aiDescription: hf
            ? '葉片 $label 的高頻能量占比高出另兩片 '
                '${c.outlierDeviation.abs().toStringAsFixed(3)}'
                '（z = ${c.z.toStringAsFixed(1)}）：粗糙表面的徵兆'
            : '葉片 $label 的寬頻噪音高出另兩片 '
                '${c.outlierDeviation.abs().toStringAsFixed(1)} dB'
                '（另兩片彼此差 ${c.othersSpread.abs().toStringAsFixed(1)} dB，'
                'z = ${c.z.toStringAsFixed(1)}）：疑似前緣侵蝕',
      ));
    }
    for (final b in r.blades) {
      if (!b.tonalExclusive) continue;
      out.add(WtDetection(
        detectionId: '$base-tonal-${b.label}',
        sessionId: sessionId,
        layer: WtLayer.dynamic_,
        blade: b.label,
        defectClass: 'blade_whistle',
        severity: 2,
        metricJson: {
          ...shared,
          'tonal_freq_hz': b.tonalFreqHz,
          'tonal_prominence_db': b.tonalProminenceDb,
        },
        mediaPath: m.path,
        source: WtDetectionSource.algorithm,
        aiDescription: '葉片 ${b.label} 在 '
            '${b.tonalFreqHz.toStringAsFixed(0)} Hz 有突出 '
            '${b.tonalProminenceDb.toStringAsFixed(1)} dB 的窄頻哨音，'
            '疑似後緣損傷或破洞',
      ));
    }
    if (out.isEmpty) {
      notes.add('${_shortPath(m.path)}（音軌）：三片寬頻位準與高頻占比一致，'
          '未見單片噪音異常。');
    }
    return out;
  }

  /// 動態層（影片多幀）的偵測。
  static List<WtDetection> _dynamicsDetections(
      BladeDynamicsResult r, WtMedia m, String sessionId) {
    final c = r.radiusComparison;
    if (c == null || !c.flagged) return const [];
    final idx = c.outlierIndex;
    return [
      WtDetection(
        detectionId: 'dyn-$sessionId-${p.basename(m.path)}-tip_radius',
        sessionId: sessionId,
        layer: WtLayer.dynamic_,
        blade: idx >= 0 && idx < 3 ? ['A', 'B', 'C'][idx] : null,
        defectClass: 'tip_radius_mismatch',
        severity: 2,
        metricJson: {
          'frames_requested': r.framesRequested,
          'frames_decoded': r.framesDecoded,
          'frames_measured': r.framesMeasured,
          'tip_radius_median_px': r.tipRadiusMedianPx,
          'tip_radius_deviation_px': c.outlierDeviation,
          'tip_radius_z': c.z,
        },
        mediaPath: m.path,
        source: WtDetectionSource.algorithm,
        aiDescription: '多幀取中位後，第 ${idx + 1} 順位通過六點鐘的葉片，'
            '葉尖半徑與另兩片差 '
            '${c.outlierDeviation.abs().toStringAsFixed(1)} px'
            '（z = ${c.z.toStringAsFixed(1)}，${r.framesMeasured} 幀量得出來）',
      )
    ];
  }

  static const Map<String, String> _metricLabels = {
    'tip_deflection_px': '葉尖偏移',
    'radius_px': '葉片長度',
    'mean_width_px': '平均弦寬',
    'residual_rms_px': '形狀不規則度',
    'band_level_db': '寬頻噪音位準',
    'high_band_ratio': '高頻能量占比',
    'tip_radius_px': '葉尖半徑（多幀中位）',
  };

  static String _metricLabel(String metric) => _metricLabels[metric] ?? metric;

  /// 合併演算法與 AI 的判斷。**公開**是刻意的：AI 補跑佇列
  /// （`blade_ai_retry_service.dart`）連線後會走同一條合併規則，
  /// 各自寫一份的話「AI 只能往上加」這條規則會兩邊漂移。
  ///
  /// **演算法的 severity 是下限，AI 只能往上加。** 理由：severity 來自量到的
  /// 數值，AI 看的是同一張照片的縮圖，沒有理由推翻量測；但 AI 可能看到量測沒有
  /// 涵蓋的東西（LEP 整片翻起、雷擊燒痕），那時它可以把等級拉高。
  /// AI 認為是正常結構時**不刪掉這筆發現**，把它的理由寫進描述交給人工判斷——
  /// 篩檢工具寧可多留一筆待確認，不要少留一筆。
  ///
  /// [aiSource] 為 [AiSource.localLlm]（Tier 1b 裝置端）時：描述冠「【離線初判】」、
  /// 來源留在 `geminiOfflinePending` 讓補跑佇列之後用雲端覆核，並把**演算法自己的等級**
  /// 存進 `metricJson['algorithm_severity']`——覆核時的下限是它，不是端側抬上去的那個
  /// （見 [algorithmFloorOf]）。
  static WtDetection mergeAlgorithmAndAi(WtDetection algo, WtDetection ai,
      {AiSource aiSource = AiSource.cloud}) {
    final local = aiSource == AiSource.localLlm;
    final severity = algo.severity == null
        ? ai.severity
        : (ai.severity == null
            ? algo.severity
            : math.max(algo.severity!, ai.severity!));
    final aiClass = ai.defectClass;
    final ruledOut = ai.metricJson['normal_structure_ruled_out'];
    final saysNormal = aiClass == 'none' || aiClass == null;
    final merged = saysNormal
        ? 'AI 認為這可能不是缺陷${ruledOut == null ? '' : '（$ruledOut）'}，'
            '但演算法量到的數值已超過門檻，仍列為待人工確認。'
            '${ai.aiDescription ?? ''}'
        : (ai.aiDescription ?? algo.aiDescription);
    final description =
        local && merged != null ? '【離線初判】$merged' : merged;
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
      metricJson: {
        ...algo.metricJson,
        ...ai.metricJson,
        'ai_source': aiSource.key,
        if (local) 'algorithm_severity': algo.severity,
      },
      mediaPath: algo.mediaPath,
      // 端側只是初判：來源仍是「待雲端 AI」，補跑佇列會接手覆核
      source: local
          ? WtDetectionSource.geminiOfflinePending
          : WtDetectionSource.gemini,
      aiDescription: description,
    );
  }

  /// 把一筆帶著端側初判的偵測還原成「演算法那一筆」當覆核的下限。
  ///
  /// 端側模型可以把等級抬上去（它跟雲端一樣受「只能往上加」的規則約束），但那個抬上去
  /// 的等級**不能**再當雲端覆核的下限——否則一個 2B 模型的誤判會變成永遠退不回去的地板。
  /// 沒有 `algorithm_severity` 的偵測（雲端判的、或純演算法）原樣回傳。
  static WtDetection algorithmFloorOf(WtDetection d) {
    if (!d.metricJson.containsKey('algorithm_severity')) return d;
    final floor = d.metricJson['algorithm_severity'];
    final metrics = Map<String, dynamic>.from(d.metricJson)
      ..remove('algorithm_severity')
      ..remove('ai_source')
      ..remove('normal_structure_ruled_out');
    return WtDetection(
      id: d.id,
      detectionId: d.detectionId,
      sessionId: d.sessionId,
      layer: d.layer,
      blade: d.blade,
      zone: d.zone,
      defectClass: d.defectClass,
      severity: floor is int ? floor : null,
      confidence: null,
      metricJson: metrics,
      // 不轉傳 bboxJson：`wt_detections.bbox_json` 目前沒有任何產生端（Mode B 實作後才有），
      // 這裡轉傳會讓死角查核把它算成「有人寫」而掩蓋那個事實
      mediaPath: d.mediaPath,
      source: d.source,
      humanStatus: d.humanStatus,
      humanNote: d.humanNote,
      aiDescription: null,
      createdAt: d.createdAt,
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

/// 幾何層 isolate 的參數：一張照片 + 型錄轉子半徑（可無）。
typedef _GeometryJob = ({
  Uint8List bytes,
  double? rotorRadiusM,
  double? hubHeightM,
  String? expectedView
});
