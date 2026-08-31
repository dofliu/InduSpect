import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import '../models/form_inspection_record.dart';
import '../services/database_service.dart';
import '../services/file_save_service.dart';

/// 統一歷史紀錄畫面
///
/// 從 SQLite 讀取所有表單檢測紀錄，
/// 支援搜尋、編輯標題、查看詳情、重新分享、刪除。
class UnifiedHistoryScreen extends StatefulWidget {
  const UnifiedHistoryScreen({super.key});

  @override
  State<UnifiedHistoryScreen> createState() => _UnifiedHistoryScreenState();
}

class _UnifiedHistoryScreenState extends State<UnifiedHistoryScreen> {
  final DatabaseService _dbService = DatabaseService();
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;

  List<FormInspectionRecord> _records = [];
  List<FormInspectionRecord> _filteredRecords = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRecords();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// Issue #16: 使用 SQL-side 搜尋，避免載入全部紀錄再在客戶端過濾
  Future<void> _loadRecords() async {
    setState(() => _isLoading = true);
    try {
      final query = _searchController.text.trim();
      if (query.isEmpty) {
        _records = await _dbService.getAllFormRecords();
      } else {
        _records = await _dbService.searchFormRecords(query);
      }
      _filteredRecords = List.from(_records);
    } catch (e) {
      debugPrint('載入紀錄失敗: $e');
    }
    if (mounted) setState(() => _isLoading = false);
  }

