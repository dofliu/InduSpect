import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import '../utils/constants.dart';

/// 圖片處理服務
class ImageService {
  static final ImageService _instance = ImageService._internal();
  factory ImageService() => _instance;
  ImageService._internal();

  /// 壓縮並保存圖片到本地
  Future<String> compressAndSaveImage(String sourcePath) async {
    try {
      // 讀取原始圖片
      final bytes = await File(sourcePath).readAsBytes();
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
      final compressed = img.encodeJpg(
        resized,
        quality: AppConstants.imageQuality,
      );

      // 保存到應用目錄
      final appDir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'inspection_$timestamp.jpg';
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
    } catch (e) {
      print('Error compressing and saving image: $e');
      rethrow;
    }
  }

  /// 將圖片轉換為 base64（用於 API 上傳）
  Future<String> imageToBase64(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      return base64Encode(bytes);
    } catch (e) {
      print('Error converting image to base64: $e');
      rethrow;
    }
  }

  /// 從 base64 創建圖片文件
  Future<String> base64ToImage(String base64String) async {
    try {
      final bytes = base64Decode(base64String);
      final appDir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'decoded_$timestamp.jpg';
      final savePath = path.join(appDir.path, 'images', fileName);

      // 確保目錄存在
      final directory = Directory(path.dirname(savePath));
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      final file = File(savePath);
      await file.writeAsBytes(bytes);

      return savePath;
    } catch (e) {
      print('Error converting base64 to image: $e');
      rethrow;
    }
  }

  /// 獲取圖片的字節數組（用於 Gemini API）
  Future<Uint8List> getImageBytes(String imagePath) async {
    try {
      return await File(imagePath).readAsBytes();
    } catch (e) {
      print('Error reading image bytes: $e');
      rethrow;
    }
  }

  /// 刪除圖片文件
  Future<bool> deleteImage(String imagePath) async {
    try {
      final file = File(imagePath);
      if (await file.exists()) {
        await file.delete();
        return true;
      }
      return false;
    } catch (e) {
      print('Error deleting image: $e');
      return false;
    }
  }

  /// 清除所有保存的圖片
  Future<void> clearAllImages() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final imagesDir = Directory(path.join(appDir.path, 'images'));

      if (await imagesDir.exists()) {
        await imagesDir.delete(recursive: true);
      }
    } catch (e) {
      print('Error clearing all images: $e');
    }
  }

  /// 獲取圖片文件大小（MB）
  Future<double> getImageSizeMB(String imagePath) async {
    try {
      final file = File(imagePath);
      final bytes = await file.length();
      return bytes / (1024 * 1024); // Convert to MB
    } catch (e) {
      print('Error getting image size: $e');
      return 0;
    }
  }

  /// 檢查圖片是否存在
  Future<bool> imageExists(String imagePath) async {
    try {
      return await File(imagePath).exists();
    } catch (e) {
      print('Error checking if image exists: $e');
      return false;
    }
  }
}
