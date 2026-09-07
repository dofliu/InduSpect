import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/wt_asset.dart';
import '../models/wt_capture_session.dart';
import '../models/wt_detection.dart';
import '../services/blade_analysis_service.dart';
import '../services/blade_report_builder.dart';
import '../services/blade_report_export.dart';
import '../services/connectivity_service.dart';
import '../services/database_service.dart';
import '../services/location_service.dart';
import 'blade_capture_guide_screen.dart';
import 'blade_history_screen.dart';

/// 風機葉片檢測（規格 §8）。
///
/// 五步：選資產 → 引導拍攝 → 演算法分析 → **人工確認** → 報告。
///
/// 第四步不是形式：演算法與 AI 都只是初判，沒有人簽過的發現不具效力。
/// 所以確認步驟不能跳過，報告上每一列也都帶著「待確認」的狀態。
class BladeInspectionScreen extends StatefulWidget {
  const BladeInspectionScreen({super.key});

  @override
  State<BladeInspectionScreen> createState() => _BladeInspectionScreenState();
}

class _BladeInspectionScreenState extends State<BladeInspectionScreen> {
  final _db = DatabaseService();
  final _uuid = const Uuid();

  int _step = 0;
  bool _busy = false;
  String? _progress;

  List<WtAsset> _assets = [];
  WtAsset? _asset;
  WtCaptureSession? _session;
  WtCaptureSession? _previousSession;
  List<WtDetection> _detections = [];
  BladeAnalysisOutcome? _outcome;

  @override
  void initState() {
    super.initState();
    _loadAssets();
  }

  Future<void> _loadAssets() async {
    final assets = await _db.getAllWtAssets();
    if (mounted) setState(() => _assets = assets);
  }

  // ── 第一步：資產 ────────────────────────────────────────────

  Future<void> _pickAsset(WtAsset asset) async {
    final past = await _db.getWtSessions(assetId: asset.assetId, limit: 1);
    if (!mounted) return;
    setState(() {
      _asset = asset;
      _previousSession = past.isEmpty ? null : past.first;
      _step = 1;
    });
  }

  Future<void> _createAsset() async {
    final created = await showDialog<WtAsset>(
      context: context,
      builder: (_) => const _AssetDialog(),
    );
    if (created == null) return;
    await _db.saveWtAsset(created);
    await _loadAssets();
    await _pickAsset(created);
  }

  // ── 第二步：拍攝 ────────────────────────────────────────────

  Future<void> _capture() async {
    final asset = _asset;
    if (asset == null) return;
    final sessionId = _session?.sessionId ?? _uuid.v4();

    final media = await Navigator.push<List<WtMedia>>(
      context,
      MaterialPageRoute(
        builder: (_) => BladeCaptureGuideScreen(
          asset: asset,
          sessionId: sessionId,
          previousSession: _previousSession,
          existing: _session?.media ?? const [],
        ),
      ),
    );
    if (media == null || media.isEmpty) return;

    final here = await LocationService().getCurrentPosition();
    final session = WtCaptureSession(
      sessionId: sessionId,
      assetId: asset.assetId,
      capturedAt: _session?.capturedAt,
      latitude: here?.latitude ?? _session?.latitude,
      longitude: here?.longitude ?? _session?.longitude,
      media: media,
      turbineState: _session?.turbineState ?? WtTurbineState.unknown,
      title: _session?.title ?? '',
    );
    await _db.saveWtSession(session);
    if (!mounted) return;
    setState(() {
      _session = session;
      _step = 2;
    });
  }

  // ── 第三步：分析 ────────────────────────────────────────────