  /// Issue #16: 以 300ms debounce 避免每按一個鍵都查 DB
  void _applyFilter() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      _loadRecords();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('檢測紀錄'),
        actions: [
          if (_records.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: '清除所有紀錄',
              onPressed: _confirmClearAll,
            ),
        ],
      ),
      body: Column(
        children: [
          // 搜尋列
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜尋標題、檔名、地點...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _applyFilter());
                        },
                      )
                    : null,
              ),
              onChanged: (_) => setState(() => _applyFilter()),
            ),
          ),

          // 統計
          if (!_isLoading && _records.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text('共 ${_filteredRecords.length} 筆紀錄',
                      style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                  const Spacer(),
                  if (_searchController.text.isNotEmpty)
                    Text('(全部 ${_records.length} 筆)',
                        style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                ],
              ),
            ),

          const SizedBox(height: 4),

          // 紀錄列表
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredRecords.isEmpty
                    ? _buildEmptyState()
                    : RefreshIndicator(
                        onRefresh: _loadRecords,
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          itemCount: _filteredRecords.length,
                          itemBuilder: (context, index) =>
                              _buildRecordCard(_filteredRecords[index]),
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.inbox, size: 64, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(
            _searchController.text.isNotEmpty ? '找不到符合的紀錄' : '尚無檢測紀錄',
            style: TextStyle(fontSize: 16, color: Colors.grey[500]),
          ),
          const SizedBox(height: 8),
          Text(
            _searchController.text.isNotEmpty ? '請嘗試不同的關鍵字' : '開始您的第一次設備檢測',
            style: TextStyle(fontSize: 14, color: Colors.grey[400]),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordCard(FormInspectionRecord record) {
    final dateStr = DateFormat('yyyy/MM/dd HH:mm').format(record.createdAt);
    final statusInfo = _getStatusInfo(record.status);
    final anomalyCount = record.anomalyCount;

    return Dismissible(
      key: Key(record.recordId),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: Colors.red,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) => _confirmDelete(record),
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: anomalyCount > 0 ? Colors.red.withValues(alpha: 0.3) : Colors.grey[200]!,
          ),
        ),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          leading: CircleAvatar(
            backgroundColor: statusInfo.color.withValues(alpha: 0.15),
            child: Icon(statusInfo.icon, color: statusInfo.color, size: 22),
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(record.title,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              IconButton(
                icon: const Icon(Icons.edit, size: 16),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                tooltip: '編輯標題',
                onPressed: () => _editTitle(record),
              ),
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(dateStr, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
              const SizedBox(height: 4),
              Row(
                children: [
                  // 狀態
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: statusInfo.color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(statusInfo.label,
                        style: TextStyle(fontSize: 10, color: statusInfo.color, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 6),
                  // 異常
                  if (anomalyCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('異常 $anomalyCount',
                          style: const TextStyle(fontSize: 10, color: Colors.red, fontWeight: FontWeight.bold)),
                    ),
                  const SizedBox(width: 6),
                  // GPS
                  if (record.locationName != null && record.locationName!.isNotEmpty)
                    Expanded(
                      child: Row(
                        children: [
                          const Icon(Icons.location_on, size: 12, color: Colors.grey),
                          const SizedBox(width: 2),
                          Expanded(
                            child: Text(record.locationName!,
                                style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                    )
                  else if (record.latitude != null)
                    Row(
                      children: [
                        const Icon(Icons.location_on, size: 12, color: Colors.grey),
                        const SizedBox(width: 2),
                        Text(
                          '${record.latitude!.toStringAsFixed(4)}, ${record.longitude!.toStringAsFixed(4)}',
                          style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                        ),
                      ],
                    ),
                ],
              ),
            ],
          ),
          children: [
            // 詳情
            if (record.sourceFileName != null)
              _detailRow(Icons.insert_drive_file, '來源', record.sourceFileName!),
            _detailRow(Icons.checklist, '完成項目', '${record.completedCount} 項'),
            if (record.anomalyCount > 0)
              _detailRow(Icons.warning, '異常數', '${record.anomalyCount} 項', color: Colors.red),

            // 摘要報告預覽
            if (record.summaryReport != null && record.summaryReport!.isNotEmpty) ...[
              const Divider(),
              const Text('AI 總結報告', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.grey[50],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  record.summaryReport!.length > 300
                      ? '${record.summaryReport!.substring(0, 300)}...'
                      : record.summaryReport!,
                  style: const TextStyle(fontSize: 12, height: 1.5),
                ),
              ),
            ],

            // 操作按鈕
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (record.filledDocumentPath != null)
                  OutlinedButton.icon(
                    onPressed: () => _reshareFile(record),
                    icon: const Icon(Icons.share, size: 16),
                    label: const Text('重新分享', style: TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(IconData icon, String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color ?? Colors.grey[600]),
          const SizedBox(width: 8),
          Text('$label: ', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }

  // ========== 操作 ==========

  Future<void> _editTitle(FormInspectionRecord record) async {
    final controller = TextEditingController(text: record.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('編輯標題'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: '輸入新標題',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('儲存'),
          ),
        ],
      ),
    );

    if (newTitle != null && newTitle.isNotEmpty && newTitle != record.title) {
      await _dbService.updateFormRecordTitle(record.recordId, newTitle);
      await _loadRecords();
    }
  }

  Future<bool> _confirmDelete(FormInspectionRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('確認刪除'),
        content: Text('確定要刪除「${record.title}」嗎？此操作無法復原。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('刪除'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _dbService.deleteFormRecord(record.recordId);
      await _loadRecords();
      return true;
    }
    return false;
  }

  Future<void> _confirmClearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除所有紀錄'),
        content: const Text('確定要刪除所有檢測紀錄嗎？此操作無法復原。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('全部刪除'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _dbService.clearAllFormRecords();
      await _loadRecords();
    }
  }

  Future<void> _reshareFile(FormInspectionRecord record) async {
    if (record.filledDocumentPath == null) return;
    try {
      final file = File(record.filledDocumentPath!);
      if (await file.exists()) {
        await FileSaveService.saveAndShare(
          bytes: await file.readAsBytes(),
          fileName: p.basename(file.path),
        );
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('檔案已不存在'), backgroundColor: Colors.orange),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('分享失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  ({IconData icon, Color color, String label}) _getStatusInfo(FormRecordStatus status) {
    switch (status) {
      case FormRecordStatus.draft:
        return (icon: Icons.edit_note, color: Colors.orange, label: '草稿');
      case FormRecordStatus.completed:
        return (icon: Icons.check_circle, color: Colors.blue, label: '已完成');
      case FormRecordStatus.exported:
        return (icon: Icons.file_download_done, color: Colors.green, label: '已匯出');
      case FormRecordStatus.shared:
        return (icon: Icons.share, color: Colors.teal, label: '已分享');
    }
  }
}
