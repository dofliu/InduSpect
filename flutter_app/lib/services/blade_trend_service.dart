import '../models/wt_capture_session.dart';
import '../models/wt_detection.dart';

/// 趨勢上的一個點：某次到場、某個格位量到的值。
class BladeTrendPoint {
  final String sessionId;
  final DateTime capturedAt;

  /// 前緣／後緣 rms 比。**這是唯一跨次可比的量**（見 `BladeTrendService` 的說明）。
  final double? ratio;

  final int? severity;
  final WtHumanStatus humanStatus;
  final String? mediaPath;

  /// 演算法量到的原始粗糙度（px）。**跨次不可比**，只當同一次的參考值。
  final double? rmsPx;

  const BladeTrendPoint({
    required this.sessionId,
    required this.capturedAt,
    this.ratio,
    this.severity,
    this.humanStatus = WtHumanStatus.pending,
    this.mediaPath,
    this.rmsPx,
  });
}

/// 一個格位（葉片 × 區段）的歷次序列。
class BladeTrendSeries {
  /// 'A' / 'B' / 'C'，未指定時 null
  final String? blade;

  /// 'mid_LE' 之類的 zone key，未指定時 null
  final String? zone;

  /// 依時間由舊到新
  final List<BladeTrendPoint> points;

  const BladeTrendSeries({this.blade, this.zone, required this.points});

  String get key => '${blade ?? '-'}/${zone ?? '-'}';

  List<BladeTrendPoint> get withRatio =>
      points.where((p) => p.ratio != null).toList();

  BladeTrendPoint? get latest => points.isEmpty ? null : points.last;

  /// 最新值減最舊值。**至少要兩個有比值的點**才回傳，否則 null——
  /// 一個點沒有趨勢，回 0 會讓畫面顯示「持平」，那是無中生有。
  double? get delta {
    final r = withRatio;
    if (r.length < 2) return null;
    return r.last.ratio! - r.first.ratio!;
  }

  /// 兩次之間的最大跳升。單調惡化與「上次掉下來這次又衝高」在報告上意義不同。
  double? get maxStep {
    final r = withRatio;
    if (r.length < 2) return null;
    var m = r[1].ratio! - r[0].ratio!;
    for (var i = 2; i < r.length; i++) {
      final step = r[i].ratio! - r[i - 1].ratio!;
      if (step > m) m = step;
    }
    return m;
  }
}

/// 跨次趨勢比對（規格 §7 把資料模型做成資產驅動的理由）。
///
/// **為什麼趨勢只看比值，不看 px**：`rms_px` 受距離、焦段、感光元件解析度影響，
/// 兩次到場只要站得遠一點，同一片葉片的 px 值就會變小——那個變化與侵蝕無關。
/// 前緣／後緣 rms **比**是同一張照片內互比出來的無因次量，距離與鏡頭都約掉了，
/// 所以它是這套流程裡唯一真的跨次可比的數字。畫面上 px 值只當同一次的參考。
///
/// 這也是為什麼未超門檻的量測值仍然要存進 DB：那些「這次沒事」的比值，
/// 正是日後判斷「有沒有在惡化」的基線。
class BladeTrendService {
  BladeTrendService._();

  /// 比值要上升多少才算值得講的惡化。
  ///
  /// 取 0.5 的理由：合成夾具上乾淨葉片的比值約 0.94、輕度門檻是 1.5，
  /// 兩者相差 0.56——比這個小的變動與量測雜訊分不開。**這個值還沒有真實
  /// 語料背書**（規格 §10 外業待辦），所以只用來排序與措辭，不產生判定。
  static const double worseningDelta = 0.5;

  /// 把某台風機的所有偵測整理成逐格位的序列。
  ///
  /// [detections] 需含同一資產跨場次的偵測（`getWtDetectionsForAsset`）；
  /// [sessions] 提供每個 sessionId 的拍攝時間。
  ///
  /// **人工駁回的點會保留在序列裡但標記出來**：駁回的是「這是缺陷」這個判斷，
  /// 量到的數值仍然是那天的事實，抽掉它會讓趨勢線憑空斷一節。
  static List<BladeTrendSeries> build({
    required List<WtDetection> detections,
    required List<WtCaptureSession> sessions,
    WtLayer layer = WtLayer.surface,
  }) {
    final when = <String, DateTime>{
      for (final s in sessions) s.sessionId: s.capturedAt,
    };
    final grouped = <String, List<BladeTrendPoint>>{};
    final labels = <String, List<String?>>{};

    for (final d in detections) {
      if (d.layer != layer) continue;
      final at = when[d.sessionId];
      if (at == null) continue; // 沒有拍攝時間就排不進時間軸
      final key = '${d.blade ?? '-'}/${d.zone ?? '-'}';
      labels[key] = [d.blade, d.zone];
      (grouped[key] ??= []).add(BladeTrendPoint(
        sessionId: d.sessionId,
        capturedAt: at,
        ratio: _numOf(d.metricJson['le_over_te_rms_ratio']),
        severity: d.severity,
        humanStatus: d.humanStatus,
        mediaPath: d.mediaPath,
        rmsPx: _numOf(d.metricJson['rms_px']),
      ));
    }

    final out = <BladeTrendSeries>[];
    for (final entry in grouped.entries) {
      final points = entry.value..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
      out.add(BladeTrendSeries(
        blade: labels[entry.key]![0],
        zone: labels[entry.key]![1],
        points: points,
      ));
    }
    // 惡化幅度大的排前面；沒有趨勢的（單點）排最後
    out.sort((a, b) {
      final da = a.delta, db = b.delta;
      if (da == null && db == null) return a.key.compareTo(b.key);
      if (da == null) return 1;
      if (db == null) return -1;
      return db.compareTo(da);
    });
    return out;
  }

  /// 一句話講這個格位在幹嘛。**不下判定**——這裡講的是變化，不是合格與否。
  static String describe(BladeTrendSeries series) {
    final r = series.withRatio;
    if (r.isEmpty) return '沒有可比對的比值（該格位尚未量到前後緣比）';
    if (r.length == 1) {
      return '只有一次量測（比值 ${r.first.ratio!.toStringAsFixed(2)}），'
          '還看不出趨勢——下次到場拍同一格位才比得出來';
    }
    final d = series.delta!;
    final first = r.first.ratio!.toStringAsFixed(2);
    final last = r.last.ratio!.toStringAsFixed(2);
    final span = '${r.length} 次量測，$first → $last';
    if (d >= worseningDelta) {
      return '$span（上升 ${d.toStringAsFixed(2)}）：前緣相對後緣變粗了，建議排近距離複檢';
    }
    if (d <= -worseningDelta) {
      return '$span（下降 ${d.abs().toStringAsFixed(2)}）：比值變小。'
          '侵蝕不會自己好，比較可能是取景或光線不同——先確認兩次拍的是同一段';
    }
    return '$span（變化 ${d.toStringAsFixed(2)}）：與量測雜訊同級，看不出變化';
  }

  /// 跨次比對的前提。**畫面上一定要講**：兩次拍的不是同一段的話，
  /// 這條趨勢線比沒有更糟——它會讓人以為量到了變化。
  static const String comparabilityCaveat =
      '跨次比對的前提是兩次拍的是同一片葉片的同一段。比值本身不受距離與焦段影響'
      '（同一張照片內前後緣互比），但如果兩次拍的其實不是同一段，這條線就沒有意義。'
      '引導拍攝會顯示上次的照片與拍攝點距離，就是為了這件事。';

  static double? _numOf(dynamic v) => v is num ? v.toDouble() : null;
}
