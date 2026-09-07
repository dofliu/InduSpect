import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/wt_asset.dart';
import '../models/wt_capture_session.dart';
import '../models/wt_detection.dart';
import '../services/blade_acoustic_service.dart';
import '../services/blade_analysis_service.dart';
import '../services/blade_audio_decode.dart';
import '../services/blade_audio_recorder.dart';
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

    await _commitMedia(asset, sessionId, media, advance: true);
  }

  /// 存檔 + 更新畫面。照片與音軌走同一條路——GPS、標題、風機狀態的沿用規則
  /// 只該有一份，各寫一次的話補拍音軌會把上次的定位覆蓋掉。
  Future<void> _commitMedia(
      WtAsset asset, String sessionId, List<WtMedia> media,
      {bool advance = false}) async {
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
      if (advance) _step = 2;
    });
  }

  /// 附加一段音軌（規格 §5.4 音軌）。
  ///
  /// 只收 WAV：裝置上沒有純 Dart 的 AAC/MP3 解碼器，而現場要的是離線可用。
  /// 手機內建錄音程式多半可以選 WAV／PCM；選不了的話這裡會明講。
  ///
  /// **當場就驗一次**，不等到分析步驟：解不開、太短、風噪主導都要在人還站在
  /// 風機旁邊、還能重錄的時候講。這與照片的品質閘門是同一個道理。
  Future<void> _attachAudio() async {
    final asset = _asset;
    if (asset == null) return;
    final sessionId = _session?.sessionId ?? _uuid.v4();

    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['wav'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      _snack('讀不到這個檔案，請改從「檔案」App 選一次', error: true);
      return;
    }

    await _ingestAudio(bytes, file.name, sessionId, asset);
  }

  /// **App 內錄音**（規格 §5.4 音軌）。
  ///
  /// 與「附加音軌」共用同一條驗證與存檔路徑——錄音只是換一個來源，
  /// 不該長出第二套判定。錄音參數（未壓縮 WAV、關掉自動增益／降噪）由
  /// `BladeRecordingSpec` 決定，理由寫在那裡：那三個開了就量不到要量的東西。
  Future<void> _recordAudio() async {
    final asset = _asset;
    if (asset == null) return;
    final sessionId = _session?.sessionId ?? _uuid.v4();

    final controller = BladeRecordingController();
    // 先開始再開對話框：權限與編碼器的問題要直接講，不要包在一個錄音畫面裡
    final tmpDir = await getApplicationDocumentsDirectory();
    final tmp = p.join(tmpDir.path, 'blade_audio', 'rec-${_uuid.v4()}.wav');
    await Directory(p.dirname(tmp)).create(recursive: true);

    final started = await controller.start(tmp);
    if (!started.ok) {
      await controller.dispose();
      if (mounted) _snack(started.message, error: true);
      return;
    }
    if (!mounted) {
      await controller.cancel();
      await controller.dispose();
      return;
    }

    final keep = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RecordDialog(controller: controller),
    );

    if (keep != true) {
      await controller.cancel();
      await controller.dispose();
      return;
    }
    final stopped = await controller.stop();
    await controller.dispose();
    if (!stopped.ok) {
      if (mounted) _snack(stopped.message, error: true);
      return;
    }
    Uint8List bytes;
    try {
      bytes = await File(stopped.path!).readAsBytes();
    } catch (e) {
      if (mounted) _snack('讀不回剛錄的檔案：$e', error: true);
      return;
    }
    await _ingestAudio(bytes, p.basename(stopped.path!), sessionId, asset);
    // 錄音的暫存檔已經複製進場次目錄，原檔不留
    try {
      final f = File(stopped.path!);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 刪不掉不影響結果
    }
  }

  /// 音軌的**唯一**驗證與存檔路徑（錄音與選檔共用）。
  ///
  /// 當場就驗一次，不等到分析步驟：解不開、太短、風噪主導都要在人還站在風機旁、
  /// 還能重錄的時候講。
  Future<void> _ingestAudio(
      Uint8List bytes, String name, String sessionId, WtAsset asset) async {
    setState(() {
      _busy = true;
      _progress = '正在檢查音軌…';
    });
    try {
      final probe = BladeAudioDecode.decodeWav(bytes);
      if (!probe.ok) {
        _snack(probe.message, error: true);
        return;
      }
      final clip = probe.clip!;
      if (BladeAcousticService.tooShort(clip)) {
        _snack('音軌只有 ${clip.durationS.toStringAsFixed(1)} 秒，太短。'
            '要切分三片得涵蓋 2–3 圈轉動（12 rpm 約 15 秒）', error: true);
        return;
      }

      final saved = await _saveAudio(bytes, name, sessionId);
      // 先跑一次分析只為了給現場一句話：不可用就當場說，別讓人回去才知道
      final quick = BladeAcousticService.analyzeSamples(clip);
      final media = <WtMedia>[
        ...(_session?.media ?? const []),
        WtMedia(
          path: saved.path,
          kind: WtMediaKind.audio,
          view: WtMediaView.other,
          qualityJson: {
            'ok': quick.usable,
            'duration_s': clip.durationS,
            // 取樣率要存：跨次比較的基準會隨它變（見 BladeRecordingSpec）
            'sample_rate': clip.sampleRate,
            if (quick.notes.isNotEmpty) 'notes': quick.notes,
          },
        ),
      ];
      await _commitMedia(asset, sessionId, media);
      if (!mounted) return;
      _snack(quick.usable
          ? '音軌可用：量到轉速 ${quick.rpmFromAudio.toStringAsFixed(1)} rpm'
          : '音軌存下來了，但目前不可用：${quick.notes.first}');
    } catch (e) {
      if (mounted) _snack('音軌處理失敗：$e', error: true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  /// 複製到 App 目錄。`file_picker` 給的可能是系統快取檔，會被清掉。
  Future<File> _saveAudio(
      List<int> bytes, String name, String sessionId) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'blade_audio', sessionId));
    if (!await dir.exists()) await dir.create(recursive: true);
    final ext = p.extension(name).isEmpty ? '.wav' : p.extension(name);
    final target = File(p.join(dir.path, '${_uuid.v4()}$ext'));
    return target.writeAsBytes(bytes);
  }

  // ── 第三步：分析 ────────────────────────────────────────────

  Future<void> _analyze() async {
    final session = _session;
    if (session == null) return;
    setState(() {
      _busy = true;
      _progress = '正在分析（照片與音軌）…';
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
      await _db.replaceWtDetections(session.sessionId, outcome.detections);
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
      final r = await BladeReportExport.exportAndShare(
        asset: asset,
        session: session,
        detections: _detections,
        summary: _outcome?.buildSummary(),
        db: _db,
      );
      if (mounted) {
        // 離線時只是排進佇列，別說成「已分享」
        _snack(r.shared
            ? '報告已產生：${p.basename(r.path)}'
            : '報告已產生（目前離線，恢復網路後自動分享）：${p.basename(r.path)}');
      }
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: FilledButton.icon(
            onPressed: _busy ? null : _recordAudio,
            icon: const Icon(Icons.mic),
            label: const Text('錄音軌（選用）'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: OutlinedButton.icon(
            onPressed: _busy ? null : _attachAudio,
            icon: const Icon(Icons.upload_file),
            label: const Text('改用既有的 WAV 檔'),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(
            '音軌用來比三片的噪音——缺陷葉片的聲音會以葉片通過的週期出現，'
            '所以切成三份互比就指得出是哪一片。錄 15 秒以上（要涵蓋 2–3 圈）、'
            '站到下風處、手機不要包在口袋裡。轉速也由音軌算，不必另外量。'
            '歷次錄音請用同一個取樣率，否則跨次比較的基準會變。',
            style: TextStyle(fontSize: 12),
          ),
        ),
        if (_session != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              '已拍 ${_session!.photoCount} 張照片，其中 '
              '${_session!.usableMediaCount} 張可用於量測'
              '${_session!.audioCount > 0 ? '；音軌 ${_session!.audioCount} 段' : ''}。',
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

  /// 這個場次的素材各自對得上哪一層。**照實說**：現場靠這句話決定要不要回頭補拍，
  /// 寫死一句「只跑表面層」在幾何層與音軌都接上之後就變成謊。
  String _coverageText(WtCaptureSession? session) {
    final usable = session?.usableMediaCount ?? 0;
    if (session == null) return '還沒有素材。';
    final segment = session.media
        .where((m) =>
            m.kind == WtMediaKind.photo &&
            m.view == WtMediaView.segment &&
            m.qualityOk == true)
        .length;
    final whole = session.media
        .where((m) =>
            m.kind == WtMediaKind.photo &&
            (m.view == WtMediaView.front || m.view == WtMediaView.side) &&
            m.qualityOk == true)
        .length;
    final audio = session.usableAudioCount;
    final video = session.media.where((m) => m.kind == WtMediaKind.video).length;

    final will = <String>[];
    if (segment > 0) will.add('表面層（$segment 張分區段照）');
    if (whole > 0) will.add('幾何層（$whole 張整機照，三片剪影互比）');
    if (audio > 0) will.add('動態層（$audio 段音軌，逐片噪音與轉速）');

    if (will.isEmpty) {
      return usable == 0 && audio == 0
          ? '沒有通過拍攝品質閘門的素材，分析不會產生任何量測值。'
              '回上一步重拍——把不可信的畫面算出數字比沒有數字更糟。'
          : '目前的素材沒有對應的分析層。';
    }
    final missing = <String>[];
    if (segment == 0) missing.add('表面層要分區段照（5x 長焦）');
    if (whole == 0) missing.add('幾何層要整機照');
    if (audio == 0) missing.add('動態層要一段 15 秒以上的音軌');
    if (video > 0) {
      missing.add('影片會保存但目前解不了幀（需原生解碼），轉速改由音軌取得');
    }
    return '本次會跑：${will.join('、')}。'
        '${missing.isEmpty ? '' : '\n未涵蓋：${missing.join('；')}。沒跑不等於沒問題。'}';
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
            color: usable == 0 && (session?.usableAudioCount ?? 0) == 0
                ? Colors.orange.shade50
                : Colors.blue.shade50,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_coverageText(session)),
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
                    color: color.withValues(alpha: 0.12),
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

/// 錄音中的對話框：只顯示已錄多久，以及停止／放棄。
///
/// 錄音**在開對話框之前就開始了**（權限與編碼器的問題要直接講，不要包在一個
/// 錄音畫面裡），所以這裡不負責啟動，只負責計時與收尾。
class _RecordDialog extends StatefulWidget {
  const _RecordDialog({required this.controller});

  final BladeRecordingController controller;

  @override
  State<_RecordDialog> createState() => _RecordDialogState();
}

class _RecordDialogState extends State<_RecordDialog> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.controller.elapsed;
    final enough = widget.controller.reachedRecommended;
    final need = BladeRecordingSpec.recommendedMin.inSeconds;
    return AlertDialog(
      title: const Text('錄音中'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${e.inMinutes}:${(e.inSeconds % 60).toString().padLeft(2, '0')}',
            style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          // 不足建議長度時給的是提示不是禁止：現場可能只有那幾秒，
          // 而分析層自己會判「不可用」並說原因
          Text(
            enough
                ? '長度足夠。要更穩可以再錄久一點。'
                : '建議至少 $need 秒（要涵蓋 2–3 圈轉動才切得出三片）。',
            style: TextStyle(
              fontSize: 13,
              color: enough ? Colors.green.shade800 : Colors.orange.shade800,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '站到下風處、背對風向，手機拿穩不要遮住麥克風。'
            '錄的是整台風機的聲音，不必對著某一片。',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('放棄'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('停止並檢查'),
        ),
      ],
    );
  }
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
