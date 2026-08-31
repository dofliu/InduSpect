import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/models/form_inspection_record.dart';

void main() {
  group('FormInspectionRecord', () {
    late FormInspectionRecord record;

    setUp(() {
      record = FormInspectionRecord(
        id: 1,
        recordId: 'test-uuid-123',
        title: '變壓器定檢 - 04/12 14:30',
        sourceFileName: 'transformer_check.xlsx',
        templateJson: '{"sections":[]}',
        filledData: {'field_1': '正常', 'field_2': '42.5'},
        aiResults: {
          'field_1': {'is_anomaly': false, 'condition_assessment': '正常'},
          'field_2': {'is_anomaly': true, 'anomaly_description': '溫度過高'},
        },
        summaryReport: '本次檢測共 2 項，1 項異常。',
        filledDocumentPath: '/tmp/filled_transformer_check.xlsx',
        status: FormRecordStatus.exported,
        latitude: 24.1477,
        longitude: 120.6736,
        locationName: '台中市 太平區 中山路',
        photoPaths: ['/photos/a.jpg', '/photos/b.jpg'],
        createdAt: DateTime(2026, 4, 12, 14, 30),
        updatedAt: DateTime(2026, 4, 12, 15, 0),
        pendingShare: false,
      );
    });

    // ========== toMap / fromMap 往返測試 ==========

    test('toMap 輸出所有必要欄位', () {
      final map = record.toMap();

      expect(map['id'], 1);
      expect(map['record_id'], 'test-uuid-123');
      expect(map['title'], '變壓器定檢 - 04/12 14:30');
      expect(map['source_file_name'], 'transformer_check.xlsx');
      expect(map['status'], 'exported');
      expect(map['latitude'], 24.1477);
      expect(map['longitude'], 120.6736);
      expect(map['location_name'], '台中市 太平區 中山路');
      expect(map['pending_share'], 0);
    });

    test('toMap 將 filledData 和 aiResults 序列化為 JSON 字串', () {
      final map = record.toMap();

      expect(map['filled_data'], isA<String>());
      expect(map['ai_results'], isA<String>());

      final decoded = jsonDecode(map['filled_data'] as String);
      expect(decoded['field_1'], '正常');
    });

    test('toMap 將 photoPaths 序列化為 JSON array', () {
      final map = record.toMap();
      final paths = map['photo_paths'] as String;

      // 應為 JSON array 格式
      final decoded = jsonDecode(paths);
      expect(decoded, isA<List>());
      expect(decoded.length, 2);
      expect(decoded[0], '/photos/a.jpg');
    });

    test('fromMap → toMap 往返一致', () {
      final map1 = record.toMap();
      final restored = FormInspectionRecord.fromMap(map1);
      final map2 = restored.toMap();

      // 核心欄位一致
      expect(map2['record_id'], map1['record_id']);
      expect(map2['title'], map1['title']);
      expect(map2['status'], map1['status']);
      expect(map2['latitude'], map1['latitude']);
      expect(map2['longitude'], map1['longitude']);
      expect(map2['pending_share'], map1['pending_share']);

      // JSON 結構一致
      expect(jsonDecode(map2['filled_data'] as String),
          jsonDecode(map1['filled_data'] as String));
      expect(jsonDecode(map2['ai_results'] as String),
          jsonDecode(map1['ai_results'] as String));
    });

    test('fromMap 處理 null / 空值不 crash', () {
      final minimal = FormInspectionRecord.fromMap({
        'record_id': 'min-id',
        'title': 'Minimal',
        'filled_data': '',
        'ai_results': null,
        'status': 'draft',
        'created_at': '2026-04-12T14:00:00',
        'updated_at': '2026-04-12T14:00:00',
      });

      expect(minimal.recordId, 'min-id');
      expect(minimal.filledData, isEmpty);
      expect(minimal.aiResults, isEmpty);
      expect(minimal.photoPaths, isEmpty);
      expect(minimal.status, FormRecordStatus.draft);
    });

    test('fromMap 處理無效 status 回退為 draft', () {
      final r = FormInspectionRecord.fromMap({
        'record_id': 'bad-status',
        'title': 'Bad',
        'filled_data': '{}',
        'status': 'nonexistent_status',
        'created_at': '2026-04-12T14:00:00',
        'updated_at': '2026-04-12T14:00:00',
      });

      expect(r.status, FormRecordStatus.draft);
    });

    // ========== photoPaths 向後相容測試 ==========

    test('fromMap 解析舊格式 ||| 分隔的 photoPaths', () {
      final r = FormInspectionRecord.fromMap({
        'record_id': 'legacy',
        'title': 'Legacy',
        'filled_data': '{}',
        'status': 'draft',
        'photo_paths': '/old/a.jpg|||/old/b.jpg|||/old/c.jpg',
        'created_at': '2026-04-12T14:00:00',
        'updated_at': '2026-04-12T14:00:00',
      });

      expect(r.photoPaths.length, 3);
      expect(r.photoPaths[0], '/old/a.jpg');
    });

    test('fromMap 解析新格式 JSON array 的 photoPaths', () {
      final r = FormInspectionRecord.fromMap({
        'record_id': 'new-fmt',
        'title': 'New',
        'filled_data': '{}',
        'status': 'draft',
        'photo_paths': '["C:\\\\photos\\\\a.jpg","C:\\\\photos\\\\b.jpg"]',
        'created_at': '2026-04-12T14:00:00',
        'updated_at': '2026-04-12T14:00:00',
      });

      expect(r.photoPaths.length, 2);
      expect(r.photoPaths[0], r'C:\photos\a.jpg');
    });

    test('fromMap 空 photoPaths 回傳空 list', () {
      final r = FormInspectionRecord.fromMap({
        'record_id': 'empty',
        'title': 'Empty',
        'filled_data': '{}',
        'status': 'draft',
        'photo_paths': '',
        'created_at': '2026-04-12T14:00:00',
        'updated_at': '2026-04-12T14:00:00',
      });

      expect(r.photoPaths, isEmpty);
    });

    // ========== computed getters 測試 ==========

    test('anomalyCount 正確計算異常數', () {
      expect(record.anomalyCount, 1);
    });

    test('anomalyCount 空 aiResults 回傳 0', () {
      final empty = FormInspectionRecord(
        recordId: 'e',
        title: 'Empty',
      );
      expect(empty.anomalyCount, 0);
    });

    test('completedCount 等於 filledData 長度', () {
      expect(record.completedCount, 2);
    });

    // ========== copyWith 測試 ==========

    test('copyWith 只改變指定欄位', () {
      final updated = record.copyWith(
        title: '新標題',
        status: FormRecordStatus.shared,
        pendingShare: true,
      );

      expect(updated.title, '新標題');
      expect(updated.status, FormRecordStatus.shared);
      expect(updated.pendingShare, true);
      // 其餘不變
      expect(updated.recordId, record.recordId);
      expect(updated.latitude, record.latitude);
      expect(updated.filledData['field_1'], '正常');
    });

    test('copyWith 深拷貝 Map 和 List', () {
      final copy = record.copyWith();

      // 修改原始不影響副本
      record.filledData['field_1'] = '修改';
      expect(copy.filledData['field_1'], '正常');
    });

    // ========== 預設值測試 ==========

    test('預設值正確：status=draft, pendingShare=false, 空 maps', () {
      final r = FormInspectionRecord(
        recordId: 'default-test',
        title: 'Default',
      );

      expect(r.status, FormRecordStatus.draft);
      expect(r.pendingShare, false);
      expect(r.filledData, isEmpty);
      expect(r.aiResults, isEmpty);
      expect(r.photoPaths, isEmpty);
      expect(r.id, isNull);
    });

    // ========== 日期解析邊界測試 ==========

    test('fromMap 處理無效日期字串回退為 now', () {
      final r = FormInspectionRecord.fromMap({
        'record_id': 'bad-date',
        'title': 'Bad Date',
        'filled_data': '{}',
        'status': 'draft',
        'created_at': 'not-a-date',
        'updated_at': '',
      });

      // 應不 crash，回退為 DateTime.now()（近似判斷）
      expect(r.createdAt.year, DateTime.now().year);
    });
  });

  group('FormRecordStatus', () {
    test('所有狀態的 .name 可被解析回來', () {
      for (final status in FormRecordStatus.values) {
        final parsed = FormRecordStatus.values.firstWhere(
          (s) => s.name == status.name,
        );
        expect(parsed, status);
      }
    });
  });

  // ========== 法規標準判定持久化（Issue #44，SQLite v4） ==========

  group('standardJudgments 持久化', () {
    final judgment = {
      'judgment': 'fail',
      'standard_text': '>= 1.0 MΩ',
      'regulation': '屋內線路裝置規則',
      'measured_value': 500,
      'unit': 'kΩ',
      'converted_value': 0.5,
      'converted_unit': 'MΩ',
    };

    test('toMap/fromMap 往返保留判定內容', () {
      final r = FormInspectionRecord(
        recordId: 'judg-1',
        title: '判定測試',
        standardJudgments: {'f1': judgment},
      );

      final restored = FormInspectionRecord.fromMap(r.toMap());
      expect(restored.standardJudgments['f1']['judgment'], 'fail');
      expect(restored.standardJudgments['f1']['regulation'], '屋內線路裝置規則');
      expect(restored.standardJudgments['f1']['converted_value'], 0.5);
    });

    test('fromMap 對 v3 舊紀錄（無 standard_judgments 欄）回空 map', () {
      final r = FormInspectionRecord.fromMap({
        'record_id': 'legacy-v3',
        'title': '舊紀錄',
        'filled_data': '{}',
        'status': 'draft',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });

      expect(r.standardJudgments, isEmpty);
      expect(r.failCount, 0);
      expect(r.warningCount, 0);
    });

    test('copyWith 未指定時深拷貝、指定時取代', () {
      final r = FormInspectionRecord(
        recordId: 'judg-2',
        title: '判定測試',
        standardJudgments: {'f1': judgment},
      );

      final copy = r.copyWith();
      expect(copy.standardJudgments['f1']['judgment'], 'fail');
      // 深拷貝：改副本的 map 不影響原本
      copy.standardJudgments['f2'] = {'judgment': 'pass'};
      expect(r.standardJudgments.containsKey('f2'), false);

      final replaced = r.copyWith(standardJudgments: {'x': {'judgment': 'pass'}});
      expect(replaced.standardJudgments.containsKey('f1'), false);
      expect(replaced.standardJudgments['x']['judgment'], 'pass');
    });

    test('failCount / warningCount 統計正確', () {
      final r = FormInspectionRecord(
        recordId: 'judg-3',
        title: '統計測試',
        standardJudgments: {
          'f1': {'judgment': 'fail'},
          'f2': {'judgment': 'warning'},
          'f3': {'judgment': 'pass'},
          'f4': {'judgment': 'fail'},
        },
      );

      expect(r.failCount, 2);
      expect(r.warningCount, 1);
    });
  });
}
