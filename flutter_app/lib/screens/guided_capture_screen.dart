import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../utils/constants.dart';
import '../services/photo_service.dart';
import '../services/image_quality_service.dart';
import '../widgets/image_quality_dialog.dart';
import '../widgets/common/cross_platform_image.dart';

/// 引導式拍照畫面
///
/// 接收來自 backend 的 photo_tasks（拍照任務清單），
/// 逐項引導使用者拍攝或從圖庫選取照片，
/// 並即時顯示進度、提示、已拍照片預覽。
///
/// 使用方式：
/// ```dart
/// Navigator.push(context, MaterialPageRoute(
///   builder: (_) => GuidedCaptureScreen(
///     photoTasks: taskList,    // 來自 generate_photo_tasks API
///     equipmentName: '離心泵 A-01',
///     onComplete: (bindings) { /* 拿到所有 PhotoBinding */ },
///   ),
/// ));
/// ```
class GuidedCaptureScreen extends StatefulWidget {
  /// 拍照任務清單（來自 backend generate_photo_tasks API）
  /// 每項包含: task_id, display_name, photo_hint, sequence, field_name 等
  final List<Map<String, dynamic>> photoTasks;

  /// 設備名稱，顯示在標題區
  final String equipmentName;

  /// 完成回調：回傳所有已綁定的 PhotoBinding 列表
  final void Function(List<PhotoBinding> bindings)? onComplete;

  /// 是否允許跳過某些拍照任務
  final bool allowSkip;

  const GuidedCaptureScreen({
    Key? key,
    required this.photoTasks,
    this.equipmentName = '',
    this.onComplete,
    this.allowSkip = true,
  }) : super(key: key);

  @override
  State<GuidedCaptureScreen> createState() => _GuidedCaptureScreenState();
}

class _GuidedCaptureScreenState extends State<GuidedCaptureScreen> {
  final PhotoService _photoService = PhotoService();
  final PageController _pageController = PageController();
  final ImagePicker _picker = ImagePicker();

  /// 每個任務的完成狀態 (task_id → PhotoBinding?)
  final Map<String, PhotoBinding?> _taskBindings = {};

  /// 每個任務的跳過狀態
  final Set<String> _skippedTasks = {};

  /// 當前聚焦的任務索引
  int _currentIndex = 0;

