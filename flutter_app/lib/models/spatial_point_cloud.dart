import 'dart:convert';

/// 代表 3D 空間中的一個座標點 (X, Y, Z, Color, Confidence)
class SpatialPoint {
  final double x;
  final double y;
  final double z;
  final int r;
  final int g;
  final int b;
  final double confidence;

  SpatialPoint({
    required this.x,
    required this.y,
    required this.z,
    this.r = 0,
    this.g = 210,
    this.b = 255,
    this.confidence = 1.0,
  });

  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
        'z': z,
        'r': r,
        'g': g,
        'b': b,
        'confidence': confidence,
      };

  factory SpatialPoint.fromJson(Map<String, dynamic> json) => SpatialPoint(
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        z: (json['z'] as num).toDouble(),
        r: json['r'] ?? 0,
        g: json['g'] ?? 210,
        b: json['b'] ?? 255,
        confidence: (json['confidence'] ?? 1.0).toDouble(),
      );
}

/// 釘在 3D 空間中的巡檢標籤錨點
class SpatialAnchor {
  final String id;
  final String title;
  final String description;
  final double x;
  final double y;
  final double z;
  final String? imagePath;
  final String status; // 'normal', 'warning', 'abnormal'
  final DateTime createdAt;

  SpatialAnchor({
    required this.id,
    required this.title,
    required this.description,
    required this.x,
    required this.y,
    required this.z,
    this.imagePath,
    this.status = 'normal',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'x': x,
        'y': y,
        'z': z,
        'imagePath': imagePath,
        'status': status,
        'createdAt': createdAt.toIso8601String(),
      };

  factory SpatialAnchor.fromJson(Map<String, dynamic> json) => SpatialAnchor(
        id: json['id'],
        title: json['title'],
        description: json['description'],
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        z: (json['z'] as num).toDouble(),
        imagePath: json['imagePath'],
        status: json['status'] ?? 'normal',
        createdAt: DateTime.parse(json['createdAt']),
      );
}

/// 3D 空間內辨識到的平面 (如地面、牆面、設備表面)
class SpatialPlane {
  final String id;
  final String type; // 'floor', 'wall', 'ceiling', 'table'
  final double centerX;
  final double centerY;
  final double centerZ;
  final double extentX;
  final double extentZ;

  SpatialPlane({
    required this.id,
    required this.type,
    required this.centerX,
    required this.centerY,
    required this.centerZ,
    required this.extentX,
    required this.extentZ,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'centerX': centerX,
        'centerY': centerY,
        'centerZ': centerZ,
        'extentX': extentX,
        'extentZ': extentZ,
      };

  factory SpatialPlane.fromJson(Map<String, dynamic> json) => SpatialPlane(
        id: json['id'],
        type: json['type'],
        centerX: (json['centerX'] as num).toDouble(),
        centerY: (json['centerY'] as num).toDouble(),
        centerZ: (json['centerZ'] as num).toDouble(),
        extentX: (json['extentX'] as num).toDouble(),
        extentZ: (json['extentZ'] as num).toDouble(),
      );
}

/// 整個 3D 空間掃描的模型集
class SpatialPointCloud {
  final String id;
  final String name;
  final List<SpatialPoint> points;
  final List<SpatialPlane> planes;
  final List<SpatialAnchor> anchors;
  final DateTime scannedAt;
  final double estimatedVolumeM3;

  SpatialPointCloud({
    required this.id,
    required this.name,
    required this.points,
    required this.planes,
    required this.anchors,
    DateTime? scannedAt,
    this.estimatedVolumeM3 = 0.0,
  }) : scannedAt = scannedAt ?? DateTime.now();

  /// 導出為標準 .ply 3D 點雲檔案格式 (Stanford PLY)
  String toPlyFormat() {
    final buffer = StringBuffer();
    buffer.writeln('ply');
    buffer.writeln('format ascii 1.0');
    buffer.writeln('comment Created by InduSpect AI Spatial Engine');
    buffer.writeln('element vertex ${points.length}');
    buffer.writeln('property float x');
    buffer.writeln('property float y');
    buffer.writeln('property float z');
    buffer.writeln('property uchar red');
    buffer.writeln('property uchar green');
    buffer.writeln('property uchar blue');
    buffer.writeln('end_header');

    for (final pt in points) {
      buffer.writeln('${pt.x.toStringAsFixed(4)} ${pt.y.toStringAsFixed(4)} ${pt.z.toStringAsFixed(4)} ${pt.r} ${pt.g} ${pt.b}');
    }

    return buffer.toString();
  }

  /// 導出為 .obj 3D 幾何物件格式
  String toObjFormat() {
    final buffer = StringBuffer();
    buffer.writeln('# InduSpect AI 3D Spatial Model');
    buffer.writeln('o SpatialSpace_$id');

    for (final pt in points) {
      buffer.writeln('v ${pt.x.toStringAsFixed(4)} ${pt.y.toStringAsFixed(4)} ${pt.z.toStringAsFixed(4)}');
    }

    return buffer.toString();
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'points': points.map((p) => p.toJson()).toList(),
        'planes': planes.map((p) => p.toJson()).toList(),
        'anchors': anchors.map((a) => a.toJson()).toList(),
        'scannedAt': scannedAt.toIso8601String(),
        'estimatedVolumeM3': estimatedVolumeM3,
      };

  factory SpatialPointCloud.fromJson(Map<String, dynamic> json) => SpatialPointCloud(
        id: json['id'],
        name: json['name'],
        points: (json['points'] as List).map((p) => SpatialPoint.fromJson(p)).toList(),
        planes: (json['planes'] as List).map((p) => SpatialPlane.fromJson(p)).toList(),
        anchors: (json['anchors'] as List).map((a) => SpatialAnchor.fromJson(a)).toList(),
        scannedAt: DateTime.parse(json['scannedAt']),
        estimatedVolumeM3: (json['estimatedVolumeM3'] as num).toDouble(),
      );
}
