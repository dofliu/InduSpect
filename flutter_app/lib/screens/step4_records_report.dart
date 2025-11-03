import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../providers/inspection_provider.dart';
import '../utils/constants.dart';
import '../widgets/common/loading_widget.dart';

/// 步驟 4: 查看記錄與生成報告
class Step4RecordsReport extends StatelessWidget {
  const Step4RecordsReport({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<InspectionProvider>(
      builder: (context, inspection, child) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 標題
              const Text('檢測記錄', style: AppTextStyles.heading2),
              const SizedBox(height: AppSpacing.md),

              // 記錄統計
              _buildStatistics(inspection),
              const SizedBox(height: AppSpacing.lg),

              // 記錄列表
              if (inspection.inspectionRecords.isEmpty)
                _buildEmptyState()
              else
                ...inspection.inspectionRecords.map((record) {
                  return _RecordCard(
                    record: record,
                    onDelete: () => inspection.deleteRecord(record.id),
                  );
                }),

              const SizedBox(height: AppSpacing.lg),
              const Divider(),

              // 報告生成部分
              const Text('巡檢總結報告', style: AppTextStyles.heading2),
              const SizedBox(height: AppSpacing.md),

              if (inspection.inspectionRecords.isEmpty)
                const Text('請先確認檢測記錄', style: AppTextStyles.body2)
              else ...[
                LoadingButton(
                  text: '產生總結報告',
                  onPressed: () => inspection.generateSummaryReport(),
                  isLoading: inspection.isAnalyzing,
                  backgroundColor: AppColors.primary,
                ),
                if (inspection.summaryReport != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  _ReportDisplay(report: inspection.summaryReport!),
                ],
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatistics(InspectionProvider inspection) {
    final totalCount = inspection.inspectionRecords.length;
    final anomalyCount = inspection.inspectionRecords
        .where((r) => r.isAnomaly)
        .length;
    final normalCount = totalCount - anomalyCount;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildStatItem('總計', totalCount, AppColors.info),
            _buildStatItem('正常', normalCount, AppColors.success),
            _buildStatItem('異常', anomalyCount, AppColors.error),
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem(String label, int count, Color color) {
    return Column(
      children: [
        Text(
          '$count',
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(label, style: AppTextStyles.caption),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Center(
          child: Column(
            children: [
              Icon(
                Icons.folder_open,
                size: 64,
                color: Colors.grey[400],
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                '尚無檢測記錄',
                style: AppTextStyles.body1.copyWith(color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecordCard extends StatelessWidget {
  final dynamic record;
  final VoidCallback onDelete;

  const _RecordCard({
    required this.record,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final dateStr = DateFormat('yyyy-MM-dd HH:mm').format(record.timestamp);

    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      child: ExpansionTile(
        leading: Icon(
          record.isAnomaly ? Icons.warning : Icons.check_circle,
          color: record.isAnomaly ? AppColors.error : AppColors.success,
        ),
        title: Text(record.itemDescription),
        subtitle: Text(dateStr, style: AppTextStyles.caption),
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildInfoRow('設備類型', record.equipmentType),
                _buildInfoRow('狀況評估', record.conditionAssessment),
                _buildInfoRow(
                  '異常狀態',
                  record.isAnomaly ? '異常' : '正常',
                  valueColor: record.isAnomaly ? AppColors.error : AppColors.success,
                ),
                if (record.anomalyDescription != null)
                  _buildInfoRow('異常描述', record.anomalyDescription!),
                if (record.measuredSize != null)
                  _buildInfoRow('測量尺寸', record.measuredSize!),
                const SizedBox(height: AppSpacing.sm),
                TextButton.icon(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete, color: AppColors.error),
                  label: const Text('刪除記錄', style: TextStyle(color: AppColors.error)),
                ),
              ],
            ),
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
}

class _ReportDisplay extends StatelessWidget {
  final String report;

  const _ReportDisplay({required this.report});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('報告內容', style: AppTextStyles.heading3),
                IconButton(
                  icon: const Icon(Icons.copy),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: report));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已複製到剪貼板')),
                    );
                  },
                  tooltip: '複製報告',
                ),
              ],
            ),
            const Divider(),
            SelectableText(
              report,
              style: AppTextStyles.body2,
            ),
          ],
        ),
      ),
    );
  }
}