  /// 是否正在處理照片
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    // 初始化所有任務為未完成
    for (final task in widget.photoTasks) {
      _taskBindings[task['task_id'] ?? ''] = null;
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  // ============ 統計 ============

  int get _completedCount =>
      _taskBindings.values.where((b) => b != null).length;

  int get _skippedCount => _skippedTasks.length;

  int get _totalCount => widget.photoTasks.length;

  int get _remainingCount =>
      _totalCount - _completedCount - _skippedCount;

  bool get _allDone => _remainingCount <= 0;

  double get _progress =>
      _totalCount > 0 ? (_completedCount + _skippedCount) / _totalCount : 0;

  // ============ 頁面導航 ============

  void _goToTask(int index) {
    if (index < 0 || index >= _totalCount) return;
    setState(() => _currentIndex = index);
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _nextTask() {
    if (_currentIndex < _totalCount - 1) {
      _goToTask(_currentIndex + 1);
    }
  }

  void _prevTask() {
    if (_currentIndex > 0) {
      _goToTask(_currentIndex - 1);
    }
  }

  /// 自動跳到下一個未完成的任務
  void _goToNextIncomplete() {
    for (int i = _currentIndex + 1; i < _totalCount; i++) {
      final taskId = widget.photoTasks[i]['task_id'] ?? '';
      if (_taskBindings[taskId] == null && !_skippedTasks.contains(taskId)) {
        _goToTask(i);
        return;
      }
    }
    // 往前找
    for (int i = 0; i < _currentIndex; i++) {
      final taskId = widget.photoTasks[i]['task_id'] ?? '';
      if (_taskBindings[taskId] == null && !_skippedTasks.contains(taskId)) {
        _goToTask(i);
        return;
      }
    }
    // 全部完成，停在當前頁
  }

  // ============ 拍照/選圖 ============

  Future<void> _capturePhoto(Map<String, dynamic> task) async {
    final source = await _showImageSourceDialog();
    if (source == null) return;

    final XFile? image = await _picker.pickImage(
      source: source,
      maxWidth: 1920,
      maxHeight: 1080,
      imageQuality: 85,
    );

    if (image == null) return;

    final Uint8List bytes;
    try {
      bytes = await image.readAsBytes();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('照片讀取失敗: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
      return;
    }

    // 品質閘門：現場光線不足/手震/錶面反光時先擋下，避免 AI 讀出錯誤數值
    // 後仍被當成正常讀值送去法規判定（純本機運算，離線同樣有效）
    final quality = await ImageQualityService.assess(bytes);
    if (!quality.isAcceptable && mounted) {
      final retake = await showImageQualityWarning(context, quality);
      if (retake) return _capturePhoto(task);
    }

    setState(() => _isProcessing = true);

    try {
      final taskId = task['task_id'] ?? '';
      final displayName = task['display_name'] ?? task['field_name'] ?? '';
      final sequence = task['sequence'] ?? (_currentIndex + 1);

      // 透過 PhotoService 綁定（含壓縮、存檔）
      final binding = await _photoService.bindPhotoToTask(
        taskId: taskId,
        displayName: displayName,
        sequence: sequence is int ? sequence : int.tryParse('$sequence') ?? 1,
        photoBytes: bytes,
      );

      setState(() {
        _taskBindings[taskId] = binding;
        _skippedTasks.remove(taskId); // 如果之前跳過，拍照後取消跳過
      });

      // 自動跳到下一個未完成項目
      if (!_allDone) {
        await Future.delayed(const Duration(milliseconds: 500));
        _goToNextIncomplete();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('照片處理失敗: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _skipTask(String taskId) {
    setState(() {
      _skippedTasks.add(taskId);
    });
    if (!_allDone) {
      _goToNextIncomplete();
    }
  }

  void _undoSkip(String taskId) {
    setState(() {
      _skippedTasks.remove(taskId);
    });
  }

  Future<void> _completeAndReturn() async {
    final allBindings = _taskBindings.values
        .where((b) => b != null)
        .cast<PhotoBinding>()
        .toList();

    widget.onComplete?.call(allBindings);

    if (mounted) {
      Navigator.of(context).pop(allBindings);
    }
  }

  // ============ UI ============

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.equipmentName.isNotEmpty
              ? widget.equipmentName
              : '引導式拍照',
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(
            value: _progress,
            backgroundColor: Colors.grey[300],
            valueColor: const AlwaysStoppedAnimation<Color>(AppColors.success),
          ),
        ),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: AppSpacing.md),
              child: Text(
                '$_completedCount / $_totalCount',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // 任務導航指示器
          _buildTaskIndicator(),
          const Divider(height: 1),
          // 主要內容：任務卡片
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              onPageChanged: (index) {
                setState(() => _currentIndex = index);
              },
              itemCount: _totalCount,
              itemBuilder: (context, index) {
                return _buildTaskPage(widget.photoTasks[index], index);
              },
            ),
          ),
          // 底部控制列
          _buildBottomBar(),
        ],
      ),
    );
  }

  /// 任務導航指示圓點
  Widget _buildTaskIndicator() {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        itemCount: _totalCount,
        itemBuilder: (context, index) {
          final task = widget.photoTasks[index];
          final taskId = task['task_id'] ?? '';
          final isCompleted = _taskBindings[taskId] != null;
          final isSkipped = _skippedTasks.contains(taskId);
          final isCurrent = index == _currentIndex;

          return GestureDetector(
            onTap: () => _goToTask(index),
            child: Container(
              width: 40,
              height: 40,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isCompleted
                    ? AppColors.success
                    : isSkipped
                        ? Colors.grey[400]
                        : isCurrent
                            ? AppColors.primary
                            : Colors.grey[200],
                border: isCurrent
                    ? Border.all(color: AppColors.primary, width: 2.5)
                    : null,
              ),
              child: Center(
                child: isCompleted
                    ? const Icon(Icons.check, color: Colors.white, size: 18)
                    : isSkipped
                        ? const Icon(Icons.skip_next, color: Colors.white, size: 16)
                        : Text(
                            '${index + 1}',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: isCurrent ? Colors.white : Colors.grey[600],
                            ),
                          ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 單一任務頁面
  Widget _buildTaskPage(Map<String, dynamic> task, int index) {
    final taskId = task['task_id'] ?? '';
    final binding = _taskBindings[taskId];
    final isSkipped = _skippedTasks.contains(taskId);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 任務標題 + 序號
          _buildTaskHeader(task, index),
          const SizedBox(height: AppSpacing.md),

          // 拍照提示卡片
          _buildHintCard(task),
          const SizedBox(height: AppSpacing.md),

          // 照片預覽 或 拍照按鈕
          if (binding != null)
            _buildPhotoPreview(task, binding)
          else if (isSkipped)
            _buildSkippedCard(taskId)
          else
            _buildCaptureArea(task),

          const SizedBox(height: AppSpacing.md),
        ],
      ),
    );
  }

  /// 任務標題區
  Widget _buildTaskHeader(Map<String, dynamic> task, int index) {
    final displayName = task['display_name'] ?? task['field_name'] ?? '拍照任務';
    final fieldName = task['field_name'] ?? '';

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: AppColors.primary.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '${index + 1} / $_totalCount',
            style: const TextStyle(
              color: AppColors.primary,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                displayName,
                style: AppTextStyles.heading3,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (fieldName.isNotEmpty && fieldName != displayName)
                Text(
                  fieldName,
                  style: AppTextStyles.caption,
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 拍照提示卡片
  Widget _buildHintCard(Map<String, dynamic> task) {
    final hint = task['photo_hint'] ?? '';
    final unit = task['unit'] ?? '';
    final fieldType = task['field_type'] ?? '';

    if (hint.isEmpty && unit.isEmpty) return const SizedBox.shrink();

    return Card(
      color: Colors.blue[50],
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.blue[200]!),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lightbulb_outline, color: Colors.blue[700], size: 20),
                const SizedBox(width: AppSpacing.xs),
                Text(
                  '拍照提示',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.blue[700],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              hint,
              style: TextStyle(
                fontSize: 14,
                color: Colors.blue[900],
                height: 1.5,
              ),
            ),
            if (unit.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Row(
                children: [
                  Icon(Icons.straighten, size: 16, color: Colors.blue[600]),
                  const SizedBox(width: 4),
                  Text(
                    '單位: $unit',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.blue[600],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
            if (fieldType.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Row(
                children: [
                  Icon(Icons.category, size: 16, color: Colors.blue[600]),
                  const SizedBox(width: 4),
                  Text(
                    '類型: $fieldType',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.blue[600],
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 照片預覽（已拍攝）
  Widget _buildPhotoPreview(Map<String, dynamic> task, PhotoBinding binding) {
    return Column(
      children: [
        // 成功標記
        Container(
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            color: AppColors.success.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const Icon(Icons.check_circle, color: AppColors.success, size: 20),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '已拍攝',
                      style: TextStyle(
                        color: AppColors.success,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '${binding.fileName}  (${binding.sizeKB.toStringAsFixed(1)} KB)',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        // 照片圖片
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            constraints: const BoxConstraints(maxHeight: 280),
            width: double.infinity,
            child: binding.filePath.isNotEmpty
                ? CrossPlatformImage(
                    imagePath: binding.filePath,
                    height: 280,
                    width: double.infinity,
                    fit: BoxFit.contain,
                  )
                : Container(
                    height: 280,
                    color: Colors.grey[200],
                    child: const Center(
                      child: Icon(Icons.image, size: 48, color: Colors.grey),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        // 重拍按鈕
        OutlinedButton.icon(
          onPressed: _isProcessing ? null : () => _capturePhoto(task),
          icon: const Icon(Icons.camera_alt),
          label: const Text('重新拍攝'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.warning,
            side: const BorderSide(color: AppColors.warning),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
          ),
        ),
      ],
    );
  }

  /// 已跳過狀態
  Widget _buildSkippedCard(String taskId) {
    return Card(
      color: Colors.grey[100],
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          children: [
            const Icon(Icons.skip_next, size: 48, color: Colors.grey),
            const SizedBox(height: AppSpacing.sm),
            const Text('已跳過此項', style: TextStyle(color: Colors.grey)),
            const SizedBox(height: AppSpacing.md),
            ElevatedButton.icon(
              onPressed: () => _undoSkip(taskId),
              icon: const Icon(Icons.undo),
              label: const Text('取消跳過'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.info,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 拍照區域（未拍攝）
  Widget _buildCaptureArea(Map<String, dynamic> task) {
    return Column(
      children: [
        // 大型拍照按鈕
        GestureDetector(
          onTap: _isProcessing ? null : () => _capturePhoto(task),
          child: Container(
            height: 220,
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppColors.primary.withOpacity(0.3),
                width: 2,
                strokeAlign: BorderSide.strokeAlignInside,
              ),
            ),
            child: _isProcessing
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: AppSpacing.md),
                        Text('處理中...'),
                      ],
                    ),
                  )
                : Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.primary.withOpacity(0.3),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.camera_alt,
                            color: Colors.white,
                            size: 36,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        const Text(
                          '點擊拍照或選擇圖片',
                          style: TextStyle(
                            fontSize: 16,
                            color: AppColors.primary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          '支援相機拍攝或從相簿選取',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey[500],
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
        // 跳過按鈕
        if (widget.allowSkip) ...[
          const SizedBox(height: AppSpacing.md),
          TextButton.icon(
            onPressed: () => _skipTask(task['task_id'] ?? ''),
            icon: const Icon(Icons.skip_next, size: 18),
            label: const Text('跳過此項'),
            style: TextButton.styleFrom(foregroundColor: Colors.grey),
          ),
        ],
      ],
    );
  }

  /// 底部控制列
  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: Row(
          children: [
            // 上一項
            IconButton(
              onPressed: _currentIndex > 0 ? _prevTask : null,
              icon: const Icon(Icons.arrow_back_ios),
              tooltip: '上一項',
            ),
            // 進度摘要
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _allDone
                        ? '全部完成!'
                        : '剩餘 $_remainingCount 項',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: _allDone ? AppColors.success : AppColors.primary,
                    ),
                  ),
                  if (_skippedCount > 0)
                    Text(
                      '$_skippedCount 項已跳過',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                ],
              ),
            ),
            // 下一項 或 完成按鈕
            if (_allDone)
              ElevatedButton.icon(
                onPressed: _completeAndReturn,
                icon: const Icon(Icons.check),
                label: const Text('完成'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.success,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: AppSpacing.sm,
                  ),
                ),
              )
            else
              IconButton(
                onPressed: _currentIndex < _totalCount - 1 ? _nextTask : null,
                icon: const Icon(Icons.arrow_forward_ios),
                tooltip: '下一項',
              ),
          ],
        ),
      ),
    );
  }

  // ============ 對話框 ============

  Future<ImageSource?> _showImageSourceDialog() async {
    return await showDialog<ImageSource>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('選擇照片來源'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.camera_alt, color: Colors.blue),
              ),
              title: const Text('拍攝照片'),
              subtitle: const Text('使用相機即時拍攝'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            const Divider(),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.green[50],
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.photo_library, color: Colors.green),
              ),
              title: const Text('從圖庫選擇'),
              subtitle: const Text('從手機相簿中選取'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
  }
}

/// 拍照任務摘要底部彈窗
///
/// 用於在拍照結束前顯示已完成 / 跳過 / 未完成的任務統計
class CaptureResultsSummary extends StatelessWidget {
  final List<Map<String, dynamic>> photoTasks;
  final Map<String, PhotoBinding?> taskBindings;
  final Set<String> skippedTasks;

  const CaptureResultsSummary({
    Key? key,
    required this.photoTasks,
    required this.taskBindings,
    required this.skippedTasks,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final completed = taskBindings.values.where((b) => b != null).length;
    final skipped = skippedTasks.length;
    final pending = photoTasks.length - completed - skipped;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '拍照任務摘要',
            style: AppTextStyles.heading3,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildStatChip(
                icon: Icons.check_circle,
                color: AppColors.success,
                label: '已完成',
                count: completed,
              ),
              _buildStatChip(
                icon: Icons.skip_next,
                color: Colors.grey,
                label: '已跳過',
                count: skipped,
              ),
              _buildStatChip(
                icon: Icons.pending,
                color: AppColors.warning,
                label: '未完成',
                count: pending,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          // 已完成任務列表
          if (completed > 0) ...[
            const Text('已拍攝:', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: AppSpacing.xs),
            ...photoTasks.where((t) {
              return taskBindings[t['task_id']] != null;
            }).map((t) {
              final binding = taskBindings[t['task_id']]!;
              return ListTile(
                dense: true,
                leading: const Icon(Icons.check_circle, color: AppColors.success, size: 20),
                title: Text(t['display_name'] ?? t['field_name'] ?? ''),
                subtitle: Text(binding.fileName),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildStatChip({
    required IconData icon,
    required Color color,
    required String label,
    required int count,
  }) {
    return Column(
      children: [
        Icon(icon, color: color, size: 32),
        const SizedBox(height: 4),
        Text(
          '$count',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}
