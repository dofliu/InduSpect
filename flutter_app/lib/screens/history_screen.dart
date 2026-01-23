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

  Widget _buildRecordCard(BuildContext context, dynamic record, int number) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 標題
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: Colors.blue[100],
                  child: Text(
                    '$number',
                    style: const TextStyle(
                      color: Colors.blue,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        record.itemDescription,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        record.equipmentType,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            // 照片
            if (record.photoPath != null) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CrossPlatformImage(
                  imagePath: record.photoPath!,
                  width: double.infinity,
                  height: 200,
                  fit: BoxFit.cover,
                ),
              ),
            ],

            // 分析結果
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: record.isAnomaly ? Colors.red[50] : Colors.green[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: record.isAnomaly ? Colors.red[200]! : Colors.green[200]!,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        record.isAnomaly ? Icons.warning_amber : Icons.check_circle,
                        size: 16,
                        color: record.isAnomaly ? Colors.red[700] : Colors.green[700],
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '狀況評估',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: record.isAnomaly ? Colors.red[900] : Colors.green[900],
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    record.conditionAssessment,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey[900],
                    ),
                  ),
                  if (record.isAnomaly && record.anomalyDescription != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      '異常描述：${record.anomalyDescription}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.red[800],
                      ),
                    ),
                  ],
                  if (record.measuredSize != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(Icons.straighten, size: 14, color: Colors.grey[700]),
                        const SizedBox(width: 4),
                        Text(
                          '測量尺寸：${record.measuredSize}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[700],
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),

            // 時間戳記
            const SizedBox(height: 8),
            Text(
              '檢測時間：${_formatDateTime(record.timestamp)}',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey[500],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDateTime(DateTime dateTime) {
    return '${dateTime.year}/${dateTime.month.toString().padLeft(2, '0')}/${dateTime.day.toString().padLeft(2, '0')} '
        '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
  }
}
