import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state_provider.dart';
import '../providers/inspection_provider.dart';
import '../utils/constants.dart';

/// 步驟 3: 審核分析結果
class Step3ReviewResults extends StatelessWidget {
  const Step3ReviewResults({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer2<AppStateProvider, InspectionProvider>(
      builder: (context, appState, inspection, child) {
        final pendingCount = inspection.pendingReviewCount;

        if (inspection.analysisResults.isEmpty) {
          return _buildEmptyState(context, appState);
        }

        return Column(
          children: [
            // 頂部信息
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              color: AppColors.backgroundLight,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('待審核結果', style: AppTextStyles.heading3),
                        Text('$pendingCount 個項目', style: AppTextStyles.caption),
                      ],
                    ),
                  ),
                  if (pendingCount > 0)
                    ElevatedButton(
                      onPressed: () => inspection.confirmAllResults(),
                      child: const Text('一鍵確認全部'),
                    ),
                ],
              ),
            ),
            // 結果列表
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(AppSpacing.md),
                itemCount: inspection.analysisResults.length,
                itemBuilder: (context, index) {
                  final entry = inspection.analysisResults.entries.elementAt(index);
                  final itemId = entry.key;
                  final result = entry.value;
                  final item = inspection.inspectionItems
                      .firstWhere((item) => item.id == itemId);

                  return _ResultCard(
                    item: item,
                    result: result,
                    onConfirm: () => inspection.confirmAnalysisResult(itemId),
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
              child: ElevatedButton(
                onPressed: () => appState.nextStep(),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                ),
                child: const Text('查看檢測記錄'),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context, AppStateProvider appState) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.check_circle_outline,
              size: 100,
              color: AppColors.success.withOpacity(0.5),
            ),
            const SizedBox(height: AppSpacing.lg),
            const Text(
              '所有項目已審核完成',
              style: AppTextStyles.heading2,
            ),
            const SizedBox(height: AppSpacing.md),
            const Text(
              '所有分析結果已確認並移至檢測記錄',
              style: AppTextStyles.body2,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xl),
            ElevatedButton(
              onPressed: () => appState.nextStep(),
              child: const Text('查看檢測記錄'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final dynamic item;
  final dynamic result;
  final VoidCallback onConfirm;

  const _ResultCard({
    required this.item,
    required this.result,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 項目描述
            Text(
              item.description,
              style: AppTextStyles.heading3,
            ),
            const Divider(),
            // 設備類型
            _buildInfoRow('設備類型', result.equipmentType ?? '未識別'),
            // 狀況評估
            _buildInfoRow('狀況評估', result.conditionAssessment ?? '無'),
            // 異常狀態
            _buildInfoRow(
              '是否異常',
              result.isAnomaly == true ? '是' : '否',
              valueColor: result.isAnomaly == true ? AppColors.error : AppColors.success,
            ),
            if (result.anomalyDescription != null)
              _buildInfoRow('異常描述', result.anomalyDescription!),
            // 確認按鈕
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: onConfirm,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.success,
                ),
                child: const Text('確認記錄'),
              ),
            ),
          ],
        ),
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
              style: AppTextStyles.body2.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: AppTextStyles.body2.copyWith(color: valueColor),
            ),
          ),
        ],
      ),
    );
  }
}
