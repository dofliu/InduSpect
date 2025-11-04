import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import '../providers/app_state_provider.dart';
import '../providers/inspection_provider.dart';
import '../utils/constants.dart';
import '../widgets/common/loading_widget.dart';

/// 快速分析模式頁面
class QuickAnalysisScreen extends StatefulWidget {
  const QuickAnalysisScreen({super.key});

  @override
  State<QuickAnalysisScreen> createState() => _QuickAnalysisScreenState();
}

class _QuickAnalysisScreenState extends State<QuickAnalysisScreen> {
  dynamic _currentResult;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('快速分析模式'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => _exitQuickMode(context),
        ),
      ),
      body: Consumer<InspectionProvider>(
        builder: (context, inspection, child) {
          if (inspection.isAnalyzing) {
            return const LoadingWidget(message: '正在分析照片...');
          }

          if (_currentResult != null) {
            return _buildResultView(context, inspection);
          }

          return _buildUploadView(context, inspection);
        },
      ),
    );
  }

  Widget _buildUploadView(BuildContext context, InspectionProvider inspection) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.flash_on,
              size: 100,
              color: AppColors.info.withOpacity(0.5),
            ),
            const SizedBox(height: AppSpacing.lg),
            const Text(
              '快速分析模式',
              style: AppTextStyles.heading1,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              '無需預先建立檢查清單\n直接對單張照片進行即時分析',
              style: AppTextStyles.body2.copyWith(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xl),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _pickImage(ImageSource.camera, inspection),
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('立即拍攝'),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(0, 56),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _pickImage(ImageSource.gallery, inspection),
                    icon: const Icon(Icons.photo_library),
                    label: const Text('從檔案上傳'),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(0, 56),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultView(BuildContext context, InspectionProvider inspection) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('分析結果', style: AppTextStyles.heading2),
          const SizedBox(height: AppSpacing.md),

          // 基本資訊卡片
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildInfoRow('設備類型', _currentResult.equipmentType ?? '未識別'),
                  _buildInfoRow('狀況評估', _currentResult.conditionAssessment ?? '無'),
                  _buildInfoRow(
                    '是否異常',
                    _currentResult.isAnomaly == true ? '是' : '否',
                    valueColor: _currentResult.isAnomaly == true
                        ? AppColors.error
                        : AppColors.success,
                  ),
                  if (_currentResult.anomalyDescription != null)
                    _buildInfoRow('異常描述', _currentResult.anomalyDescription!),
                  if (_currentResult.aiEstimatedSize != null)
                    _buildInfoRow('估算尺寸', _currentResult.aiEstimatedSize!),
                ],
              ),
            ),
          ),

          // 數值資料卡片
          if (_currentResult.readings != null && _currentResult.readings!.isNotEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: AppSpacing.md),
                const Text('檢測數值', style: AppTextStyles.heading3),
                const SizedBox(height: AppSpacing.sm),
                Card(
                  color: Colors.blue[50],
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _currentResult.readings!.entries.map((entry) {
                        final reading = entry.value as Map<String, dynamic>;
                        final value = reading['value'];
                        final unit = reading['unit'] ?? '';
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                entry.key,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w500,
                                  fontSize: 14,
                                ),
                              ),
                              Text(
                                '$value $unit',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.blue[900],
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ],
            ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: () async {
                    await inspection.saveQuickAnalysisResult(_currentResult);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已儲存至檢測記錄')),
                      );
                    }
                    setState(() => _currentResult = null);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.success,
                  ),
                  child: const Text('儲存此記錄'),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: ElevatedButton(
                  onPressed: () {
                    setState(() => _currentResult = null);
                  },
                  child: const Text('分析另一張照片'),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          TextButton(
            onPressed: () => _exitQuickMode(context),
            child: const Text('返回主流程'),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: Text(value, style: TextStyle(color: valueColor)),
          ),
        ],
      ),
    );
  }

  Future<void> _pickImage(ImageSource source, InspectionProvider inspection) async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(
      source: source,
      maxWidth: 1920,
      maxHeight: 1080,
      imageQuality: 85,
    );

    if (image != null) {
      final result = await inspection.quickAnalyzeFromXFile(image);

      // 檢查是否有錯誤（例如試用次數已用完）
      if (inspection.errorMessage != null && mounted) {
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
        return;
      }

      if (result != null) {
        setState(() => _currentResult = result);
      }
    }
  }

  void _exitQuickMode(BuildContext context) {
    Navigator.pop(context);
  }
}
