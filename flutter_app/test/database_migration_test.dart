import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:induspect_ai/models/form_inspection_record.dart';
import 'package:induspect_ai/services/database_service.dart';

/// SQLite v3 → v4 migration 測試（Issue #44：法規判定持久化）
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
}
