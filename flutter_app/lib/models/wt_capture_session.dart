import 'dart:convert';

/// 風機當時的狀態。停機時葉片轉到六點鐘可把距離縮到一半、解析度翻倍（規格 §3.2）。
enum WtTurbineState { stopped, idling, running, unknown }

/// 拍攝作業的處理狀態
enum WtSessionStatus { draft, analyzed, confirmed, shared }

/// 一張照片／一段影片
enum WtMediaKind { photo, video }

/// 拍攝視角。`front`/`side` 是全機照（幾何層，Phase 2）；
/// `segment` 是長焦分區段照（表面層，Phase 1 的主力）。
enum WtMediaView { front, side, segment, tower, other }

/// 拍攝作業裡的一份媒體。
///
/// `qualityJson` 存 `ImageQualityService` 與葉片閘門的判定結果。**不合格的照片照樣留著**
/// ——現場重拍要看得到上一張哪裡不合格，而且刪掉會讓「拍了幾張」的紀錄失真。
class WtMedia {
  final String path;
  final WtMediaKind kind;
  final WtMediaView view;
  final double? zoom; // 光學倍率，1.0 / 5.0…
  final String? bladePosition; // 'A' | 'B' | 'C' | '6oclock' | null
  final String? zone; // 'root' | 'mid' | 'tip'
  final String? leadingEdge; // 'top' | 'bottom'：分區段照的前緣在畫面哪一側
  final Map<String, dynamic> qualityJson;
  final DateTime capturedAt;

  WtMedia({
    required this.path,
    this.kind = WtMediaKind.photo,
    this.view = WtMediaView.segment,
    this.zoom,
    this.bladePosition,
    this.zone,
    this.leadingEdge,
    Map<String, dynamic>? qualityJson,
    DateTime? capturedAt,
  })  : qualityJson = qualityJson ?? {},
        capturedAt = capturedAt ?? DateTime.now();

  /// 品質閘門是否放行。沒有判定結果時回 null（尚未分析），不要當成合格。
  bool? get qualityOk =>
      qualityJson.containsKey('ok') ? qualityJson['ok'] == true : null;

  Map<String, dynamic> toJson() => {
        'path': path,
        'kind': kind.name,
        'view': view.name,
        if (zoom != null) 'zoom': zoom,
        if (bladePosition != null) 'blade_position': bladePosition,
        if (zone != null) 'zone': zone,
        if (leadingEdge != null) 'le': leadingEdge,
        if (qualityJson.isNotEmpty) 'quality': qualityJson,
        'captured_at': capturedAt.toIso8601String(),
      };

  factory WtMedia.fromJson(Map<String, dynamic> json) => WtMedia(
        path: json['path'] as String? ?? '',
        kind: _enumOf(WtMediaKind.values, json['kind'], WtMediaKind.photo),
        view: _enumOf(WtMediaView.values, json['view'], WtMediaView.segment),
        zoom: (json['zoom'] as num?)?.toDouble(),
        bladePosition: json['blade_position'] as String?,
        zone: json['zone'] as String?,
        leadingEdge: json['le'] as String?,
        qualityJson: (json['quality'] as Map?)?.cast<String, dynamic>() ?? {},
        capturedAt:
            DateTime.tryParse(json['captured_at'] as String? ?? '') ?? DateTime.now(),
      );

  WtMedia copyWith({Map<String, dynamic>? qualityJson}) => WtMedia(
        path: path,
        kind: kind,
        view: view,
        zoom: zoom,
        bladePosition: bladePosition,
        zone: zone,
        leadingEdge: leadingEdge,
        qualityJson: qualityJson ?? this.qualityJson,
        capturedAt: capturedAt,
      );
}

/// 一次到場的拍攝作業 — 對應 SQLite `wt_capture_sessions` 表（v5 新增，規格 §7）。
class WtCaptureSession {
  final int? id;
  final String sessionId;
  final String assetId;
  String title;
  final DateTime capturedAt;
  WtTurbineState turbineState;
  final double? latitude;
  final double? longitude;
  String? weatherNote;
  String? inspector;
  final List<WtMedia> media;
  WtSessionStatus status;
  String? reportPath;
  bool pendingShare;
  DateTime updatedAt;

  WtCaptureSession({
    this.id,
    required this.sessionId,
    required this.assetId,
    this.title = '',
    DateTime? capturedAt,
    this.turbineState = WtTurbineState.unknown,
    this.latitude,
    this.longitude,
    this.weatherNote,
    this.inspector,
    List<WtMedia>? media,
    this.status = WtSessionStatus.draft,
    this.reportPath,
    this.pendingShare = false,
    DateTime? updatedAt,
  })  : media = media ?? [],
        capturedAt = capturedAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  List<WtMedia> mediaOfView(WtMediaView view) =>
      media.where((m) => m.view == view).toList();

  /// 通過品質閘門的媒體數。分析只能用這些。
  int get usableMediaCount => media.where((m) => m.qualityOk == true).length;

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'session_id': sessionId,
      'asset_id': assetId,
      'title': title,
      'captured_at': capturedAt.toIso8601String(),
      'turbine_state': turbineState.name,
      'latitude': latitude,
      'longitude': longitude,
      'weather_note': weatherNote,
      'inspector': inspector,
      'media': jsonEncode(media.map((m) => m.toJson()).toList()),
      'status': status.name,
      'report_path': reportPath,
      'pending_share': pendingShare ? 1 : 0,
      'updated_at': updatedAt.toIso8601String(),
    };
    if (id != null) map['id'] = id;
    return map;
  }

  factory WtCaptureSession.fromMap(Map<String, dynamic> map) => WtCaptureSession(
        id: map['id'] as int?,
        sessionId: map['session_id'] as String,
        assetId: map['asset_id'] as String,
        title: map['title'] as String? ?? '',
        capturedAt:
            DateTime.tryParse(map['captured_at'] as String? ?? '') ?? DateTime.now(),
        turbineState:
            _enumOf(WtTurbineState.values, map['turbine_state'], WtTurbineState.unknown),
        latitude: (map['latitude'] as num?)?.toDouble(),
        longitude: (map['longitude'] as num?)?.toDouble(),
        weatherNote: map['weather_note'] as String?,
        inspector: map['inspector'] as String?,
        media: _decodeMedia(map['media']),
        status: _enumOf(WtSessionStatus.values, map['status'], WtSessionStatus.draft),
        reportPath: map['report_path'] as String?,
        pendingShare: (map['pending_share'] as int? ?? 0) == 1,
        updatedAt:
            DateTime.tryParse(map['updated_at'] as String? ?? '') ?? DateTime.now(),
      );

  static List<WtMedia> _decodeMedia(dynamic raw) {
    if (raw == null || (raw is String && raw.isEmpty)) return [];
    try {
      final decoded = jsonDecode(raw as String);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((m) => WtMedia.fromJson(m.cast<String, dynamic>()))
            .toList();
      }
    } catch (_) {
      // 同 form_inspection_record：欄位壞掉不該讓整筆紀錄消失
    }
    return [];
  }
}

T _enumOf<T extends Enum>(List<T> values, dynamic raw, T fallback) {
  final name = raw as String?;
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}
