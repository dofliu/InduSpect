import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image/image.dart' as img;
import '../utils/constants.dart';

// 條件導入：只在非 Web 平台導入 dart:io
import 'dart:io' if (dart.library.html) 'dart:html';
import 'package:path_provider/path_provider.dart'
    if (dart.library.html) 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

/// 圖片處理服務
/// 支持 Web 和移動平台
class ImageService {
  static final ImageService _instance = ImageService._internal();
  factory ImageService() => _instance;
  ImageService._internal();

  // Web 平台的內存存儲
  final Map<String, Uint8List> _webImageCache = {};

  /// 壓縮並保存圖片
  /// Web 平台：保存到內存並返回唯一 ID
  /// 移動平台：保存到文件系統並返回路徑
  Future<String> compressAndSaveImage(String sourcePath) async {
    try {
      Uint8List bytes;

      // 讀取原始圖片
      if (kIsWeb) {
        // Web 平台：sourcePath 實際上是 XFile 的路徑，需要特殊處理
        // 但由於我們在上層已經處理了，這裡直接返回路徑
        // 實際上在 Web 上我們應該直接傳遞 bytes
        throw UnsupportedError(
            'compressAndSaveImage should not be called with path on Web. Use compressAndSaveImageFromBytes instead.');
      } else {
        // 移動平台
        final file = File(sourcePath);
        bytes = await file.readAsBytes();
      }

      return await _processAndSaveImage(bytes);
    } catch (e) {
      print('Error compressing and saving image: $e');
      rethrow;
    }
  }

  /// 從字節數組壓縮並保存圖片（跨平台）
  Future<String> compressAndSaveImageFromBytes(Uint8List bytes) async {
    try {
      return await _processAndSaveImage(bytes);
    } catch (e) {
      print('Error compressing and saving image from bytes: $e');
      rethrow;
    }
  }

  /// 處理並保存圖片（內部方法）
  Future<String> _processAndSaveImage(Uint8List bytes) async {
    try {
      // 解碼圖片
      final image = img.decodeImage(bytes);

      if (image == null) {
        throw Exception('Failed to decode image');
      }

      // 調整大小（如果超過最大尺寸）
      img.Image resized = image;
      if (image.width > AppConstants.maxImageWidth ||
          image.height > AppConstants.maxImageHeight) {
        resized = img.copyResize(
          image,
          width: image.width > AppConstants.maxImageWidth
              ? AppConstants.maxImageWidth
              : null,
          height: image.height > AppConstants.maxImageHeight
              ? AppConstants.maxImageHeight
              : null,
        );
      }

      // 壓縮為 JPEG
      final compressed = Uint8List.fromList(
        img.encodeJpg(
          resized,
          quality: AppConstants.imageQuality,
        ),
      );

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'inspection_$timestamp.jpg';

      if (kIsWeb) {
        // Web 平台：保存到內存
        final imageId = 'web_$fileName';
        _webImageCache[imageId] = compressed;
        return imageId;
      } else {
        // 移動平台：保存到文件系統
        final appDir = await getApplicationDocumentsDirectory();
        final savePath = path.join(appDir.path, 'images', fileName);

        // 確保目錄存在
        final directory = Directory(path.dirname(savePath));
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }

        // 寫入文件
        final file = File(savePath);
        await file.writeAsBytes(compressed);

        return savePath;
      }
    } catch (e) {
      print('Error in _processAndSaveImage: $e');
      rethrow;
    }
  }

  /// 將圖片轉換為 base64（用於 API 上傳）
  Future<String> imageToBase64(String imagePath) async {
    try {
      final bytes = await getImageBytes(imagePath);
      return base64Encode(bytes);
    } catch (e) {
      print('Error converting image to base64: $e');
      rethrow;
    }
  }

  /// 從 base64 創建圖片
  Future<String> base64ToImage(String base64String) async {
    try {
      final bytes = base64Decode(base64String);
      return await _processAndSaveImage(bytes);
    } catch (e) {
      print('Error converting base64 to image: $e');
      rethrow;
    }
  }

  /// 獲取圖片的字節數組（用於 Gemini API）
  Future<Uint8List> getImageBytes(String imagePath) async {
    try {
      if (kIsWeb) {
        // Web 平台：從內存緩存讀取
        final bytes = _webImageCache[imagePath];
        if (bytes == null) {
          throw Exception('Image not found in cache: $imagePath');
        }
        return bytes;
      } else {
        // 移動平台：從文件讀取
        final file = File(imagePath);
        return await file.readAsBytes();
      }
    } catch (e) {
      print('Error reading image bytes: $e');
      rethrow;
    }
  }

  /// 刪除圖片
  Future<bool> deleteImage(String imagePath) async {
    try {
      if (kIsWeb) {
        // Web 平台：從內存移除
        _webImageCache.remove(imagePath);
        return true;
      } else {
        // 移動平台：刪除文件
        final file = File(imagePath);
        if (await file.exists()) {
          await file.delete();
          return true;
        }
        return false;
      }
    } catch (e) {
      print('Error deleting image: $e');
      return false;
    }
  }

  /// 清除所有保存的圖片
  Future<void> clearAllImages() async {
    try {
      if (kIsWeb) {
        // Web 平台：清空內存緩存
        _webImageCache.clear();
      } else {
        // 移動平台：刪除目錄
        final appDir = await getApplicationDocumentsDirectory();
        final imagesDir = Directory(path.join(appDir.path, 'images'));

        if (await imagesDir.exists()) {
          await imagesDir.delete(recursive: true);
        }
      }
    } catch (e) {
      print('Error clearing all images: $e');
    }
  }

  /// 獲取圖片文件大小（MB）
  Future<double> getImageSizeMB(String imagePath) async {
    try {
      if (kIsWeb) {
        // Web 平台：計算內存中的大小
        final bytes = _webImageCache[imagePath];
        if (bytes == null) return 0;
        return bytes.length / (1024 * 1024);
      } else {
        // 移動平台：獲取文件大小
        final file = File(imagePath);
        final bytes = await file.length();
        return bytes / (1024 * 1024);
      }
    } catch (e) {
      print('Error getting image size: $e');
      return 0;
    }
  }

  /// 檢查圖片是否存在
  Future<bool> imageExists(String imagePath) async {
    try {
      if (kIsWeb) {
        // Web 平台：檢查內存緩存
        return _webImageCache.containsKey(imagePath);
      } else {
        // 移動平台：檢查文件
        return await File(imagePath).exists();
      }
    } catch (e) {
      print('Error checking if image exists: $e');
      return false;
    }
  }

  /// 從 Web XFile 路徑獲取圖片 URL（僅 Web）
  String? getWebImageUrl(String imagePath) {
    if (!kIsWeb) return null;

    // 如果是從 XFile 來的原始路徑，直接返回
    if (!imagePath.startsWith('web_')) {
      return imagePath;
    }

    // 如果是我們處理過的，轉換為 data URL
    final bytes = _webImageCache[imagePath];
    if (bytes == null) return null;

    final base64 = base64Encode(bytes);
    return 'data:image/jpeg;base64,$base64';
  }
}
