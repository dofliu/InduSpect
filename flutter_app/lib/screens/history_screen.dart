import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/inspection_provider.dart';
import '../widgets/common/cross_platform_image.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final inspection = Provider.of<InspectionProvider>(context);
    final records = inspection.inspectionRecords;

    return Scaffold(
      appBar: AppBar(
        title: const Text('檢測歷史'),
        actions: [
          if (records.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _showClearConfirmDialog(context, inspection),
            ),
        ],
      ),
      body: records.isEmpty
          ? _buildEmptyState()
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: records.length,
              itemBuilder: (context, index) {
                final record = records[index];
                return _buildRecordCard(context, record, records.length - index);
              },
            ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.history, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            '尚無檢測記錄',
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '開始您的第一次設備檢測',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[500],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordCard(BuildContext context, InspectionRecord record, int number) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: Colors.blue[100],
          child: Text(
            '$number',
            style: const TextStyle(
              color: Colors.blue,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        title: Text(
          '檢測記錄 $number',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          '${record.checklistItems.length} 個檢測項目',
          style: const TextStyle(fontSize: 12),
        ),
        children: [
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 檢查清單照片
                if (record.checklistImagePath != null) ...[
                  Text(
                    '檢查清單',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CrossPlatformImage(
                      imagePath: record.checklistImagePath!,
                      width: double.infinity,
                      height: 200,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // 檢測項目列表
                Text(
                  '檢測項目',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                ...record.checklistItems.map((item) => _buildItemCard(context, item)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItemCard(BuildContext context, ChecklistItem item) {
    final hasPhoto = item.photoPath != null;
    final hasResult = item.result != null;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 項目標題和狀態
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.description,
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 15,
                    ),
                  ),
                ),
                if (hasPhoto)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.green[100],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle, size: 14, color: Colors.green[700]),
                        const SizedBox(width: 4),
                        Text(
                          '已拍照',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.green[700],
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),

            // 照片
            if (hasPhoto) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CrossPlatformImage(
                  imagePath: item.photoPath!,
                  width: double.infinity,
                  height: 150,
                  fit: BoxFit.cover,
                ),
              ),
            ],

            // AI 分析結果
            if (hasResult) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue[200]!),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.auto_awesome, size: 16, color: Colors.blue[700]),
                        const SizedBox(width: 6),
                        Text(
                          'AI 分析結果',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.blue[900],
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _buildResultRow(
                      '設備類型',
                      item.result!.equipmentType ?? '未知',
                      Icons.category,
                    ),
                    if (item.result!.conditionAssessment != null) ...[
                      const SizedBox(height: 8),
                      _buildResultRow(
                        '狀況評估',
                        item.result!.conditionAssessment!,
                        Icons.assessment,
                      ),
                    ],
                    if (item.result!.anomalyDescription != null) ...[
                      const SizedBox(height: 8),
                      _buildResultRow(
                        '異常描述',
                        item.result!.anomalyDescription!,
                        Icons.warning_amber,
                      ),
                    ],
                    if (item.result!.dimensions != null) ...[
                      const SizedBox(height: 8),
                      _buildResultRow(
                        '測量尺寸',
                        '${item.result!.dimensions!.objectName}: ${item.result!.dimensions!.value} ${item.result!.dimensions!.unit}',
                        Icons.straighten,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildResultRow(String label, String value, IconData icon) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: Colors.blue[700]),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey[700],
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey[900],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _showClearConfirmDialog(BuildContext context, InspectionProvider inspection) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除所有記錄'),
        content: const Text('確定要刪除所有檢測記錄嗎？此操作無法復原。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              inspection.clearHistory();
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已清除所有記錄')),
              );
            },
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text('刪除'),
          ),
        ],
      ),
    );
  }
}
