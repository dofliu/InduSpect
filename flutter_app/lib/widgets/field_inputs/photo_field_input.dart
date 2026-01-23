import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../models/template_field.dart';
import '../../services/photo_sync_service.dart';
import '../../services/connectivity_service.dart';

class PhotoFieldInput extends StatefulWidget {
  final TemplateField field;
  final dynamic value;
  final ValueChanged<dynamic> onChanged;
  final Future<void> Function(String fieldId, Map<String, dynamic>) onAIAnalysis;
  final String? recordId; // For sync queue

  const PhotoFieldInput({
    Key? key,
    required this.field,
    required this.value,
    required this.onChanged,
    required this.onAIAnalysis,
    this.recordId,
  }) : super(key: key);

  @override
  State<PhotoFieldInput> createState() => _PhotoFieldInputState();
}

class _PhotoFieldInputState extends State<PhotoFieldInput> {
  final PhotoSyncService _syncService = PhotoSyncService();
  final ConnectivityService _connectivityService = ConnectivityService();
  bool _isSyncing = false;

  @override
  Widget build(BuildContext context) {
    if (widget.field.fieldType == FieldType.photoMultiple) {
      return _buildMultiplePhotoInput(context);
    } else {
      return _buildSinglePhotoInput(context);
    }
  }

  Widget _buildSinglePhotoInput(BuildContext context) {
    final photoPath = widget.value != null ? widget.value['path'] : null;
    final isOnline = _connectivityService.isOnline;

    return Column(
      children: [
        if (photoPath != null)
          Stack(
            children: [
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
              // Sync status badge
              if (!isOnline || _isSyncing)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _isSyncing ? Colors.orange : Colors.grey,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _isSyncing ? Icons.sync : Icons.cloud_off,
                          color: Colors.white,
                          size: 14,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _isSyncing ? 'Syncing...' : 'Offline',
                          style: const TextStyle(color: Colors.white, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: () => _takeSinglePhoto(context),
          icon: const Icon(Icons.camera_alt),
          label: Text(photoPath != null ? 'Retake Photo' : 'Take Photo'),
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
    final photos = widget.value != null && widget.value is List ? widget.value : [];
    final isOnline = _connectivityService.isOnline;

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
          onPressed: photos.length < (widget.field.maxCount ?? 5)
              ? () => _takeMultiplePhoto(context)
              : null,
          icon: const Icon(Icons.add_a_photo),
          label: Text('Add Photo (${photos.length}/${widget.field.maxCount ?? 5})'),
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
      widget.onChanged({
        'path': photo.path,
        'timestamp': DateTime.now().toIso8601String(),
      });

      // Queue for AI analysis if enabled and we have recordId
      if (widget.field.aiFillable && widget.recordId != null) {
        await _queuePhotoForAnalysis(photo.path);
      }
    }
  }

  Future<void> _queuePhotoForAnalysis(String photoPath) async {
    if (widget.recordId == null) return;

    setState(() {
      _isSyncing = true;
    });

    try {
      final isOnline = _connectivityService.isOnline;

      if (isOnline) {
        // Online: Trigger AI analysis directly
        await widget.onAIAnalysis(widget.field.fieldId, {});
      } else {
        // Offline: Queue for later sync
        await _syncService.queuePhotoForSync(
          recordId: widget.recordId!,
          fieldId: widget.field.fieldId,
          photoPath: photoPath,
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Row(
                children: [
                  Icon(Icons.cloud_off, color: Colors.white),
                  SizedBox(width: 8),
                  Text('Photo saved. Will sync when online.'),
                ],
              ),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Error queuing photo: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
        });
      }
    }
  }

  Future<void> _takeMultiplePhoto(BuildContext context) async {
    final source = await _showImageSourceDialog(context);
    if (source == null) return;

    final picker = ImagePicker();
    final photo = await picker.pickImage(source: source);

    if (photo != null) {
      final currentPhotos = widget.value != null && widget.value is List ? List.from(widget.value) : [];
      currentPhotos.add({
        'path': photo.path,
        'timestamp': DateTime.now().toIso8601String(),
      });
      widget.onChanged(currentPhotos);

      // Queue for AI analysis if enabled and we have recordId
      if (widget.field.aiFillable && widget.recordId != null) {
        await _queuePhotoForAnalysis(photo.path);
      }
    }
  }

  void _removePhoto(int index) {
    final currentPhotos = List.from(widget.value);
    currentPhotos.removeAt(index);
    widget.onChanged(currentPhotos);
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
