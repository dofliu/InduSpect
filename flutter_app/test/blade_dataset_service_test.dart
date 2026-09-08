import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/models/wt_asset.dart';
import 'package:induspect_ai/models/wt_capture_session.dart';
import 'package:induspect_ai/models/wt_detection.dart';
import 'package:induspect_ai/services/blade_dataset_service.dart';

/// 訓練語料的標記規則（規格 §9 Phase 4 的前置）。
///
/// 這支測試守的是一件事：**「演算法沒報」不等於「人看過沒問題」**。
/// 把這兩者混在一起，健康樣本異常偵測的記憶庫裡就會摻進演算法漏檢的真缺陷，
/// 於是模型把缺陷學成正常——而那種失效不會有任何徵兆。
void main() {
  WtMedia photo({
    String path = '/p/a.jpg',
    bool? quality = true,
    WtMediaView view = WtMediaView.segment,
    String? zone = 'mid',
  }) =>
      WtMedia(
        path: path,
        view: view,
        zone: zone,
        qualityJson: quality == null ? {} : {'ok': quality},
      );

  WtCaptureSession session({
    WtSessionStatus status = WtSessionStatus.confirmed,
    List<WtMedia>? media,
    String assetId = 'WTG-01',
    String sessionId = 's1',
  }) =>
      WtCaptureSession(
        sessionId: sessionId,
        assetId: assetId,
        status: status,
        media: media ?? [photo()],
      );

  WtDetection det({
    String id = 'd1',
    String path = '/p/a.jpg',
    WtHumanStatus human = WtHumanStatus.confirmed,
    int? severity = 4,
    String sessionId = 's1',
  }) =>
      WtDetection(
        detectionId: id,
        sessionId: sessionId,
        layer: WtLayer.surface,
        defectClass: 'leading_edge_erosion',
        severity: severity,
        mediaPath: path,
        humanStatus: human,
        metricJson: const {'le_over_te_rms_ratio': 2.4},
      );

  BladeDatasetLabel labelOf(WtCaptureSession s, List<WtDetection> ds) =>
      BladeDatasetService.labelOf(
          media: s.media.first, session: s, mediaDetections: ds);

  group('品質閘門優先於一切', () {
    test('沒過閘門 → unusable，即使人已經簽核', () {
      final s = session(media: [photo(quality: false)]);
      expect(labelOf(s, const []), BladeDatasetLabel.unusable);
    });

    test('**沒驗過品質也算 unusable**（qualityOk 是 null 時不能當驗過了）', () {
      final s = session(media: [photo(quality: null)]);
      expect(labelOf(s, const []), BladeDatasetLabel.unusable,
          reason: '把模糊的畫面放進記憶庫等於教模型「模糊是正常的」');
    });

    test('沒過閘門且有人工確認的發現 → 仍然 unusable（數值不可採信）', () {
      final s = session(media: [photo(quality: false)]);
      expect(labelOf(s, [det()]), BladeDatasetLabel.unusable);
    });
  });

  group('沒人簽核就不是健康樣本', () {
    for (final st in [WtSessionStatus.draft, WtSessionStatus.analyzed]) {
      test('${st.name} 的場次即使零發現也只是 unreviewed，不是 humanClean', () {
        expect(labelOf(session(status: st), const []),
            BladeDatasetLabel.unreviewed,
            reason: '「演算法沒報」與「人看過沒問題」是兩件事');
      });
    }

    test('簽核過的場次裡還有 pending 的發現 → 不信任這次簽核', () {
      final s = session();
      expect(labelOf(s, [det(human: WtHumanStatus.pending)]),
          BladeDatasetLabel.unreviewed,
          reason: '寧可少收一筆，不要收一筆錯的');
    });

    test('shared 也算簽核過（分享過的報告一定先確認過）', () {
      expect(labelOf(session(status: WtSessionStatus.shared), const []),
          BladeDatasetLabel.humanClean);
    });
  });

  group('簽核過之後的三種結果', () {
    test('零發現 → humanClean（唯一能進記憶庫的那一類）', () {
      expect(labelOf(session(), const []), BladeDatasetLabel.humanClean);
    });

    test('有人工確認的發現 → defect', () {
      expect(labelOf(session(), [det()]), BladeDatasetLabel.defect);
    });

    test('全部被駁回 → falsePositive（演算法誤報，最有價值的負樣本）', () {
      expect(labelOf(session(), [det(human: WtHumanStatus.rejected)]),
          BladeDatasetLabel.falsePositive);
    });

    test('確認與駁回混在同一份媒體 → defect，而且兩筆都帶出去', () {
      final s = session();
      final ds = [
        det(id: 'd1', human: WtHumanStatus.confirmed),
        det(id: 'd2', human: WtHumanStatus.rejected),
      ];
      expect(labelOf(s, ds), BladeDatasetLabel.defect);
      final items = BladeDatasetService.collect(
          sessions: [s], detectionsBySession: {'s1': ds});
      expect(items.single.detections.length, 2,
          reason: '被駁回的那筆不能消失——它記錄了演算法在哪裡弄錯');
    });
  });

  group('collect', () {
    test('只收指定標記，其餘略過', () {
      final s = session(media: [
        photo(path: '/p/clean.jpg'),
        photo(path: '/p/bad.jpg', quality: false),
      ]);
      final all = BladeDatasetService.collect(
          sessions: [s], detectionsBySession: const {});
      expect(all.length, 2);
      final only = BladeDatasetService.collect(
        sessions: [s],
        detectionsBySession: const {},
        onlyLabels: const {BladeDatasetLabel.humanClean},
      );
      expect(only.length, 1);
      expect(only.single.relativePath, 'media/s1/clean.jpg');
    });

    test('相對路徑不含絕對路徑（語料要能搬到別的機器）', () {
      for (final src in ['/data/user/0/x/a.jpg', r'C:\photos\a.jpg']) {
        final s = session(media: [photo(path: src)]);
        final it = BladeDatasetService.collect(
                sessions: [s], detectionsBySession: const {})
            .single;
        expect(it.relativePath, 'media/s1/a.jpg');
        expect(it.sourcePath, src, reason: '原始路徑留著給複製用，但不寫進 manifest');
        expect(it.toJson().containsKey('source_path'), isFalse);
      }
    });

    test('帶上機型（同機型的葉片才有可比性）', () {
      final s = session();
      final it = BladeDatasetService.collect(
        sessions: [s],
        detectionsBySession: const {},
        assets: {'WTG-01': WtAsset(assetId: 'WTG-01', model: 'V112-3.0')},
      ).single;
      expect(it.toJson()['turbine_model'], 'V112-3.0');
    });

    test('只挑屬於這份媒體的發現（不會把別張照片的發現算進來）', () {
      final s = session(media: [photo(path: '/p/a.jpg'), photo(path: '/p/b.jpg')]);
      final ds = [det(id: 'd1', path: '/p/a.jpg')];
      final items = BladeDatasetService.collect(
          sessions: [s], detectionsBySession: {'s1': ds});
      final a = items.firstWhere((i) => i.relativePath.endsWith('a.jpg'));
      final b = items.firstWhere((i) => i.relativePath.endsWith('b.jpg'));
      expect(a.label, BladeDatasetLabel.defect);
      expect(b.label, BladeDatasetLabel.humanClean);
      expect(b.detections, isEmpty);
    });
  });

  group('統計與「還差多少」', () {
    List<BladeDatasetItem> cleanSegments(int n) {
      final media = List<WtMedia>.generate(
          n, (i) => photo(path: '/p/s$i.jpg', view: WtMediaView.segment));
      final s = session(media: media);
      return BladeDatasetService.collect(
          sessions: [s], detectionsBySession: const {});
    }

    test('記憶庫候選只算分區段照——整機照上一片葉片只有幾個像素', () {
      final s = session(media: [
        photo(path: '/p/seg.jpg', view: WtMediaView.segment),
        photo(path: '/p/front.jpg', view: WtMediaView.front, zone: null),
        photo(path: '/p/tower.jpg', view: WtMediaView.tower, zone: null),
      ]);
      final items = BladeDatasetService.collect(
          sessions: [s], detectionsBySession: const {});
      final sum =
          BladeDatasetService.summarize(items: items, sessions: [s]);
      expect(sum.of(BladeDatasetLabel.humanClean), 3);
      expect(sum.memoryBankCandidates, 1, reason: '只有分區段照能學到表面紋理');
      expect(sum.humanCleanByView[WtMediaView.front], 1);
      expect(sum.humanCleanByZone['mid'], 1);
    });

    test('零張時說清楚「不能訓練」，而且說明合成影像不能替代', () {
      final sum = BladeDatasetService.summarize(items: const [], sessions: const []);
      expect(sum.memoryBankCandidates, 0);
      expect(sum.readiness, contains('0 張'));
      expect(sum.readiness, contains('無法訓練'));
      expect(sum.readiness, contains('合成影像'),
          reason: '要擋掉「拿合成圖訓練」這條看起來可行的路');
    });

    test('不足下限時說不足，不給樂觀說法', () {
      final items = cleanSegments(5);
      final sum = BladeDatasetService.summarize(
          items: items, sessions: [session()]);
      expect(sum.memoryBankCandidates, 5);
      expect(sum.readiness, contains('還不足以訓練'));
    });

    test('超過下限但低於文獻量級時要提醒留測試集', () {
      final items = cleanSegments(60);
      final sum = BladeDatasetService.summarize(
          items: items, sessions: [session()]);
      expect(sum.readiness, contains('測試集'));
      expect(sum.readiness, isNot(contains('無法訓練')));
    });

    test('達到文獻量級時提醒缺陷正樣本才是瓶頸', () {
      final items = cleanSegments(220);
      final sum = BladeDatasetService.summarize(
          items: items, sessions: [session()]);
      expect(sum.readiness, contains('缺陷正樣本'));
    });

    test('場次統計分得清「總共幾次」與「幾次有人簽核」', () {
      final sessions = [
        session(sessionId: 's1', status: WtSessionStatus.confirmed),
        session(sessionId: 's2', status: WtSessionStatus.analyzed),
        session(sessionId: 's3', assetId: 'WTG-02', status: WtSessionStatus.shared),
      ];
      final sum = BladeDatasetService.summarize(
          items: const [], sessions: sessions);
      expect(sum.sessionCount, 3);
      expect(sum.reviewedSessionCount, 2);
      expect(sum.assetCount, 2);
    });
  });

  group('manifest 自我描述', () {
    test('帶格式版本，並在 readme 裡寫明每個標記的語意', () {
      final s = session();
      final items = BladeDatasetService.collect(
          sessions: [s], detectionsBySession: const {});
      final m = BladeDatasetService.buildManifest(
        items: items,
        summary: BladeDatasetService.summarize(items: items, sessions: [s]),
        exportedAt: DateTime.utc(2026, 9, 7),
      );
      expect(m['schema_version'], BladeDatasetService.schemaVersion);
      expect(m['exported_at'], '2026-09-07T00:00:00.000Z');
      final readme = (m['_readme'] as List).join();
      for (final l in BladeDatasetLabel.values) {
        expect(readme, contains(l.name), reason: '${l.name} 的語意要寫出來');
      }
      expect(readme, contains('人工確認'),
          reason: '要講明標籤來源是人不是演算法');
    });

    test('演算法的等級與人的判定是分開的欄位（訓練時不能混）', () {
      final s = session();
      final ds = [det(severity: 5, human: WtHumanStatus.rejected)];
      final it = BladeDatasetService.collect(
              sessions: [s], detectionsBySession: {'s1': ds})
          .single;
      final d = it.detections.single;
      expect(d['algorithm_severity'], 5);
      expect(d['human_status'], 'rejected');
      expect(d.containsKey('severity'), isFalse,
          reason: '不留一個含糊的 severity 欄位讓人誤以為那是標籤');
      expect(d['metrics'], isNotNull, reason: '演算法量到的數值要帶出去');
    });
  });
}
