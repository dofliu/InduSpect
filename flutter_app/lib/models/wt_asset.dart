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

  /// 以名稱為鍵新增或覆蓋一個拍攝點，回傳新物件（不 mutate）。
  ///
  /// 這是拍攝點**唯一的寫入口**。在此之前 `capturePoint()` 有人讀（引導拍攝畫面
  /// 拿它算「到上次拍攝點的距離」），但全 app 沒有任何地方寫——於是「導回上次
  /// 拍攝點」這個功能永遠不會亮。寫入的來源是每張全機照自己的 GPS
  /// （`WtMedia.latitude/longitude`），不是場次的到場位置：正視與側視站在不同地方。
  WtAsset upsertCapturePoint(WtCapturePoint point) {
    final next = capturePoints.where((p) => p.name != point.name).toList()
      ..add(point);
    return copyWith(capturePoints: next);
  }

  /// 全機照的站位（規格 §10.2，2026-09-16 依 `OFFAXIS_SENSITIVITY.md` 改）：
  /// **水平距離 3–4 倍輪轂高度**（仰角 14–18°）、站在轉子軸線上。
  /// 舊規則 1.5–2 倍是仰角 27–34°，那種站位三片半徑離散 > 15%，拍攝閘門**一定拒收**；
  /// 3 倍以外閘門放行，透視殘量再由姿態估計補償。沒有輪轂高度就回 null，不猜。
  String? get standingDistanceHint {
    final h = hubHeightM;
    if (h == null || h <= 0) return null;
    return '${(h * standingDistanceMinFactor).round()}–${(h * standingDistanceMaxFactor).round()} m';
  }

  /// 站位下限／建議上限（× 輪轂高度）。下限 3 = 仰角約 18°：合成掃描裡 1.8 倍（29°）全被
  /// 閘門擋下、3 倍全放行；上限 4 = 仰角約 14°，再遠轉子在 12 MP 畫面上就不到一半了。
  static const double standingDistanceMinFactor = 3.0;
  static const double standingDistanceMaxFactor = 4.0;

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