  Future<void> _analyze() async {
    final session = _session;
    if (session == null) return;
    setState(() {
      _busy = true;
      _progress = '正在分析分區段照…';
    });
    try {
      // 廠區常常有 AP 沒 uplink，所以先探可達性再決定要不要等 AI
      // `checkConnection` 而不是 `isOnline`：後者只看網路介面，
      // 廠區常常有 AP 沒 uplink——那種情況要走離線路徑，不要空等 AI 逾時
      final online = await ConnectivityService().checkConnection();
      final outcome = await BladeAnalysisService.analyzeSession(
        session: session,
        useAi: online,
      );
      await _db.replaceWtDetections(
          session.sessionId, WtLayer.surface, outcome.detections);
      session.status = WtSessionStatus.analyzed;
      await _db.saveWtSession(session);
      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        _detections = outcome.reportable;
        _step = 3;
      });
    } catch (e) {
      if (mounted) _snack('分析失敗：$e', error: true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  // ── 第四步：人工確認 ────────────────────────────────────────

  Future<void> _setStatus(WtDetection d, WtHumanStatus status) async {
    setState(() => d.humanStatus = status);
    await _db.updateWtDetectionHumanStatus(d.detectionId, status,
        note: d.humanNote);
  }

  Future<void> _editNote(WtDetection d) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => _NoteDialog(initial: d.humanNote),
    );
    if (note == null) return;
    setState(() => d.humanNote = note);
    await _db.updateWtDetectionHumanStatus(d.detectionId, d.humanStatus,
        note: note);
  }

  bool get _allReviewed => _detections.every((d) => !d.needsConfirmation);

  Future<void> _finishReview() async {
    final session = _session;
    if (session == null) return;
    session.status = WtSessionStatus.confirmed;
    await _db.saveWtSession(session);
    if (mounted) setState(() => _step = 4);
  }

  // ── 第五步：報告 ────────────────────────────────────────────

  Future<void> _exportReport() async {
    final asset = _asset, session = _session;
    if (asset == null || session == null) return;
    setState(() {
      _busy = true;
      _progress = '正在產生 PDF…';
    });
    try {
      final path = await BladeReportExport.exportAndShare(
        asset: asset,
        session: session,
        detections: _detections,
        summary: _outcome?.buildSummary(),
        db: _db,
      );
      if (mounted) _snack('報告已產生：${p.basename(path)}');
    } catch (e) {
      if (mounted) _snack('PDF 產生失敗：$e', error: true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  void _snack(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red : null,
    ));
  }

  // ── 版面 ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('風機葉片檢測'),
        actions: [
          IconButton(
            tooltip: '檢測歷史與趨勢',
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BladeHistoryScreen()),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(value: (_step + 1) / 5, minHeight: 4),
        ),
      ),
      body: Stack(
        children: [
          _stepBody(),
          if (_busy)
            Positioned.fill(
              child: ColoredBox(
                color: const Color(0x66000000),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      if (_progress != null) ...[
                        const SizedBox(height: 12),
                        Text(_progress!,
                            style: const TextStyle(color: Colors.white)),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _stepBody() {
    switch (_step) {
      case 0:
        return _assetStep();
      case 1:
        return _captureStep();
      case 2:
        return _analyzeStep();
      case 3:
        return _reviewStep();
      default:
        return _reportStep();
    }
  }

  Widget _stepHeader(String title, String note) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('步驟 ${_step + 1} / 5 · $title',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(note,
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ],
        ),
      );

  Widget _assetStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _stepHeader('選擇風機',
              '葉片檢測是「跟著一台風機」的紀錄，不是跟著一張表單。選同一台才能比對歷次結果。'),
          Expanded(
            child: _assets.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('還沒有風機資料。先建一台，之後每次到場都選同一台。',
                          textAlign: TextAlign.center),
                    ),
                  )
                : ListView.builder(
                    itemCount: _assets.length,
                    itemBuilder: (_, i) {
                      final a = _assets[i];
                      return ListTile(
                        leading: const Icon(Icons.energy_savings_leaf),
                        title: Text(a.assetId),
                        subtitle: Text([
                          if (a.siteName.isNotEmpty) a.siteName,
                          if (a.model != null) a.model!,
                          if (a.rotorDiameterM != null)
                            '轉子 ${a.rotorDiameterM!.toStringAsFixed(0)} m',
                        ].join(' · ')),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _pickAsset(a),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: OutlinedButton.icon(
              onPressed: _createAsset,
              icon: const Icon(Icons.add),
              label: const Text('新增風機'),
            ),
          ),
        ],
      );

  Widget _captureStep() {
    final prev = _previousSession;
    return ListView(
      children: [
        _stepHeader('引導拍攝',
            '照片一律原尺寸保存。用系統相機拍——分區段照要用 5x 光學長焦，'
                'App 內建預覽碰不到那顆鏡頭。'),
        if (prev != null)
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: ListTile(
              leading: const Icon(Icons.history),
              title: Text('上次到場：'
                  '${prev.capturedAt.year}-${_two(prev.capturedAt.month)}-${_two(prev.capturedAt.day)}'),
              subtitle: Text('${prev.media.length} 張照片可當取景參考'),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: _capture,
            icon: const Icon(Icons.camera_alt),
            label: Text(_session == null ? '開始拍攝' : '繼續拍攝／補拍'),
          ),
        ),
        if (_session != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '已拍 ${_session!.media.length} 張，其中 '
              '${_session!.usableMediaCount} 張可用於量測。',
            ),
          ),
        if (_session != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              onPressed: () => setState(() => _step = 2),
              child: const Text('下一步：分析'),
            ),
          ),
      ],
    );
  }

  Widget _analyzeStep() {
    final session = _session;
    final usable = session?.usableMediaCount ?? 0;
    return ListView(
      children: [
        _stepHeader('演算法分析',
            '數字由演算法算、AI 只負責解讀「這是缺陷還是正常結構」。兩者都只是初判。'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Card(
            color: usable == 0 ? Colors.orange.shade50 : Colors.blue.shade50,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(usable == 0
                  ? '沒有通過拍攝品質閘門的照片，分析不會產生任何量測值。'
                      '回上一步重拍——把不可信的畫面算出數字比沒有數字更糟。'
                  : '$usable 張照片可用於量測。本次只跑表面層（前緣輪廓粗糙度）；'
                      '幾何層與動態層還沒在 App 端實作，照片會保存下來供日後補跑。'),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: _busy ? null : _analyze,
            icon: const Icon(Icons.analytics),
            label: const Text('開始分析'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextButton(
            onPressed: () => setState(() => _step = 1),
            child: const Text('回上一步補拍'),
          ),
        ),
      ],
    );
  }

  Widget _reviewStep() {
    final outcome = _outcome;
    return ListView(
      children: [
        _stepHeader('人工確認',
            '沒有人簽過的發現不具效力。逐筆確認或駁回——駁回的不列進報告，但照片照樣附上。'),
        if (outcome != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Card(
              color: Colors.grey.shade100,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(outcome.buildSummary(),
                    style: const TextStyle(fontSize: 12)),
              ),
            ),
          ),
        if (_detections.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '本次沒有超過門檻的發現。這不等於葉片沒有問題——手機地面拍攝屬 '
              'Level 1 篩檢，受解析度物理限制。量到的數值已存下來，下次到場可比對趨勢。',
              textAlign: TextAlign.center,
            ),
          ),
        ..._detections.map(_detectionCard),
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: _finishReview,
            child: Text(_allReviewed || _detections.isEmpty
                ? '下一步：產生報告'
                : '仍有未確認項目，先產生報告'),
          ),
        ),
      ],
    );
  }

  Widget _detectionCard(WtDetection d) {
    final verdict = BladeReportBuilder.verdictOf(d);
    final color = verdict == '不合格'
        ? Colors.red
        : (verdict == '警告' ? Colors.orange : Colors.blueGrey);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(verdict,
                      style: TextStyle(color: color, fontSize: 12)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(BladeReportBuilder.labelOf(d),
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            if (BladeReportBuilder.valueOf(d) != null) ...[
              const SizedBox(height: 6),
              Text(BladeReportBuilder.valueOf(d)!,
                  style: const TextStyle(fontSize: 12)),
            ],
            if (d.aiDescription != null) ...[
              const SizedBox(height: 4),
              Text(d.aiDescription!,
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ],
            if (d.source == WtDetectionSource.geminiOfflinePending)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('（AI 解讀待補：離線時只有演算法的數值）',
                    style: TextStyle(fontSize: 11, color: Colors.orange)),
              ),
            if (d.mediaPath != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.file(
                  File(d.mediaPath!),
                  height: 120,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ],
            if (d.humanNote != null && d.humanNote!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('人工備註：${d.humanNote}',
                  style: const TextStyle(fontSize: 12)),
            ],
            const SizedBox(height: 4),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () => _setStatus(d, WtHumanStatus.confirmed),
                  icon: Icon(Icons.check,
                      color: d.humanStatus == WtHumanStatus.confirmed
                          ? Colors.green
                          : null),
                  label: const Text('確認'),
                ),
                TextButton.icon(
                  onPressed: () => _setStatus(d, WtHumanStatus.rejected),
                  icon: Icon(Icons.close,
                      color: d.humanStatus == WtHumanStatus.rejected
                          ? Colors.red
                          : null),
                  label: const Text('駁回'),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => _editNote(d),
                  icon: const Icon(Icons.edit_note),
                  tooltip: '備註',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _reportStep() {
    final rejected =
        _detections.where((d) => d.humanStatus == WtHumanStatus.rejected).length;
    final pending = _detections.where((d) => d.needsConfirmation).length;
    return ListView(
      children: [
        _stepHeader('報告', '報告不下「合格」判定——篩檢查不到的東西不等於不存在。'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${_asset?.assetId ?? ''} · '
                      '${_session?.media.length ?? 0} 張照片'),
                  const SizedBox(height: 4),
                  Text('列入報告 ${_detections.length - rejected} 筆'
                      '${rejected > 0 ? '（駁回 $rejected 筆）' : ''}'
                      '${pending > 0 ? '，其中 $pending 筆未確認' : ''}'),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: _busy ? null : _exportReport,
            icon: const Icon(Icons.picture_as_pdf),
            label: const Text('產生並分享 PDF 報告'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextButton(
            onPressed: () => setState(() => _step = 3),
            child: const Text('回上一步修改確認狀態'),
          ),
        ),
      ],
    );
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}

/// 新增風機。只問「量測用得到」的欄位——問了不用的欄位只會讓人跳過。
class _AssetDialog extends StatefulWidget {
  const _AssetDialog();

  @override
  State<_AssetDialog> createState() => _AssetDialogState();
}

class _AssetDialogState extends State<_AssetDialog> {
  final _id = TextEditingController();
  final _site = TextEditingController();
  final _model = TextEditingController();
  final _diameter = TextEditingController();

  @override
  void dispose() {
    _id.dispose();
    _site.dispose();
    _model.dispose();
    _diameter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('新增風機'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _id,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '風機編號（必填）',
                  hintText: 'WTG-07',
                ),
              ),
              TextField(
                controller: _site,
                decoration: const InputDecoration(labelText: '風場'),
              ),
              TextField(
                controller: _model,
                decoration: const InputDecoration(
                  labelText: '機型',
                  hintText: '決定葉長與 LEP 帶位置，填了報告上看得到',
                ),
              ),
              TextField(
                controller: _diameter,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '轉子直徑（m）',
                  hintText: '幾何層要用它把像素換算成實尺',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final id = _id.text.trim();
              if (id.isEmpty) return;
              Navigator.pop(
                context,
                WtAsset(
                  assetId: id,
                  siteName: _site.text.trim(),
                  model: _model.text.trim().isEmpty ? null : _model.text.trim(),
                  rotorDiameterM: double.tryParse(_diameter.text.trim()),
                ),
              );
            },
            child: const Text('建立'),
          ),
        ],
      );
}

class _NoteDialog extends StatefulWidget {
  final String? initial;
  const _NoteDialog({this.initial});

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  late final TextEditingController _c =
      TextEditingController(text: widget.initial ?? '');

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('人工備註'),
        content: TextField(
          controller: _c,
          autofocus: true,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: '看到什麼、判斷是什麼、要不要排近距離複檢',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _c.text.trim()),
            child: const Text('儲存'),
          ),
        ],
      );
}
