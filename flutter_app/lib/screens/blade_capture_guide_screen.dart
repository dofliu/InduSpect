import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/wt_asset.dart';
import '../models/wt_capture_session.dart';
import '../services/blade_capture_gate.dart';
import '../services/image_quality_service.dart';
import '../services/location_service.dart';

/// 一個拍攝格位。畫面就是一張「還沒拍 / 已拍」的清單。
class BladeShot {
  final String id;
  final WtMediaView view;
  final String title;
  final String instruction;

  /// 建議的光學倍率。1.0 = 主鏡頭、5.0 = 長焦。**只是提示**，
  /// 實際倍率由操作者在系統相機裡選（見下方 `_pickPhoto` 的說明）。
  final double zoomHint;

  /// 對應資產上的拍攝點名稱（'front' / 'side'），有記錄就能導引回同一個位置
  final String? capturePointName;

  final bool isRequired;

  String? blade; // 'A' | 'B' | 'C'
  String? zone; // 'root' | 'mid' | 'tip'
  String? leadingEdge; // 'top' | 'bottom'
  WtMedia? media;
  BladeCaptureVerdict? verdict;

  BladeShot({
    required this.id,
    required this.view,
    required this.title,
    required this.instruction,
    this.zoomHint = 1.0,
    this.capturePointName,
    this.isRequired = false,
    this.blade,
    this.zone,
    this.leadingEdge,
  });

  bool get done => media != null;

  /// 分區段照沒指定前緣在畫面哪一側就算不出前後緣比（唯一可靠的侵蝕判據），
  /// 所以那一項是必填。
  bool get needsLeadingEdge =>
      view == WtMediaView.segment && leadingEdge == null;
}

/// 引導拍攝畫面（規格 §3.2 / §8）。
///
/// **用系統相機（`image_picker`）而不是 App 內的即時預覽**，是刻意的取捨：
/// 規格 §3.1/§5.2 的整套物理前提建立在「主鏡頭最高像素模式 + 5x 光學長焦」上，
/// 而 Flutter `camera` plugin 只拿得到邏輯相機，鏡頭切換（5x 望遠）與最高像素
/// 模式都碰不到——`ResolutionPreset.max` 給的是支援的預設值，不是感光元件全解析度。
/// 用 App 內預覽就能疊即時輪廓線，但會失去這次量測賴以成立的解析度與焦段。
/// 所以「取景重複性」改用另一種方式達成：**拍照前先看上次同一格位的照片**，
/// 加上 GPS 導回同一個拍攝點。
///
/// 照片一律**原尺寸保存**，不走 `PhotoService.compressPhoto`
/// （那條路會降到 1280×960，等於把 4.8 cm/px 的量測前提丟掉）。
class BladeCaptureGuideScreen extends StatefulWidget {
  final WtAsset asset;
  final String sessionId;

  /// 上次到場的同一資產場次。有的話每個格位會顯示上次的照片當取景參考。
  final WtCaptureSession? previousSession;

  /// 已經拍過的（回頭補拍時帶進來）
  final List<WtMedia> existing;

  const BladeCaptureGuideScreen({
    super.key,
    required this.asset,
    required this.sessionId,
    this.previousSession,
    this.existing = const [],
  });

  @override
  State<BladeCaptureGuideScreen> createState() =>
      _BladeCaptureGuideScreenState();
}

class _BladeCaptureGuideScreenState extends State<BladeCaptureGuideScreen> {
  final ImagePicker _picker = ImagePicker();
  final List<BladeShot> _shots = [];
  LocationData? _here;
  bool _busy = false;

  static const _zoneNames = {'root': '根部段', 'mid': '中段', 'tip': '葉尖段'};

  @override
  void initState() {
    super.initState();
    _shots.addAll(_defaultPlan());
    _restoreExisting();
    _refreshLocation();
  }

  /// 預設格位：全機兩張（正視 / 側視）+ 一片葉片的三個區段。
  ///
  /// 只排一片是因為現場的實情：高倍率分區段照要葉片在**六點鐘**位置才拍得到，
  /// 停機時只有一片朝下。要拍另外兩片得等轉子轉過去——所以其餘葉片用
  /// 「再加一組」按鈕按需新增，而不是先排九個永遠填不滿的空格。
  List<BladeShot> _defaultPlan() => [
        BladeShot(
          id: 'front',
          view: WtMediaView.front,
          title: '正視全機',
          instruction: '站在轉子正面，三片葉片都在畫面內，'
              '背對太陽（逆光是硬限制，事後無法補救）。'
              '天空越乾淨越好，有大片雲塊時換角度或等雲走。',
          capturePointName: 'front',
          isRequired: true,
        ),
        BladeShot(
          id: 'side',
          view: WtMediaView.side,
          title: '側視全機',
          instruction: '走到轉子側面（與正視方向約 90°），整支塔架與轉子都在畫面內。'
              '這張用來看葉尖有沒有異常前後偏擺。',
          capturePointName: 'side',
          isRequired: true,
        ),
        ..._segmentShots('A'),
      ];

