import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../providers/inspection_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/app_state_provider.dart';
import '../models/form_inspection_record.dart';
import '../services/database_service.dart';
import 'blade_inspection_screen.dart';
import 'form_inspection_screen.dart';
import 'unified_history_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _isInitialized = false;
  // 快取 Future 避免每次 build 都重新查詢
  Future<List<FormInspectionRecord>>? _recentRecordsFuture;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    final appState = context.read<AppStateProvider>();
    final inspection = context.read<InspectionProvider>();
    final settings = context.read<SettingsProvider>();

    await Future.wait([
      appState.init(),
      inspection.init(),
      settings.init(),
    ]);

    if (mounted) {
      setState(() {
        _isInitialized = true;
        _recentRecordsFuture = DatabaseService().getAllFormRecords(limit: 3);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 顯示載入畫面直到初始化完成
    if (!_isInitialized) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                '正在初始化...',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ],
          ),
        ),
      );
    }

    final settings = Provider.of<SettingsProvider>(context);
    final inspection = Provider.of<InspectionProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('InduSpect AI'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.pushNamed(context, '/settings'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 歡迎卡片
            _buildWelcomeCard(context, settings),

            const SizedBox(height: 24),

            // 主要功能按鈕
            _buildMainActions(context),

            const SizedBox(height: 24),

            // 使用統計
            _buildUsageStats(context, settings, inspection),

            const SizedBox(height: 24),

            // 最近檢測記錄
            _buildRecentFormInspections(context),
          ],
        ),
      ),
    );
  }

  Widget _buildWelcomeCard(BuildContext context, SettingsProvider settings) {
    final hasApiKey = settings.hasValidApiKey;
    final usageInfo = settings.getUsageInfo();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.factory, size: 32, color: Colors.blue),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '工業設備智能檢測',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'AI 輔助設備巡檢與異常分析',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (!hasApiKey)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange[200]!),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.orange[700]),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '試用模式：剩餘 ${usageInfo['remaining']} 次',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.orange[900],
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '試用完畢後請設定您的 API Key',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.orange[700],
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pushNamed(context, '/settings'),
                      child: const Text('設定'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainActions(BuildContext context) {
    return Column(
      // stretch：卡片撐滿可用寬度。用 start 時卡片會依內容（副標題長度）縮成
      // 不同寬度，與下方「全寬突出」的設計不符；標題 Text 預設左對齊不受影響。
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '選擇檢測模式',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        // 主要功能：開始檢測（全寬突出）
        _buildActionCard(
          context,
          icon: Icons.auto_fix_high,
          title: '開始檢測',
          subtitle: '上傳定檢表 → 拍照 → AI 分析 → 自動回填',
          color: Colors.teal,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => const FormInspectionScreen(),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // 歷史紀錄
        _buildActionCard(
          context,
          icon: Icons.history,
          title: '歷史紀錄',
          subtitle: '查看過往檢測記錄',
          color: Colors.indigo,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => const UnifiedHistoryScreen(),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // 風機葉片檢測（獨立功能：資產驅動，不走定檢表單那條流程）
        _buildActionCard(
          context,
          icon: Icons.energy_savings_leaf,
          title: '風機葉片檢測',
          subtitle: '地面目視篩檢：引導拍攝 → 演算法量測 → 人工確認 → 報告',
          color: Colors.green,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => const BladeInspectionScreen(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildActionCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 32, color: color),
              ),
              const SizedBox(height: 12),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[600],
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUsageStats(
    BuildContext context,
    SettingsProvider settings,
    InspectionProvider inspection,
  ) {
    final usageInfo = settings.getUsageInfo();
    final selectedModel = settings.selectedModel;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '使用統計',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                TextButton.icon(
                  onPressed: () => Navigator.pushNamed(context, '/history'),
                  icon: const Icon(Icons.history, size: 18),
                  label: const Text('查看全部'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _buildStatItem(
                    context,
                    icon: Icons.analytics,
                    label: '已使用',
                    value: '${usageInfo['used']}',
                    color: Colors.blue,
                  ),
                ),
                Expanded(
                  child: _buildStatItem(
                    context,
                    icon: Icons.check_circle_outline,
                    label: '剩餘次數',
                    value: settings.hasValidApiKey
                        ? '無限'
                        : '${usageInfo['remaining']}',
                    color: Colors.green,
                  ),
                ),
                Expanded(
                  child: _buildStatItem(
                    context,
                    icon: Icons.memory,
                    label: 'AI 模型',
                    value: selectedModel.contains('pro') ? 'Pro' : 'Flash',
                    color: Colors.orange,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Column(
      children: [
        Icon(icon, color: color, size: 24),
        const SizedBox(height: 8),
        Text(
          value,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey[600],
          ),
        ),
      ],
    );
  }

  Widget _buildRecentFormInspections(BuildContext context) {
    return FutureBuilder<List<FormInspectionRecord>>(
      future: _recentRecordsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox.shrink();
        }

        final records = snapshot.data ?? [];

        if (records.isEmpty) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Column(
                  children: [
                    Icon(Icons.inbox, size: 48, color: Colors.grey[400]),
                    const SizedBox(height: 16),
                    Text('尚無檢測記錄',
                        style: TextStyle(fontSize: 16, color: Colors.grey[600])),
                    const SizedBox(height: 8),
                    Text('開始您的第一次設備檢測',
                        style: TextStyle(fontSize: 14, color: Colors.grey[500])),
                  ],
                ),
              ),
            ),
          );
        }

        return Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('最近檢測',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            )),
                    TextButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const UnifiedHistoryScreen()),
                      ),
                      child: const Text('查看更多'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: records.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final record = records[index];
                  final dateStr = DateFormat('MM/dd HH:mm').format(record.createdAt);
                  final hasAnomaly = record.anomalyCount > 0;

                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: hasAnomaly ? Colors.red[50] : Colors.blue[50],
                      child: Icon(
                        hasAnomaly ? Icons.warning : Icons.check_circle,
                        color: hasAnomaly ? Colors.red : Colors.blue,
                      ),
                    ),
                    title: Text(record.title,
                        style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    subtitle: Row(
                      children: [
                        Text(dateStr, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                        if (record.locationName != null) ...[
                          const SizedBox(width: 8),
                          const Icon(Icons.location_on, size: 12, color: Colors.grey),
                          Expanded(
                            child: Text(record.locationName!,
                                style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ],
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const UnifiedHistoryScreen()),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
