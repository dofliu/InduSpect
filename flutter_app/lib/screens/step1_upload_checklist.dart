import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import '../providers/app_state_provider.dart';
import '../providers/inspection_provider.dart';
import '../utils/constants.dart';
import '../widgets/common/loading_widget.dart';

/// 步驟 1: 上傳定檢表
class Step1UploadChecklist extends StatelessWidget {
  const Step1UploadChecklist({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer2<AppStateProvider, InspectionProvider>(
      builder: (context, appState, inspection, child) {
        // 如果已經有巡檢項目,顯示列表和繼續按鈕
        if (inspection.inspectionItems.isNotEmpty) {
          return _buildItemsList(context, appState, inspection);
        }

        // 否則顯示上傳界面
        return _buildUploadInterface(context, inspection);
      },
    );
  }

  Widget _buildUploadInterface(BuildContext context, InspectionProvider inspection) {
    if (inspection.isAnalyzing) {
      return const LoadingWidget(message: '正在分析定檢表...請稍候');
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.upload_file,
              size: 100,
              color: AppColors.primary.withOpacity(0.5),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              '上傳定檢表照片',
              style: AppTextStyles.heading2,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'AI 將自動提取檢查項目並建立數位化清單',
              style: AppTextStyles.body2.copyWith(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xl),
            LoadingButton(
              text: '選擇定檢表照片',
              onPressed: () => _pickImage(context, inspection),
              backgroundColor: AppColors.primary,
            ),
            if (inspection.errorMessage != null) ...[
              const SizedBox(height: AppSpacing.md),
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: AppColors.error.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: AppColors.error),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        inspection.errorMessage!,
                        style: const TextStyle(color: AppColors.error),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildItemsList(BuildContext context, AppStateProvider appState, InspectionProvider inspection) {
    return Column(
      children: [
        // 標題
        Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          color: AppColors.backgroundLight,
          child: Row(
            children: [
              const Icon(Icons.check_circle, color: AppColors.success),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '定檢表已上傳',
                      style: AppTextStyles.heading3,
                    ),
                    Text(
                      '共 ${inspection.inspectionItems.length} 個檢查項目',
                      style: AppTextStyles.caption,
                    ),
                  ],
                ),
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
              return Card(
                margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: AppColors.primary,
                    child: Text('${index + 1}'),
                  ),
                  title: Text(item.description),
                  trailing: item.isCompleted
                      ? const Icon(Icons.check, color: AppColors.success)
                      : null,
                ),
              );
            },
          ),
        ),
        // 底部按鈕
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LoadingButton(
                text: '開始巡檢拍攝',
                onPressed: () => appState.nextStep(),
                backgroundColor: AppColors.success,
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: () => _reuploadChecklist(context, inspection),
                child: const Text('重新上傳定檢表'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _pickImage(BuildContext context, InspectionProvider inspection) async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(
      source: ImageSource.camera,
      maxWidth: 1920,
      maxHeight: 1080,
    );

    if (image != null) {
      await inspection.uploadChecklistFromXFile(image);
    }
  }

  Future<void> _reuploadChecklist(BuildContext context, InspectionProvider inspection) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('確認重新上傳'),
        content: const Text('這將清除當前的檢查清單。確定要繼續嗎？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('確定'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await inspection.clearAllData();
      _pickImage(context, inspection);
    }
  }
}
