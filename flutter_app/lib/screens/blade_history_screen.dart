import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/wt_asset.dart';
import '../models/wt_capture_session.dart';
import '../models/wt_detection.dart';
import '../services/blade_dataset_export.dart';
import '../services/blade_dataset_service.dart';
import '../services/blade_report_builder.dart';
import '../services/blade_report_export.dart';
import '../services/blade_trend_service.dart';
import '../services/database_service.dart';

/// 葉片檢測歷史（規格 §7）。
///
/// 這個畫面是**資料模型做成資產驅動的兌現處**：定檢紀錄是一張表單一次交付，
/// 葉片是同一台風機累積下來的一條線。沒有這個畫面，Phase 1 只交付得出單次篩檢。
class BladeHistoryScreen extends StatefulWidget {
  const BladeHistoryScreen({super.key});

  @override
  State<BladeHistoryScreen> createState() => _BladeHistoryScreenState();
}

class _BladeHistoryScreenState extends State<BladeHistoryScreen> {
  final _db = DatabaseService();
  List<WtAsset> _assets = [];
  final Map<String, List<WtCaptureSession>> _sessions = {};
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final assets = await _db.getAllWtAssets();
    final sessions = <String, List<WtCaptureSession>>{};
    for (final a in assets) {
      sessions[a.assetId] = await _db.getWtSessions(assetId: a.assetId);
    }
    if (!mounted) return;
    setState(() {
      _assets = assets;
      _sessions
        ..clear()
        ..addAll(sessions);
      _loading = false;
    });
  }

  /// 訓練語料的統計與匯出（規格 §9 Phase 4 的前置）。
  ///
  /// **先給數字再給按鈕**：Phase 4 的估時在規格裡寫的是「視資料量」，
  /// 而在這之前沒有任何地方看得到資料量。使用者要先知道「還差多少」，
  /// 匯出才有意義。
  Future<void> _showDatasetSheet() async {
    setState(() => _busy = true);
    BladeDatasetSummary summary;
    try {
      summary = await BladeDatasetExport.summarize(db: _db);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('讀不到語料統計：$e')));
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);

    final go = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _DatasetSheet(summary: summary),
    );
    if (go != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final r = await BladeDatasetExport.exportAndShare(db: _db);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已匯出 ${r.copiedCount} 個檔案'
            '${r.missingCount > 0 ? '（${r.missingCount} 個原檔已不存在，'
                '仍列在 manifest 裡）' : ''}：${r.fileName}'),
        duration: const Duration(seconds: 6),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('匯出失敗：$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('葉片檢測歷史'),
        actions: [
          IconButton(
            tooltip: '匯出訓練語料',
            icon: const Icon(Icons.upload_file),
            onPressed: _busy ? null : _showDatasetSheet,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _assets.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('還沒有葉片檢測紀錄。', textAlign: TextAlign.center),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    itemCount: _assets.length,
                    itemBuilder: (_, i) => _assetTile(_assets[i]),
                  ),
                ),
    );
  }

  Widget _assetTile(WtAsset asset) {
    final sessions = _sessions[asset.assetId] ?? const <WtCaptureSession>[];
    final last = sessions.isEmpty ? null : sessions.first.capturedAt;
    return ListTile(
      leading: const Icon(Icons.energy_savings_leaf),
      title: Text(asset.assetId),
      subtitle: Text([
        if (asset.siteName.isNotEmpty) asset.siteName,
        '${sessions.length} 次檢測',
        if (last != null) '最近 ${_date(last)}',
      ].join(' · ')),
      trailing: const Icon(Icons.chevron_right),
      onTap: sessions.isEmpty
          ? null
          : () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => BladeAssetHistoryScreen(asset: asset),
                ),
              );
              await _load();
            },
    );
  }

  static String _date(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)}';
  static String _two(int v) => v.toString().padLeft(2, '0');
}

/// 一台風機的歷次紀錄 + 趨勢。
class BladeAssetHistoryScreen extends StatefulWidget {
  final WtAsset asset;
  const BladeAssetHistoryScreen({super.key, required this.asset});

