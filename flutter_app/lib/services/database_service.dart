import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:flutter/foundation.dart';
import '../models/template_inspection_record.dart';
import '../models/photo_sync_task.dart';

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
      version: 2,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
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
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    debugPrint('Upgrading database from version $oldVersion to $newVersion');

    // Add photo_sync_tasks table for version 2
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
}