  List<BladeShot> _segmentShots(String blade) => [
        for (final zone in const ['root', 'mid', 'tip'])
          BladeShot(
            id: 'seg-$blade-$zone',
            view: WtMediaView.segment,
            title: '葉片 $blade · ${_zoneNames[zone]}',
            instruction: '把葉片轉到六點鐘（朝下）位置，用 5x 長焦拍這一段，'
                '讓葉片橫越畫面、上下都留天空。'
                '同一片的三段接起來要涵蓋整支葉片。',
            zoomHint: 5.0,
            blade: blade,
            zone: zone,
          ),
      ];

  void _restoreExisting() {
    for (final m in widget.existing) {
      final shot = _shots.firstWhere(
        (s) => _matches(s, m),
        orElse: () => BladeShot(
          id: 'extra-${m.path.hashCode}',
          view: m.view,
          title: '補充照片',
          instruction: '不在預設格位裡的照片',
          blade: m.bladePosition,
          zone: m.zone,
          leadingEdge: m.leadingEdge,
        ),
      );
      shot.media = m;
      if (!_shots.contains(shot)) _shots.add(shot);
    }
  }

  bool _matches(BladeShot s, WtMedia m) =>
      s.view == m.view && s.blade == m.bladePosition && s.zone == m.zone;

  Future<void> _refreshLocation() async {
    final here = await LocationService().getCurrentPosition();
    if (mounted) setState(() => _here = here);
  }

  /// 到拍攝點的距離（m）。沒有其中一邊的座標就回 null——**不猜**。
  double? _distanceTo(String? pointName) {
    if (pointName == null || _here == null) return null;
    final point = widget.asset.capturePoint(pointName);
    if (point == null || !point.hasLocation) return null;
    return Geolocator.distanceBetween(
      _here!.latitude,
      _here!.longitude,
      point.latitude!,
      point.longitude!,
    );
  }

  WtMedia? _previousFor(BladeShot shot) {
    final prev = widget.previousSession;
    if (prev == null) return null;
    for (final m in prev.media) {
      if (_matches(shot, m)) return m;
    }
    return null;
  }

  Future<void> _pickPhoto(BladeShot shot) async {
    if (shot.needsLeadingEdge) {
      _toast('請先指定前緣在畫面的哪一側，否則這張算不出前後緣比');
      return;
    }
    // maxWidth/maxHeight 一律不給：任何縮放都會直接吃掉量測解析度。
    final XFile? file = await _picker.pickImage(source: ImageSource.camera);
    if (file == null) return;

    setState(() => _busy = true);
    try {
      // 只有全機照（正視／側視）有固定站位需要記位置；分區段照跟著葉片走，不取。
      // GPS 與存檔／品質判定並行等，不把 10 秒的定位逾時串在後面。
      final Future<LocationData?>? hereF = shot.capturePointName == null
          ? null
          : LocationService().getCurrentPosition();
      final saved = await _saveOriginal(file, shot);
      final report = await ImageQualityService.assess(await saved.readAsBytes());
      final verdict = BladeCaptureGate.judge(report);
      final here = hereF == null ? null : await hereF;
      final media = WtMedia(
        path: saved.path,
        view: shot.view,
        zoom: shot.zoomHint,
        bladePosition: shot.blade,
        zone: shot.zone,
        leadingEdge: shot.leadingEdge,
        qualityJson: verdict.toJson(),
        // 這張的位置，之後由 blade_inspection_screen 寫進資產的拍攝點
        latitude: here?.latitude,
        longitude: here?.longitude,
      );
      if (!mounted) return;
      setState(() {
        shot.media = media;
        shot.verdict = verdict;
        if (here != null) _here = here;
      });
      if (!verdict.ok) await _showBlockedDialog(shot, verdict);
    } catch (e) {
      if (mounted) _toast('存檔失敗：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 原尺寸複製到 App 目錄。`image_picker` 給的是系統快取檔，會被清掉。
  Future<File> _saveOriginal(XFile file, BladeShot shot) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'blade_photos', widget.sessionId));
    if (!await dir.exists()) await dir.create(recursive: true);
    final ext = p.extension(file.path).isEmpty ? '.jpg' : p.extension(file.path);
    final target = File(p.join(dir.path, '${shot.id}$ext'));
    return File(file.path).copy(target.path);
  }

