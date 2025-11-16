import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import '../providers/app_state_provider.dart';
import '../providers/inspection_provider.dart';
import '../utils/constants.dart';
import '../widgets/common/loading_widget.dart';
import '../widgets/common/cross_platform_image.dart';

/// 步驟 2: 拍攝巡檢照片
class Step2CapturePhotos extends StatelessWidget {
  const Step2CapturePhotos({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer2<AppStateProvider, InspectionProvider>(
      builder: (context, appState, inspection, child) {
        if (inspection.selectedJob == null) {
          return _buildNoJobSelected();
        }

        if (inspection.isAnalyzing) {
          return LoadingWidget(
            message: '正在同步/分析照片...',
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    inspection.selectedJob?.title ?? '當前巡檢',
                    style: AppTextStyles.heading3,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '$completedCount / $totalCount 已完成',
                              style: AppTextStyles.caption,
                            ),
                            if (inspection.hasPendingUploads)
                              Text(
                                '${inspection.pendingUploadTasks.length} 張照片待同步',
                                style: AppTextStyles.caption.copyWith(
                                  color: AppColors.warning,
                                ),
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
                    isPendingUpload:
                        inspection.pendingUploadItemIds.contains(item.id),
                    pendingError: inspection.getPendingUploadError(item.id),
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
                  text: inspection.hasPendingUploads
                      ? '同步 ${inspection.pendingUploadTasks.length} 張照片'
                      : '開始分析所有項目',
                  onPressed: () => _analyzeAll(context, appState, inspection),
                  backgroundColor:
                      inspection.hasPendingUploads ? AppColors.info : AppColors.success,
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildNoJobSelected() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.assignment, size: 80, color: AppColors.primary),
            const SizedBox(height: AppSpacing.md),
            const Text('請先在步驟 1 選擇巡檢任務', style: AppTextStyles.heading3),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '回到上一步登入並選擇任務後，即可開始拍攝巡檢照片。',
              textAlign: TextAlign.center,
              style: AppTextStyles.body2.copyWith(color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _capturePhoto(
    BuildContext context,
    InspectionProvider inspection,
    String itemId,
  ) async {
    // 顯示選擇對話框
    final source = await showDialog<ImageSource>(
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

    if (source != null) {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (image != null) {
        await inspection.addPhotoToItemFromXFile(itemId, image);
      }
    }
  }

  Future<void> _analyzeAll(
    BuildContext context,
    AppStateProvider appState,
    InspectionProvider inspection,
  ) async {
    await inspection.analyzeAllPhotos();

    if (context.mounted) {
      if (inspection.errorMessage != null) {
        // 顯示錯誤提示（例如試用次數已用完）
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Row(
              children: const [
                Icon(Icons.warning_amber_rounded, color: Colors.orange),
                SizedBox(width: 12),
                Text('提示'),
              ],
            ),
            content: Text(inspection.errorMessage!),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('稍後再說'),
              ),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(context); // 關閉對話框
                  Navigator.pushNamed(context, '/settings'); // 前往設定頁面
                },
                icon: const Icon(Icons.settings),
                label: const Text('前往設定'),
              ),
            ],
          ),
        );
      } else {
        await appState.nextStep();
      }
    }
  }
}

class _PhotoItemCard extends StatelessWidget {
  final dynamic item;
  final int index;
  final VoidCallback onCapture;
  final bool isPendingUpload;
  final String? pendingError;

  const _PhotoItemCard({
    required this.item,
    required this.index,
    required this.onCapture,
    required this.isPendingUpload,
    required this.pendingError,
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
                child: CrossPlatformImage(
                  imagePath: item.photoPath!,
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
          if (isPendingUpload || pendingError != null)
            Padding(
              padding: const EdgeInsets.only(
                left: AppSpacing.sm,
                right: AppSpacing.sm,
                bottom: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Icon(
                    isPendingUpload ? Icons.cloud_upload : Icons.error_outline,
                    color: isPendingUpload ? AppColors.warning : AppColors.error,
                    size: 18,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Text(
                      pendingError ?? '等待網路連線後自動上傳',
                      style: TextStyle(
                        fontSize: 12,
                        color: isPendingUpload
                            ? AppColors.warning
                            : AppColors.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
