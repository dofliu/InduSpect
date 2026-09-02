import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute, debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/form_inspection_record.dart';
import '../models/inspection_template.dart';
import '../models/template_field.dart';

/// PDF 報告中的單一檢測項目
class PdfReportItem {
  final String fieldId;
  final String label;

  /// 檢測值（AI 讀值 / 手動填寫 / 狀況描述），未填寫為 null
  final String? value;

  /// 判定文字：合格 / 不合格 / 警告 / 待判定 / 已填寫 / 未檢測
  final String verdict;

  /// 法規依據（「標準 ≥1.0 MΩ（屋內線路裝置規則）」）
  final String? standardBasis;

  /// 單位換算說明（「換算: 500kΩ → 0.5MΩ」）
  final String? conversionNote;

  /// AI 異常描述
  final String? anomalyDescription;

  /// 對應照片路徑（無法對應時為 null）
  final String? photoPath;

  const PdfReportItem({
    required this.fieldId,
    required this.label,
    this.value,
    required this.verdict,
    this.standardBasis,
    this.conversionNote,
    this.anomalyDescription,
    this.photoPath,
  });

  bool get isCompleted => verdict != '未檢測';
  bool get isProblem => verdict == '不合格' || verdict == '警告';
}

/// PDF 報告輸入資料（與 UI / SQLite 解耦，便於測試）
class PdfReportData {
  final String title;
  final String? sourceFileName;
  final DateTime inspectionDate;
  final String? locationName;
  final double? latitude;
  final double? longitude;
  final String? recordId;
  final List<PdfReportItem> items;
  final String? summaryReport;

  /// 無法對應到項目的照片（歷史紀錄僅存扁平照片清單時使用）
  final List<String> extraPhotoPaths;

  const PdfReportData({
    required this.title,
    this.sourceFileName,
    required this.inspectionDate,
    this.locationName,
    this.latitude,
    this.longitude,
    this.recordId,
    required this.items,
    this.summaryReport,
    this.extraPhotoPaths = const [],
  });

  int get completedCount => items.where((i) => i.isCompleted).length;
  int get passCount => items.where((i) => i.verdict == '合格').length;
  int get failCount => items.where((i) => i.verdict == '不合格').length;
  int get warningCount => items.where((i) => i.verdict == '警告').length;
  int get pendingCount => items.where((i) => i.verdict == '待判定').length;
  List<PdfReportItem> get problemItems => items.where((i) => i.isProblem).toList();

  /// 從 SQLite 紀錄重建報告資料（歷史紀錄「匯出 PDF」用）
  ///
  /// 項目順序與標籤取自 `template_json`；無模板時退回以 filledData/aiResults 的
  /// fieldId 作為標籤。照片欄位/簽名欄位不列入檢測項目（與檢測流程一致）。
  factory PdfReportData.fromRecord(FormInspectionRecord record) {
    final items = <PdfReportItem>[];
    final seen = <String>{};

    void addItem(String fieldId, String label, String fieldType) {
      if (!seen.add(fieldId)) return;
      final judgment = record.standardJudgments[fieldId];
      final ai = record.aiResults[fieldId];
      final raw = record.filledData[fieldId];
      items.add(PdfReportItem(
        fieldId: fieldId,
        label: label,
        value: formatValue(raw, fieldType: fieldType, aiResult: ai, judgment: judgment),
        verdict: resolveVerdict(judgment: judgment, aiResult: ai, value: raw),
        standardBasis: standardBasisOf(judgment),
        conversionNote: conversionNoteOf(judgment),
        anomalyDescription: (ai is Map && ai['is_anomaly'] == true)
            ? ai['anomaly_description']?.toString()
            : null,
      ));
    }

    InspectionTemplate? template;
    if (record.templateJson != null && record.templateJson!.isNotEmpty) {
      try {
        template = InspectionTemplate.fromJson(
          Map<String, dynamic>.from(jsonDecode(record.templateJson!) as Map),
        );
      } catch (e) {
        debugPrint('PdfReportData.fromRecord: template_json 解析失敗: $e');
      }
    }

    if (template != null) {
      for (final section in template.sections) {
        for (final field in section.fields) {
          if (field.fieldType == FieldType.photo ||
              field.fieldType == FieldType.photoMultiple ||
              field.fieldType == FieldType.signature) {
            continue;
          }
          addItem(field.fieldId, field.label, field.fieldType.name);
        }
      }
    }

    // 模板缺失或紀錄含模板外的欄位：以 fieldId 補列，避免資料遺漏
    for (final fieldId in [...record.filledData.keys, ...record.aiResults.keys]) {
      addItem(fieldId, fieldId, 'text');
    }

    return PdfReportData(
      title: record.title,
      sourceFileName: record.sourceFileName,
      inspectionDate: record.createdAt,
      locationName: record.locationName,
      latitude: record.latitude,
      longitude: record.longitude,
      recordId: record.recordId,
      items: items,
      summaryReport: record.summaryReport,
      extraPhotoPaths: List.from(record.photoPaths),
    );
  }