  Future<void> _showBlockedDialog(
      BladeShot shot, BladeCaptureVerdict verdict) async {
    final retake = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('這張照片不能用於量測'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ...verdict.blockers.map((b) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('• $b'),
                )),
            const SizedBox(height: 4),
            const Text(
              '照片會保留，但不會拿去分析——把不可信的畫面算出數字比沒有數字更糟。',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('先保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('重拍'),
          ),
        ],
      ),
    );
    if (retake == true) await _pickPhoto(shot);
  }

  void _addBladeSet() {
    final used = _shots
        .where((s) => s.view == WtMediaView.segment)
        .map((s) => s.blade)
        .whereType<String>()
        .toSet();
    final next = ['A', 'B', 'C'].where((b) => !used.contains(b)).toList();
    if (next.isEmpty) {
      _toast('三片都已排入格位了');
      return;
    }
    setState(() => _shots.addAll(_segmentShots(next.first)));
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  List<WtMedia> get _captured =>
      _shots.map((s) => s.media).whereType<WtMedia>().toList();

  @override
  Widget build(BuildContext context) {
    final usable = _captured.where((m) => m.qualityOk == true).length;
    final missing = _shots.where((s) => s.isRequired && !s.done).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('引導拍攝'),
        actions: [
          TextButton(
            onPressed: _captured.isEmpty
                ? null
                : () => Navigator.pop(context, _captured),
            child: Text('完成（${_captured.length}）'),
          ),
        ],
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _summaryCard(usable, missing),
              const SizedBox(height: 12),
              ..._shots.map(_shotCard),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _addBladeSet,
                icon: const Icon(Icons.add),
                label: const Text('再加一片葉片的三個區段'),
              ),
              const SizedBox(height: 32),
            ],
          ),
          // Positioned.fill：Stack 裡未定位的子元件拿到的是寬鬆約束，
          // 不加這層遮罩只會有指示器大小，蓋不住畫面
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

  Widget _summaryCard(int usable, int missing) => Card(
        color: Colors.blue.shade50,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${widget.asset.assetId}'
                  '${widget.asset.siteName.isEmpty ? '' : ' · ${widget.asset.siteName}'}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text('已拍 ${_captured.length} 張，其中 $usable 張可用於量測'
                  '${missing > 0 ? '；還缺 $missing 張必拍' : ''}'),
              const SizedBox(height: 6),
              const Text(
                '拍攝重點：背對太陽、天空乾淨、分區段照用 5x 長焦讓葉片橫越畫面。',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ),
        ),
      );

  Widget _shotCard(BladeShot shot) {
    final dist = _distanceTo(shot.capturePointName);
    final prev = _previousFor(shot);
    final verdict = shot.verdict;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  shot.done ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: shot.done
                      ? (shot.media?.qualityOk == true
                          ? Colors.green
                          : Colors.orange)
                      : Colors.grey,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(shot.title,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                if (shot.zoomHint > 1.0)
                  Chip(
                    label: Text('${shot.zoomHint.toStringAsFixed(0)}x 長焦'),
                    visualDensity: VisualDensity.compact,
                  ),
                if (shot.isRequired && !shot.done)
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Text('必拍',
                        style: TextStyle(fontSize: 11, color: Colors.red)),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(shot.instruction,
                style: const TextStyle(fontSize: 12, color: Colors.black87)),
            if (dist != null) ...[
              const SizedBox(height: 6),
              Text(
                dist < 15
                    ? '已在上次的拍攝點附近（相距 ${dist.toStringAsFixed(0)} m）'
                    : '距上次拍攝點 ${dist.toStringAsFixed(0)} m — 走回同一個位置，'
                        '兩次比對才有意義',
                style: TextStyle(
                  fontSize: 12,
                  color: dist < 15 ? Colors.green.shade700 : Colors.orange.shade800,
                ),
              ),
            ],
            if (shot.view == WtMediaView.segment) _leadingEdgePicker(shot),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (prev != null) _thumb(prev.path, '上次'),
                if (shot.media != null) _thumb(shot.media!.path, '這次'),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : () => _pickPhoto(shot),
                      icon: Icon(shot.done ? Icons.refresh : Icons.camera_alt),
                      label: Text(shot.done ? '重拍' : '拍照'),
                    ),
                  ),
                ),
              ],
            ),
            if (verdict != null) ...[
              const SizedBox(height: 6),
              ...verdict.blockers.map((b) => Text('✕ $b',
                  style: const TextStyle(fontSize: 12, color: Colors.red))),
              ...verdict.advisories.map((a) => Text('△ $a',
                  style:
                      TextStyle(fontSize: 12, color: Colors.orange.shade800))),
              if (verdict.ok && verdict.advisories.isEmpty)
                const Text('✓ 可用於量測',
                    style: TextStyle(fontSize: 12, color: Colors.green)),
            ],
          ],
        ),
      ),
    );
  }

  /// 前緣在畫面哪一側只有拍攝者知道（葉片轉到六點鐘時前緣朝哪要看轉向與槳距），
  /// 演算法猜不出來，所以在這裡問。
  Widget _leadingEdgePicker(BladeShot shot) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: [
            const Text('前緣在畫面：', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 8),
            ChoiceChip(
              label: const Text('上緣'),
              selected: shot.leadingEdge == 'top',
              onSelected: (_) => setState(() => shot.leadingEdge = 'top'),
            ),
            const SizedBox(width: 6),
            ChoiceChip(
              label: const Text('下緣'),
              selected: shot.leadingEdge == 'bottom',
              onSelected: (_) => setState(() => shot.leadingEdge = 'bottom'),
            ),
          ],
        ),
      );

  Widget _thumb(String path, String label) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Column(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.file(
                File(path),
                width: 64,
                height: 64,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  width: 64,
                  height: 64,
                  color: Colors.grey.shade300,
                  child: const Icon(Icons.broken_image, size: 20),
                ),
              ),
            ),
            Text(label, style: const TextStyle(fontSize: 10)),
          ],
        ),
      );
}
