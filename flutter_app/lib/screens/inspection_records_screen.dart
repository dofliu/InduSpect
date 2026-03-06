import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/inspection_provider.dart';
import '../models/inspection_record.dart';
import '../utils/constants.dart';

import 'package:intl/intl.dart';

class InspectionRecordsScreen extends StatelessWidget {
  const InspectionRecordsScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('歷史檢測記錄'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清除所有記錄',
            onPressed: () => _showClearAllDialog(context),
          ),
        ],
      ),
      body: Consumer<InspectionProvider>(
        builder: (context, inspection, child) {
          final records = inspection.inspectionRecords;

          if (records.isEmpty) {
            return _buildEmptyState();
          }

          // 按時間倒序排列
          final sortedRecords = List<InspectionRecord>.from(records)
            ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

          return ListView.builder(
            itemCount: sortedRecords.length,
            padding: const EdgeInsets.all(AppSpacing.md),
            itemBuilder: (context, index) {
              return _buildRecordCard(context, sortedRecords[index]);
            },
          );
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.history,
            size: 80,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            '暫無歷史記錄',
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '完成巡檢並確認後，記錄將顯示於此',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[500],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordCard(BuildContext context, InspectionRecord record) {
    final dateFormat = DateFormat('yyyy/MM/dd HH:mm');
    
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: record.isAnomaly ? AppColors.error : AppColors.success,
          child: Icon(
            record.isAnomaly ? Icons.warning_amber : Icons.check,
            color: Colors.white,
          ),
        ),
        title: Text(
          record.equipmentType,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(dateFormat.format(record.timestamp)),
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildInfoRow('檢查項目', record.itemDescription),
                const SizedBox(height: 8),
                _buildInfoRow('狀況評估', record.conditionAssessment),
                const SizedBox(height: 8),
                if (record.isAnomaly) ...[
                  _buildInfoRow('異常描述', record.anomalyDescription ?? '無詳細描述', 
                    valueColor: AppColors.error),
                  const SizedBox(height: 8),
                ],
                if (record.readings != null && record.readings!.isNotEmpty) ...[
                  const Text('儀表讀數:', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  ...record.readings!.entries.map((e) {
                     final val = e.value as Map<String, dynamic>;
                     return Padding(
                       padding: const EdgeInsets.only(left: 12, bottom: 2),
                       child: Text('${e.key}: ${val['value']} ${val['unit'] ?? ''}'),
                     );
                  }).toList(),
                  const SizedBox(height: 8),
                ],
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    icon: const Icon(Icons.delete, size: 16),
                    label: const Text('刪除此記錄'),
                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                    onPressed: () => _deleteRecord(context, record),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, {Color? valueColor}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.grey,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(color: valueColor),
          ),
        ),
      ],
    );
  }

  Future<void> _deleteRecord(BuildContext context, InspectionRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('刪除記錄'),
        content: const Text('確定要刪除這條記錄嗎？此操作無法復原。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('刪除'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await context.read<InspectionProvider>().deleteRecord(record.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('記錄已刪除')),
        );
      }
    }
  }

  Future<void> _showClearAllDialog(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除所有記錄'),
        content: const Text('確定要清空所有歷史記錄嗎？此操作無法復原。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('確認清除'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await context.read<InspectionProvider>().clearAllData();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('所有記錄已清除')),
        );
      }
    }
  }
}
