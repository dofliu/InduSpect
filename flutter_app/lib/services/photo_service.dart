import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';

// 移動平台用
import 'dart:io' show File, Directory;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import '../utils/image_decode.dart';

/// 照片管理服務 - 管理拍照任務綁定、自動命名、壓縮、本地儲存
///
/// Sprint 2 Task 2.4:
/// 命名規則: {序號}-{項目簡稱}_{時間戳}.jpg
/// 例: "03-絕緣電阻_20260313_143052.jpg"
class PhotoService {
  static final PhotoService _instance = PhotoService._internal();
  factory PhotoService() => _instance;
  PhotoService._internal();

  /// task_id → 照片列表的綁定關係
  final Map<String, List<PhotoBinding>> _bindings = {};

  /// 最大單張照片大小（KB）
  static const int maxPhotoSizeKB = 300;

  /// 最大照片寬度（px）
  static const int maxPhotoWidth = 1280;

  /// 最大照片高度（px）
  static const int maxPhotoHeight = 960;

  /// Web 平台的記憶體暫存
  final Map<String, Uint8List> _webPhotoCache = {};

  // ============ 照片綁定管理 ============

  /// 將照片綁定到拍照任務
  Future<PhotoBinding> bindPhotoToTask({
    required String taskId,
    required String displayName,
    required int sequence,
    required Uint8List photoBytes,
  }) async {
    final now = DateTime.now();
    final fileName = _generateFileName(
      sequence: sequence,
      displayName: displayName,
      timestamp: now,
    );

    // 壓縮照片
    final compressed = await compressPhoto(photoBytes);

    // 儲存照片
    final savedPath = await _savePhoto(fileName, compressed);

    // 建立綁定
    final binding = PhotoBinding(
      taskId: taskId,
      displayName: displayName,
      fileName: fileName,
      filePath: savedPath,
      photoBytes: compressed,
      captureTime: now,
      sequence: sequence,
      sizeKB: compressed.lengthInBytes / 1024,
    );

    // 加入綁定列表
    _bindings.putIfAbsent(taskId, () => []);
    _bindings[taskId]!.add(binding);

    debugPrint(
        '[PhotoService] Bound photo $fileName to task $taskId '
        '(${binding.sizeKB.toStringAsFixed(1)} KB)');

    return binding;
  }

  /// 取得某個任務的所有照片綁定
  List<PhotoBinding> getBindingsForTask(String taskId) {
    return _bindings[taskId] ?? [];
  }

  /// 取得所有綁定（用於上傳）
  Map<String, List<PhotoBinding>> getAllBindings() {
    return Map.unmodifiable(_bindings);
  }

  /// 移除某個任務的照片綁定
  void removeBindingsForTask(String taskId) {
    final removed = _bindings.remove(taskId);
    if (removed != null) {
      for (final binding in removed) {
        _deletePhoto(binding.filePath);
        if (kIsWeb) {
          _webPhotoCache.remove(binding.fileName);
        }
      }
      debugPrint('[PhotoService] Removed ${removed.length} bindings for task $taskId');
    }
  }

  /// 清除所有綁定
  void clearAll() {
    for (final bindings in _bindings.values) {
      for (final binding in bindings) {
        _deletePhoto(binding.filePath);
      }
    }
    _bindings.clear();
    _webPhotoCache.clear();
    debugPrint('[PhotoService] Cleared all photo bindings');
  }

  /// 取得綁定統計
  PhotoServiceStats getStats() {
    int totalPhotos = 0;
    double totalSizeKB = 0;

    for (final bindings in _bindings.values) {
      totalPhotos += bindings.length;
      for (final binding in bindings) {
        totalSizeKB += binding.sizeKB;
      }
    }

    return PhotoServiceStats(
      totalTasks: _bindings.length,
      totalPhotos: totalPhotos,
      totalSizeKB: totalSizeKB,
    );
  }

  // ============ 照片命名 ============