  /// 判定文字（鏡射 `InspectionItemState.verdict` 的優先序：
  /// 法規判定 → AI 異常判定 → 手動填寫 → 未檢測）
  static String resolveVerdict({dynamic judgment, dynamic aiResult, dynamic value}) {
    if (judgment is Map) {
      switch (judgment['judgment']) {
        case 'pass':
          return '合格';
        case 'fail':
          return '不合格';
        case 'warning':
          return '警告';
      }
    }
    if (aiResult is Map) {
      return aiResult['is_anomaly'] == true ? '不合格' : '合格';
    }
    if (value != null && value.toString().isNotEmpty) {
      return '已填寫';
    }
    return '未檢測';
  }

  /// 法規依據文字（鏡射 `InspectionItemState.standardBasis`）
  static String? standardBasisOf(dynamic judgment) {
    if (judgment is! Map) return null;
    final std = judgment['standard_text']?.toString().trim() ?? '';
    if (std.isEmpty) return null;
    final reg = judgment['regulation']?.toString().trim() ?? '';
    return reg.isEmpty ? '標準 $std' : '標準 $std（$reg）';
  }

  /// 單位換算說明（鏡射 `InspectionItemState.conversionNote`）
  static String? conversionNoteOf(dynamic judgment) {
    if (judgment is! Map) return null;
    final cv = judgment['converted_value'];
    if (cv == null) return null;
    final cu = judgment['converted_unit'] ?? '';
    final mv = judgment['measured_value'];
    final mu = judgment['unit'] ?? '';
    return '換算: $mv$mu → $cv$cu';
  }

  /// 將 filledData 的原始值轉為可讀文字
  ///
  /// - radio 欄位的 pass/fail → 合格/不合格
  /// - 量測值若判定結果帶單位且原值未含單位 → 補上單位
  /// - 無填入值但有 AI 結果 → 使用狀況評估
  static String? formatValue(
    dynamic raw, {
    String fieldType = 'text',
    dynamic aiResult,
    dynamic judgment,
  }) {
    String? text = raw?.toString().trim();
    if (text != null && text.isEmpty) text = null;

    if (text == null && aiResult is Map) {
      final condition = aiResult['condition_assessment']?.toString().trim();
      if (condition != null && condition.isNotEmpty) text = condition;
    }
    if (text == null) return null;

    if (text == 'pass') return '合格';
    if (text == 'fail') return '不合格';

    if (judgment is Map) {
      final unit = judgment['unit']?.toString().trim() ?? '';
      final numeric = num.tryParse(text);
      if (unit.isNotEmpty && numeric != null) {
        return '$text $unit';
      }
    }
    return text;
  }
}

/// 讀取照片並回傳可嵌入 PDF 的 JPEG bytes；失敗回傳 null（該照片略過）
typedef PdfPhotoLoader = Future<Uint8List?> Function(String path);

/// ★ 申報用 PDF 報告產生器（純 Dart、離線、全平台）
///
/// 產出內容：基本資料、判定統計、逐項檢測結果（含法規依據與單位換算）、
/// 異常/不合格清單、AI 總結報告、照片附件。
/// 中文字型使用內嵌的 Noto Sans TC 子集（`assets/fonts/`，OFL 授權），
/// 不依賴系統字型與網路，符合「斷網可完成拍照 → 判定 → 匯出」的產品原則。
class PdfReportService {
  static const String fontAsset = 'assets/fonts/NotoSansTC-Regular-subset.ttf';

