import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import '../providers/app_state_provider.dart';
import '../providers/inspection_provider.dart';
import '../utils/constants.dart';
import '../widgets/common/loading_widget.dart';

/// 步驟 2: 拍攝巡檢照片
class Step2CapturePhotos extends StatelessWidget {
  const Step2CapturePhotos({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer2<AppStateProvider, InspectionProvider>(
      builder: (context, appState, inspection, child) {
        if (inspection.isAnalyzing) {
          return LoadingWidget(
            message: '正在分析照片...\n${inspection.currentAnalyzingItemId != null ? "處理中..." : ""}',
          );
        }

        final completedCount = inspection.completedItemsCount;
        final totalCount = inspection.inspectionItems.length;
        final allCompleted = completedCount == totalCount;

        return Column(
          children: [
            // 進度指示
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              color: AppColors.backgroundLight,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '拍攝進度',
                          style: AppTextStyles.heading3,
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          '$completedCount / $totalCount 已完成',
                          style: AppTextStyles.caption,
                        ),
                      ],
                    ),
                  ),
                  CircularProgressIndicator(
                    value: totalCount > 0 ? completedCount / totalCount : 0,
                    backgroundColor: Colors.grey[300],
                    valueColor: const AlwaysStoppedAnimation<Color>(AppColors.success),
                  ),
                ],
              ),
            ),
            // 項目列表
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(AppSpacing.md),
                itemCount: inspection.inspectionItems.length,
                itemBuilder: (context, index) {
                  final item = inspection.inspectionItems[index];
                  return _PhotoItemCard(
                    item: item,
                    index: index,
                    onCapture: () => _capturePhoto(context, inspection, item.id),
                  );
                },
              ),
            ),
            // 底部按鈕
            if (allCompleted)
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 4,
                      offset: const Offset(0, -2),
                    ),
                  ],
                ),
                child: LoadingButton(
                  text: '開始分析所有項目',
                  onPressed: () => _analyzeAll(context, appState, inspection),
                  backgroundColor: AppColors.success,
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _capturePhoto(
    BuildContext context,
    InspectionProvider inspection,
    String itemId,
  ) async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(
      source: ImageSource.camera,
      maxWidth: 1920,
      maxHeight: 1080,
      imageQuality: 85,
    );

    if (image != null) {
      await inspection.addPhotoToItem(itemId, image.path);
    }
  }

  Future<void> _analyzeAll(
    BuildContext context,
    AppStateProvider appState,
    InspectionProvider inspection,
  ) async {
    await inspection.analyzeAllPhotos();

    if (context.mounted && inspection.errorMessage == null) {
      await appState.nextStep();
    }
  }
}

class _PhotoItemCard extends StatelessWidget {
  final dynamic item;
  final int index;
  final VoidCallback onCapture;

  const _PhotoItemCard({
    required this.item,
    required this.index,
    required this.onCapture,
  });

  @override
  Widget build(BuildContext context) {
    final isCompleted = item.isCompleted;

    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor:
                  isCompleted ? AppColors.success : AppColors.primary,
              child: isCompleted
                  ? const Icon(Icons.check, color: Colors.white)
                  : Text('${index + 1}'),
            ),
            title: Text(item.description),
            subtitle: isCompleted
                ? const Text('已拍攝', style: TextStyle(color: AppColors.success))
                : const Text('待拍攝'),
          ),
          if (isCompleted && item.photoPath != null)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(item.photoPath!),
                  height: 200,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onCapture,
                icon: Icon(isCompleted ? Icons.camera_alt : Icons.add_a_photo),
                label: Text(isCompleted ? '重新拍攝' : '拍攝照片'),
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      isCompleted ? AppColors.warning : AppColors.primary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