  /// 產生照片檔名
  ///
  /// 格式: {序號(2位)}-{項目簡稱}_{時間戳}.jpg
  /// 例: "03-絕緣電阻_20260313_143052.jpg"
  String _generateFileName({
    required int sequence,
    required String displayName,
    required DateTime timestamp,
  }) {
    final seqStr = sequence.toString().padLeft(2, '0');
    final shortName = _shortenName(displayName);
    final timeStr = DateFormat('yyyyMMdd_HHmmss').format(timestamp);
    return '$seqStr-${shortName}_$timeStr.jpg';
  }

  /// 縮短名稱（移除空格、限制長度）
  String _shortenName(String name, {int maxLen = 15}) {
    // 移除空格和特殊字元
    String shortened = name
        .replaceAll(RegExp(r'[\s　]+'), '')
        .replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');

    if (shortened.length > maxLen) {
      shortened = shortened.substring(0, maxLen);
    }

    return shortened;
  }

  // ============ 照片壓縮 ============

  /// 壓縮照片至目標大小以下
  Future<Uint8List> compressPhoto(
    Uint8List bytes, {
    int? maxSizeKB,
    int? maxWidth,
    int? maxHeight,
  }) async {
    maxSizeKB ??= PhotoService.maxPhotoSizeKB;
    maxWidth ??= PhotoService.maxPhotoWidth;
    maxHeight ??= PhotoService.maxPhotoHeight;

    try {
      // safeDecodeImage 而不是 img.decodeImage：外層的 catch 本來就接得住
      // RangeError（`catch (e)` 連 Error 一起接），所以這裡**不是**在修崩潰；
      // 差別在紀錄——截斷的檔案原本會走到下面 catch 印出「Compress failed:
      // RangeError...」，現在會走這一支印出「Failed to decode」，
      // 那才是實際發生的事。
      final image = safeDecodeImage(bytes);
      if (image == null) {
        debugPrint('[PhotoService] Failed to decode image, returning original');
        return bytes;
      }

      // 縮放
      img.Image resized = image;
      if (image.width > maxWidth || image.height > maxHeight) {
        final ratio = [
          maxWidth / image.width,
          maxHeight / image.height,
        ].reduce((a, b) => a < b ? a : b);

        resized = img.copyResize(
          image,
          width: (image.width * ratio).round(),
          height: (image.height * ratio).round(),
          interpolation: img.Interpolation.linear,
        );
      }

      // 逐步降低品質直到低於目標大小
      int quality = 85;
      Uint8List compressed;

      do {
        compressed = Uint8List.fromList(
          img.encodeJpg(resized, quality: quality),
        );

        if (compressed.lengthInBytes / 1024 <= maxSizeKB) {
          break;
        }

        quality -= 10;
      } while (quality >= 30);

      debugPrint(
          '[PhotoService] Compressed: ${bytes.lengthInBytes ~/ 1024}KB → '
          '${compressed.lengthInBytes ~/ 1024}KB (quality=$quality)');

      return compressed;
    } catch (e) {
      debugPrint('[PhotoService] Compress failed: $e, returning original');
      return bytes;
    }
  }

  // ============ 照片儲存 ============

  /// 儲存照片到本地
  Future<String> _savePhoto(String fileName, Uint8List bytes) async {
    if (kIsWeb) {
      _webPhotoCache[fileName] = bytes;
      return 'web://$fileName';
    }

    try {
      final dir = await _getPhotosDirectory();
      final filePath = path.join(dir.path, fileName);
      final file = File(filePath);
      await file.writeAsBytes(bytes);
      return filePath;
    } catch (e) {
      debugPrint('[PhotoService] Save failed: $e');
      return 'error://$fileName';
    }
  }

