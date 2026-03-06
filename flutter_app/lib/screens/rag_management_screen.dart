import 'package:flutter/material.dart';
import '../services/backend_api_service.dart';

import 'package:file_picker/file_picker.dart';

class RagManagementScreen extends StatefulWidget {
  const RagManagementScreen({super.key});

  @override
  State<RagManagementScreen> createState() => _RagManagementScreenState();
}

class _RagManagementScreenState extends State<RagManagementScreen> {
  final BackendApiService _apiService = BackendApiService();
  List<Map<String, dynamic>> _items = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  Future<void> _loadItems() async {
    setState(() => _isLoading = true);
    final items = await _apiService.getAllItems();
    if (mounted) {
      setState(() {
        _items = items;
        _isLoading = false;
      });
    }
  }

  Future<void> _deleteItem(String id) async {
    final success = await _apiService.deleteItem(id);
    if (success) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
           const SnackBar(content: Text('刪除成功'), backgroundColor: Colors.green),
        );
        _loadItems();
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
           const SnackBar(content: Text('刪除失敗'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _pickAndUploadFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'txt', 'md', 'json'],
        withData: true, // 重要：確保 Web 端有數據
      );

      if (result != null) {
        final file = result.files.single;
        
        // 顯示上傳中提示
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
             SnackBar(
              content: Row(
                children: [
                   const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                   const SizedBox(width: 12),
                   Expanded(child: Text('正在上傳並透過 Gemini AI 分析 ${file.name}，這可能需要一點時間...')),
                ],
              ),
              duration: const Duration(seconds: 30), // 長一點的時間
             ),
          );
          
          setState(() => _isLoading = true);
        }

        final response = await _apiService.uploadDocument(file);
        
        if (mounted) {
           ScaffoldMessenger.of(context).hideCurrentSnackBar();
           if (response['success'] == true) {
              ScaffoldMessenger.of(context).showSnackBar(
                 SnackBar(content: Text('成功: ${response['message']}'), backgroundColor: Colors.green),
              );
           } else {
              ScaffoldMessenger.of(context).showSnackBar(
                 SnackBar(content: Text('失敗: ${response['error']}'), backgroundColor: Colors.red),
              );
           }
        }
      }
    } catch (e) {
       if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('發生錯誤: $e'), backgroundColor: Colors.red),
         );
       }
    } finally {
       _loadItems();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('知識庫管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.upload_file),
            tooltip: '上傳維修手冊',
            onPressed: _pickAndUploadFile,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadItems,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.inbox_outlined, size: 64, color: Colors.grey),
                      SizedBox(height: 16),
                      Text('目前沒有資料', style: TextStyle(color: Colors.grey)),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: _items.length,
                  itemBuilder: (context, index) {
                    final item = _items[index];
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.blue[100],
                          child: const Icon(Icons.article, color: Colors.blue),
                        ),
                        title: Text(
                          item['equipment_type'] ?? '未分類',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 4),
                            Text(
                              item['content'] ?? '',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: Colors.grey[700]),
                            ),
                            const SizedBox(height: 4),
                            Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                    color: Colors.grey[200],
                                    borderRadius: BorderRadius.circular(4)
                                ),
                                child: Text(
                                    item['source_type'] == 'inspection' ? '來自巡檢' : '手動匯入',
                                    style: TextStyle(fontSize: 10, color: Colors.grey[800])
                                )
                            )
                          ],
                        ),
                        isThreeLine: true,
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.grey),
                          onPressed: () => showDialog(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('確認刪除'),
                              content: const Text('確定要刪除這筆資料嗎？此動作無法復原。'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx),
                                  child: const Text('取消'),
                                ),
                                TextButton(
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    _deleteItem(item['id']);
                                  },
                                  child: const Text('刪除',
                                      style: TextStyle(color: Colors.red)),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
