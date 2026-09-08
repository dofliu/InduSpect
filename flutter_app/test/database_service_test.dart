import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:induspect_ai/models/form_inspection_record.dart';
import 'package:induspect_ai/services/database_service.dart';

// 直接操作 DB 測試 CRUD，不透過 singleton 避免與其他測試衝突
Future<Database> _createTestDb() async {
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;
  final db = await factory.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 1,
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
        await db.execute(
            'CREATE INDEX idx_form_status ON form_inspection_records(status)');
        await db.execute(
            'CREATE INDEX idx_form_title ON form_inspection_records(title)');
      },
    ),
  );
  return db;
}

/// 簡易 CRUD helper（模擬 DatabaseService 的邏輯）
Future<int> insertRecord(Database db, FormInspectionRecord record) async {
  record.updatedAt = DateTime.now();
  return await db.insert(
    'form_inspection_records',
    record.toMap(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}

Future<FormInspectionRecord?> getByRecordId(Database db, String recordId) async {
  final results = await db.query(
    'form_inspection_records',
    where: 'record_id = ?',
    whereArgs: [recordId],
    limit: 1,
  );
  if (results.isEmpty) return null;
  return FormInspectionRecord.fromMap(results.first);
}

Future<List<FormInspectionRecord>> getAll(Database db, {int? limit}) async {
  final results = await db.query(
    'form_inspection_records',
    orderBy: 'created_at DESC',
    limit: limit,
  );
  return results.map((m) => FormInspectionRecord.fromMap(m)).toList();
}

Future<List<FormInspectionRecord>> search(Database db, String query) async {
  final pattern = '%$query%';
  final results = await db.query(
    'form_inspection_records',
    where: 'title LIKE ? OR source_file_name LIKE ? OR location_name LIKE ?',
    whereArgs: [pattern, pattern, pattern],
    orderBy: 'created_at DESC',
  );
  return results.map((m) => FormInspectionRecord.fromMap(m)).toList();
}

void main() {
  late Database db;

  setUp(() async {
    db = await _createTestDb();
  });

  tearDown(() async {
    await db.close();
  });

  group('Form Inspection Record CRUD', () {
    test('insert 並 read back 一筆紀錄', () async {
      final record = FormInspectionRecord(
        recordId: 'crud-001',
        title: '變壓器檢測',
        sourceFileName: 'transformer.xlsx',
        filledData: {'f1': '合格'},
        status: FormRecordStatus.draft,
        latitude: 24.15,
        longitude: 120.67,
        locationName: '台中市',
      );

      final id = await insertRecord(db, record);
      expect(id, greaterThan(0));

      final fetched = await getByRecordId(db, 'crud-001');
      expect(fetched, isNotNull);
      expect(fetched!.title, '變壓器檢測');
      expect(fetched.filledData['f1'], '合格');
      expect(fetched.latitude, 24.15);
      expect(fetched.locationName, '台中市');
      expect(fetched.status, FormRecordStatus.draft);
    });

    test('update 既有紀錄', () async {
      final record = FormInspectionRecord(
        recordId: 'crud-002',
        title: '初始標題',
        filledData: {},
      );
      await insertRecord(db, record);

      // 讀回取得 id
      final saved = await getByRecordId(db, 'crud-002');
      final updated = saved!.copyWith(
        title: '修改後標題',
        status: FormRecordStatus.completed,
      );

      // 使用 replace 模式更新
      await db.update(
        'form_inspection_records',
        updated.toMap(),
        where: 'id = ?',
        whereArgs: [saved.id],
      );

      final result = await getByRecordId(db, 'crud-002');
      expect(result!.title, '修改後標題');
      expect(result.status, FormRecordStatus.completed);
    });

    test('delete 紀錄', () async {
      await insertRecord(db, FormInspectionRecord(
        recordId: 'crud-del',
        title: 'To Delete',
        filledData: {},
      ));

      final count = await db.delete(
        'form_inspection_records',
        where: 'record_id = ?',
        whereArgs: ['crud-del'],
      );
      expect(count, 1);

      final result = await getByRecordId(db, 'crud-del');
      expect(result, isNull);
    });

    test('getAll 按 created_at DESC 排序', () async {
      await insertRecord(db, FormInspectionRecord(
        recordId: 'a',
        title: 'First',
        filledData: {},
        createdAt: DateTime(2026, 1, 1),
      ));
      await insertRecord(db, FormInspectionRecord(
        recordId: 'b',
        title: 'Second',
        filledData: {},
        createdAt: DateTime(2026, 4, 12),
      ));
      await insertRecord(db, FormInspectionRecord(
        recordId: 'c',
        title: 'Third',
        filledData: {},
        createdAt: DateTime(2026, 2, 15),
      ));

      final all = await getAll(db);
      expect(all.length, 3);
      // 最新的在前
      expect(all[0].recordId, 'b');
      expect(all[1].recordId, 'c');
      expect(all[2].recordId, 'a');
    });

    test('getAll 支援 limit', () async {
      for (int i = 0; i < 5; i++) {
        await insertRecord(db, FormInspectionRecord(
          recordId: 'limit-$i',
          title: 'Record $i',
          filledData: {},
        ));
      }

      final limited = await getAll(db, limit: 3);
      expect(limited.length, 3);
    });

    test('search 搜尋 title', () async {
      await insertRecord(db, FormInspectionRecord(
        recordId: 's1',
        title: '變壓器定期檢測報告',
        filledData: {},
      ));
      await insertRecord(db, FormInspectionRecord(
        recordId: 's2',
        title: '馬達絕緣測試',
        filledData: {},
      ));

      final results = await search(db, '變壓器');
      expect(results.length, 1);
      expect(results[0].recordId, 's1');
    });

    test('search 搜尋 locationName', () async {
      await insertRecord(db, FormInspectionRecord(
        recordId: 'loc1',
        title: 'A',
        filledData: {},
        locationName: '台中市太平區',
      ));
      await insertRecord(db, FormInspectionRecord(
        recordId: 'loc2',
        title: 'B',
        filledData: {},
        locationName: '台北市大安區',
      ));

      final results = await search(db, '太平');
      expect(results.length, 1);
      expect(results[0].recordId, 'loc1');
    });

    test('pending_share 查詢', () async {
      await insertRecord(db, FormInspectionRecord(
        recordId: 'ps1',
        title: 'Not Pending',
        filledData: {},
        pendingShare: false,
      ));
      await insertRecord(db, FormInspectionRecord(
        recordId: 'ps2',
        title: 'Pending',
        filledData: {},
        pendingShare: true,
      ));

      final pending = await db.query(
        'form_inspection_records',
        where: 'pending_share = 1',
      );
      expect(pending.length, 1);
      final r = FormInspectionRecord.fromMap(pending.first);
      expect(r.recordId, 'ps2');
    });

    test('record_id UNIQUE 約束生效', () async {
      await insertRecord(db, FormInspectionRecord(
        recordId: 'dup-1',
        title: 'First',
        filledData: {},
      ));

      // ConflictAlgorithm.replace 會覆蓋
      await insertRecord(db, FormInspectionRecord(
        recordId: 'dup-1',
        title: 'Replaced',
        filledData: {},
      ));

      final all = await getAll(db);
      expect(all.length, 1);
      expect(all[0].title, 'Replaced');
    });

    test('clearAll 清空所有紀錄', () async {
      for (int i = 0; i < 3; i++) {
        await insertRecord(db, FormInspectionRecord(
          recordId: 'clr-$i',
          title: 'Record $i',
          filledData: {},
        ));
      }

      await db.delete('form_inspection_records');
      final all = await getAll(db);
      expect(all, isEmpty);
    });
  });

  group('GPS 資料持久化', () {
    test('GPS 座標正確儲存與讀取', () async {
      await insertRecord(db, FormInspectionRecord(
        recordId: 'gps-1',
        title: 'GPS Test',
        filledData: {},
        latitude: 24.147731,
        longitude: 120.673648,
        locationName: '台中市太平區 中山路四段',
      ));

      final r = await getByRecordId(db, 'gps-1');
      expect(r!.latitude, closeTo(24.147731, 0.0001));
      expect(r.longitude, closeTo(120.673648, 0.0001));
      expect(r.locationName, contains('太平區'));
    });

    test('GPS 為 null 時不影響其他欄位', () async {
      await insertRecord(db, FormInspectionRecord(
        recordId: 'no-gps',
        title: 'No GPS',
        filledData: {'f1': '正常'},
      ));

      final r = await getByRecordId(db, 'no-gps');
      expect(r!.latitude, isNull);
      expect(r.longitude, isNull);
      expect(r.locationName, isNull);
      expect(r.filledData['f1'], '正常');
    });
  });
  group('分頁載入（Issue #43：大量歷史紀錄）', () {
    late Database db;
    late DatabaseService svc;

    setUp(() async {
      db = await _createTestDb();
      svc = DatabaseService();
      svc.attachDatabaseForTesting(db);
      addTearDown(() async {
        svc.attachDatabaseForTesting(null);
        await db.close();
      });
      // 建 25 筆，created_at 遞減，好驗排序與翻頁邊界
      for (var i = 0; i < 25; i++) {
        await insertRecord(
            db,
            FormInspectionRecord(
              recordId: 'rec-${i.toString().padLeft(2, '0')}',
              title: i % 2 == 0 ? '變電站 $i' : '空壓機 $i',
              locationName: '台中',
              filledData: {'f1': '正常'},
              createdAt: DateTime(2026, 1, 1).add(Duration(minutes: i)),
            ));
      }
    });

    test('limit 限制筆數，offset 接得上，且不重疊不漏', () async {
      final p1 = await svc.getAllFormRecords(limit: 10, offset: 0);
      final p2 = await svc.getAllFormRecords(limit: 10, offset: 10);
      final p3 = await svc.getAllFormRecords(limit: 10, offset: 20);
      expect(p1.length, 10);
      expect(p2.length, 10);
      expect(p3.length, 5, reason: '最後一頁不足一頁');

      final ids = [...p1, ...p2, ...p3].map((r) => r.recordId).toList();
      expect(ids.toSet().length, 25, reason: '不能有重複');
      expect(ids.length, 25, reason: '不能漏');
    });

    test('排序是 created_at DESC，翻頁不會打亂', () async {
      final p1 = await svc.getAllFormRecords(limit: 10, offset: 0);
      final p2 = await svc.getAllFormRecords(limit: 10, offset: 10);
      final all = [...p1, ...p2];
      for (var i = 1; i < all.length; i++) {
        expect(all[i].createdAt.isAfter(all[i - 1].createdAt), isFalse,
            reason: '第 $i 筆應該不比前一筆新');
      }
      expect(p1.first.recordId, 'rec-24', reason: '最新的在最前面');
    });

    test('超出總數的 offset 回空清單，不丟例外', () async {
      expect(await svc.getAllFormRecords(limit: 10, offset: 100), isEmpty);
    });

    test('不給 limit 時仍回全部（既有呼叫端的行為不變）', () async {
      expect((await svc.getAllFormRecords()).length, 25);
    });

    test('搜尋也支援分頁——搜到很多筆時一次全載一樣會卡', () async {
      final hits = await svc.searchFormRecords('變電站');
      expect(hits.length, 13, reason: '0,2,4..24 共 13 筆');

      final p1 = await svc.searchFormRecords('變電站', limit: 5, offset: 0);
      final p2 = await svc.searchFormRecords('變電站', limit: 5, offset: 5);
      final p3 = await svc.searchFormRecords('變電站', limit: 5, offset: 10);
      expect([p1.length, p2.length, p3.length], [5, 5, 3]);
      expect([...p1, ...p2, ...p3].map((r) => r.recordId).toSet().length, 13);
    });

    test('搜尋的分頁與排序一致（不會因為翻頁而錯位）', () async {
      final full = await svc.searchFormRecords('空壓機');
      final paged = <FormInspectionRecord>[];
      for (var off = 0; off < full.length; off += 4) {
        paged.addAll(
            await svc.searchFormRecords('空壓機', limit: 4, offset: off));
      }
      expect(paged.map((r) => r.recordId).toList(),
          full.map((r) => r.recordId).toList());
    });
  });
}
