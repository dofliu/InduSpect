import 'package:flutter/material.dart';
import '../services/user_defaults_service.dart';
import '../services/photo_service.dart';
import 'guided_capture_screen.dart';

/// 一站式定檢流程畫面
///
/// 6 步驟流程 (Step 0-5):
/// Step 0: 選擇設備 + 基本資訊（inspectorName, location 等，可從 UserDefaults 帶入）
/// Step 1: 上傳定檢表 + 結構分析
/// Step 2: 拍照 / 輸入量測值
/// Step 3: AI 自動判定 + 精準映射（呼叫 one-stop-process）
/// Step 4: 預覽回填結果，使用者可逐項確認或修改
/// Step 5: 執行回填 + 匯出 + 儲存歷史
class OneStopInspectionScreen extends StatefulWidget {
  const OneStopInspectionScreen({Key? key}) : super(key: key);

  @override
  State<OneStopInspectionScreen> createState() =>
      _OneStopInspectionScreenState();
}

class _OneStopInspectionScreenState extends State<OneStopInspectionScreen> {
  final UserDefaultsService _defaults = UserDefaultsService();
  final PageController _pageController = PageController();

  int _currentStep = 0;
  static const int _totalSteps = 6;

  // Step 0: 設備 + 基本資訊
  String _inspectorName = '';
  String _equipmentId = '';
  String _equipmentName = '';
  String _equipmentType = '';
  String _location = '';
  List<String> _recentEquipments = [];

  // Step 1: 上傳定檢表
  List<Map<String, dynamic>> _fieldMap = [];
  bool _isAnalyzing = false;

  // Step 2: 量測讀數
  List<Map<String, dynamic>> _readings = [];
  List<Map<String, dynamic>> _photoTaskBindings = [];

  // Step 3: AI 判定結果
  List<Map<String, dynamic>> _judgments = [];
  List<Map<String, dynamic>> _mappings = [];
  List<Map<String, dynamic>> _previousValues = [];
  List<String> _warnings = [];
  Map<String, dynamic> _summary = {};
  bool _isProcessing = false;


  // Step 5: 完成
  bool _isExporting = false;
  bool _isDone = false;

