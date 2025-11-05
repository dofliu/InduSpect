import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../models/template_field.dart';

class PhotoFieldInput extends StatelessWidget {
  final TemplateField field;
  final dynamic value;
  final ValueChanged<dynamic> onChanged;
  final Future<void> Function(String fieldId, Map<String, dynamic>) onAIAnalysis;

  const PhotoFieldInput({
    Key? key,
    required this.field,
    required this.value,
    required this.onChanged,
    required this.onAIAnalysis,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (field.fieldType == FieldType.photoMultiple) {
      return _buildMultiplePhotoInput(context);
    } else {
      return _buildSinglePhotoInput(context);
    }
  }

  Widget _buildSinglePhotoInput(BuildContext context) {
    final photoPath = value != null ? value['path'] : null;

    return Column(
      children: [
        if (photoPath != null)
          Container(
            height: 200,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(
                File(photoPath),
                fit: BoxFit.cover,
              ),
            ),
          ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: () => _takeSinglePhoto(context),
          icon: const Icon(Icons.camera_alt),
          label: Text(photoPath != null ? '重新拍攝' : '拍攝照片'),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 16,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMultiplePhotoInput(BuildContext context) {
    final photos = value != null && value is List ? value : [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (photos.isNotEmpty)
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: photos.length,
            itemBuilder: (context, index) {
              return Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(photos[index]['path']),
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => _removePhoto(index),
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black54,
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: photos.length < (field.maxCount ?? 5)
              ? () => _takeMultiplePhoto(context)
              : null,
          icon: const Icon(Icons.add_a_photo),
          label: Text('拍攝照片 (${photos.length}/${field.maxCount ?? 5})'),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 16,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _takeSinglePhoto(BuildContext context) async {
    final source = await _showImageSourceDialog(context);
    if (source == null) return;

    final picker = ImagePicker();
    final photo = await picker.pickImage(source: source);

    if (photo != null) {
      onChanged({
        'path': photo.path,
        'timestamp': DateTime.now().toIso8601String(),
      });

      // 如果需要 AI 分析，執行分析
      if (field.aiAnalyze == true) {
        // TODO: 整合 AI 分析功能
        await onAIAnalysis(field.fieldId, {});
      }
    }
  }

  Future<void> _takeMultiplePhoto(BuildContext context) async {
    final source = await _showImageSourceDialog(context);
    if (source == null) return;

    final picker = ImagePicker();
    final photo = await picker.pickImage(source: source);

    if (photo != null) {
      final currentPhotos = value != null && value is List ? List.from(value) : [];
      currentPhotos.add({
        'path': photo.path,
        'timestamp': DateTime.now().toIso8601String(),
      });
      onChanged(currentPhotos);

      // 如果需要 AI 分析，執行分析
      if (field.aiAnalyze == true) {
        await onAIAnalysis(field.fieldId, {});
      }
    }
  }

  void _removePhoto(int index) {
    final currentPhotos = List.from(value);
    currentPhotos.removeAt(index);
    onChanged(currentPhotos);
  }

  Future<ImageSource?> _showImageSourceDialog(BuildContext context) async {
    return await showDialog<ImageSource>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('選擇照片來源'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt, color: Colors.blue),
              title: const Text('拍攝照片'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: Colors.green),
              title: const Text('從圖庫選擇'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
  }
}
