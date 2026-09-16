import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';
import '../services/ai/ai_tier_policy.dart';
import '../services/ai/local_model_manager.dart';
import '../services/device_info_channel.dart';

/// 設定頁的「離線 AI 初判（Tier 1b）」卡片。
///
/// 它只做三件事：開關、把模型弄進來（匯入檔案或從網址下載）、把狀態說清楚。
/// 「這一次分析要不要用端側」不在這裡決定——那是 `AiRouter`／`chooseAiTier` 的事。
class OfflineAiCard extends StatefulWidget {
  const OfflineAiCard({super.key});

  @override
  State<OfflineAiCard> createState() => _OfflineAiCardState();
}

class _OfflineAiCardState extends State<OfflineAiCard> {
  final _device = DeviceInfoChannel();
  int? _ramMb;
  int? _freeBytes;
  bool _probed = false;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    final ram = await _device.totalMemoryMb();
    final free = await _device.freeStorageBytes();
    if (!mounted) return;
    setState(() {
      _ramMb = ram;
      _freeBytes = free;
      _probed = true;
    });
  }

  String _gb(int bytes) => '${(bytes / 1e9).toStringAsFixed(1)} GB';

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final models = context.watch<LocalModelManager>();
    final eligible = deviceEligibleForLocalModel(_ramMb);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('離線 AI 初判（裝置端 Gemma 3n）',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              subtitle: const Text(
                '沒有網路時由手機上的模型做外觀初判；讀值仍由 OCR 負責。'
                '結果會標「離線初判」，連線後請重新分析。',
                style: TextStyle(fontSize: 12),
              ),
              value: settings.offlineAiEnabled,
              onChanged: (v) => settings.setOfflineAiEnabled(v),
            ),
            const Divider(),
            _statusRow(
              icon: Icons.memory,
              label: '裝置記憶體',
              value: !_probed
                  ? '查詢中…'
                  : _ramMb == null
                      ? '查不到（此平台不支援端側模型）'
                      : '${(_ramMb! / 1024).toStringAsFixed(1)} GB'
                          '${eligible ? '' : '（不足 ${(LocalModelRequirements.minTotalRamMb / 1024).toStringAsFixed(0)} GB，無法使用）'}',
              ok: eligible,
            ),
            _statusRow(
              icon: Icons.sd_storage,
              label: '模型',
              value: switch (models.state) {
                LocalModelState.notInstalled =>
                  '未安裝（${LocalModelRequirements.displayName}，約 ${_gb(LocalModelRequirements.approxSizeBytes)}）',
                LocalModelState.installing => '安裝中 ${models.progress}%',
                LocalModelState.ready => '已就位（${LocalModelRequirements.displayName}）',
                LocalModelState.failed => '失敗：${models.error ?? '未知原因'}',
              },
              ok: models.isReady,
            ),
            if (models.state == LocalModelState.installing)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(value: models.progress / 100),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.file_open),
                  label: const Text('匯入模型檔（.litertlm）'),
                  onPressed: !eligible || models.state == LocalModelState.installing
                      ? null
                      : () => _importFile(models),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.cloud_download),
                  label: const Text('從網址下載'),
                  onPressed: !eligible || models.state == LocalModelState.installing
                      ? null
                      : () => _downloadDialog(settings, models),
                ),
                if (models.isReady)
                  TextButton.icon(
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('移除模型'),
                    onPressed: () => models.remove(),
                  ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('只在 Wi-Fi 下載', style: TextStyle(fontSize: 13)),
              value: settings.offlineAiWifiOnly,
              onChanged: (v) => settings.setOfflineAiWifiOnly(v),
            ),
            const SizedBox(height: 4),
            Text(
              '模型由 Google 以 Gemma 授權條款發布，需自行到 Hugging Face（${LocalModelRequirements.huggingFaceRepo}）'
              '接受條款後取得檔案或存取權杖。點此複製授權連結。',
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
            TextButton(
              onPressed: () {
                Clipboard.setData(const ClipboardData(text: LocalModelRequirements.licenseUrl));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已複製授權連結')),
                );
              },
              child: const Text(LocalModelRequirements.licenseUrl, style: TextStyle(fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusRow({required IconData icon, required String label, required String value, required bool ok}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: ok ? Colors.green : Colors.grey),
          const SizedBox(width: 8),
          Text('$label：', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  Future<void> _importFile(LocalModelManager models) async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: false, // 3.7 GB 絕對不能讀進記憶體，只拿路徑
    );
    final path = picked?.files.single.path;
    if (path == null) return;
    if (!path.toLowerCase().endsWith('.litertlm')) {
      _toast('請選 .litertlm 檔（${LocalModelRequirements.modelId}）');
      return;
    }
    final ok = await models.install(LocalModelSource.file(path));
    _toast(ok ? '模型已就位' : '安裝失敗：${models.error ?? ''}');
  }

  Future<void> _downloadDialog(SettingsProvider settings, LocalModelManager models) async {
    final urlCtrl = TextEditingController(
      text: 'https://huggingface.co/${LocalModelRequirements.huggingFaceRepo}/resolve/main/${LocalModelRequirements.modelId}',
    );
    final tokenCtrl = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('從網址下載模型'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: urlCtrl, decoration: const InputDecoration(labelText: '模型網址'), maxLines: 3, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            TextField(controller: tokenCtrl, decoration: const InputDecoration(labelText: 'Hugging Face 權杖（gated 模型需要）'), obscureText: true),
            const SizedBox(height: 8),
            Text('約 ${_gb(LocalModelRequirements.approxSizeBytes)}，需預留 ${_gb(LocalModelRequirements.freeSpaceMarginBytes)} 給照片與資料。',
                style: TextStyle(fontSize: 11, color: Colors.grey[600])),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('開始下載')),
        ],
      ),
    );
    if (go != true || !mounted) return;

    final conn = await Connectivity().checkConnectivity();
    // connectivity_plus 5.x 回單一值（6.x 起才是 List）。
    final onWifi = conn == ConnectivityResult.wifi || conn == ConnectivityResult.ethernet;
    if (!downloadAllowed(onWifi: onWifi, wifiOnly: settings.offlineAiWifiOnly, freeBytes: _freeBytes)) {
      _toast(!onWifi && settings.offlineAiWifiOnly
          ? '目前不是 Wi-Fi。要用行動網路下載請先關掉「只在 Wi-Fi 下載」。'
          : '儲存空間不足：需要 ${_gb(LocalModelRequirements.approxSizeBytes + LocalModelRequirements.freeSpaceMarginBytes)}，'
              '目前 ${_freeBytes == null ? '查不到' : _gb(_freeBytes!)}。');
      return;
    }
    final token = tokenCtrl.text.trim();
    final ok = await models.install(LocalModelSource.network(urlCtrl.text.trim(), token: token.isEmpty ? null : token));
    _toast(ok ? '模型已就位' : '下載失敗：${models.error ?? ''}');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