  @override
  void initState() {
    super.initState();
    _loadDefaults();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _loadDefaults() async {
    final defaults = await _defaults.loadDefaults();
    final recents = await _defaults.getRecentEquipments();
    setState(() {
      _inspectorName = defaults['inspectorName'] ?? '';
      _location = defaults['recentLocation'] ?? '';
      _recentEquipments = recents;
    });
  }

  void _goToStep(int step) {
    if (step < 0 || step >= _totalSteps) return;
    setState(() => _currentStep = step);
    _pageController.animateToPage(
      step,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _nextStep() => _goToStep(_currentStep + 1);
  void _prevStep() => _goToStep(_currentStep - 1);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('一站式定檢流程'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(
            value: (_currentStep + 1) / _totalSteps,
            backgroundColor: Colors.grey[300],
          ),
        ),
      ),
      body: Column(
        children: [
          // Step indicator
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: List.generate(_totalSteps, (i) {
                final labels = ['設備', '表單', '量測', '判定', '預覽', '完成'];
                final isActive = i == _currentStep;
                final isDone = i < _currentStep;
                return Column(
                  children: [
                    CircleAvatar(
                      radius: 14,
                      backgroundColor: isDone
                          ? Colors.green
                          : isActive
                              ? Theme.of(context).primaryColor
                              : Colors.grey[300],
                      child: isDone
                          ? const Icon(Icons.check, size: 16, color: Colors.white)
                          : Text(
                              '$i',
                              style: TextStyle(
                                fontSize: 12,
                                color: isActive ? Colors.white : Colors.grey[600],
                              ),
                            ),
                    ),
                    const SizedBox(height: 2),
                    Text(labels[i], style: const TextStyle(fontSize: 10)),
                  ],
                );
              }),
            ),
          ),
          const Divider(height: 1),
          // Page content
          Expanded(
            child: PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _buildStep0Equipment(),
                _buildStep1Upload(),
                _buildStep2Readings(),
                _buildStep3Judging(),
                _buildStep4Preview(),
                _buildStep5Done(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ==================== Step 0: 設備 + 基本資訊 ====================

  Widget _buildStep0Equipment() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Step 0: 選擇設備與基本資訊',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          TextField(
            decoration: const InputDecoration(
              labelText: '檢查人員',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.person),
            ),
            controller: TextEditingController(text: _inspectorName),
            onChanged: (v) => _inspectorName = v,
          ),
          const SizedBox(height: 12),
          TextField(
            decoration: const InputDecoration(
              labelText: '設備編號',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.qr_code),
            ),
            controller: TextEditingController(text: _equipmentId),
            onChanged: (v) => _equipmentId = v,
          ),
          const SizedBox(height: 12),
          TextField(
            decoration: const InputDecoration(
              labelText: '設備名稱',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.electrical_services),
            ),
            controller: TextEditingController(text: _equipmentName),
            onChanged: (v) => _equipmentName = v,
          ),
          const SizedBox(height: 12),
          TextField(
            decoration: const InputDecoration(
              labelText: '設備類型',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.category),
            ),
            controller: TextEditingController(text: _equipmentType),
            onChanged: (v) => _equipmentType = v,
          ),
          const SizedBox(height: 12),
          TextField(
            decoration: const InputDecoration(
              labelText: '位置/廠區',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.location_on),
            ),
            controller: TextEditingController(text: _location),
            onChanged: (v) => _location = v,
          ),
          if (_recentEquipments.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('最近使用的設備:', style: TextStyle(fontWeight: FontWeight.bold)),
            Wrap(
              spacing: 8,
              children: _recentEquipments.map((eq) {
                return ActionChip(
                  label: Text(eq),
                  onPressed: () {
                    setState(() => _equipmentId = eq);
                  },
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _equipmentId.isEmpty
                ? null
                : () async {
                    // 儲存 defaults
                    await _defaults.saveDefaults(
                      inspectorName: _inspectorName,
                      recentLocation: _location,
                    );
                    await _defaults.addRecentEquipment(_equipmentId);
                    _nextStep();
                  },
            icon: const Icon(Icons.arrow_forward),
            label: const Text('下一步: 上傳定檢表'),
          ),
        ],
      ),
    );
  }

  // ==================== Step 1: 上傳定檢表 ====================

  Widget _buildStep1Upload() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Step 1: 上傳定檢表',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          if (_isAnalyzing)
            const Center(child: CircularProgressIndicator())
          else if (_fieldMap.isNotEmpty)
            Card(
              child: ListTile(
                leading: const Icon(Icons.check_circle, color: Colors.green),
                title: Text('已分析 ${_fieldMap.length} 個欄位'),
                subtitle: const Text('表單結構分析完成'),
              ),
            )
          else
            ElevatedButton.icon(
              onPressed: () {
                // TODO: 實際整合 file_picker 上傳 + analyze-structure
                // 此處展示流程骨架
                setState(() => _isAnalyzing = true);
                Future.delayed(const Duration(seconds: 1), () {
                  setState(() {
                    _isAnalyzing = false;
                    _fieldMap = []; // 待實際 API 回填
                  });
                });
              },
              icon: const Icon(Icons.upload_file),
              label: const Text('選擇定檢表 (Excel/Word)'),
            ),
          const SizedBox(height: 24),
          Row(
            children: [
              TextButton(onPressed: _prevStep, child: const Text('上一步')),
              const Spacer(),
              ElevatedButton(
                onPressed: _nextStep,
                child: const Text('下一步: 量測輸入'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ==================== Step 2: 拍照 / 輸入量測值 ====================

  Widget _buildStep2Readings() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Step 2: 拍照 / 輸入量測值',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),

          // 引導式拍照入口
          Card(
            color: Colors.blue[50],
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.camera_enhance, color: Colors.blue),
                      const SizedBox(width: 8),
                      const Text('引導式拍照',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          )),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text('根據定檢表自動產生拍照任務，逐項引導拍攝。'),
                  const SizedBox(height: 12),
                  if (_photoTaskBindings.isNotEmpty)
                    Text(
                      '已拍攝 ${_photoTaskBindings.length} 張照片',
                      style: const TextStyle(
                        color: Colors.green,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed: _fieldMap.isNotEmpty
                        ? () => _launchGuidedCapture()
                        : null,
                    icon: const Icon(Icons.camera_alt),
                    label: Text(_photoTaskBindings.isNotEmpty
                        ? '繼續拍照 / 補拍'
                        : '開始引導式拍照'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                    ),
                  ),
                  if (_fieldMap.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text(
                        '請先在 Step 1 上傳並分析定檢表',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 手動量測值輸入
          const Text('手動量測值',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 8),
          if (_readings.isEmpty && _photoTaskBindings.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('尚無量測值，請拍照或手動輸入'),
              ),
            )
          else
            ...List.generate(_readings.length, (i) {
              final r = _readings[i];
              return Card(
                child: ListTile(
                  title: Text(r['field_name'] ?? ''),
                  subtitle: Text('${r['value']} ${r['unit'] ?? ''}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete),
                    onPressed: () {
                      setState(() => _readings.removeAt(i));
                    },
                  ),
                ),
              );
            }),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _showAddReadingDialog,
            icon: const Icon(Icons.add),
            label: const Text('新增量測值'),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              TextButton(onPressed: _prevStep, child: const Text('上一步')),
              const Spacer(),
              ElevatedButton(
                onPressed: (_readings.isNotEmpty || _photoTaskBindings.isNotEmpty)
                    ? _nextStep
                    : null,
                child: const Text('下一步: AI 判定'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 啟動引導式拍照畫面
  Future<void> _launchGuidedCapture() async {
    // 從 field_map 建構 photo_tasks（模擬 backend generate_photo_tasks）
    // 實際使用時應呼叫 _api.generatePhotoTasks(_fieldMap)
    final photoTasks = _fieldMap
        .where((f) =>
            f['field_type'] == 'number' ||
            f['field_type'] == 'photo' ||
            (f['current_value'] == null || f['current_value'].toString().isEmpty))
        .toList()
        .asMap()
        .entries
        .map((entry) => {
              'task_id': 'task_${entry.key}',
              'field_name': entry.value['field_name'] ?? '項目 ${entry.key + 1}',
              'display_name': entry.value['display_name'] ?? entry.value['field_name'] ?? '項目 ${entry.key + 1}',
              'photo_hint': entry.value['photo_hint'] ?? '請拍攝此檢查項目的照片',
              'sequence': entry.key + 1,
              'unit': entry.value['unit'] ?? '',
              'field_type': entry.value['field_type'] ?? 'text',
            })
        .toList();

    if (photoTasks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('沒有需要拍照的項目')),
      );
      return;
    }

    final result = await Navigator.push<List<PhotoBinding>>(
      context,
      MaterialPageRoute(
        builder: (_) => GuidedCaptureScreen(
          photoTasks: photoTasks,
          equipmentName: _equipmentName.isNotEmpty
              ? _equipmentName
              : _equipmentId,
          allowSkip: true,
        ),
      ),
    );

    if (result != null && result.isNotEmpty) {
      setState(() {
        // 將拍照結果轉為 photo_task_bindings 格式
        _photoTaskBindings = result.map((binding) => {
          'task_id': binding.taskId,
          'display_name': binding.displayName,
          'file_name': binding.fileName,
          'file_path': binding.filePath,
          'capture_time': binding.captureTime.toIso8601String(),
          'size_kb': binding.sizeKB,
        }).toList();
      });
    }
  }

  void _showAddReadingDialog() {
    String fieldName = '';
    String value = '';
    String unit = '';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增量測值'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              decoration: const InputDecoration(labelText: '項目名稱'),
              onChanged: (v) => fieldName = v,
            ),
            TextField(
              decoration: const InputDecoration(labelText: '量測值'),
              keyboardType: TextInputType.number,
              onChanged: (v) => value = v,
            ),
            TextField(
              decoration: const InputDecoration(labelText: '單位'),
              onChanged: (v) => unit = v,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              final numVal = double.tryParse(value);
              if (fieldName.isNotEmpty && numVal != null) {
                setState(() {
                  _readings.add({
                    'field_name': fieldName,
                    'value': numVal,
                    'unit': unit,
                  });
                });
              }
              Navigator.pop(ctx);
            },
            child: const Text('新增'),
          ),
        ],
      ),
    );
  }

  // ==================== Step 3: AI 自動判定 + 映射 ====================

  Widget _buildStep3Judging() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Step 3: AI 自動判定',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          if (_isProcessing)
            const Center(
              child: Column(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('AI 分析中...'),
                ],
              ),
            )
          else if (_judgments.isNotEmpty) ...[
            // 摘要卡片
            Card(
              color: _summary['fail_count'] == 0
                  ? Colors.green[50]
                  : Colors.red[50],
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '判定結果摘要',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(height: 8),
                    Text('合格: ${_summary['pass_count'] ?? 0}'),
                    Text('不合格: ${_summary['fail_count'] ?? 0}'),
                    Text('警告: ${_summary['warning_count'] ?? 0}'),
                    Text('未知: ${_summary['unknown_count'] ?? 0}'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            // 警告列表
            if (_warnings.isNotEmpty)
              ...List.generate(_warnings.length, (i) {
                return Card(
                  color: Colors.orange[50],
                  child: ListTile(
                    leading: const Icon(Icons.warning, color: Colors.orange),
                    title: Text(_warnings[i]),
                  ),
                );
              }),
            // 判定詳情
            ...List.generate(_judgments.length, (i) {
              final j = _judgments[i];
              final icon = j['judgment'] == 'pass'
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : j['judgment'] == 'fail'
                      ? const Icon(Icons.cancel, color: Colors.red)
                      : const Icon(Icons.help, color: Colors.grey);
              return Card(
                child: ListTile(
                  leading: icon,
                  title: Text(j['field_name'] ?? ''),
                  subtitle: Text(
                    '${j['measured_value']} ${j['unit'] ?? ''}'
                    '${j['standard_text'] != null && j['standard_text'].isNotEmpty ? " (標準: ${j['standard_text']})" : ""}',
                  ),
                ),
              );
            }),
          ] else
            ElevatedButton.icon(
              onPressed: () async {
                setState(() => _isProcessing = true);
                try {
                  // TODO: 呼叫 _api.oneStopProcess(...)
                  // 此處為流程骨架，待 API service 整合
                  await Future.delayed(const Duration(seconds: 1));
                } finally {
                  setState(() => _isProcessing = false);
                }
              },
              icon: const Icon(Icons.auto_awesome),
              label: const Text('開始 AI 判定'),
            ),
          const SizedBox(height: 24),
          Row(
            children: [
              TextButton(onPressed: _prevStep, child: const Text('上一步')),
              const Spacer(),
              ElevatedButton(
                onPressed: _judgments.isNotEmpty ? _nextStep : null,
                child: const Text('下一步: 預覽結果'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ==================== Step 4: 預覽回填結果 ====================

  Widget _buildStep4Preview() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Step 4: 預覽回填結果',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          if (_mappings.isNotEmpty)
            ...List.generate(_mappings.length, (i) {
              final m = _mappings[i];
              return Card(
                child: ListTile(
                  title: Text(m['field_id'] ?? ''),
                  subtitle: Text('值: ${m['suggested_value'] ?? ''}'),
                  trailing: Text(
                    '${((m['confidence'] ?? 0) * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              );
            })
          else
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('映射結果為空，請返回上一步重新分析'),
              ),
            ),
          // 前次數值對照
          if (_previousValues.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('前次數值對照:',
                style: TextStyle(fontWeight: FontWeight.bold)),
            ...List.generate(_previousValues.length, (i) {
              final pv = _previousValues[i];
              return ListTile(
                dense: true,
                title: Text(pv['field_name'] ?? ''),
                subtitle: Text('前次: ${pv['value']} ${pv['unit'] ?? ''} (${pv['date'] ?? ''})'),
              );
            }),
          ],
          const SizedBox(height: 24),
          Row(
            children: [
              TextButton(onPressed: _prevStep, child: const Text('上一步')),
              const Spacer(),
              ElevatedButton(
                onPressed: _nextStep,
                child: const Text('確認並匯出'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ==================== Step 5: 完成 ====================

  Widget _buildStep5Done() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (_isExporting)
            const CircularProgressIndicator()
          else if (_isDone) ...[
            const Icon(Icons.check_circle, color: Colors.green, size: 80),
            const SizedBox(height: 16),
            const Text('定檢完成!', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('報告已匯出，歷史記錄已儲存'),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('返回首頁'),
            ),
          ] else ...[
            const Text('Step 5: 執行回填與匯出',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () async {
                setState(() => _isExporting = true);
                try {
                  // TODO: 呼叫 execute auto-fill + save history
                  await Future.delayed(const Duration(seconds: 1));
                  setState(() => _isDone = true);
                } finally {
                  setState(() => _isExporting = false);
                }
              },
              icon: const Icon(Icons.download),
              label: const Text('執行回填並匯出'),
            ),
            const SizedBox(height: 12),
            TextButton(onPressed: _prevStep, child: const Text('返回修改')),
          ],
        ],
      ),
    );
  }
}
