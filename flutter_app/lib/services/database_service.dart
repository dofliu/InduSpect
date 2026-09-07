import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:flutter/foundation.dart';
import '../models/template_inspection_record.dart';
import '../models/photo_sync_task.dart';
import '../models/form_inspection_record.dart';
import '../models/wt_asset.dart';
import '../models/wt_capture_session.dart';
import '../models/wt_detection.dart';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'induspect_template.db');

    return await openDatabase(
      path,
      version: 5,
      onCreate: onCreate,
      onUpgrade: onUpgrade,
    );
  }

  @visibleForTesting
  Future<void> onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE template_inspection_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        record_id TEXT UNIQUE NOT NULL,
        template_id TEXT NOT NULL,
        template_name TEXT NOT NULL,
        status TEXT NOT NULL,
        filled_data TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        equipment_code TEXT,
        equipment_name TEXT,
        customer_name TEXT,
        photos_pending_upload TEXT,
        has_validation_errors INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_template_id ON template_inspection_records(template_id)
    ''');
    await db.execute('''
      CREATE INDEX idx_status ON template_inspection_records(status)
    ''');
    await db.execute('''
      CREATE INDEX idx_equipment_code ON template_inspection_records(equipment_code)
    ''');
    await db.execute('''
      CREATE INDEX idx_created_at ON template_inspection_records(created_at)
    ''');

    // Photo sync tasks table
    await db.execute('''
      CREATE TABLE photo_sync_tasks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id TEXT UNIQUE NOT NULL,
        record_id TEXT NOT NULL,
        field_id TEXT NOT NULL,
        photo_path TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        error_message TEXT,
        ai_result TEXT
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_sync_status ON photo_sync_tasks(status)
    ''');
    await db.execute('''
      CREATE INDEX idx_sync_record_id ON photo_sync_tasks(record_id)
    ''');

    // 表單檢測紀錄表（v3）
    await _createFormInspectionRecordsTable(db);
    await _createBladeTables(db);
  }

  Future<void> _createFormInspectionRecordsTable(Database db) async {
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

    await db.execute('''
      CREATE INDEX idx_form_status ON form_inspection_records(status)
    ''');
    await db.execute('''
      CREATE INDEX idx_form_created_at ON form_inspection_records(created_at)
    ''');
    await db.execute('''
      CREATE INDEX idx_form_title ON form_inspection_records(title)
    ''');
  }

  @visibleForTesting
  Future<void> onUpgrade(Database db, int oldVersion, int newVersion) async {
    debugPrint('Upgrading database from version $oldVersion to $newVersion');

    // v2: photo_sync_tasks 表
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE photo_sync_tasks (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          task_id TEXT UNIQUE NOT NULL,
          record_id TEXT NOT NULL,
          field_id TEXT NOT NULL,
          photo_path TEXT NOT NULL,
          status TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          error_message TEXT,
          ai_result TEXT
        )
      ''');

      await db.execute('''
        CREATE INDEX idx_sync_status ON photo_sync_tasks(status)
      ''');
      await db.execute('''
        CREATE INDEX idx_sync_record_id ON photo_sync_tasks(record_id)
      ''');
    }

    // v3: form_inspection_records 表
    if (oldVersion < 3) {
      await _createFormInspectionRecordsTable(db);
    }

    // v4: 法規標準判定結果持久化（Issue #44）
    // 舊使用者升級路徑：既有紀錄該欄為 NULL，model 端 _decodeJson 回空 map
    if (oldVersion < 4) {
      await db.execute(
        'ALTER TABLE form_inspection_records ADD COLUMN standard_judgments TEXT',
      );
    }

    // v5: 風力機葉片檢測（BLADE_INSPECTION_SPEC.md §7）
    // 純新增三張表，既有三張表完全不動——葉片是資產驅動、定檢是表單驅動，
    // 兩者不共用資料模型。舊使用者升級後這三張表是空的，功能自然從零開始。
    if (oldVersion < 5) {
      await _createBladeTables(db);
    }
  }

  /// 葉片檢測的三張表（v5）。資產 → 拍攝作業 → 偵測結果。
  Future<void> _createBladeTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS wt_assets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        asset_id TEXT UNIQUE NOT NULL,
        site_name TEXT,
        model TEXT,
        hub_height_m REAL,
        rotor_diameter_m REAL,
        capture_points TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS wt_capture_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT UNIQUE NOT NULL,
        asset_id TEXT NOT NULL,
        title TEXT,
        captured_at TEXT NOT NULL,
        turbine_state TEXT,
        latitude REAL,
        longitude REAL,
        weather_note TEXT,
        inspector TEXT,
        media TEXT,
        status TEXT NOT NULL,
        report_path TEXT,
        pending_share INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS wt_detections (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        detection_id TEXT UNIQUE NOT NULL,
        session_id TEXT NOT NULL,
        layer TEXT NOT NULL,
        blade TEXT,
        zone TEXT,
        defect_class TEXT,
        severity INTEGER,
        confidence REAL,
        metric_json TEXT,
        bbox_json TEXT,
        media_path TEXT,
        source TEXT NOT NULL,
        human_status TEXT NOT NULL,
        human_note TEXT,
        ai_description TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    // 查詢一律以 asset / session 為軸（列出某台風機的歷次作業、某次作業的所有發現）
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_wt_session_asset ON wt_capture_sessions(asset_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_wt_session_status ON wt_capture_sessions(status)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_wt_detection_session ON wt_detections(session_id)');
  }

  Future<int> saveRecord(TemplateInspectionRecord record) async {
    final db = await database;
    final map = record.toMap();

    if (record.id != null) {
      await db.update(
        'template_inspection_records',
        map,
        where: 'id = ?',
        whereArgs: [record.id],
      );
      return int.parse(record.id!);
    } else {
      return await db.insert(
        'template_inspection_records',
        map,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  Future<TemplateInspectionRecord?> getRecordById(String id) async {
    final db = await database;
    final results = await db.query(
      'template_inspection_records',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (results.isEmpty) return null;
    return TemplateInspectionRecord.fromMap(results.first);
  }

  Future<TemplateInspectionRecord?> getRecordByRecordId(String recordId) async {
    final db = await database;
    final results = await db.query(
      'template_inspection_records',
      where: 'record_id = ?',
      whereArgs: [recordId],
      limit: 1,
    );

    if (results.isEmpty) return null;
    return TemplateInspectionRecord.fromMap(results.first);
  }

  Future<List<TemplateInspectionRecord>> getAllRecords({
    RecordStatus? status,
    String? templateId,
    int? limit,
    int? offset,
  }) async {
    final db = await database;

    String whereClause = '';
    List<dynamic> whereArgs = [];

    if (status != null) {
      whereClause = 'status = ?';
      whereArgs.add(status.toString().split('.').last);
    }

    if (templateId != null) {
      if (whereClause.isNotEmpty) whereClause += ' AND ';
      whereClause += 'template_id = ?';
      whereArgs.add(templateId);
    }

    final results = await db.query(
      'template_inspection_records',
      where: whereClause.isEmpty ? null : whereClause,
      whereArgs: whereArgs.isEmpty ? null : whereArgs,
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );

    return results.map((map) => TemplateInspectionRecord.fromMap(map)).toList();
  }

  Future<List<TemplateInspectionRecord>> searchRecords({
    String? equipmentCode,
    String? equipmentName,
    String? customerName,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final db = await database;

    List<String> conditions = [];
    List<dynamic> args = [];

    if (equipmentCode != null && equipmentCode.isNotEmpty) {
      conditions.add('equipment_code LIKE ?');
      args.add('%$equipmentCode%');
    }

    if (equipmentName != null && equipmentName.isNotEmpty) {
      conditions.add('equipment_name LIKE ?');
      args.add('%$equipmentName%');
    }

    if (customerName != null && customerName.isNotEmpty) {
      conditions.add('customer_name LIKE ?');
      args.add('%$customerName%');
    }

    if (startDate != null) {
      conditions.add('created_at >= ?');
      args.add(startDate.toIso8601String());
    }

    if (endDate != null) {
      conditions.add('created_at <= ?');
      args.add(endDate.toIso8601String());
    }

    final whereClause = conditions.isEmpty ? null : conditions.join(' AND ');

    final results = await db.query(
      'template_inspection_records',
      where: whereClause,
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'created_at DESC',
    );

    return results.map((map) => TemplateInspectionRecord.fromMap(map)).toList();
  }

  Future<List<TemplateInspectionRecord>> getDrafts() async {
    return await getAllRecords(status: RecordStatus.draft);
  }

  Future<List<TemplateInspectionRecord>> getCompletedRecords() async {
    return await getAllRecords(status: RecordStatus.completed);
  }

  Future<List<TemplateInspectionRecord>> getRecordsNeedingSync() async {
    final db = await database;
    final results = await db.query(
      'template_inspection_records',
      where: 'status != ? OR photos_pending_upload != ?',
      whereArgs: [RecordStatus.synced.toString().split('.').last, ''],
      orderBy: 'updated_at ASC',
    );

    return results.map((map) => TemplateInspectionRecord.fromMap(map)).toList();
  }

  Future<TemplateInspectionRecord?> getLatestRecordByTemplate(String templateId) async {
    final db = await database;
    final results = await db.query(
      'template_inspection_records',
      where: 'template_id = ?',
      whereArgs: [templateId],
      orderBy: 'created_at DESC',
      limit: 1,
    );

    if (results.isEmpty) return null;
    return TemplateInspectionRecord.fromMap(results.first);
  }

  Future<TemplateInspectionRecord?> getLatestRecordByEquipment(String equipmentCode) async {
    final db = await database;
    final results = await db.query(
      'template_inspection_records',
      where: 'equipment_code = ?',
      whereArgs: [equipmentCode],
      orderBy: 'created_at DESC',
      limit: 1,
    );

    if (results.isEmpty) return null;
    return TemplateInspectionRecord.fromMap(results.first);
  }

  Future<int> deleteRecord(String id) async {
    final db = await database;
    return await db.delete(
      'template_inspection_records',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteRecordsByStatus(RecordStatus status) async {
    final db = await database;
    return await db.delete(
      'template_inspection_records',
      where: 'status = ?',
      whereArgs: [status.toString().split('.').last],
    );
  }

  Future<int> getRecordCount({RecordStatus? status}) async {
    final db = await database;

    String whereClause = '';
    List<dynamic> whereArgs = [];

    if (status != null) {
      whereClause = 'status = ?';
      whereArgs.add(status.toString().split('.').last);
    }

    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM template_inspection_records' +
      (whereClause.isEmpty ? '' : ' WHERE $whereClause'),
      whereArgs.isEmpty ? null : whereArgs,
    );

    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> clearAllRecords() async {
    final db = await database;
    await db.delete('template_inspection_records');
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
    _database = null;
  }

  // ==================== Photo Sync Task Operations ====================

  Future<int> saveSyncTask(PhotoSyncTask task) async {
    final db = await database;
    final map = task.toMap();

    if (task.id != null) {
      await db.update(
        'photo_sync_tasks',
        map,
        where: 'id = ?',
        whereArgs: [task.id],
      );
      return int.parse(task.id!);
    } else {
      return await db.insert(
        'photo_sync_tasks',
        map,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  Future<PhotoSyncTask?> getSyncTaskById(String taskId) async {
    final db = await database;
    final results = await db.query(
      'photo_sync_tasks',
      where: 'task_id = ?',
      whereArgs: [taskId],
      limit: 1,
    );

    if (results.isEmpty) return null;
    return PhotoSyncTask.fromMap(results.first);
  }

  Future<List<PhotoSyncTask>> getSyncTasksByStatus(SyncStatus status) async {
    final db = await database;
    final results = await db.query(
      'photo_sync_tasks',
      where: 'status = ?',
      whereArgs: [status.toString().split('.').last],
      orderBy: 'created_at ASC',
    );

    return results.map((map) => PhotoSyncTask.fromMap(map)).toList();
  }

  Future<List<PhotoSyncTask>> getPendingSyncTasks() async {
    return await getSyncTasksByStatus(SyncStatus.pending);
  }

  Future<List<PhotoSyncTask>> getFailedSyncTasks() async {
    return await getSyncTasksByStatus(SyncStatus.failed);
  }

  Future<List<PhotoSyncTask>> getSyncTasksByRecordId(String recordId) async {
    final db = await database;
    final results = await db.query(
      'photo_sync_tasks',
      where: 'record_id = ?',
      whereArgs: [recordId],
      orderBy: 'created_at DESC',
    );

    return results.map((map) => PhotoSyncTask.fromMap(map)).toList();
  }

  Future<void> updateSyncTaskStatus({
    required String taskId,
    required SyncStatus status,
    String? errorMessage,
    Map<String, dynamic>? aiResult,
  }) async {
    final db = await database;
    final updateData = {
      'status': status.toString().split('.').last,
      'updated_at': DateTime.now().toIso8601String(),
    };

    if (errorMessage != null) {
      updateData['error_message'] = errorMessage;
    }

    if (aiResult != null) {
      updateData['ai_result'] = aiResult.toString();
    }

    await db.update(
      'photo_sync_tasks',
      updateData,
      where: 'task_id = ?',
      whereArgs: [taskId],
    );
  }

  Future<int> deleteSyncTask(String taskId) async {
    final db = await database;
    return await db.delete(
      'photo_sync_tasks',
      where: 'task_id = ?',
      whereArgs: [taskId],
    );
  }

  Future<int> deleteCompletedSyncTasks() async {
    final db = await database;
    return await db.delete(
      'photo_sync_tasks',
      where: 'status = ?',
      whereArgs: [SyncStatus.completed.toString().split('.').last],
    );
  }

  Future<int> getSyncTaskCount({SyncStatus? status}) async {
    final db = await database;

    String whereClause = '';
    List<dynamic> whereArgs = [];

    if (status != null) {
      whereClause = 'status = ?';
      whereArgs.add(status.toString().split('.').last);
    }

    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM photo_sync_tasks' +
      (whereClause.isEmpty ? '' : ' WHERE $whereClause'),
      whereArgs.isEmpty ? null : whereArgs,
    );

    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> clearAllSyncTasks() async {
    final db = await database;
    await db.delete('photo_sync_tasks');
  }

  // ==================== Form Inspection Record Operations ====================

  /// 儲存表單檢測紀錄（新增或更新）
  ///
  /// Issue #17: 不再直接修改傳入的 record 物件，
  /// 改為在序列化後的 Map 上設定 updatedAt。
  Future<int> saveFormRecord(FormInspectionRecord record) async {
    final db = await database;
    final map = record.toMap();
    // 永遠以當前時間覆寫 updated_at，不 mutate 原物件
    map['updated_at'] = DateTime.now().toIso8601String();

    if (record.id != null) {
      await db.update(
        'form_inspection_records',
        map,
        where: 'id = ?',
        whereArgs: [record.id],
      );
      return record.id!;
    } else {
      return await db.insert(
        'form_inspection_records',
        map,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  /// 依 recordId 查詢
  Future<FormInspectionRecord?> getFormRecordByRecordId(String recordId) async {
    final db = await database;
    final results = await db.query(
      'form_inspection_records',
      where: 'record_id = ?',
      whereArgs: [recordId],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return FormInspectionRecord.fromMap(results.first);
  }

  /// 取得所有表單檢測紀錄
  Future<List<FormInspectionRecord>> getAllFormRecords({
    FormRecordStatus? status,
    int? limit,
    int? offset,
  }) async {
    final db = await database;

    String? where;
    List<dynamic>? whereArgs;

    if (status != null) {
      where = 'status = ?';
      whereArgs = [status.name];
    }

    final results = await db.query(
      'form_inspection_records',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );

    return results.map((m) => FormInspectionRecord.fromMap(m)).toList();
  }

  /// 搜尋表單檢測紀錄（標題、檔名、地點）
  Future<List<FormInspectionRecord>> searchFormRecords(String query) async {
    final db = await database;
    final pattern = '%$query%';

    final results = await db.query(
      'form_inspection_records',
      where: 'title LIKE ? OR source_file_name LIKE ? OR location_name LIKE ?',
      whereArgs: [pattern, pattern, pattern],
      orderBy: 'created_at DESC',
    );

    return results.map((m) => FormInspectionRecord.fromMap(m)).toList();
  }

  /// 更新紀錄標題
  Future<void> updateFormRecordTitle(String recordId, String newTitle) async {
    final db = await database;
    await db.update(
      'form_inspection_records',
      {
        'title': newTitle,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'record_id = ?',
      whereArgs: [recordId],
    );
  }

  /// 取得待分享的紀錄
  Future<List<FormInspectionRecord>> getFormRecordsPendingShare() async {
    final db = await database;
    final results = await db.query(
      'form_inspection_records',
      where: 'pending_share = 1',
      orderBy: 'updated_at ASC',
    );
    return results.map((m) => FormInspectionRecord.fromMap(m)).toList();
  }

  /// 標記分享完成
  Future<void> markFormShareComplete(String recordId) async {
    final db = await database;
    await db.update(
      'form_inspection_records',
      {
        'pending_share': 0,
        'status': FormRecordStatus.shared.name,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'record_id = ?',
      whereArgs: [recordId],
    );
  }

  /// 刪除表單檢測紀錄
  Future<int> deleteFormRecord(String recordId) async {
    final db = await database;
    return await db.delete(
      'form_inspection_records',
      where: 'record_id = ?',
      whereArgs: [recordId],
    );
  }

  /// 取得表單檢測紀錄數量
  Future<int> getFormRecordCount({FormRecordStatus? status}) async {
    final db = await database;
    String sql = 'SELECT COUNT(*) as count FROM form_inspection_records';
    List<dynamic>? args;

    if (status != null) {
      sql += ' WHERE status = ?';
      args = [status.name];
    }

    final result = await db.rawQuery(sql, args);
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// 清除所有表單檢測紀錄
  Future<void> clearAllFormRecords() async {
    final db = await database;
    await db.delete('form_inspection_records');
  }

  // ─────────────────────────── 葉片檢測（v5）───────────────────────────

  /// 新增或更新風機資產。`asset_id` 是現場編號、UNIQUE，所以用 replace
  /// ——同一台風機重複建立時視為更新，不會長出兩筆。
  Future<int> saveWtAsset(WtAsset asset) async {
    final db = await database;
    final map = asset.toMap();
    if (asset.id != null) {
      await db.update('wt_assets', map, where: 'id = ?', whereArgs: [asset.id]);
      return asset.id!;
    }
    return db.insert('wt_assets', map,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<WtAsset?> getWtAsset(String assetId) async {
    final db = await database;
    final rows = await db.query('wt_assets',
        where: 'asset_id = ?', whereArgs: [assetId], limit: 1);
    return rows.isEmpty ? null : WtAsset.fromMap(rows.first);
  }

  Future<List<WtAsset>> getAllWtAssets() async {
    final db = await database;
    final rows = await db.query('wt_assets', orderBy: 'asset_id ASC');
    return rows.map(WtAsset.fromMap).toList();
  }

  /// 刪除資產時連帶刪掉它的作業與偵測結果。
  /// SQLite 的外鍵預設不啟用，所以手動級聯——留下孤兒作業比刪掉更糟，
  /// 那些作業在 UI 上會找不到所屬資產而永遠顯示不出來。
  Future<void> deleteWtAsset(String assetId) async {
    final db = await database;
    final sessions = await db.query('wt_capture_sessions',
        columns: ['session_id'], where: 'asset_id = ?', whereArgs: [assetId]);
    await db.transaction((txn) async {
      for (final row in sessions) {
        await txn.delete('wt_detections',
            where: 'session_id = ?', whereArgs: [row['session_id']]);
      }
      await txn
          .delete('wt_capture_sessions', where: 'asset_id = ?', whereArgs: [assetId]);
      await txn.delete('wt_assets', where: 'asset_id = ?', whereArgs: [assetId]);
    });
  }

  /// 新增或更新拍攝作業。永遠以當前時間覆寫 `updated_at`，不 mutate 傳入物件
  /// （同 `saveFormRecord`，Issue #17 的教訓）。
  Future<int> saveWtSession(WtCaptureSession session) async {
    final db = await database;
    final map = session.toMap();
    map['updated_at'] = DateTime.now().toIso8601String();
    if (session.id != null) {
      await db.update('wt_capture_sessions', map,
          where: 'id = ?', whereArgs: [session.id]);
      return session.id!;
    }
    return db.insert('wt_capture_sessions', map,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<WtCaptureSession?> getWtSession(String sessionId) async {
    final db = await database;
    final rows = await db.query('wt_capture_sessions',
        where: 'session_id = ?', whereArgs: [sessionId], limit: 1);
    return rows.isEmpty ? null : WtCaptureSession.fromMap(rows.first);
  }

  /// 列出拍攝作業。給 assetId 就只列該台風機的歷次作業（跨次比對用）。
  Future<List<WtCaptureSession>> getWtSessions({
    String? assetId,
    WtSessionStatus? status,
    int? limit,
  }) async {
    final db = await database;
    final where = <String>[];
    final args = <dynamic>[];
    if (assetId != null) {
      where.add('asset_id = ?');
      args.add(assetId);
    }
    if (status != null) {
      where.add('status = ?');
      args.add(status.name);
    }
    final rows = await db.query(
      'wt_capture_sessions',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'captured_at DESC',
      limit: limit,
    );
    return rows.map(WtCaptureSession.fromMap).toList();
  }

  Future<List<WtCaptureSession>> getWtSessionsPendingShare() async {
    final db = await database;
    final rows = await db.query('wt_capture_sessions',
        where: 'pending_share = 1', orderBy: 'updated_at ASC');
    return rows.map(WtCaptureSession.fromMap).toList();
  }

  Future<void> deleteWtSession(String sessionId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn
          .delete('wt_detections', where: 'session_id = ?', whereArgs: [sessionId]);
      await txn.delete('wt_capture_sessions',
          where: 'session_id = ?', whereArgs: [sessionId]);
    });
  }

  /// 寫入一批偵測結果。一次分析會產生多筆，用 transaction 避免中途失敗留下半套。
  Future<void> saveWtDetections(List<WtDetection> detections) async {
    if (detections.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      for (final d in detections) {
        await txn.insert('wt_detections', d.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  /// 更新單筆偵測的人工確認狀態。這是稽核依據，只改人工欄位，不動演算法數值。
  Future<void> updateWtDetectionHumanStatus(
    String detectionId,
    WtHumanStatus status, {
    String? note,
  }) async {
    final db = await database;
    await db.update(
      'wt_detections',
      {'human_status': status.name, if (note != null) 'human_note': note},
      where: 'detection_id = ?',
      whereArgs: [detectionId],
    );
  }

  Future<List<WtDetection>> getWtDetections(String sessionId, {WtLayer? layer}) async {
    final db = await database;
    final where = <String>['session_id = ?'];
    final args = <dynamic>[sessionId];
    if (layer != null) {
      where.add('layer = ?');
      args.add(layer.name);
    }
    final rows = await db.query('wt_detections',
        where: where.join(' AND '), whereArgs: args, orderBy: 'created_at ASC');
    return rows.map(WtDetection.fromMap).toList();
  }

  /// 替換某次作業某一層的偵測結果（重新分析時用）。
  /// 只刪演算法產出的那一層，**保留其他層與人工已確認的紀錄**——
  /// 重跑幾何層不該把表面層的人工簽核一起清掉。
  Future<void> replaceWtDetections(
    String sessionId,
    WtLayer layer,
    List<WtDetection> detections,
  ) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'wt_detections',
        where: 'session_id = ? AND layer = ? AND human_status = ?',
        whereArgs: [sessionId, layer.name, WtHumanStatus.pending.name],
      );
      for (final d in detections) {
        await txn.insert('wt_detections', d.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }
}
