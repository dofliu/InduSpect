import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../models/spatial_point_cloud.dart';

class SpatialMappingService {
  static final SpatialMappingService _instance = SpatialMappingService._internal();
  factory SpatialMappingService() => _instance;
  SpatialMappingService._internal();

  final _uuid = const Uuid();

  /// 模擬/實時擷取 3D 空間掃描點雲與特徵平面
  Future<SpatialPointCloud> startSpatialScan({
    required String spaceName,
    int pointDensity = 1200,
    Function(double progress, int pointsCaptured)? onProgress,
  }) async {
    final List<SpatialPoint> points = [];
    final Random random = Random();

    // 模擬 15-30 秒相機手持掃描軌跡與特徵點生成
    for (int i = 0; i < pointDensity; i++) {
      await Future.delayed(const Duration(milliseconds: 2));

      // 建立房間長方體幾何邊界與設備結構點
      double x, y, z;
      int r = 0, g = 210, b = 255;

      int section = i % 4;
      if (section == 0) {
        // 地板特徵點 (y ≈ -1.2)
        x = (random.nextDouble() - 0.5) * 4.0;
        y = -1.2 + (random.nextDouble() - 0.5) * 0.05;
        z = (random.nextDouble() - 0.5) * 4.0;
        r = 100; g = 110; b = 120;
      } else if (section == 1) {
        // 後方牆面特徵點 (z ≈ 2.0)
        x = (random.nextDouble() - 0.5) * 4.0;
        y = (random.nextDouble() - 0.5) * 2.4;
        z = 2.0 + (random.nextDouble() - 0.5) * 0.05;
        r = 180; g = 190; b = 200;
      } else if (section == 2) {
        // 機房配電箱 / 變壓器設備體積 (x: 0.2~1.2, y: -0.8~0.6, z: 0.8~1.8)
        x = 0.2 + random.nextDouble() * 1.0;
        y = -0.8 + random.nextDouble() * 1.4;
        z = 0.8 + random.nextDouble() * 1.0;
        r = 0; g = 230; b = 180; // 亮青綠色標示設備區域
      } else {
        // 周圍隨機空間特徵點 (SLAM Feature Points)
        x = (random.nextDouble() - 0.5) * 3.5;
        y = (random.nextDouble() - 0.5) * 2.2;
        z = (random.nextDouble() - 0.5) * 3.5;
        r = 0; g = 180; b = 255;
      }

      points.add(SpatialPoint(
        x: x,
        y: y,
        z: z,
        r: r,
        g: g,
        b: b,
        confidence: 0.8 + random.nextDouble() * 0.2,
      ));

      if (onProgress != null && i % 40 == 0) {
        onProgress((i + 1) / pointDensity, points.length);
      }
    }

    // 計算 3D 平面 (Planes)
    final planes = [
      SpatialPlane(id: 'plane_floor', type: 'floor', centerX: 0, centerY: -1.2, centerZ: 0, extentX: 4.0, extentZ: 4.0),
      SpatialPlane(id: 'plane_wall_back', type: 'wall', centerX: 0, centerY: 0, centerZ: 2.0, extentX: 4.0, extentZ: 2.4),
      SpatialPlane(id: 'plane_equip_top', type: 'table', centerX: 0.7, centerY: 0.6, centerZ: 1.3, extentX: 1.0, extentZ: 1.0),
    ];

    // 初始化範例巡檢 3D 空間錨點
    final anchors = [
      SpatialAnchor(
        id: _uuid.v4(),
        title: '3號變壓器表針',
        description: '油壓值 5.2 bar, 運作正常',
        x: 0.7,
        y: 0.2,
        z: 1.3,
        status: 'normal',
      ),
      SpatialAnchor(
        id: _uuid.v4(),
        title: '配電管線熱點過熱',
        description: '紅外線測溫 78.5℃ (高於警報值 70℃)',
        x: 0.4,
        y: -0.3,
        z: 1.1,
        status: 'warning',
      ),
    ];

    // 計算預估體積
    final volume = _calculateVolume(points);

    final model = SpatialPointCloud(
      id: _uuid.v4(),
      name: spaceName.isEmpty ? '機房空間 3D 模型' : spaceName,
      points: points,
      planes: planes,
      anchors: anchors,
      estimatedVolumeM3: volume,
    );

    return model;
  }

  /// 計算 3D 點雲 Bounding Box 與估算體積 (m³)
  double _calculateVolume(List<SpatialPoint> points) {
    if (points.isEmpty) return 0.0;
    double minX = points.first.x, maxX = points.first.x;
    double minY = points.first.y, maxY = points.first.y;
    double minZ = points.first.z, maxZ = points.first.z;

    for (final p in points) {
      if (p.x < minX) minX = p.x;
      if (p.x > maxX) maxX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.y > maxY) maxY = p.y;
      if (p.z < minZ) minZ = p.z;
      if (p.z > maxZ) maxZ = p.z;
    }

    final width = maxX - minX;
    final height = maxY - minY;
    final depth = maxZ - minZ;
    return width * height * depth;
  }

  /// 儲存 3D 模型檔案為 .ply 格式
  Future<File> saveSpatialModelAsPly(SpatialPointCloud model) async {
    final appDir = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(appDir.path, 'spatial_models'));
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }

    final file = File(p.join(folder.path, '${model.id}.ply'));
    final plyData = model.toPlyFormat();
    await file.writeAsString(plyData);
    return file;
  }

  /// 儲存 3D 空間 JSON 描述
  Future<File> saveSpatialModelJson(SpatialPointCloud model) async {
    final appDir = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(appDir.path, 'spatial_models'));
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }

    final file = File(p.join(folder.path, '${model.id}.json'));
    final jsonStr = jsonEncode(model.toJson());
    await file.writeAsString(jsonStr);
    return file;
  }

  /// 讀取本地所有已建立的 3D 空間模型
  Future<List<SpatialPointCloud>> loadSavedSpatialModels() async {
    final appDir = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(appDir.path, 'spatial_models'));
    if (!await folder.exists()) return [];

    final List<SpatialPointCloud> result = [];
    final entities = folder.listSync();
    for (final entity in entities) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          final content = await entity.readAsString();
          final jsonMap = jsonDecode(content);
          result.add(SpatialPointCloud.fromJson(jsonMap));
        } catch (e) {
          // ignore corrupted files
        }
      }
    }
    return result;
  }
}
