import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _apiKeyController = TextEditingController();
  bool _showApiKey = false;

  @override
  void initState() {
    super.initState();
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    _apiKeyController.text = settings.customApiKey ?? '';
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('設定'),
      ),
      body: ListView(
        children: [
          // API Key 設定區塊
          _buildSection(
            context,
            title: 'API Key 設定',
            children: [
              _buildApiKeyCard(context, settings),
            ],
          ),

          const Divider(),

          // 模型選擇區塊
          _buildSection(
            context,
            title: 'AI 模型選擇',
            children: [
              _buildModelSelectionCard(context, settings),
            ],
          ),

          const Divider(),

          // 使用說明和關於
          _buildSection(
            context,
            title: '說明與支援',
            children: [
              ListTile(
                leading: const Icon(Icons.help_outline),
                title: const Text('使用說明'),
                subtitle: const Text('如何使用 InduSpect AI'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pushNamed(context, '/guide'),
              ),
              ListTile(
                leading: const Icon(Icons.key),
                title: const Text('如何取得 API Key'),
                subtitle: const Text('申請 Google Gemini API Key'),
                trailing: const Icon(Icons.open_in_new),
                onTap: () => _showApiKeyGuide(context),
              ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('關於 InduSpect AI'),
                subtitle: const Text('版本 1.0.0'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showAboutDialog(context),
              ),
            ],
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildSection(
    BuildContext context, {
    required String title,
    required List<Widget> children,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: Colors.blue,
            ),
          ),
        ),
        ...children,
      ],
    );
  }

  Widget _buildApiKeyCard(BuildContext context, SettingsProvider settings) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  settings.hasValidApiKey ? Icons.check_circle : Icons.info_outline,
                  color: settings.hasValidApiKey ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        settings.hasValidApiKey ? '已設定 API Key' : '使用試用模式',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        settings.hasValidApiKey
                            ? '使用您的 API Key，無使用次數限制'
                            : '剩餘 ${settings.remainingTrials} 次免費試用',
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
            const SizedBox(height: 16),
            TextField(
              controller: _apiKeyController,
              obscureText: !_showApiKey,
              decoration: InputDecoration(
                labelText: 'Google Gemini API Key',
                hintText: '輸入您的 API Key',
                border: const OutlineInputBorder(),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(_showApiKey ? Icons.visibility_off : Icons.visibility),
                      onPressed: () {
                        setState(() {
                          _showApiKey = !_showApiKey;
                        });
                      },
                    ),
                    if (_apiKeyController.text.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _apiKeyController.clear();
                        },
                      ),
                  ],
                ),
              ),
              maxLines: 1,
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => _showApiKeyGuide(context),
                  child: const Text('如何取得 API Key？'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () => _saveApiKey(context, settings),
                  child: const Text('儲存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModelSelectionCard(BuildContext context, SettingsProvider settings) {
    final models = settings.getAvailableModels();

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '選擇 AI 模型',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '不同模型有不同的效能和費用',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 16),
            ...models.map((model) => _buildModelOption(context, settings, model)),
          ],
        ),
      ),
    );
  }

  Widget _buildModelOption(
    BuildContext context,
    SettingsProvider settings,
    Map<String, String> model,
  ) {
    final isSelected = settings.selectedModel == model['id'];

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        border: Border.all(
          color: isSelected ? Colors.blue : Colors.grey[300]!,
          width: isSelected ? 2 : 1,
        ),
        borderRadius: BorderRadius.circular(8),
        color: isSelected ? Colors.blue[50] : null,
      ),
      child: RadioListTile<String>(
        value: model['id']!,
        groupValue: settings.selectedModel,
        onChanged: (value) {
          if (value != null) {
            settings.setSelectedModel(value);
          }
        },
        title: Row(
          children: [
            Text(
              model['name']!,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: model['badge'] == '推薦'
                    ? Colors.green
                    : model['badge'] == '實驗版'
                    ? Colors.orange
                    : Colors.blue,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                model['badge']!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(model['description']!),
            const SizedBox(height: 4),
            Text(
              '費用：${model['cost']}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: model['cost'] == '較高'
                    ? Colors.red[700]
                    : model['cost'] == '較低'
                    ? Colors.green[700]
                    : Colors.orange[700],
              ),
            ),
          ],
        ),
        isThreeLine: true,
      ),
    );
  }

  Future<void> _saveApiKey(BuildContext context, SettingsProvider settings) async {
    final apiKey = _apiKeyController.text.trim();

    if (apiKey.isEmpty) {
      // 清除 API Key
      await settings.setApiKey(null);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已清除 API Key，將使用試用模式'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    // 簡單驗證 API Key 格式
    if (!apiKey.startsWith('AIza')) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('API Key 格式似乎不正確，請檢查'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    await settings.setApiKey(apiKey);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('API Key 已儲存！'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  void _showApiKeyGuide(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('如何取得 API Key'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '請依照以下步驟申請 Google Gemini API Key：',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              _buildStep('1', '前往 Google AI Studio', 'https://aistudio.google.com/'),
              _buildStep('2', '使用 Google 帳號登入', ''),
              _buildStep('3', '點擊 "Get API Key"', ''),
              _buildStep('4', '創建或選擇專案', ''),
              _buildStep('5', '複製 API Key', ''),
              _buildStep('6', '貼回此處並儲存', ''),
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
                        const Icon(Icons.info_outline, size: 18, color: Colors.blue),
                        const SizedBox(width: 8),
                        Text(
                          '費用說明',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.blue[900],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Gemini API 每月有免費額度，一般使用足夠。詳情請見 Google AI Studio 定價頁面。',
                      style: TextStyle(fontSize: 12, color: Colors.blue[800]),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(
                const ClipboardData(text: 'https://aistudio.google.com/'),
              );
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('網址已複製')),
              );
            },
            child: const Text('複製網址'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Widget _buildStep(String number, String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: const BoxDecoration(
              color: Colors.blue,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                number,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showAboutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 應用圖標
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(Icons.factory, color: Colors.white, size: 40),
                ),
                const SizedBox(height: 16),

                // 應用名稱和版本
                const Text(
                  'InduSpect AI',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  '版本 1.0.0 Build 1',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 20),

                // 應用說明
                const Text(
                  '工業設備智能檢測系統',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                const Text(
                  '結合 Google Gemini AI 技術，提供快速、準確的設備檢測與異常分析。',
                  style: TextStyle(fontSize: 14, height: 1.4),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),

                const Divider(),
                const SizedBox(height: 16),

                // 主要功能
                Align(
                  alignment: Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '主要功能：',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      const SizedBox(height: 8),
                      _buildFeatureItem('快速分析模式 - 單張照片即時檢測'),
                      _buildFeatureItem('詳細分析模式 - 依清單逐項檢測'),
                      _buildFeatureItem('AI 智能異常識別與評估'),
                      _buildFeatureItem('檢測記錄管理與報告生成'),
                      _buildFeatureItem('多模型支援（Flash / Pro）'),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // 技術支援
                Align(
                  alignment: Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        '技術支援：',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      SizedBox(height: 8),
                      Text(
                        '• Google Gemini 2.5 AI',
                        style: TextStyle(fontSize: 13),
                      ),
                      Text(
                        '• Flutter 跨平台框架',
                        style: TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),
                const Divider(),
                const SizedBox(height: 16),

                // 開發團隊資訊
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.blue[100]!),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.groups, color: Colors.blue[700], size: 20),
                          const SizedBox(width: 8),
                          Text(
                            '開發團隊',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: Colors.blue[900],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'doflab',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Colors.blue[800],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '劉瑞弘老師研究團隊',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.blue[700],
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // 版權資訊
                Text(
                  '© 2025 doflab. All rights reserved.',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  textAlign: TextAlign.center,
                ),

                const SizedBox(height: 20),

                // 關閉按鈕
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('關閉'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFeatureItem(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('• ', style: TextStyle(fontSize: 13, color: Colors.blue)),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
