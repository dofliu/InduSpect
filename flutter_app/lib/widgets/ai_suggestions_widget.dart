import 'package:flutter/material.dart';
import '../models/rag_models.dart';
import '../services/backend_api_service.dart';
import '../utils/constants.dart';

/// AI 建議元件
/// 顯示 RAG 查詢結果和維修建議
class AiSuggestionsWidget extends StatefulWidget {
  final String equipmentType;
  final String anomalyDescription;
  final String? conditionAssessment;
  final VoidCallback? onAddToKnowledge;

  const AiSuggestionsWidget({
    super.key,
    required this.equipmentType,
    required this.anomalyDescription,
    this.conditionAssessment,
    this.onAddToKnowledge,
  });

  @override
  State<AiSuggestionsWidget> createState() => _AiSuggestionsWidgetState();
}

class _AiSuggestionsWidgetState extends State<AiSuggestionsWidget> {
  final BackendApiService _apiService = BackendApiService();
  RagQueryResponse? _response;
  bool _isLoading = true;
  bool _addedToKnowledge = false;

  @override
  void initState() {
    super.initState();
    _fetchSuggestions();
  }

  Future<void> _fetchSuggestions() async {
    setState(() => _isLoading = true);

    final response = await _apiService.querySimilarCases(
      equipmentType: widget.equipmentType,
      anomalyDescription: widget.anomalyDescription,
      conditionAssessment: widget.conditionAssessment,
    );

    if (mounted) {
      setState(() {
        _response = response;
        _isLoading = false;
      });
    }
  }

  Future<void> _addToKnowledgeBase() async {
    final content = '''
設備類型: ${widget.equipmentType}
異常描述: ${widget.anomalyDescription}
狀況評估: ${widget.conditionAssessment ?? '無'}
''';

    final success = await _apiService.addToKnowledgeBase(
      content: content,
      equipmentType: widget.equipmentType,
      sourceType: 'inspection',
    );

    if (success && mounted) {
      setState(() => _addedToKnowledge = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已加入知識庫'),
          backgroundColor: Colors.green,
        ),
      );
      widget.onAddToKnowledge?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.md),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.purple[50]!, Colors.blue[50]!],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.purple[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 標題列
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.purple[100]!.withAlpha(128),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
            ),
            child: Row(
              children: [
                Icon(Icons.auto_awesome, color: Colors.purple[700], size: 20),
                const SizedBox(width: 8),
                Text(
                  'AI 智能建議',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.purple[900],
                    fontSize: 14,
                  ),
                ),
                const Spacer(),
                if (_isLoading)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),

          // 內容區
          Padding(
            padding: const EdgeInsets.all(12),
            child: _isLoading
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('正在查詢相似案例...'),
                    ),
                  )
                : _buildContent(),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_response == null || _response!.error == 'offline') {
      return const Text(
        '⚠️ 離線中，無法查詢 AI 建議',
        style: TextStyle(color: Colors.orange),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 相似案例
        if (_response!.hasResults) ...[
          Text(
            '找到 ${_response!.results.length} 個相似案例',
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 8),
          ..._response!.results.take(3).map((r) => _buildCaseCard(r)),
        ],

        // 維修建議
        if (_response!.hasSuggestions) ...[
          const SizedBox(height: 12),
          const Text(
            '💡 維修建議',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          ..._response!.suggestions.map((s) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('• ', style: TextStyle(fontSize: 16)),
                Expanded(child: Text(s)),
              ],
            ),
          )),
        ],

        // 加入知識庫按鈕
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _addedToKnowledge ? null : _addToKnowledgeBase,
            icon: Icon(
              _addedToKnowledge ? Icons.check : Icons.add_circle_outline,
            ),
            label: Text(_addedToKnowledge ? '已加入知識庫' : '加入知識庫'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _addedToKnowledge ? Colors.green : Colors.purple,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCaseCard(RagResult result) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.blue[100],
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${(result.similarity * 100).toStringAsFixed(0)}% 相似',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.blue[900],
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                result.equipmentType,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.grey,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            result.content,
            style: const TextStyle(fontSize: 13),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