  @override
  State<BladeAssetHistoryScreen> createState() =>
      _BladeAssetHistoryScreenState();
}

class _BladeAssetHistoryScreenState extends State<BladeAssetHistoryScreen> {
  final _db = DatabaseService();
  List<WtCaptureSession> _sessions = [];
  List<WtDetection> _detections = [];
  List<BladeTrendSeries> _trend = [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sessions = await _db.getWtSessions(assetId: widget.asset.assetId);
    final detections =
        await _db.getWtDetectionsForAsset(widget.asset.assetId);
    if (!mounted) return;
    setState(() {
      _sessions = sessions;
      _detections = detections;
      _trend = BladeTrendService.build(
        detections: detections,
        sessions: sessions,
      );
      _loading = false;
    });
  }

  Future<void> _reexport(WtCaptureSession session) async {
    setState(() => _busy = true);
    try {
      final detections = await _db.getWtDetections(session.sessionId);
      final r = await BladeReportExport.exportAndShare(
        asset: widget.asset,
        session: session,
        // 人工駁回的不列進報告；`buildData` 也會再擋一次
        detections: detections
            .where((d) => d.humanStatus != WtHumanStatus.rejected)
            .toList(),
        db: _db,
      );
      if (mounted) {
        // 離線時報告已排進佇列而不是已送出——提示要說對，不然使用者以為客戶收到了
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(r.shared
                ? '已重新匯出：${p.basename(r.path)}'
                : '目前離線，已重新匯出並排入待分享（恢復網路後自動送出）'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('匯出失敗：$e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(WtCaptureSession session) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('刪除這次檢測？'),
        content: const Text('偵測結果與人工確認紀錄會一起刪除，趨勢線會少一個點。'
            '照片檔本身不會被刪。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('刪除')),
        ],
      ),
    );
    if (ok != true) return;
    await _db.deleteWtSession(session.sessionId);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.asset.assetId} 檢測歷史')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                ListView(
                  padding: const EdgeInsets.only(bottom: 32),
                  children: [
                    _trendSection(),
                    const Divider(height: 24),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text('歷次檢測（${_sessions.length}）',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 8),
                    ..._sessions.map(_sessionCard),
                  ],
                ),
                if (_busy)
                  const Positioned.fill(
                    child: ColoredBox(
                      color: Color(0x66000000),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _trendSection() {
    final comparable = _trend.where((s) => s.withRatio.length >= 2).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('前緣粗糙度趨勢',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text(
            '縱軸是前緣／後緣 rms 比——同一張照片內互比，所以距離與焦段都約掉了，'
            '是這套流程裡唯一跨次可比的數字。原始 px 值不可跨次比較。',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
          const SizedBox(height: 8),
          if (_trend.isEmpty)
            const Text('還沒有表面層的量測值。')
          else if (comparable.isEmpty)
            const Text('每個格位都只有一次量測，還看不出趨勢——'
                '下次到場拍同一格位才比得出來。',
                style: TextStyle(fontSize: 13))
          else
            ...comparable.map(_seriesCard),
          const SizedBox(height: 8),
          Card(
            color: Colors.amber.shade50,
            child: const Padding(
              padding: EdgeInsets.all(10),
              child: Text(BladeTrendService.comparabilityCaveat,
                  style: TextStyle(fontSize: 11)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _seriesCard(BladeTrendSeries series) {
    final d = series.delta ?? 0;
    final worsening = d >= BladeTrendService.worseningDelta;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(_seriesLabel(series),
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                if (worsening)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('上升',
                        style: TextStyle(fontSize: 11, color: Colors.red)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 96,
              child: CustomPaint(
                painter: _TrendPainter(series.withRatio),
                child: const SizedBox.expand(),
              ),
            ),
            const SizedBox(height: 6),
            Text(BladeTrendService.describe(series),
                style: const TextStyle(fontSize: 12)),
            if (series.points.any((pt) => pt.humanStatus == WtHumanStatus.rejected))
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('△ 其中有被人工駁回的點（仍畫在線上：量到的數值是那天的事實）',
                    style: TextStyle(fontSize: 11, color: Colors.orange)),
              ),
          ],
        ),
      ),
    );
  }

  static String _seriesLabel(BladeTrendSeries s) {
    final parts = <String>[];
    if (s.blade != null) parts.add('葉片 ${s.blade}');
    if (s.zone != null) {
      parts.add(BladeReportBuilder.zoneLabels[s.zone] ?? s.zone!);
    }
    return parts.isEmpty ? '未指定格位' : parts.join(' · ');
  }

  Widget _sessionCard(WtCaptureSession session) {
    final mine = _detections.where((d) => d.sessionId == session.sessionId);
    final findings = mine.where((d) => d.severity != null).length;
    final pending = mine.where((d) => d.needsConfirmation).length;
    final pendingAi = mine
        .where((d) => d.source == WtDetectionSource.geminiOfflinePending)
        .length;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    session.title.isEmpty
                        ? _dateTime(session.capturedAt)
                        : session.title,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Text(_statusLabel(session.status),
                    style: const TextStyle(fontSize: 11, color: Colors.black54)),
              ],
            ),
            const SizedBox(height: 4),
            Text([
              '${session.media.length} 張照片',
              '${session.usableMediaCount} 張可量測',
              findings == 0 ? '未檢出超門檻異常' : '$findings 筆發現',
              if (pending > 0) '$pending 筆待確認',
            ].join(' · '), style: const TextStyle(fontSize: 12)),
            if (pendingAi > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('$pendingAi 筆 AI 解讀待補（連線後會自動補跑）',
                    style: TextStyle(fontSize: 11, color: Colors.orange.shade800)),
              ),
            if (session.pendingShare)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('報告待分享（連線後自動送出）',
                    style: TextStyle(fontSize: 11, color: Colors.orange)),
              ),
            if (session.media.isNotEmpty) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 56,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: session.media.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (_, i) => _thumb(session.media[i]),
                ),
              ),
            ],
            Row(
              children: [
                TextButton.icon(
                  onPressed: _busy ? null : () => _reexport(session),
                  icon: const Icon(Icons.picture_as_pdf, size: 18),
                  label: const Text('重新匯出'),
                ),
                const Spacer(),
                IconButton(
                  onPressed: _busy ? null : () => _delete(session),
                  icon: const Icon(Icons.delete_outline),
                  tooltip: '刪除',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _thumb(WtMedia media) => ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 56,
          height: 56,
          // 非照片的媒體不能走 `Image.file`：那條路會落到 errorBuilder，
          // 於是一段好好的音軌在畫面上顯示成「圖片壞了」。
          child: media.kind == WtMediaKind.video
              ? const ColoredBox(
                  color: Colors.black12,
                  child: Center(child: Icon(Icons.burst_mode, size: 20)),
                )
              : media.kind == WtMediaKind.audio
                  ? const ColoredBox(
                      color: Colors.black12,
                      child: Center(
                          child: Icon(Icons.insert_drive_file, size: 20)),
                    )
                  : Image.file(
                      File(media.path),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => ColoredBox(
                        color: Colors.grey.shade300,
                        child: const Icon(Icons.broken_image, size: 18),
                      ),
                    ),
        ),
      );

  static String _statusLabel(WtSessionStatus s) {
    switch (s) {
      case WtSessionStatus.draft:
        return '草稿';
      case WtSessionStatus.analyzed:
        return '已分析';
      case WtSessionStatus.confirmed:
        return '已確認';
      case WtSessionStatus.shared:
        return '已分享';
    }
  }

  static String _dateTime(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';
  static String _two(int v) => v.toString().padLeft(2, '0');
}

/// 比值折線。門檻線畫在 1.5 / 2.0 / 5.0——與 `BladeSurfaceTriage` 同一組值，
/// 讓「這條線離門檻多遠」看得出來，而不是只看得到相對高低。
/// 訓練語料的統計表 + 匯出按鈕。
///
/// 這張表最重要的一列是 `humanClean` 的**分區段照**張數：健康樣本異常偵測
/// （PatchCore 類）的記憶庫只能用那一類，而「演算法沒報」不算——那是兩件事。
class _DatasetSheet extends StatelessWidget {
  const _DatasetSheet({required this.summary});

  final BladeDatasetSummary summary;

  static const Map<BladeDatasetLabel, String> _labelText = {
    BladeDatasetLabel.defect: '人工確認的缺陷（正樣本）',
    BladeDatasetLabel.falsePositive: '人工駁回（演算法誤報）',
    BladeDatasetLabel.humanClean: '人看過且乾淨（可進記憶庫）',
    BladeDatasetLabel.unusable: '沒過品質閘門（不可用）',
    BladeDatasetLabel.unreviewed: '還沒有人簽核',
  };

  @override
  Widget build(BuildContext context) {
    final can = summary.memoryBankCandidates;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('訓練語料', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('${summary.sessionCount} 次拍攝、'
                '${summary.reviewedSessionCount} 次有人簽核、'
                '${summary.assetCount} 台風機'),
            const SizedBox(height: 16),
            Card(
              color: can == 0 ? Colors.orange.shade50 : Colors.blue.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(summary.readiness,
                    style: const TextStyle(fontSize: 13)),
              ),
            ),
            const SizedBox(height: 12),
            for (final l in BladeDatasetLabel.values)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(child: Text(_labelText[l] ?? l.name,
                        style: const TextStyle(fontSize: 13))),
                    Text('${summary.of(l)}',
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            const Text(
              '匯出的 zip 含 manifest.json（自我描述：每張照片的區段、拍攝條件、'
              '演算法量到的數值、AI 的解讀、以及**人的判定**）。'
              '照片只複製前三類；沒過閘門與沒簽核的仍列在 manifest 裡但不複製檔案'
              '——一次外業可能是幾百 MB，而那兩類對訓練沒有用。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('關閉'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.upload_file),
                  label: const Text('匯出並分享'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  final List<BladeTrendPoint> points;
  const _TrendPainter(this.points);

  static const _thresholds = [1.5, 2.0, 5.0];

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final values = points.map((p) => p.ratio!).toList();
    // 值域一定含門檻 1.5，否則「離門檻很遠」這件事在圖上看不出來
    var lo = math.min(values.reduce(math.min), 1.0);
    var hi = math.max(values.reduce(math.max), 2.0);
    if (hi - lo < 0.5) {
      final mid = (hi + lo) / 2;
      lo = mid - 0.25;
      hi = mid + 0.25;
    }
    final pad = (hi - lo) * 0.12;
    lo -= pad;
    hi += pad;

    double y(double v) => size.height * (1 - (v - lo) / (hi - lo));
    double x(int i) =>
        points.length == 1 ? 0 : size.width * i / (points.length - 1);

    final grid = Paint()
      ..color = Colors.grey.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    final label = TextPainter(textDirection: TextDirection.ltr);
    for (final t in _thresholds) {
      if (t < lo || t > hi) continue;
      final yy = y(t);
      canvas.drawLine(Offset(0, yy), Offset(size.width, yy), grid);
      label.text = TextSpan(
        text: t.toStringAsFixed(1),
        style: TextStyle(fontSize: 9, color: Colors.grey.shade600),
      );
      label.layout();
      label.paint(canvas, Offset(size.width - label.width, yy - 10));
    }

    final line = Paint()
      ..color = Colors.teal
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path()..moveTo(x(0), y(values[0]));
    for (var i = 1; i < values.length; i++) {
      path.lineTo(x(i), y(values[i]));
    }
    canvas.drawPath(path, line);

    for (var i = 0; i < values.length; i++) {
      final rejected = points[i].humanStatus == WtHumanStatus.rejected;
      canvas.drawCircle(
        Offset(x(i), y(values[i])),
        3.5,
        Paint()..color = rejected ? Colors.grey : Colors.teal,
      );
    }
  }

  @override
  bool shouldRepaint(_TrendPainter old) => old.points != points;
}
