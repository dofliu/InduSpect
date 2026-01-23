import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io' show File;
import '../../services/image_service.dart';

/// 跨平台圖片顯示組件
/// Web 平台：使用 Image.memory() 從緩存讀取
/// 移動平台：使用 Image.file() 從文件系統讀取
class CrossPlatformImage extends StatelessWidget {
  final String imagePath;
  final double? width;
  final double? height;
  final BoxFit? fit;

  const CrossPlatformImage({
    super.key,
    required this.imagePath,
    this.width,
    this.height,
    this.fit,
  });

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      // Web 平台：使用 FutureBuilder 從內存緩存加載
      return FutureBuilder<Uint8List>(
        future: ImageService().getImageBytes(imagePath),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return SizedBox(
              width: width,
              height: height,
              child: const Center(child: CircularProgressIndicator()),
            );
          }

          if (snapshot.hasError || !snapshot.hasData) {
            return SizedBox(
              width: width,
              height: height,
              child: const Center(
                child: Icon(Icons.broken_image, size: 48, color: Colors.grey),
              ),
            );
          }

          return Image.memory(
            snapshot.data!,
            width: width,
            height: height,
            fit: fit,
          );
        },
      );
    } else {
      // 移動平台：直接使用 File
      return Image.file(
        File(imagePath),
        width: width,
        height: height,
        fit: fit,
      );
    }
  }
}
