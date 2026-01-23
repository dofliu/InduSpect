import 'package:flutter/material.dart';

class GuideScreen extends StatelessWidget {
  const GuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('使用說明'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildIntroCard(),
          const SizedBox(height: 16),
          _buildFeatureSection(context, '快速分析', [
            '適用場景：單一設備快速檢測',
            '步驟 1：點擊首頁「快速分析」',
            '步驟 2：拍攝設備照片',
            '步驟 3：AI 立即分析並提供結果',
            '結果包含：設備類型、狀況評估、建議',
          ], Icons.flash_on, Colors.blue),
          const SizedBox(height: 16),
          _buildFeatureSection(context, '詳細分析', [
            '適用場景：依檢查清單逐項檢測',
            '步驟 1：上傳檢查清單照片',
            '步驟 2：AI 自動識別檢查項目',
            '步驟 3：逐項拍照記錄',
            '步驟 4：生成完整檢測報告',
            '結果包含：所有項目詳細分析',
          ], Icons.checklist, Colors.green),
          const SizedBox(height: 16),
          _buildApiKeySection(context),
          const SizedBox(height: 16),
          _buildModelSection(context),
          const SizedBox(height: 16),
          _buildTipsSection(context),
        ],
      ),
    );
  }

  Widget _buildIntroCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.lightbulb_outline, color: Colors.orange, size: 32),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '歡迎使用 InduSpect AI',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'AI 驅動的工業設備智能檢測系統',
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              '本系統結合 Google Gemini AI，為您的設備檢測工作提供智能輔助，幫助您快速發現異常、評估設備狀況。',
              style: TextStyle(color: Colors.grey[700]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeatureSection(
    BuildContext context,
    String title,
    List<String> steps,
    IconData icon,
    Color color,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, color: color, size: 24),
                ),
                const SizedBox(width: 12),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ...steps.map((step) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(step)),
                ],
              ),
            )),
          ],
        ),
      ),
    );
  }

  Widget _buildApiKeySection(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.key, color: Colors.purple, size: 24),
                SizedBox(width: 12),
                Text(
                  'API Key 說明',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildInfoItem(
              '試用模式',
              '首次使用可免費試用 5 次，無需設定 API Key',
              Icons.workspace_premium,
              Colors.orange,
            ),
            const SizedBox(height: 12),
            _buildInfoItem(
              '設定 API Key',
              '前往設定頁面輸入您的 Google Gemini API Key，即可無限使用',
              Icons.vpn_key,
              Colors.blue,
            ),
            const SizedBox(height: 12),
            _buildInfoItem(
              '費用說明',
              'Gemini API 提供免費額度，一般使用足夠。詳情請見 Google AI Studio',
              Icons.attach_money,
              Colors.green,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModelSection(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.memory, color: Colors.blue, size: 24),
                SizedBox(width: 12),
                Text(
                  'AI 模型選擇',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildModelItem(
              'Flash (推薦)',
              '平衡效能與成本，適合大多數場景',
              Colors.green,
            ),
            const SizedBox(height: 8),
            _buildModelItem(
              'Pro',
              '最強分析能力，適合複雜設備檢測，費用較高',
              Colors.orange,
            ),
            const SizedBox(height: 8),
            _buildModelItem(
              'Lite',
              '快速回應，適合簡單檢測，費用較低',
              Colors.blue,
            ),
            const SizedBox(height: 12),
            Text(
              '可在設定頁面切換模型',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[600],
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModelItem(String name, String description, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: color.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(8),
        color: color.withOpacity(0.05),
      ),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 40,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoItem(String title, String description, IconData icon, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                description,
                style: TextStyle(fontSize: 12, color: Colors.grey[700]),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTipsSection(BuildContext context) {
    return Card(
      color: Colors.blue[50],
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.tips_and_updates, color: Colors.blue[700], size: 24),
                const SizedBox(width: 12),
                Text(
                  '使用技巧',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue[900],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildTip('拍照時保持光線充足，設備細節清晰'),
            _buildTip('可在照片中加入參照物（如信用卡）以利 AI 判斷尺寸'),
            _buildTip('多角度拍攝可提供更全面的檢測資訊'),
            _buildTip('定期檢測可建立設備健康趨勢'),
          ],
        ),
      ),
    );
  }

  Widget _buildTip(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.check_circle, size: 18, color: Colors.blue[700]),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: Colors.blue[900]),
            ),
          ),
        ],
      ),
    );
  }
}