  /// 刪除照片
  Future<void> _deletePhoto(String filePath) async {
    if (kIsWeb || filePath.startsWith('web://') || filePath.startsWith('error://')) {
      return;
    }

    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('[PhotoService] Delete failed: $e');
    }
  }

  /// 取得照片儲存目錄
  Future<Directory> _getPhotosDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final photosDir = Directory(path.join(appDir.path, 'inspection_photos'));
    if (!await photosDir.exists()) {
      await photosDir.create(recursive: true);
    }
    return photosDir;
  }

  /// 取得照片的 base64（用於上傳到後端）
  String? getPhotoBase64(PhotoBinding binding) {
    if (kIsWeb) {
      final bytes = _webPhotoCache[binding.fileName];
      if (bytes != null) {
        return base64Encode(bytes);
      }
    }

    // 如果有 photoBytes 直接用
    if (binding.photoBytes != null) {
      return base64Encode(binding.photoBytes!);
    }

    return null;
  }

  /// 將所有綁定轉為後端 photo_bindings 格式
  List<Map<String, dynamic>> toPhotoBindingsForBackend() {
    final result = <Map<String, dynamic>>[];
    final timeFormat = DateFormat('yyyy-MM-dd HH:mm');

    for (final entry in _bindings.entries) {
      for (final binding in entry.value) {
        final b64 = getPhotoBase64(binding);
        if (b64 != null) {
          result.add({
            'task_id': binding.taskId,
            'display_name': binding.displayName,
            'photo_base64': b64,
            'capture_time': timeFormat.format(binding.captureTime),
            'sequence': binding.sequence,
          });
        }
      }
    }

    // 按 sequence 排序
    result.sort((a, b) =>
        (a['sequence'] as int).compareTo(b['sequence'] as int));

    return result;
  }

  // ============ 儲存空間管理 ============

  /// 檢查儲存空間使用量
  Future<double> getStorageUsageMB() async {
    if (kIsWeb) {
      double totalBytes = 0;
      for (final bytes in _webPhotoCache.values) {
        totalBytes += bytes.lengthInBytes;
      }
      return totalBytes / (1024 * 1024);
    }

    try {
      final dir = await _getPhotosDirectory();
      double totalBytes = 0;
      await for (final entity in dir.list()) {
        if (entity is File) {
          totalBytes += await entity.length();
        }
      }
      return totalBytes / (1024 * 1024);
    } catch (e) {
      return 0;
    }
  }

  /// 清理舊照片（超過指定天數）
  Future<int> cleanOldPhotos({int daysOld = 7}) async {
    if (kIsWeb) {
      // Web 平台不需清理（記憶體會自動釋放）
      return 0;
    }

    int cleaned = 0;
    try {
      final dir = await _getPhotosDirectory();
      final cutoff = DateTime.now().subtract(Duration(days: daysOld));

      await for (final entity in dir.list()) {
        if (entity is File) {
          final stat = await entity.stat();
          if (stat.modified.isBefore(cutoff)) {
            await entity.delete();
            cleaned++;
          }
        }
      }

      debugPrint('[PhotoService] Cleaned $cleaned old photos');
    } catch (e) {
      debugPrint('[PhotoService] Clean old photos failed: $e');
    }

    return cleaned;
  }
}


/// 照片綁定資料
class PhotoBinding {
  final String taskId;
  final String displayName;
  final String fileName;
  final String filePath;
  final Uint8List? photoBytes;
  final DateTime captureTime;
  final int sequence;
  final double sizeKB;

  PhotoBinding({
    required this.taskId,
    required this.displayName,
    required this.fileName,
    required this.filePath,
    this.photoBytes,
    required this.captureTime,
    required this.sequence,
    required this.sizeKB,
  });

  Map<String, dynamic> toJson() => {
    'task_id': taskId,
    'display_name': displayName,
    'file_name': fileName,
    'file_path': filePath,
    'capture_time': captureTime.toIso8601String(),
    'sequence': sequence,
    'size_kb': sizeKB,
  };
}


/// 照片服務統計
class PhotoServiceStats {
  final int totalTasks;
  final int totalPhotos;
  final double totalSizeKB;

  PhotoServiceStats({
    required this.totalTasks,
    required this.totalPhotos,
    required this.totalSizeKB,
  });

  double get totalSizeMB => totalSizeKB / 1024;

  @override
  String toString() =>
      'PhotoServiceStats(tasks=$totalTasks, photos=$totalPhotos, '
      'size=${totalSizeMB.toStringAsFixed(1)}MB)';
}