  /// 照片嵌入前的最長邊上限（px），控制 PDF 大小
  static const int photoMaxDimension = 900;

  static final _dateFmt = DateFormat('yyyy-MM-dd HH:mm');

  /// 建議檔名：`<標題或來源檔名>_report_yyyyMMdd.pdf`
  static String suggestedFileName(PdfReportData data) {
    var base = data.sourceFileName?.replaceAll(RegExp(r'\.\w+$'), '') ?? '';
    if (base.trim().isEmpty) base = data.title;
    base = base.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
    if (base.isEmpty) base = 'inspection';
    return '${base}_report_${DateFormat('yyyyMMdd').format(data.inspectionDate)}.pdf';
  }

  /// 產生 PDF bytes
  ///
  /// [includePhotos] 為 false 時不含照片附件（純文字報告，檔案最小）。
  /// [fontData] / [photoLoader] 可注入以便測試。
  static Future<Uint8List> build(
    PdfReportData data, {
    bool includePhotos = true,
    ByteData? fontData,
    PdfPhotoLoader? photoLoader,
  }) async {
    final font = pw.Font.ttf(fontData ?? await rootBundle.load(fontAsset));
    final theme = pw.ThemeData.withFont(base: font, bold: font, italic: font, boldItalic: font);

    // 照片先載入（MultiPage build 是同步的）
    final photos = <_PdfPhoto>[];
    if (includePhotos) {
      final loader = photoLoader ?? loadPhotoForPdf;
      final candidates = <_PdfPhoto>[
        for (final item in data.items)
          if (item.photoPath != null) _PdfPhoto(path: item.photoPath!, caption: item.label),
        for (final path in data.extraPhotoPaths) _PdfPhoto(path: path, caption: _captionFromPath(path)),
      ];
      final seen = <String>{};
      for (final c in candidates) {
        if (!seen.add(c.path)) continue;
        final bytes = await loader(c.path);
        if (bytes != null && bytes.isNotEmpty) {
          photos.add(_PdfPhoto(path: c.path, caption: c.caption, bytes: bytes));
        }
      }
    }

    final generatedAt = DateTime.now();
    final doc = pw.Document(
      title: '${data.title} 檢測報告',
      author: 'InduSpect AI',
      creator: 'InduSpect AI',
      theme: theme,
    );

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(36, 40, 36, 40),
      maxPages: 400,
      header: (ctx) => _header(ctx, data),
      footer: (ctx) => _footer(ctx, generatedAt),
      build: (ctx) => [
        _titleBlock(data),
        pw.SizedBox(height: 10),
        _sectionTitle('一、基本資料'),
        _basicInfoTable(data),
        pw.SizedBox(height: 12),
        _sectionTitle('二、判定統計'),
        _statsRow(data),
        pw.SizedBox(height: 12),
        _sectionTitle('三、檢測項目明細'),
        _itemsTable(data),
        if (data.problemItems.isNotEmpty) ...[
          pw.SizedBox(height: 12),
          _sectionTitle('四、異常 / 不合格項目'),
          ..._problemList(data),
        ],
        if (data.summaryReport != null && data.summaryReport!.trim().isNotEmpty) ...[
          pw.SizedBox(height: 12),
          _sectionTitle(data.problemItems.isNotEmpty ? '五、AI 總結報告' : '四、AI 總結報告'),
          ..._summaryParagraphs(data.summaryReport!),
        ],
        if (photos.isNotEmpty) ...[
          pw.NewPage(),
          _sectionTitle('附件：現場照片（共 ${photos.length} 張）'),
          ..._photoGrid(photos),
        ],
        pw.SizedBox(height: 16),
        _declaration(),
      ],
    ));

    return doc.save();
  }

  // ---------- 版面元件 ----------

  static const _colorPrimary = PdfColor.fromInt(0xFF1E6F8E);
  static const _colorPass = PdfColor.fromInt(0xFF2E7D32);
  static const _colorFail = PdfColor.fromInt(0xFFC62828);
  static const _colorWarn = PdfColor.fromInt(0xFFEF6C00);
  static const _colorGrey = PdfColor.fromInt(0xFF757575);
  static const _colorLine = PdfColor.fromInt(0xFFBDBDBD);
  static const _colorZebra = PdfColor.fromInt(0xFFF5F7F9);

  static PdfColor verdictColor(String verdict) {
    switch (verdict) {
      case '不合格':
        return _colorFail;
      case '警告':
        return _colorWarn;
      case '待判定':
      case '未檢測':
        return _colorGrey;
      default:
        return _colorPass;
    }
  }

  static pw.Widget _header(pw.Context ctx, PdfReportData data) {
    if (ctx.pageNumber == 1) return pw.SizedBox();
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 6),
      margin: const pw.EdgeInsets.only(bottom: 10),
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _colorLine, width: 0.5)),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('${data.title} — 設備定期檢測報告',
              style: const pw.TextStyle(fontSize: 9, color: _colorGrey)),
          pw.Text(_dateFmt.format(data.inspectionDate),
              style: const pw.TextStyle(fontSize: 9, color: _colorGrey)),
        ],
      ),
    );
  }

  static pw.Widget _footer(pw.Context ctx, DateTime generatedAt) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(top: 6),
      margin: const pw.EdgeInsets.only(top: 10),
      decoration: const pw.BoxDecoration(
        border: pw.Border(top: pw.BorderSide(color: _colorLine, width: 0.5)),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('InduSpect AI 產生於 ${_dateFmt.format(generatedAt)}',
              style: const pw.TextStyle(fontSize: 8, color: _colorGrey)),
          pw.Text('第 ${ctx.pageNumber} / ${ctx.pagesCount} 頁',
              style: const pw.TextStyle(fontSize: 8, color: _colorGrey)),
        ],
      ),
    );
  }

  static pw.Widget _titleBlock(PdfReportData data) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 10),
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _colorPrimary, width: 2)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('設備定期檢測報告',
              style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, color: _colorPrimary)),
          pw.SizedBox(height: 4),
          pw.Text(data.title, style: const pw.TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  static pw.Widget _sectionTitle(String text) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(top: 4, bottom: 6),
      child: pw.Text(text,
          style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: _colorPrimary)),
    );
  }

  static pw.Widget _basicInfoTable(PdfReportData data) {
    final rows = <List<String>>[
      ['檢測標題', data.title],
      ['檢測日期', _dateFmt.format(data.inspectionDate)],
      if (data.sourceFileName != null && data.sourceFileName!.isNotEmpty) ['來源表單', data.sourceFileName!],
      if (data.locationName != null && data.locationName!.isNotEmpty) ['檢測地點', data.locationName!],
      if (data.latitude != null && data.longitude != null)
        ['GPS 座標', '${data.latitude!.toStringAsFixed(6)}, ${data.longitude!.toStringAsFixed(6)}'],
      if (data.recordId != null) ['紀錄編號', data.recordId!],
    ];
    return pw.Table(
      border: pw.TableBorder.all(color: _colorLine, width: 0.5),
      columnWidths: const {0: pw.FixedColumnWidth(80), 1: pw.FlexColumnWidth()},
      children: [
        for (final r in rows)
          pw.TableRow(children: [
            pw.Container(
              color: _colorZebra,
              padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: pw.Text(r[0], style: const pw.TextStyle(fontSize: 9.5)),
            ),
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: pw.Text(r[1], style: const pw.TextStyle(fontSize: 9.5)),
            ),
          ]),
      ],
    );
  }

  static pw.Widget _statsRow(PdfReportData data) {
    pw.Widget cell(String label, int value, PdfColor color) {
      return pw.Expanded(
        child: pw.Container(
          margin: const pw.EdgeInsets.only(right: 6),
          padding: const pw.EdgeInsets.symmetric(vertical: 8),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: color, width: 0.8),
            borderRadius: pw.BorderRadius.circular(4),
          ),
          child: pw.Column(children: [
            pw.Text('$value', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: color)),
            pw.Text(label, style: pw.TextStyle(fontSize: 8.5, color: color)),
          ]),
        ),
      );
    }

    return pw.Row(children: [
      cell('項目總數', data.items.length, _colorPrimary),
      cell('已完成', data.completedCount, _colorPrimary),
      cell('合格', data.passCount, _colorPass),
      cell('不合格', data.failCount, _colorFail),
      cell('警告', data.warningCount, _colorWarn),
      cell('待判定', data.pendingCount, _colorGrey),
    ]);
  }

  static pw.Widget _itemsTable(PdfReportData data) {
    final headerStyle = pw.TextStyle(fontSize: 9.0, fontWeight: pw.FontWeight.bold, color: PdfColors.white);
    const cellStyle = pw.TextStyle(fontSize: 9.0);
    const noteStyle = pw.TextStyle(fontSize: 7.5, color: _colorGrey);

    pw.Widget headerCell(String t) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
          child: pw.Text(t, style: headerStyle),
        );
    pw.Widget cell(pw.Widget child) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
          child: child,
        );

    return pw.Table(
      border: pw.TableBorder.all(color: _colorLine, width: 0.5),
      columnWidths: const {
        0: pw.FixedColumnWidth(24),
        1: pw.FlexColumnWidth(2.2),
        2: pw.FlexColumnWidth(1.6),
        3: pw.FixedColumnWidth(44),
        4: pw.FlexColumnWidth(2.6),
      },
      children: [
        pw.TableRow(
          repeat: true,
          decoration: const pw.BoxDecoration(color: _colorPrimary),
          children: [
            headerCell('#'),
            headerCell('檢測項目'),
            headerCell('檢測值'),
            headerCell('判定'),
            headerCell('法規依據 / 說明'),
          ],
        ),
        for (var i = 0; i < data.items.length; i++)
          pw.TableRow(
            decoration: pw.BoxDecoration(color: i.isOdd ? _colorZebra : PdfColors.white),
            children: [
              cell(pw.Text('${i + 1}', style: cellStyle)),
              cell(pw.Text(data.items[i].label, style: cellStyle)),
              cell(pw.Text(data.items[i].value ?? '—', style: cellStyle)),
              cell(pw.Text(
                data.items[i].verdict,
                style: pw.TextStyle(
                  fontSize: 9,
                  fontWeight: pw.FontWeight.bold,
                  color: verdictColor(data.items[i].verdict),
                ),
              )),
              cell(pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  if (data.items[i].standardBasis != null)
                    pw.Text(data.items[i].standardBasis!, style: const pw.TextStyle(fontSize: 8.5)),
                  if (data.items[i].conversionNote != null)
                    pw.Text(data.items[i].conversionNote!, style: noteStyle),
                  if (data.items[i].anomalyDescription != null &&
                      data.items[i].anomalyDescription!.isNotEmpty)
                    pw.Text(data.items[i].anomalyDescription!, style: noteStyle),
                  if (data.items[i].standardBasis == null &&
                      data.items[i].conversionNote == null &&
                      (data.items[i].anomalyDescription ?? '').isEmpty)
                    pw.Text('—', style: cellStyle),
                ],
              )),
            ],
          ),
      ],
    );
  }

  static List<pw.Widget> _problemList(PdfReportData data) {
    return [
      for (final item in data.problemItems)
        pw.Container(
          margin: const pw.EdgeInsets.only(bottom: 6),
          padding: const pw.EdgeInsets.all(8),
          decoration: pw.BoxDecoration(
            border: pw.Border(left: pw.BorderSide(color: verdictColor(item.verdict), width: 3)),
            color: _colorZebra,
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(item.label, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                  pw.Text(item.verdict,
                      style: pw.TextStyle(
                          fontSize: 10, fontWeight: pw.FontWeight.bold, color: verdictColor(item.verdict))),
                ],
              ),
              if (item.value != null) pw.Text('檢測值：${item.value}', style: const pw.TextStyle(fontSize: 9)),
              if (item.standardBasis != null) pw.Text(item.standardBasis!, style: const pw.TextStyle(fontSize: 9)),
              if (item.conversionNote != null)
                pw.Text(item.conversionNote!, style: const pw.TextStyle(fontSize: 8.5, color: _colorGrey)),
              if (item.anomalyDescription != null && item.anomalyDescription!.isNotEmpty)
                pw.Text(item.anomalyDescription!, style: const pw.TextStyle(fontSize: 9)),
            ],
          ),
        ),
    ];
  }

  static List<pw.Widget> _summaryParagraphs(String report) {
    // 逐段輸出，讓長報告可自然跨頁；去掉 Markdown 標題/粗體記號以免出現雜訊
    final lines = report.replaceAll('\r\n', '\n').split('\n');
    return [
      for (final raw in lines)
        if (raw.trim().isNotEmpty)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 3),
            child: pw.Text(
              raw.replaceAll(RegExp(r'^\s*#{1,6}\s*'), '').replaceAll('**', ''),
              style: const pw.TextStyle(fontSize: 9.5, lineSpacing: 2),
            ),
          ),
    ];
  }

  static List<pw.Widget> _photoGrid(List<_PdfPhoto> photos) {
    const photoHeight = 190.0;
    pw.Widget tile(_PdfPhoto? photo) {
      if (photo == null) return pw.Expanded(child: pw.SizedBox());
      return pw.Expanded(
        child: pw.Padding(
          padding: const pw.EdgeInsets.all(4),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Container(
                height: photoHeight,
                decoration: pw.BoxDecoration(border: pw.Border.all(color: _colorLine, width: 0.5)),
                child: pw.Center(child: pw.Image(pw.MemoryImage(photo.bytes!), fit: pw.BoxFit.contain)),
              ),
              pw.SizedBox(height: 3),
              pw.Text(photo.caption, style: const pw.TextStyle(fontSize: 8.5), maxLines: 2),
            ],
          ),
        ),
      );
    }

    return [
      for (var i = 0; i < photos.length; i += 2)
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [tile(photos[i]), tile(i + 1 < photos.length ? photos[i + 1] : null)],
        ),
    ];
  }

  static pw.Widget _declaration() {
    return pw.Container(
      padding: const pw.EdgeInsets.all(8),
      decoration: pw.BoxDecoration(border: pw.Border.all(color: _colorLine, width: 0.5)),
      child: pw.Text(
        '說明：本報告由 InduSpect AI 協助產生。AI 辨識之讀值與狀況評估已提供檢測人員審閱修正；'
        '「判定」欄依內建法規標準庫自動比對（量測值先換算至標準單位再比較），法規依據列於同列。'
        '判定為「待判定」之項目表示未能匹配標準，需人工確認。',
        style: const pw.TextStyle(fontSize: 8, color: _colorGrey, lineSpacing: 2),
      ),
    );
  }

  static String _captionFromPath(String path) {
    final name = path.split(RegExp(r'[\\/]')).last;
    return name.replaceAll(RegExp(r'\.\w+$'), '');
  }

  // ---------- 照片載入 ----------

  /// 預設照片載入器：讀檔 → 降採樣至 [photoMaxDimension] → JPEG（isolate 執行）
  static Future<Uint8List?> loadPhotoForPdf(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      return await compute(_downscaleToJpeg, bytes);
    } catch (e) {
      debugPrint('PDF 照片載入失敗 ($path): $e');
      return null;
    }
  }

  /// 純函式：解碼 → 等比縮小 → JPEG q75；無法解碼回傳 null
  static Uint8List? _downscaleToJpeg(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    var image = img.bakeOrientation(decoded);
    final longest = image.width > image.height ? image.width : image.height;
    if (longest > photoMaxDimension) {
      image = image.width >= image.height
          ? img.copyResize(image, width: photoMaxDimension)
          : img.copyResize(image, height: photoMaxDimension);
    }
    return Uint8List.fromList(img.encodeJpg(image, quality: 75));
  }
}

class _PdfPhoto {
  final String path;
  final String caption;
  final Uint8List? bytes;
  const _PdfPhoto({required this.path, required this.caption, this.bytes});
}
