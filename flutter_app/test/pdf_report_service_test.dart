import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show ByteData, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:induspect_ai/models/form_inspection_record.dart';
import 'package:induspect_ai/services/pdf_report_service.dart';

/// PDF 報告產生器測試（LAUNCH_PLAN 第 5-8 週「PDF 報告輸出」）
///
/// 驗證重點：
/// - 產出為合法 PDF（標頭、頁數、字型內嵌）
/// - 從 SQLite 紀錄重建報告資料（模板順序、判定優先序、值格式化）
/// - 照片附件：載入失敗容錯、關閉照片時不嵌圖
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ByteData fontData;

  setUpAll(() async {
    fontData = await rootBundle.load(PdfReportService.fontAsset);
  });

  /// 統計 PDF 內的頁物件數（`/Type /Page` 不含 `/Pages`）
  int countPages(Uint8List bytes) {
    final text = latin1.decode(bytes, allowInvalid: true);
    return RegExp(r'/Type\s*/Page(?![s])').allMatches(text).length;
  }

  /// PDF 內是否含影像物件（`/ProcSet` 的 `/ImageB` 不算）
  bool hasImage(Uint8List bytes) =>
      RegExp(r'/Subtype\s*/Image').hasMatch(latin1.decode(bytes, allowInvalid: true));

  /// 產生一張小 JPEG 測試圖
  Uint8List fakeJpeg({int w = 64, int h = 48}) {
    final image = img.Image(width: w, height: h);
    img.fill(image, color: img.ColorRgb8(200, 120, 40));
    return Uint8List.fromList(img.encodeJpg(image));
  }

  PdfReportData sampleData({List<PdfReportItem>? items, List<String> extraPhotos = const []}) {
    return PdfReportData(
      title: 'A 廠區 高壓盤定檢',
      sourceFileName: '高壓盤定檢表.xlsx',
      inspectionDate: DateTime(2026, 9, 2, 10, 30),
      locationName: '新北市土城區某某路 1 號',
      latitude: 24.97,
      longitude: 121.44,
      recordId: 'rec-001',
      items: items ??
          const [
            PdfReportItem(
              fieldId: 'f1',
              label: '絕緣電阻 R相',
              value: '500 kΩ',
              verdict: '不合格',
              standardBasis: '標準 ≥1.0 MΩ（屋內線路裝置規則）',
              conversionNote: '換算: 500kΩ → 0.5MΩ',
              photoPath: '/photos/f1.jpg',
            ),
            PdfReportItem(fieldId: 'f2', label: '接地電阻', value: '8 Ω', verdict: '合格'),
            PdfReportItem(fieldId: 'f3', label: '外觀檢查', value: '異常: 端子鏽蝕', verdict: '不合格',
                anomalyDescription: '端子有明顯鏽蝕'),
            PdfReportItem(fieldId: 'f4', label: '溫度', value: '62 °C', verdict: '警告'),
            PdfReportItem(fieldId: 'f5', label: '備註', verdict: '未檢測'),
          ],
      summaryReport: '## 總結\n**整體狀況**：1 項不合格需立即處理。\n\n建議更換 R 相絕緣。',
      extraPhotoPaths: extraPhotos,
    );
  }

  group('PdfReportService.build', () {
    test('產出合法 PDF：標頭、至少一頁、內嵌 TrueType 字型', () async {
      final bytes = await PdfReportService.build(
        sampleData(),
        fontData: fontData,
        photoLoader: (_) async => fakeJpeg(),
      );

      expect(bytes.length, greaterThan(1000));
      expect(latin1.decode(bytes.sublist(0, 5)), '%PDF-');
      expect(countPages(bytes), greaterThanOrEqualTo(2)); // 主文 + 照片附件頁
      final text = latin1.decode(bytes, allowInvalid: true);
      expect(text, contains('/FontFile2')); // TrueType 子集已嵌入
      expect(hasImage(bytes), isTrue); // 照片已嵌入
    });

    test('includePhotos=false 不嵌任何圖片、不呼叫 loader', () async {
      var loaderCalls = 0;
      final bytes = await PdfReportService.build(
        sampleData(),
        includePhotos: false,
        fontData: fontData,
        photoLoader: (_) async {
          loaderCalls++;
          return fakeJpeg();
        },
      );

      expect(loaderCalls, 0);
      expect(hasImage(bytes), isFalse);
      // 含照片版本多一頁附件
      final withPhotos = await PdfReportService.build(
        sampleData(),
        fontData: fontData,
        photoLoader: (_) async => fakeJpeg(),
      );
      expect(countPages(bytes), lessThan(countPages(withPhotos)));
    });

    test('照片載入失敗（回傳 null）時略過該照片，仍能產生報告', () async {
      final bytes = await PdfReportService.build(
        sampleData(extraPhotos: ['/missing/a.jpg', '/missing/b.jpg']),
        fontData: fontData,
        photoLoader: (_) async => null,
      );

      expect(latin1.decode(bytes.sublist(0, 5)), '%PDF-');
      expect(hasImage(bytes), isFalse);
    });

    test('重複照片路徑只嵌入一次', () async {
      final seen = <String>[];
      await PdfReportService.build(
        sampleData(extraPhotos: ['/photos/f1.jpg', '/photos/x.jpg', '/photos/x.jpg']),
        fontData: fontData,
        photoLoader: (path) async {
          seen.add(path);
          return fakeJpeg();
        },
      );
      expect(seen, ['/photos/f1.jpg', '/photos/x.jpg']);
    });

    test('大量項目（120 項）可跨頁產出', () async {
      final items = List.generate(
        120,
        (i) => PdfReportItem(
          fieldId: 'f$i',
          label: '檢測項目 $i',
          value: '${i * 1.5} MΩ',
          verdict: i % 7 == 0 ? '不合格' : '合格',
          standardBasis: '標準 ≥1.0 MΩ（屋內線路裝置規則）',
        ),
      );
      final bytes = await PdfReportService.build(
        sampleData(items: items),
        includePhotos: false,
        fontData: fontData,
      );
      expect(countPages(bytes), greaterThanOrEqualTo(3));
    });

    test('空項目清單、無報告文字也能產出', () async {
      final bytes = await PdfReportService.build(
        PdfReportData(title: '空白', inspectionDate: DateTime(2026, 1, 1), items: const []),
        includePhotos: false,
        fontData: fontData,
      );
      expect(latin1.decode(bytes.sublist(0, 5)), '%PDF-');
      expect(countPages(bytes), 1);
    });
  });

  group('PdfReportService.suggestedFileName', () {
    test('以來源檔名為主、去副檔名、附日期', () {
      expect(PdfReportService.suggestedFileName(sampleData()), '高壓盤定檢表_report_20260902.pdf');
    });

    test('無來源檔名時使用標題並清理非法字元', () {
      final data = PdfReportData(
        title: 'A 廠區/高壓盤:定檢',
        inspectionDate: DateTime(2026, 9, 2),
        items: const [],
      );
      expect(PdfReportService.suggestedFileName(data), 'A_廠區_高壓盤_定檢_report_20260902.pdf');
    });
  });

  group('PdfReportData.fromRecord', () {
    final templateJson = jsonEncode({
      'template_id': 't1',
      'template_name': '高壓盤定檢',
      'sections': [
        {
          'section_id': 's1',
          'section_title': '電氣',
          'fields': [
            {'field_id': 'r', 'label': '絕緣電阻 R相', 'field_type': 'measurement'},
            {'field_id': 'photo', 'label': '現場照片', 'field_type': 'photo'},
            {'field_id': 'sig', 'label': '簽名', 'field_type': 'signature'},
            {'field_id': 'judge', 'label': '總判定', 'field_type': 'radio'},
            {'field_id': 'note', 'label': '備註', 'field_type': 'text'},
            {'field_id': 'look', 'label': '外觀', 'field_type': 'text'},
          ],
        },
      ],
    });

    FormInspectionRecord makeRecord() => FormInspectionRecord(
          recordId: 'rec-9',
          title: '測試紀錄',
          sourceFileName: 'form.xlsx',
          templateJson: templateJson,
          filledData: {'r': '500', 'judge': 'fail', 'note': '手動備註', 'extra': '模板外欄位'},
          aiResults: {
            'r': {'is_anomaly': false, 'condition_assessment': '讀值清楚'},
            'look': {'is_anomaly': true, 'anomaly_description': '端子鏽蝕'},
          },
          standardJudgments: {
            'r': {
              'judgment': 'fail',
              'standard_text': '≥1.0 MΩ',
              'regulation': '屋內線路裝置規則',
              'measured_value': 500,
              'unit': 'kΩ',
              'converted_value': 0.5,
              'converted_unit': 'MΩ',
            },
          },
          summaryReport: '摘要',
          latitude: 25.0,
          longitude: 121.5,
          locationName: '台北',
          photoPaths: ['/p/1.jpg', '/p/2.jpg'],
          createdAt: DateTime(2026, 9, 1, 9),
        );

    test('依模板順序建立項目，跳過照片/簽名欄位，模板外欄位補列於末尾', () {
      final data = PdfReportData.fromRecord(makeRecord());
      expect(data.items.map((i) => i.fieldId).toList(), ['r', 'judge', 'note', 'look', 'extra']);
      expect(data.items.map((i) => i.label).toList(), ['絕緣電阻 R相', '總判定', '備註', '外觀', 'extra']);
    });

    test('判定優先序：法規判定 > AI 異常 > 手動填寫 > 未檢測', () {
      final data = PdfReportData.fromRecord(makeRecord());
      final byId = {for (final i in data.items) i.fieldId: i};
      expect(byId['r']!.verdict, '不合格'); // 法規 fail 蓋過 AI 正常
      expect(byId['look']!.verdict, '不合格'); // AI 異常
      expect(byId['judge']!.verdict, '已填寫');
      expect(byId['note']!.verdict, '已填寫');
      expect(data.failCount, 2);
      expect(data.completedCount, 5);
    });

    test('值格式化：量測值補單位、radio pass/fail 轉中文、AI 狀況評估補位', () {
      final data = PdfReportData.fromRecord(makeRecord());
      final byId = {for (final i in data.items) i.fieldId: i};
      expect(byId['r']!.value, '500 kΩ');
      expect(byId['judge']!.value, '不合格');
      expect(byId['look']!.value, isNull); // 無 condition_assessment、非數值
      expect(byId['look']!.anomalyDescription, '端子鏽蝕');
      expect(byId['r']!.standardBasis, '標準 ≥1.0 MΩ（屋內線路裝置規則）');
      expect(byId['r']!.conversionNote, '換算: 500kΩ → 0.5MΩ');
    });

    test('基本資料與照片清單帶入', () {
      final data = PdfReportData.fromRecord(makeRecord());
      expect(data.title, '測試紀錄');
      expect(data.sourceFileName, 'form.xlsx');
      expect(data.inspectionDate, DateTime(2026, 9, 1, 9));
      expect(data.locationName, '台北');
      expect(data.latitude, 25.0);
      expect(data.recordId, 'rec-9');
      expect(data.summaryReport, '摘要');
      expect(data.extraPhotoPaths, ['/p/1.jpg', '/p/2.jpg']);
    });

    test('無模板（舊紀錄）時以 fieldId 作標籤，不會拋例外', () {
      final record = FormInspectionRecord(
        recordId: 'old',
        title: '舊紀錄',
        filledData: {'a': 'x'},
        aiResults: {'b': {'is_anomaly': false}},
      );
      final data = PdfReportData.fromRecord(record);
      expect(data.items.map((i) => i.label).toList(), ['a', 'b']);
      expect(data.items[1].verdict, '合格');
    });

    test('template_json 損毀時退回 fieldId 標籤', () {
      final record = FormInspectionRecord(
        recordId: 'bad',
        title: '壞模板',
        templateJson: '{not json',
        filledData: {'a': '1'},
      );
      expect(PdfReportData.fromRecord(record).items.single.label, 'a');
    });

    test('從紀錄重建的資料可實際產出 PDF', () async {
      final bytes = await PdfReportService.build(
        PdfReportData.fromRecord(makeRecord()),
        fontData: fontData,
        photoLoader: (_) async => fakeJpeg(),
      );
      expect(latin1.decode(bytes.sublist(0, 5)), '%PDF-');
      expect(countPages(bytes), greaterThanOrEqualTo(2));
    });
  });

  group('PdfReportData 靜態工具', () {
    test('resolveVerdict 各分支', () {
      expect(PdfReportData.resolveVerdict(judgment: {'judgment': 'pass'}), '合格');
      expect(PdfReportData.resolveVerdict(judgment: {'judgment': 'warning'}), '警告');
      expect(PdfReportData.resolveVerdict(judgment: {'judgment': 'unknown'}, aiResult: {'is_anomaly': true}),
          '不合格');
      expect(PdfReportData.resolveVerdict(value: ''), '未檢測');
      expect(PdfReportData.resolveVerdict(value: 'ok'), '已填寫');
      expect(PdfReportData.resolveVerdict(), '未檢測');
    });

    test('formatValue：非數值不補單位、空字串視為 null', () {
      expect(PdfReportData.formatValue('N/A', judgment: {'unit': 'MΩ'}), 'N/A');
      expect(PdfReportData.formatValue('  '), isNull);
      expect(PdfReportData.formatValue(null), isNull);
      expect(PdfReportData.formatValue(52.3, judgment: {'unit': 'MΩ'}), '52.3 MΩ');
    });

    test('verdictColor 對應', () {
      expect(PdfReportService.verdictColor('不合格'), isNot(PdfReportService.verdictColor('合格')));
      expect(PdfReportService.verdictColor('待判定'), PdfReportService.verdictColor('未檢測'));
    });
  });
}
