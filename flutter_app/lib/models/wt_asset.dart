import 'dart:convert';

/// 一個拍攝點：到場後要站的位置與朝向。
///
/// 跨次比對的前提是「站在同一個位置拍」——葉尖偏移的量測差在幾像素的量級，
/// 換一個站位帶進來的透視差會遠大於缺陷本身。GPS + 羅盤只能把人帶回大概的
/// 位置，最後的對齊靠 `blade_capture_guide_screen` 疊上次的剪影。
class WtCapturePoint {
  final String name; // 'front' | 'side' | 自訂
  final double? latitude;
  final double? longitude;
  final double? headingDeg; // 相機朝向（磁北 0°，順時鐘）
  final String? note;

  const WtCapturePoint({
    required this.name,
    this.latitude,
    this.longitude,
    this.headingDeg,
    this.note,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        if (latitude != null) 'lat': latitude,
        if (longitude != null) 'lng': longitude,
        if (headingDeg != null) 'heading': headingDeg,
        if (note != null) 'note': note,
      };

  factory WtCapturePoint.fromJson(Map<String, dynamic> json) => WtCapturePoint(
        name: json['name'] as String? ?? '',
        latitude: (json['lat'] as num?)?.toDouble(),
        longitude: (json['lng'] as num?)?.toDouble(),
        headingDeg: (json['heading'] as num?)?.toDouble(),
        note: json['note'] as String?,
      );

  bool get hasLocation => latitude != null && longitude != null;
}

/// 風機資產 — 對應 SQLite `wt_assets` 表（v5 新增，規格 §7）。
///
/// 定檢是表單驅動（主鍵 = 一張表），葉片檢測是**資產驅動**（主鍵 = 一台風機，
/// 反覆檢測、跨次比對），所以獨立建表，不動既有三張表。
class WtAsset {
  final int? id;
  final String assetId; // 'WTG-07'，現場編號，使用者輸入
  String siteName;
  String? model; // 機型：決定 OEM 參數（葉長、根弦、LEP 帶位置）
  double? hubHeightM;
  double? rotorDiameterM;
  final List<WtCapturePoint> capturePoints;
  final DateTime createdAt;

  WtAsset({
    this.id,
    required this.assetId,
    this.siteName = '',
    this.model,
    this.hubHeightM,
    this.rotorDiameterM,
    List<WtCapturePoint>? capturePoints,
    DateTime? createdAt,
  })  : capturePoints = capturePoints ?? [],
        createdAt = createdAt ?? DateTime.now();

  /// 轉子半徑（m）。幾何層要用它把像素換算成實尺——沒有它就只能報像素差。
  double? get rotorRadiusM =>
      rotorDiameterM == null ? null : rotorDiameterM! / 2.0;

  WtCapturePoint? capturePoint(String name) {
    for (final p in capturePoints) {
      if (p.name == name) return p;
    }
    return null;
  }

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'asset_id': assetId,
      'site_name': siteName,
      'model': model,
      'hub_height_m': hubHeightM,
      'rotor_diameter_m': rotorDiameterM,
      'capture_points': jsonEncode(capturePoints.map((p) => p.toJson()).toList()),
      'created_at': createdAt.toIso8601String(),
    };
    if (id != null) map['id'] = id;
    return map;
  }

  factory WtAsset.fromMap(Map<String, dynamic> map) => WtAsset(
        id: map['id'] as int?,
        assetId: map['asset_id'] as String,
        siteName: map['site_name'] as String? ?? '',
        model: map['model'] as String?,
        hubHeightM: (map['hub_height_m'] as num?)?.toDouble(),
        rotorDiameterM: (map['rotor_diameter_m'] as num?)?.toDouble(),
        capturePoints: _decodePoints(map['capture_points']),
        createdAt: DateTime.tryParse(map['created_at'] as String? ?? '') ??
            DateTime.now(),
      );

  static List<WtCapturePoint> _decodePoints(dynamic raw) {
    if (raw == null || (raw is String && raw.isEmpty)) return [];
    try {
      final decoded = jsonDecode(raw as String);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((m) => WtCapturePoint.fromJson(m.cast<String, dynamic>()))
            .toList();
      }
    } catch (_) {
      // 欄位壞掉不該讓整個列表讀不出來：回空陣列，資產本身還在
    }
    return [];
  }

  WtAsset copyWith({
    String? siteName,
    String? model,
    double? hubHeightM,
    double? rotorDiameterM,
    List<WtCapturePoint>? capturePoints,
  }) =>
      WtAsset(
        id: id,
        assetId: assetId,
        siteName: siteName ?? this.siteName,
        model: model ?? this.model,
        hubHeightM: hubHeightM ?? this.hubHeightM,
        rotorDiameterM: rotorDiameterM ?? this.rotorDiameterM,
        capturePoints: capturePoints ?? this.capturePoints,
        createdAt: createdAt,
      );
}
