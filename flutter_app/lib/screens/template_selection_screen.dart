import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/inspection_template.dart';
import '../models/template_inspection_record.dart';
import '../services/template_service.dart';
import '../services/database_service.dart';
import '../utils/constants.dart';
import 'template_filling_screen.dart';

/// 模板選擇畫面
class TemplateSelectionScreen extends StatefulWidget {
  const TemplateSelectionScreen({Key? key}) : super(key: key);

  @override
  State<TemplateSelectionScreen> createState() => _TemplateSelectionScreenState();
}

class _TemplateSelectionScreenState extends State<TemplateSelectionScreen> {
  final TemplateService _templateService = TemplateService();
  final DatabaseService _databaseService = DatabaseService();
  List<InspectionTemplate> _templates = [];
  Map<String, TemplateInspectionRecord> _latestRecords = {}; // templateId -> latest record
  bool _isLoading = true;
  String _searchQuery = '';
  String? _selectedCategory;

  @override
  void initState() {
    super.initState();
    _loadTemplates();
  }

  Future<void> _loadTemplates() async {
    setState(() => _isLoading = true);

    try {
      await _templateService.init();
      final templates = await _templateService.getAllTemplates();

      // Load latest record for each template
      final latestRecords = <String, TemplateInspectionRecord>{};
      for (final template in templates) {
        final record = await _databaseService.getLatestRecordByTemplate(template.templateId);
        if (record != null) {
          latestRecords[template.templateId] = record;
        }
      }

      if (mounted) {
        setState(() {
          _templates = templates;
          _latestRecords = latestRecords;
          _isLoading = false;
        });
      }
    } catch (e) {
      print('❌ Failed to load templates: $e');
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load templates: $e')),
        );
      }
    }
  }

  List<InspectionTemplate> get _filteredTemplates {
    var filtered = _templates;

    // 分類篩選
    if (_selectedCategory != null) {
      filtered = filtered.where((t) => t.category == _selectedCategory).toList();
    }

    // 搜尋篩選
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      filtered = filtered.where((t) {
        return t.templateName.toLowerCase().contains(query) ||
            t.category.toLowerCase().contains(query);
      }).toList();
    }

    return filtered;
  }

  Set<String> get _categories {
    return _templates.map((t) => t.category).toSet();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('選擇檢測模板'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadTemplates,
            tooltip: '重新載入',
          ),
        ],
      ),
      body: Column(
        children: [
          // 搜尋與篩選區
          _buildSearchAndFilter(),

          // 模板列表
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredTemplates.isEmpty
                    ? _buildEmptyState()
                    : _buildTemplateList(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showImportDialog,
        icon: const Icon(Icons.upload_file),
        label: const Text('匯入模板'),
      ),
    );
  }

  Widget _buildSearchAndFilter() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          // 搜尋框
          TextField(
            decoration: InputDecoration(
              hintText: '搜尋模板名稱或類別...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
            onChanged: (value) {
              setState(() => _searchQuery = value);
            },
          ),

          const SizedBox(height: 12),

          // 分類篩選
          if (_categories.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildCategoryChip('全部', null),
                  const SizedBox(width: 8),
                  ..._categories.map((category) {
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _buildCategoryChip(category, category),
                    );
                  }),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCategoryChip(String label, String? category) {
    final isSelected = _selectedCategory == category;

    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (selected) {
        setState(() {
          _selectedCategory = selected ? category : null;
        });
      },
      backgroundColor: Colors.grey[200],
      selectedColor: AppColors.primary.withOpacity(0.2),
      checkmarkColor: AppColors.primary,
    );
  }

  Widget _buildTemplateList() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _filteredTemplates.length,
      itemBuilder: (context, index) {
        final template = _filteredTemplates[index];
        return _buildTemplateCard(template);
      },
    );
  }

  Widget _buildTemplateCard(InspectionTemplate template) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: () => _startInspection(template),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 標題與類別
              Row(
                children: [
                  // 圖示
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.assignment,
                      color: AppColors.primary,
                      size: 24,
                    ),
                  ),

                  const SizedBox(width: 12),

                  // 名稱與類別
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          template.templateName,
                          style: AppTextStyles.heading3,
                        ),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.blue[50],
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            template.category,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.blue[700],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // 箭頭
                  const Icon(Icons.chevron_right, color: Colors.grey),
                ],
              ),

              const SizedBox(height: 16),

              // 統計資訊
              Row(
                children: [
                  _buildInfoChip(
                    Icons.list_alt,
                    '${template.sections.length} 個區段',
                    Colors.purple,
                  ),
                  const SizedBox(width: 12),
                  _buildInfoChip(
                    Icons.check_box,
                    '${template.getTotalFieldCount()} 個欄位',
                    Colors.green,
                  ),
                  const SizedBox(width: 12),
                  _buildInfoChip(
                    Icons.timer,
                    '約 ${template.metadata.estimatedDurationMinutes} 分鐘',
                    Colors.orange,
                  ),
                ],
              ),

              // 週期與說明
              if (template.metadata.safetyNotes != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red[50],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.warning, color: Colors.red, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          template.metadata.safetyNotes!,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.red,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoChip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: color,
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
          Icon(
            Icons.inbox,
            size: 80,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            _searchQuery.isNotEmpty ? '找不到符合的模板' : '尚無可用模板',
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '請點擊下方「匯入模板」按鈕',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[500],
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _showImportDialog,
            icon: const Icon(Icons.upload_file),
            label: const Text('匯入模板'),
          ),
        ],
      ),
    );
  }

  Future<void> _startInspection(InspectionTemplate template) async {
    // Check if there's a previous record for this template
    final previousRecord = _latestRecords[template.templateId];

    if (previousRecord != null) {
      // Ask if user wants to copy previous data
      final shouldCopy = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Found Previous Inspection'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Would you like to copy data from your previous inspection?'),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.access_time, size: 16, color: Colors.grey),
                        const SizedBox(width: 8),
                        Text(
                          _formatDateTime(previousRecord.updatedAt),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ],
                    ),
                    if (previousRecord.equipmentCode != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Equipment: ${previousRecord.equipmentCode}',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'This will copy all filled data as a starting point.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Start Fresh'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Copy Previous'),
            ),
          ],
        ),
      );

      if (!mounted) return;

      if (shouldCopy == true) {
        // Copy previous data but create a new record
        final copiedRecord = TemplateInspectionRecord(
          recordId: DateTime.now().millisecondsSinceEpoch.toString(),
          templateId: template.templateId,
          templateName: template.templateName,
          status: RecordStatus.draft,
          filledData: Map<String, dynamic>.from(previousRecord.filledData),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          equipmentCode: previousRecord.equipmentCode,
          equipmentName: previousRecord.equipmentName,
          customerName: previousRecord.customerName,
        );

        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => TemplateFillingScreen(
              template: template,
              existingRecord: copiedRecord,
            ),
          ),
        );
        return;
      }
    }

    // Start fresh inspection
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TemplateFillingScreen(template: template),
      ),
    );
  }

  String _formatDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes} minutes ago';
    } else if (difference.inDays < 1) {
      return '${difference.inHours} hours ago';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} days ago';
    } else {
      return '${dateTime.year}/${dateTime.month}/${dateTime.day}';
    }
  }

  void _showImportDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('匯入模板'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.file_upload, color: AppColors.primary),
              title: const Text('從檔案匯入'),
              subtitle: const Text('選擇 JSON 格式的模板檔案'),
              onTap: () {
                Navigator.pop(context);
                _importFromFile();
              },
            ),
            ListTile(
              leading: const Icon(Icons.code, color: Colors.green),
              title: const Text('從 JSON 文字匯入'),
              subtitle: const Text('貼上 JSON 模板內容'),
              onTap: () {
                Navigator.pop(context);
                _importFromText();
              },
            ),
            ListTile(
              leading: const Icon(Icons.qr_code_scanner, color: Colors.orange),
              title: const Text('掃描 QR Code'),
              subtitle: const Text('掃描模板分享的 QR Code'),
              onTap: () {
                Navigator.pop(context);
                _importFromQRCode();
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Future<void> _importFromFile() async {
    // TODO: 實作檔案選擇與匯入
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('檔案匯入功能開發中...')),
    );
  }

  Future<void> _importFromText() async {
    final controller = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('貼上 JSON 模板'),
        content: TextField(
          controller: controller,
          maxLines: 10,
          decoration: const InputDecoration(
            hintText: '請貼上 JSON 格式的模板內容...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('匯入'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      try {
        await _templateService.loadTemplateFromJson(result);
        await _loadTemplates();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('✅ 模板匯入成功！')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('❌ 匯入失敗：$e')),
          );
        }
      }
    }
  }

  Future<void> _importFromQRCode() async {
    // TODO: 實作 QR Code 掃描
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('QR Code 掃描功能開發中...')),
    );
  }
}
