import 'package:flutter/material.dart';
import '../models/template_inspection_record.dart';
import '../services/database_service.dart';
import '../services/template_service.dart';
import '../models/inspection_template.dart';
import 'template_filling_screen.dart';

/// ¢,hkb
class InspectionRecordsScreen extends StatefulWidget {
  const InspectionRecordsScreen({Key? key}) : super(key: key);

  @override
  State<InspectionRecordsScreen> createState() => _InspectionRecordsScreenState();
}

class _InspectionRecordsScreenState extends State<InspectionRecordsScreen> {
  final DatabaseService _databaseService = DatabaseService();
  final TemplateService _templateService = TemplateService();
  List<TemplateInspectionRecord> _records = [];
  bool _isLoading = true;
  RecordStatus? _filterStatus;

  @override
  void initState() {
    super.initState();
    _loadRecords();
  }

  Future<void> _loadRecords() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final records = await _databaseService.getAllRecords(
        status: _filterStatus,
      );

      setState(() {
        _records = records;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('	e1W: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _continueEditing(TemplateInspectionRecord record) async {
    // 	e!
    final template = await _templateService.getTemplateById(record.templateId);

    if (template == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('~0É„!'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    if (mounted) {
      // *0këkb
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => TemplateFillingScreen(
            template: template,
            existingRecord: record,
          ),
        ),
      );

      // ÔÞŒÍ°	e
      _loadRecords();
    }
  }

  Future<void> _deleteRecord(TemplateInspectionRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('º*d'),
        content: Text('ºš*dd¢,Î\n\n${record.templateName}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Öˆ'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text('*d'),
          ),
        ],
      ),
    );

    if (confirmed == true && record.id != null) {
      try {
        await _databaseService.deleteRecord(record.id!);
        _loadRecords();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('ò*d')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('*d1W: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('¢,'),
        actions: [
          // éx	
          PopupMenuButton<RecordStatus?>(
            icon: const Icon(Icons.filter_list),
            tooltip: 'éx',
            onSelected: (status) {
              setState(() {
                _filterStatus = status;
              });
              _loadRecords();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: null,
                child: Text('hè'),
              ),
              const PopupMenuItem(
                value: RecordStatus.draft,
                child: Text('I?'),
              ),
              const PopupMenuItem(
                value: RecordStatus.completed,
                child: Text('òŒ'),
              ),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _records.isEmpty
              ? _buildEmptyState()
              : RefreshIndicator(
                  onRefresh: _loadRecords,
                  child: ListView.builder(
                    itemCount: _records.length,
                    itemBuilder: (context, index) {
                      return _buildRecordCard(_records[index]);
                    },
                  ),
                ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.assignment_outlined,
            size: 80,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            _filterStatus == null ? '„’	¢,' : '~0&ö„',
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '‹Ë°„¢,†úË',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[500],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordCard(TemplateInspectionRecord record) {
    final isCompleted = record.status == RecordStatus.completed;
    final isDraft = record.status == RecordStatus.draft;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: InkWell(
        onTap: () => _continueEditing(record),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // L
              Row(
                children: [
                  // ÀK:
                  Icon(
                    isCompleted ? Icons.check_circle : Icons.edit_note,
                    color: isCompleted ? Colors.green : Colors.orange,
                    size: 24,
                  ),
                  const SizedBox(width: 12),

                  // !1
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          record.templateName,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          isDraft ? 'I?' : 'òŒ',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDraft ? Colors.orange : Colors.green,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // *d	
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    color: Colors.grey,
                    onPressed: () => _deleteRecord(record),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // -™Ç

              if (record.equipmentCode != null || record.equipmentName != null) ...[
                Row(
                  children: [
                    const Icon(Icons.precision_manufacturing, size: 16, color: Colors.grey),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        [
                          if (record.equipmentCode != null) record.equipmentCode,
                          if (record.equipmentName != null) record.equipmentName,
                        ].join(' - '),
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[700],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],

              // B“Ç

              Row(
                children: [
                  const Icon(Icons.access_time, size: 16, color: Colors.grey),
                  const SizedBox(width: 8),
                  Text(
                    _formatDateTime(record.updatedAt),
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),

              // Õ\	
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _continueEditing(record),
                      icon: Icon(isDraft ? Icons.edit : Icons.visibility),
                      label: Text(isDraft ? '|Œè/' : 'åsÅ'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return '[[';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes} M';
    } else if (difference.inDays < 1) {
      return '${difference.inHours} BM';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} )M';
    } else {
      return '${dateTime.year}/${dateTime.month}/${dateTime.day}';
    }
  }
}
