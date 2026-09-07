import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/screens/form_inspection_screen.dart';

/// 測試 InspectionItemState 的 computed properties 和 controller 管理
void main() {
  group('InspectionItemState', () {
    test('displayValue 回傳 AI condition_assessment（正常時）', () {
      final item = InspectionItemState(
        fieldId: 'f1',
        label: '絕緣電阻',
        fieldType: 'number',
        aiResult: {
          'condition_assessment': '正常',
          'is_anomaly': false,
        },
      );

      expect(item.displayValue, '正常');
    });

    test('displayValue 回傳異常描述', () {
      final item = InspectionItemState(
        fieldId: 'f2',
        label: '溫度',
        fieldType: 'number',
        aiResult: {
          'condition_assessment': '過熱',
          'is_anomaly': true,
          'anomaly_description': '溫度超過 85°C',
        },
      );

      expect(item.displayValue, contains('異常'));
      expect(item.displayValue, contains('溫度超過 85°C'));
    });

    test('displayValue 無 AI 結果時回傳 manualValue', () {
      final item = InspectionItemState(
        fieldId: 'f3',
        label: '外觀',
        fieldType: 'text',
        manualValue: '外觀完好',
      );

      expect(item.displayValue, '外觀完好');
    });

    test('displayValue 無任何值時回傳 null', () {
      final item = InspectionItemState(
        fieldId: 'f4',
        label: '備註',
        fieldType: 'text',
      );

      expect(item.displayValue, isNull);
    });

    test('verdict: AI 異常 → 不合格', () {
      final item = InspectionItemState(
        fieldId: 'f5',
        label: '接地',
        fieldType: 'radio',
        aiResult: {'is_anomaly': true},
      );

      expect(item.verdict, '不合格');
    });

    test('verdict: AI 正常 → 合格', () {
      final item = InspectionItemState(
        fieldId: 'f6',
        label: '接地',
        fieldType: 'radio',
        aiResult: {'is_anomaly': false},
      );

      expect(item.verdict, '合格');
    });

    test('verdict: 手動填寫 → 已填寫', () {
      final item = InspectionItemState(
        fieldId: 'f7',
        label: '備註',
        fieldType: 'text',
        manualValue: '正常',
      );

      expect(item.verdict, '已填寫');
    });

    test('verdict: 未填寫 → 未檢測', () {
      final item = InspectionItemState(
        fieldId: 'f8',
        label: '備註',
        fieldType: 'text',
      );

      expect(item.verdict, '未檢測');
    });

    test('manualController 初始值與建構參數一致', () {
      final item = InspectionItemState(
        fieldId: 'ctrl1',
        label: 'Test',
        fieldType: 'text',
        manualValue: '初始值',
      );

      expect(item.manualController.text, '初始值');
      // 清理
      item.manualController.dispose();
    });

    test('manualController 無初始值時為空字串', () {
      final item = InspectionItemState(
        fieldId: 'ctrl2',
        label: 'Test',
        fieldType: 'text',
      );

      expect(item.manualController.text, '');
      item.manualController.dispose();
    });

    test('isCompleted 預設為 false', () {
      final item = InspectionItemState(
        fieldId: 'new',
        label: 'New',
        fieldType: 'text',
      );

      expect(item.isCompleted, false);
      expect(item.isAnalyzing, false);
      item.manualController.dispose();
    });
  });

  group('InspectionItemState 法規標準判定', () {
    test('verdict: 標準判定 pass → 合格（優先於 AI 異常）', () {
      final item = InspectionItemState(
        fieldId: 'j1',
        label: '絕緣電阻',
        fieldType: 'measurement',
        aiResult: {'is_anomaly': true}, // AI 視覺誤判為異常
        standardJudgment: {
          'judgment': 'pass',
          'standard_text': '≥1.0 MΩ',
          'regulation': '屋內線路裝置規則 第59條',
        },
      );

      // 量測欄位以法規標準判定為準
      expect(item.verdict, '合格');
    });

    test('verdict: 標準判定 fail → 不合格', () {
      final item = InspectionItemState(
        fieldId: 'j2',
        label: '絕緣電阻 S相',
        fieldType: 'measurement',
        aiResult: {'is_anomaly': false},
        standardJudgment: {
          'judgment': 'fail',
          'standard_text': '≥1.0 MΩ',
          'regulation': '屋內線路裝置規則 第59條',
        },
      );

      expect(item.verdict, '不合格');
    });

    test('verdict: 標準判定 warning → 警告', () {
      final item = InspectionItemState(
        fieldId: 'j3',
        label: '接地電阻',
        fieldType: 'measurement',
        standardJudgment: {
          'judgment': 'warning',
          'standard_text': '≤100.0 Ω',
        },
      );

      expect(item.verdict, '警告');
    });

    test('verdict: 標準判定 unknown → 落回 AI 判定', () {
      final item = InspectionItemState(
        fieldId: 'j4',
        label: '某項目',
        fieldType: 'measurement',
        aiResult: {'is_anomaly': true},
        standardJudgment: {'judgment': 'unknown', 'standard_text': ''},
      );

      expect(item.verdict, '不合格');
    });

    test('verdict: 離線待判定 → 待判定', () {
      final item = InspectionItemState(
        fieldId: 'j5',
        label: '電壓',
        fieldType: 'measurement',
        aiResult: {'is_anomaly': false},
        standardJudgmentPending: true,
      );

      expect(item.verdict, '待判定');
    });

    test('judgmentCode: unknown 視為無判定（回傳 null）', () {
      final item = InspectionItemState(
        fieldId: 'j6',
        label: 'x',
        fieldType: 'measurement',
        standardJudgment: {'judgment': 'unknown'},
      );

      expect(item.judgmentCode, isNull);
    });

    test('standardBasis: 組合標準文字與法規名稱', () {
      final item = InspectionItemState(
        fieldId: 'j7',
        label: '絕緣電阻',
        fieldType: 'measurement',
        standardJudgment: {
          'judgment': 'pass',
          'standard_text': '≥1.0 MΩ',
          'regulation': '屋內線路裝置規則 第59條',
        },
      );

      expect(item.standardBasis, '標準 ≥1.0 MΩ（屋內線路裝置規則 第59條）');
    });

    test('standardBasis: 無標準文字時回傳 null', () {
      final item = InspectionItemState(
        fieldId: 'j8',
        label: 'x',
        fieldType: 'measurement',
        standardJudgment: {'judgment': 'unknown', 'standard_text': ''},
      );

      expect(item.standardBasis, isNull);
    });

    test('conversionNote: 有換算值時顯示原始 → 換算', () {
      final item = InspectionItemState(
        fieldId: 'j9',
        label: '絕緣電阻',
        fieldType: 'measurement',
        standardJudgment: {
          'judgment': 'fail',
          'standard_text': '≥1.0 MΩ',
          'measured_value': 500,
          'unit': 'kΩ',
          'converted_value': 0.5,
          'converted_unit': 'MΩ',
        },
      );

      expect(item.conversionNote, '換算: 500kΩ → 0.5MΩ');
    });

    test('conversionNote: 無換算時回傳 null', () {
      final item = InspectionItemState(
        fieldId: 'j10',
        label: '絕緣電阻',
        fieldType: 'measurement',
        standardJudgment: {
          'judgment': 'pass',
          'converted_value': null,
        },
      );

      expect(item.conversionNote, isNull);
    });
  });

  group('verdictColor', () {
    test('不合格 → 紅、警告 → 橘、待判定 → 灰、合格 → 綠', () {
      expect(verdictColor('不合格'), Colors.red);
      expect(verdictColor('警告'), Colors.orange);
      expect(verdictColor('待判定'), Colors.grey);
      expect(verdictColor('未檢測'), Colors.grey);
      expect(verdictColor('合格'), Colors.green);
      expect(verdictColor('已填寫'), Colors.green);
    });
  });

  // Issue #43「離線 → 恢復網路 → 待判定項目重新判定」的後半段。
  // 原本畫面提示寫著「恢復網路後可重新判定」，但沒有任何程式碼做那件事。
  group('恢復連線後的補判', () {
    InspectionItemState item({
      String id = 'f1',
      Map<String, dynamic>? aiResult,
      Map<String, dynamic>? standardJudgment,
      bool pending = false,
    }) =>
        InspectionItemState(
          fieldId: id,
          label: '絕緣電阻',
          fieldType: 'number',
          aiResult: aiResult,
          standardJudgment: standardJudgment,
          standardJudgmentPending: pending,
        );

    test('沒有待判定項目時不重跑', () {
      expect(shouldRejudgeOnReconnect(const <InspectionItemState>[]), isFalse);
      expect(
        shouldRejudgeOnReconnect([
          item(id: 'a', standardJudgment: const {'judgment': 'pass'}),
          item(id: 'b'),
        ]),
        isFalse,
      );
    });

    test('有任何一項待判定就重跑', () {
      expect(
        shouldRejudgeOnReconnect([
          item(id: 'a', standardJudgment: const {'judgment': 'pass'}),
          item(id: 'b', pending: true),
        ]),
        isTrue,
      );
    });

    test('★ 目標只有待判定的，已經有判定結果的不重跑', () {
      final judged = item(id: 'judged', standardJudgment: const {'judgment': 'fail'});
      final waiting = item(id: 'waiting', pending: true);
      final untouched = item(id: 'untouched');

      final targets = rejudgeTargets([judged, waiting, untouched]);

      expect(targets.map((i) => i.fieldId), ['waiting'],
          reason: '本地引擎與後端讀同一份標準資料，重跑只會無聲換掉使用者看過的判定');
    });

    test('匹配不到標準（unknown）不算待判定，也不重跑', () {
      // unknown 代表標準庫裡沒有這一項；兩邊標準相同，再問一次還是 unknown
      final unknown = item(id: 'u', standardJudgment: const {'judgment': 'unknown'});

      expect(unknown.judgmentCode, isNull);
      expect(rejudgeTargets([unknown]), isEmpty);
      expect(shouldRejudgeOnReconnect([unknown]), isFalse);
    });

    test('多個待判定時全部進目標，且維持原順序', () {
      final a = item(id: 'a', pending: true);
      final b = item(id: 'b', standardJudgment: const {'judgment': 'pass'});
      final c = item(id: 'c', pending: true);

      expect(rejudgeTargets([a, b, c]).map((i) => i.fieldId), ['a', 'c']);
    });

    test('補判成功後 verdict 由「待判定」變成標準判定', () {
      final target = item(
        id: 'x',
        pending: true,
        aiResult: const {'is_anomaly': false},
      );
      expect(target.verdict, '待判定');

      // 補判寫回的兩件事（與 _runStandardJudgment 成功分支一致）
      target.standardJudgment = const {'judgment': 'fail', 'standard_text': '≥ 1'};
      target.standardJudgmentPending = false;

      expect(target.verdict, '不合格');
      expect(rejudgeTargets([target]), isEmpty, reason: '補判完就不該再是目標');
    });
  });
}
