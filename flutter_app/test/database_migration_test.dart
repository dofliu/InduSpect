import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:induspect_ai/models/form_inspection_record.dart';
import 'package:induspect_ai/models/wt_asset.dart';
import 'package:induspect_ai/models/wt_capture_session.dart';
import 'package:induspect_ai/models/wt_detection.dart';
import 'package:induspect_ai/services/database_service.dart';

/// SQLite migration 測試：v3 → v4（Issue #44 法規判定持久化）與 v4 → v5（葉片檢測三張表）
///
/// 以「歷史 v3 schema 快照」建庫（migration 測試必須固定舊 schema，
/// 不可由現行程式碼生成），再以 DatabaseService 真實的 onUpgrade 升級，
/// 驗證既有使用者的升級路徑。
void main() {
  late String dbPath;
  late Directory tmpDir;

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('induspect_db_test');
    dbPath = '${tmpDir.path}/migration_test.db';
  });

  tearDown(() async {
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  /// 歷史 v3 schema 快照（2026-04 時期，無 standard_judgments 欄）
  Future<Database> openV3(String path) {
    return databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE form_inspection_records (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              record_id TEXT UNIQUE NOT NULL,
              title TEXT NOT NULL,
              source_file_name TEXT,
              template_json TEXT,
              filled_data TEXT NOT NULL,
              ai_results TEXT,
              summary_report TEXT,
              filled_document_path TEXT,
              status TEXT NOT NULL,
              latitude REAL,
              longitude REAL,
              location_name TEXT,
              photo_paths TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              pending_share INTEGER DEFAULT 0
            )
          ''');
        },
      ),
    );
  }

  test('v3 → v4 升級：新增 standard_judgments 欄位，舊紀錄可讀且判定為空', () async {
    // 1. 建立 v3 資料庫並塞入一筆舊紀錄
    final v3 = await openV3(dbPath);
    await v3.insert('form_inspection_records', {
      'record_id': 'legacy-1',
      'title': '升級前的舊紀錄',
      'filled_data': '{"f1":"ok"}',
      'ai_results': '{}',
      'status': 'completed',
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await v3.close();

    // 2. 以 DatabaseService 真實 migration 邏輯升級到 v4
    final svc = DatabaseService();
    final v4 = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 4,
        onCreate: svc.onCreate,
        onUpgrade: svc.onUpgrade,
      ),
    );

    // 3. 欄位存在
    final cols = await v4.rawQuery('PRAGMA table_info(form_inspection_records)');
    expect(cols.map((c) => c['name']), contains('standard_judgments'));

    // 4. 舊紀錄可正常讀取，判定為空（不 crash）
    final rows = await v4.query('form_inspection_records',
        where: 'record_id = ?', whereArgs: ['legacy-1']);
    expect(rows.length, 1);
    final legacy = FormInspectionRecord.fromMap(rows.first);
    expect(legacy.title, '升級前的舊紀錄');
    expect(legacy.standardJudgments, isEmpty);

    // 5. 升級後可寫入並讀回帶判定的新紀錄
    final newRecord = FormInspectionRecord(
      recordId: 'post-upgrade-1',
      title: '升級後的新紀錄',
      standardJudgments: {
        'f1': {
          'judgment': 'fail',
          'standard_text': '>= 1.0 MΩ',
          'regulation': '屋內線路裝置規則',
        },
      },
    );
    await v4.insert('form_inspection_records', newRecord.toMap());
    final newRows = await v4.query('form_inspection_records',
        where: 'record_id = ?', whereArgs: ['post-upgrade-1']);
    final restored = FormInspectionRecord.fromMap(newRows.first);
    expect(restored.standardJudgments['f1']['judgment'], 'fail');
    expect(restored.failCount, 1);

    await v4.close();
  });

  test('全新安裝（v4 onCreate）即包含 standard_judgments 欄位', () async {
    final svc = DatabaseService();
    final db = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 4,
        onCreate: svc.onCreate,
        onUpgrade: svc.onUpgrade,
      ),
    );

    final cols = await db.rawQuery('PRAGMA table_info(form_inspection_records)');
    expect(cols.map((c) => c['name']), contains('standard_judgments'));

    // round-trip
    final record = FormInspectionRecord(
      recordId: 'fresh-1',
      title: '全新安裝',
      standardJudgments: {
        'f1': {'judgment': 'warning', 'standard_text': '<= 30 mA'},
      },
    );
    await db.insert('form_inspection_records', record.toMap());
    final rows = await db.query('form_inspection_records');
    final restored = FormInspectionRecord.fromMap(rows.first);
    expect(restored.warningCount, 1);

    await db.close();
  });
  // ───────────────────── v4 → v5：葉片檢測三張表 ─────────────────────

  /// 歷史 v4 schema 快照（2026-08 時期，只有定檢的三張表）。
  /// migration 測試必須固定舊 schema，不可由現行程式碼生成。
  Future<Database> openV4Snapshot(String path) {
    return databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 4,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE form_inspection_records (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              record_id TEXT UNIQUE NOT NULL,
              title TEXT NOT NULL,
              source_file_name TEXT,
              template_json TEXT,
              filled_data TEXT NOT NULL,
              ai_results TEXT,
              standard_judgments TEXT,
              summary_report TEXT,
              filled_document_path TEXT,
              status TEXT NOT NULL,
              latitude REAL,
              longitude REAL,
              location_name TEXT,
              photo_paths TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              pending_share INTEGER DEFAULT 0
            )
          ''');
        },
      ),
    );
  }

  Future<Database> openWithService(String path, int version) {
    final svc = DatabaseService();
    return databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: version,
        onCreate: svc.onCreate,
        onUpgrade: svc.onUpgrade,
      ),
    );
  }

  test('v4 → v5 升級：新增葉片三張表，既有定檢紀錄完全不受影響', () async {
    final v4 = await openV4Snapshot(dbPath);
    await v4.insert('form_inspection_records', {
      'record_id': 'legacy-form-1',
      'title': '升級前的定檢紀錄',
      'filled_data': '{"f1":"ok"}',
      'standard_judgments': '{"f1":{"judgment":"pass"}}',
      'status': 'completed',
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await v4.close();

    final v5 = await openWithService(dbPath, 5);

    // 三張新表都在
    final tables = (await v5.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table'"))
        .map((r) => r['name'])
        .toList();
    expect(tables, containsAll(['wt_assets', 'wt_capture_sessions', 'wt_detections']));

    // 既有定檢紀錄一字未動——葉片是資產驅動、獨立建表，不該碰到定檢的資料
    final rows = await v5.query('form_inspection_records',
        where: 'record_id = ?', whereArgs: ['legacy-form-1']);
    expect(rows.length, 1);
    final legacy = FormInspectionRecord.fromMap(rows.first);
    expect(legacy.title, '升級前的定檢紀錄');
    expect(legacy.standardJudgments['f1']['judgment'], 'pass');

    await v5.close();
  });

  test('全新安裝（v5 onCreate）即包含葉片三張表與定檢三張表', () async {
    final db = await openWithService(dbPath, 5);
    final tables = (await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table'"))
        .map((r) => r['name'])
        .toList();
    expect(
        tables,
        containsAll([
          'template_inspection_records',
          'photo_sync_tasks',
          'form_inspection_records',
          'wt_assets',
          'wt_capture_sessions',
          'wt_detections',
        ]));
    await db.close();
  });

  test('葉片資料 round-trip：資產 → 作業 → 偵測，JSON 欄位不失真', () async {
    final db = await openWithService(dbPath, 5);

    final asset = WtAsset(
      assetId: 'WTG-07',
      siteName: '彰濱風場',
      model: 'V150-4.2',
      hubHeightM: 105,
      rotorDiameterM: 150,
      capturePoints: const [
        WtCapturePoint(
            name: 'front', latitude: 24.1, longitude: 120.4, headingDeg: 315),
        WtCapturePoint(name: 'side', latitude: 24.101, longitude: 120.402),
      ],
    );
    await db.insert('wt_assets', asset.toMap());
    final aRows = await db.query('wt_assets', where: 'asset_id = ?', whereArgs: ['WTG-07']);
    final a = WtAsset.fromMap(aRows.first);
    expect(a.siteName, '彰濱風場');
    expect(a.rotorRadiusM, 75.0);
    expect(a.capturePoints.length, 2);
    expect(a.capturePoint('front')!.headingDeg, 315);
    expect(a.capturePoint('side')!.hasLocation, isTrue);
    expect(a.capturePoint('nope'), isNull);

    final session = WtCaptureSession(
      sessionId: 'sess-1',
      assetId: 'WTG-07',
      title: 'WTG-07 2026-09-20',
      turbineState: WtTurbineState.stopped,
      inspector: '王大明',
      media: [
        WtMedia(
          path: '/tmp/seg1.jpg',
          view: WtMediaView.segment,
          zoom: 5.0,
          bladePosition: 'A',
          zone: 'mid',
          leadingEdge: 'top',
          qualityJson: const {'ok': true, 'sharpness': 142.0},
        ),
        WtMedia(path: '/tmp/front.jpg', view: WtMediaView.front, zoom: 1.0),
      ],
    );
    await db.insert('wt_capture_sessions', session.toMap());
    final sRows = await db
        .query('wt_capture_sessions', where: 'session_id = ?', whereArgs: ['sess-1']);
    final s = WtCaptureSession.fromMap(sRows.first);
    expect(s.turbineState, WtTurbineState.stopped);
    expect(s.media.length, 2);
    expect(s.media.first.zone, 'mid');
    expect(s.media.first.qualityOk, isTrue);
    expect(s.media.last.qualityOk, isNull, reason: '尚未分析 → 不可當成合格');
    expect(s.usableMediaCount, 1);
    expect(s.mediaOfView(WtMediaView.front).length, 1);

    final detection = WtDetection(
      detectionId: 'det-1',
      sessionId: 'sess-1',
      layer: WtLayer.surface,
      blade: 'A',
      zone: 'mid_LE',
      defectClass: 'leading_edge_erosion',
      severity: 3,
      confidence: 0.71,
      metricJson: const {'le_over_te_rms_ratio': 5.2, 'inward_p95_px': 1.5},
      bboxJson: const {'x': 10, 'y': 20, 'w': 300, 'h': 40},
      mediaPath: '/tmp/seg1.jpg',
    );
    await db.insert('wt_detections', detection.toMap());
    final dRows =
        await db.query('wt_detections', where: 'detection_id = ?', whereArgs: ['det-1']);
    final d = WtDetection.fromMap(dRows.first);
    expect(d.layer, WtLayer.surface);
    expect(d.metricJson['le_over_te_rms_ratio'], 5.2);
    expect(d.bboxJson['w'], 300);
    expect(d.source, WtDetectionSource.algorithm);
    expect(d.needsConfirmation, isTrue, reason: '演算法初判必須待人工確認');

    await db.close();
  });

  test('壞掉的 JSON 欄位不會讓整筆紀錄讀不出來', () async {
    // 既有 model 的慣例：解析失敗回空集合，紀錄本身還在
    final asset = WtAsset.fromMap({
      'asset_id': 'WTG-BAD',
      'capture_points': '{不是合法 JSON',
      'created_at': 'not-a-date',
    });
    expect(asset.assetId, 'WTG-BAD');
    expect(asset.capturePoints, isEmpty);

    final session = WtCaptureSession.fromMap({
      'session_id': 'sess-bad',
      'asset_id': 'WTG-BAD',
      'media': '[[[',
      'status': '不存在的狀態',
      'captured_at': '',
      'updated_at': '',
    });
    expect(session.media, isEmpty);
    expect(session.status, WtSessionStatus.draft, reason: '未知 enum 值退回預設');

    final det = WtDetection.fromMap({
      'detection_id': 'det-bad',
      'session_id': 'sess-bad',
      'layer': 'surface',
      'source': 'algorithm',
      'human_status': 'pending',
      'metric_json': 'null',
      'bbox_json': '',
      'created_at': '',
    });
    expect(det.metricJson, isEmpty);
    expect(det.bboxJson, isEmpty);
  });

  test('音軌媒體不需要 migration：JSON 往返得回來，舊列也照樣讀', () {
    final session = WtCaptureSession(
      sessionId: 'sess-audio',
      assetId: 'WTG-01',
      media: [
        WtMedia(path: '/tmp/seg.jpg', qualityJson: const {'ok': true}),
        WtMedia(
            path: '/tmp/rec.wav',
            kind: WtMediaKind.audio,
            view: WtMediaView.other,
            qualityJson: const {'ok': true, 'duration_s': 18.0}),
        WtMedia(path: '/tmp/clip.mp4', kind: WtMediaKind.video),
      ],
    );
    final back = WtCaptureSession.fromMap(session.toMap());
    expect(back.media.map((m) => m.kind).toList(),
        [WtMediaKind.photo, WtMediaKind.audio, WtMediaKind.video]);
    expect(back.audioCount, 1);
    expect(back.photoCount, 1);
    expect(back.usableAudioCount, 1);
    expect(back.usableMediaCount, 1,
        reason: '「幾張可用於量測」只算照片——音軌不是「張」也不走同一組閘門');

    // 舊列（kind 只有 photo/video）照樣讀得起來，這是不需要 migration 的理由
    final legacy = WtMedia.fromJson(const {'path': '/tmp/a.jpg', 'kind': 'photo'});
    expect(legacy.kind, WtMediaKind.photo);
    // 認不出的值退回預設，不會丟例外
    final unknown = WtMedia.fromJson(const {'path': '/tmp/a', 'kind': 'hologram'});
    expect(unknown.kind, WtMediaKind.photo);
  });

  test('重新分析會清掉整個場次的待確認偵測，但不動人已簽核的', () async {
    final db = await openWithService(dbPath, 5);
    final svc = DatabaseService();
    svc.attachDatabaseForTesting(db);
    // singleton 的狀態會外洩到其他測試，所以一定要卸下；
    // 也要先關掉 DB，否則外層 tearDown 刪暫存目錄時檔案還開著
    addTearDown(() async {
      svc.attachDatabaseForTesting(null);
      await db.close();
    });
    WtDetection det(String id, WtLayer layer, WtHumanStatus status) =>
        WtDetection(
          detectionId: id,
          sessionId: 'sess-1',
          layer: layer,
          severity: 2,
          humanStatus: status,
        );

    // 第一輪：三層各一筆待確認 + 一筆人工已確認
    await svc.replaceWtDetections('sess-1', [
      det('a', WtLayer.surface, WtHumanStatus.pending),
      det('b', WtLayer.geometry, WtHumanStatus.pending),
      det('c', WtLayer.dynamic_, WtHumanStatus.pending),
      det('d', WtLayer.geometry, WtHumanStatus.confirmed),
    ]);
    expect((await svc.getWtDetections('sess-1')).length, 4);

    // 第二輪只剩表面層有發現。**其他層的舊待確認必須消失**——
    // 上一輪標記過、這一輪不再標記的發現留在報告上，是憑空多出來的「異常」。
    await svc.replaceWtDetections(
        'sess-1', [det('a', WtLayer.surface, WtHumanStatus.pending)]);
    final after = await svc.getWtDetections('sess-1');
    expect(after.map((d) => d.detectionId).toSet(), {'a', 'd'});
    expect(
        after.firstWhere((d) => d.detectionId == 'd').humanStatus,
        WtHumanStatus.confirmed,
        reason: '人已簽核的不能被重新分析吃掉——那等於推翻簽核');
  });
}
