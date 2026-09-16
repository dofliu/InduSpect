import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/models/wt_asset.dart';
import 'package:induspect_ai/models/wt_capture_session.dart';

/// 拍攝點的**寫入端**。
///
/// 全 codebase 查核抓到的缺口：`WtAsset.capturePoint()` 有人讀（引導拍攝畫面
/// 拿它算「到上次拍攝點的距離」），但沒有任何地方寫——於是「導回上次拍攝點」
/// 永遠不會亮。這裡釘住的是新加的三段：每張全機照帶自己的 GPS、
/// 由 view 決定對應哪個拍攝點、以及 upsert 進資產。
void main() {
  group('WtMedia 的拍攝位置', () {
    test('JSON 往返保留 lat/lng', () {
      final m = WtMedia(
        path: '/p/front.jpg',
        view: WtMediaView.front,
        latitude: 24.1234,
        longitude: 120.5678,
      );
      final back = WtMedia.fromJson(m.toJson());
      expect(back.latitude, 24.1234);
      expect(back.longitude, 120.5678);
      expect(back.hasLocation, isTrue);
    });

    test('★ 舊列沒有 lat/lng 鍵照樣讀得起來（media 是列裡的 JSON，不需 migration）', () {
      final back = WtMedia.fromJson({
        'path': '/p/old.jpg',
        'kind': 'photo',
        'view': 'front',
        'captured_at': '2026-09-01T10:00:00.000',
      });
      expect(back.latitude, isNull);
      expect(back.longitude, isNull);
      expect(back.hasLocation, isFalse);
    });

    test('沒有位置時不寫鍵，不要寫成 null', () {
      final json = WtMedia(path: '/p/x.jpg').toJson();
      expect(json.containsKey('lat'), isFalse);
      expect(json.containsKey('lng'), isFalse);
    });

    test('copyWith 不會把位置丟掉', () {
      final m = WtMedia(path: '/p/a.jpg', latitude: 1.0, longitude: 2.0);
      final c = m.copyWith(qualityJson: const {'ok': true});
      expect(c.latitude, 1.0);
      expect(c.longitude, 2.0);
    });

    test('只有半個座標不算有位置', () {
      expect(WtMedia(path: '/p', latitude: 1.0).hasLocation, isFalse);
    });
  });

  group('WtMedia.capturePointName（與 BladeShot 用同一組字串）', () {
    test('正視 → front、側視 → side', () {
      expect(WtMedia(path: '/p', view: WtMediaView.front).capturePointName, 'front');
      expect(WtMedia(path: '/p', view: WtMediaView.side).capturePointName, 'side');
    });

    test('分區段照／塔架／其他沒有固定站位 → null', () {
      for (final v in [WtMediaView.segment, WtMediaView.tower, WtMediaView.other]) {
        expect(WtMedia(path: '/p', view: v).capturePointName, isNull,
            reason: '$v 是跟著葉片走的，沒有「同一個位置」可言');
      }
    });
  });

  group('WtAsset.upsertCapturePoint', () {
    final base = WtAsset(assetId: 'WTG-07');

    test('第一次寫入：從沒有到有，capturePoint() 讀得到', () {
      final a = base.upsertCapturePoint(
          const WtCapturePoint(name: 'front', latitude: 24.0, longitude: 120.0));
      expect(a.capturePoints, hasLength(1));
      expect(a.capturePoint('front')!.latitude, 24.0);
      expect(a.capturePoint('front')!.hasLocation, isTrue);
      expect(a.capturePoint('side'), isNull);
    });

    test('★ 同名覆蓋、不同名並存——下一次到場站位微調要以最新為準', () {
      final a = base
          .upsertCapturePoint(
              const WtCapturePoint(name: 'front', latitude: 24.0, longitude: 120.0))
          .upsertCapturePoint(
              const WtCapturePoint(name: 'side', latitude: 24.1, longitude: 120.1))
          .upsertCapturePoint(
              const WtCapturePoint(name: 'front', latitude: 24.5, longitude: 120.5));
      expect(a.capturePoints, hasLength(2));
      expect(a.capturePoint('front')!.latitude, 24.5, reason: '同名要被覆蓋');
      expect(a.capturePoint('side')!.latitude, 24.1, reason: '不同名不能被動到');
    });

    test('不 mutate 原物件，且保留 id / 其他欄位', () {
      final withId = WtAsset(id: 7, assetId: 'WTG-07', siteName: '彰濱', rotorDiameterM: 150);
      final a = withId.upsertCapturePoint(
          const WtCapturePoint(name: 'front', latitude: 1, longitude: 2));
      expect(withId.capturePoints, isEmpty, reason: '原物件不能被改');
      expect(a.id, 7, reason: 'id 丟了 saveWtAsset 會變成 insert 而不是 update');
      expect(a.siteName, '彰濱');
      expect(a.rotorDiameterM, 150);
    });

    test('拍攝點跟著 toMap/fromMap 落地', () {
      final a = base.upsertCapturePoint(
          const WtCapturePoint(name: 'side', latitude: 3, longitude: 4, headingDeg: 90));
      final back = WtAsset.fromMap(a.toMap());
      expect(back.capturePoint('side')!.longitude, 4);
      expect(back.capturePoint('side')!.headingDeg, 90);
    });
  });

  group('WtAsset.standingDistanceHint（規格 §10.2：3–4 倍輪轂高度，2026-09-16 依偏軸掃描改）', () {
    test('有輪轂高度才提示', () {
      expect(WtAsset(assetId: 'a', hubHeightM: 100).standingDistanceHint, '300–400 m');
      expect(WtAsset(assetId: 'a', hubHeightM: 85).standingDistanceHint, '255–340 m');
      // 下限 3 倍 = 仰角約 18°：合成掃描裡 1.8 倍（29°）全被閘門擋、3 倍全放行
      expect(WtAsset.standingDistanceMinFactor, 3.0);
      expect(WtAsset.standingDistanceMaxFactor, 4.0);
    });

    test('沒有或不合理就 null，不猜', () {
      expect(WtAsset(assetId: 'a').standingDistanceHint, isNull);
      expect(WtAsset(assetId: 'a', hubHeightM: 0).standingDistanceHint, isNull);
      expect(WtAsset(assetId: 'a', hubHeightM: -5).standingDistanceHint, isNull);
    });
  });
}
