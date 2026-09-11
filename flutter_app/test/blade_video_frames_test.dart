import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/services/blade_video_frames.dart';

/// 裝置端抽幀的 Dart 端契約。
///
/// 原生端（Kotlin）在這裡跑不到，測的是這一層**對原生回什麼、對呼叫端給什麼**：
/// - 參數怎麼送（秒 → 毫秒、四捨五入、長邊上限）
/// - 原生回的 typed data / List<int> / null / 例外，各對到 `analyzeFrames` 定義的
///   「這一幀沒有」（null），**不丟例外**
/// - 非 Android 平台不碰 channel，直接 null；`extractorOrNull` 也是 null，
///   服務層才會照原本的路寫「尚未接上」
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  /// 掛一個假原生端；handler 回什麼就是原生回什麼
  void mockNative(Future<Object?> Function(MethodCall call) handler) {
    calls.clear();
    messenger.setMockMethodCallHandler(BladeVideoFrames.channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(BladeVideoFrames.channel, null);
  });

  group('extract：參數怎麼送', () {
    test('秒 → 毫秒四捨五入、帶路徑與長邊上限', () async {
      mockNative((_) async => Uint8List.fromList([1, 2, 3]));

      await BladeVideoFrames.extract('/v/clip.mp4', 12.3456);

      expect(calls, hasLength(1));
      expect(calls.single.method, 'frameAt');
      final args = (calls.single.arguments as Map).cast<String, Object?>();
      expect(args['path'], '/v/clip.mp4');
      expect(args['atMs'], 12346, reason: '12345.6 ms 四捨五入');
      expect(args['maxSide'], BladeVideoFrames.defaultMaxSide);
    });

    test('maxSide 可覆寫', () async {
      mockNative((_) async => Uint8List.fromList([1]));
      await BladeVideoFrames.extract('/v/clip.mp4', 1.0, maxSide: 640);
      expect((calls.single.arguments as Map)['maxSide'], 640);
    });

    test('負的或非有限的時刻不問原生，直接 null', () async {
      mockNative((_) async => Uint8List.fromList([1]));
      expect(await BladeVideoFrames.extract('/v/clip.mp4', -0.5), isNull);
      expect(await BladeVideoFrames.extract('/v/clip.mp4', double.nan), isNull);
      expect(calls, isEmpty);
    });
  });

  group('extract：原生回什麼 → 呼叫端拿到什麼', () {
    test('Uint8List 原樣回傳', () async {
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
      mockNative((_) async => jpeg);
      final got = await BladeVideoFrames.extract('/v/clip.mp4', 1.0);
      expect(got, isNotNull);
      expect(got!.toList(), jpeg.toList());
    });

    test('List<int> 也接（不同 codec 路徑）', () async {
      mockNative((_) async => <int>[9, 8, 7]);
      final got = await BladeVideoFrames.extract('/v/clip.mp4', 1.0);
      expect(got!.toList(), [9, 8, 7]);
    });

    test('★ null／空陣列 → null：analyzeFrames 把它當「這一幀沒有」', () async {
      mockNative((_) async => null);
      expect(await BladeVideoFrames.extract('/v/clip.mp4', 1.0), isNull);
      mockNative((_) async => Uint8List(0));
      expect(await BladeVideoFrames.extract('/v/clip.mp4', 1.0), isNull);
    });

    test('★ 原生丟 PlatformException → null，不往上炸', () async {
      mockNative((_) async => throw PlatformException(code: 'DECODE', message: 'boom'));
      expect(await BladeVideoFrames.extract('/v/clip.mp4', 1.0), isNull);
      mockNative((_) async => throw PlatformException(code: 'NO_FILE'));
      expect(await BladeVideoFrames.extract('/v/gone.mp4', 1.0), isNull);
    });

    test('原生端沒註冊（MissingPluginException）→ null', () async {
      // 不掛 handler：Flutter 會丟 MissingPluginException
      messenger.setMockMethodCallHandler(BladeVideoFrames.channel, null);
      expect(await BladeVideoFrames.extract('/v/clip.mp4', 1.0), isNull);
    });
  });

  group('平台守門', () {
    test('★ 非 Android：不碰 channel、直接 null；extractorOrNull 是 null', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      mockNative((_) async => Uint8List.fromList([1]));

      expect(BladeVideoFrames.isSupported, isFalse);
      expect(await BladeVideoFrames.extract('/v/clip.mp4', 1.0), isNull);
      expect(calls, isEmpty, reason: '不支援的平台不該打 channel');
      expect(BladeVideoFrames.extractorOrNull, isNull,
          reason: '服務層拿到 null 才會寫「尚未接上」');
    });

    test('Android：extractorOrNull 就是 extract 的 tear-off 形狀', () async {
      mockNative((_) async => Uint8List.fromList([4, 2]));
      final f = BladeVideoFrames.extractorOrNull;
      expect(f, isNotNull);
      final got = await f!('/v/clip.mp4', 2.0);
      expect(got!.toList(), [4, 2]);
      expect((calls.single.arguments as Map)['atMs'], 2000);
    });

    test('非 Android 的 probe 直接講原因', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(
        () => BladeVideoFrames.probe('/v/clip.mp4'),
        throwsA(isA<BladeVideoError>().having((e) => e.message, 'message', contains('僅 Android'))),
      );
    });
  });

  group('probe', () {
    test('解出長度／尺寸／旋轉／幀率；毫秒 → 秒', () async {
      mockNative((call) async {
        expect(call.method, 'probe');
        return <String, Object?>{
          'durationMs': 30500,
          'width': 1080,
          'height': 1920,
          'rotation': 90,
          'frameRate': 29.97,
        };
      });
      final info = await BladeVideoFrames.probe('/v/clip.mp4');
      expect(info.durationS, closeTo(30.5, 1e-9));
      expect(info.width, 1080);
      expect(info.height, 1920);
      expect(info.rotationDeg, 90);
      expect(info.frameRate, closeTo(29.97, 1e-9));
      expect(info.longEnough, isTrue);
    });

    test('幀率缺席是 null（很多手機不寫）；長度不足 10 秒 → longEnough false', () async {
      mockNative((_) async => <String, Object?>{'durationMs': 8000, 'width': 3840, 'height': 2160, 'rotation': 0});
      final info = await BladeVideoFrames.probe('/v/short.mp4');
      expect(info.frameRate, isNull);
      expect(info.longEnough, isFalse);
    });

    test('★ 錯誤碼對到人看得懂的原因', () async {
      mockNative((_) async => throw PlatformException(code: 'NO_FILE'));
      expect(
        () => BladeVideoFrames.probe('/v/gone.mp4'),
        throwsA(isA<BladeVideoError>().having((e) => e.message, 'message', '找不到影片檔')),
      );
      mockNative((_) async => throw PlatformException(code: 'DECODE', message: 'bad moov'));
      expect(
        () => BladeVideoFrames.probe('/v/bad.mp4'),
        throwsA(isA<BladeVideoError>().having((e) => e.message, 'message', contains('bad moov'))),
      );
    });

    test('原生回的不是 Map → 有原因的錯，不是型別例外', () async {
      mockNative((_) async => 'nope');
      expect(() => BladeVideoFrames.probe('/v/x.mp4'), throwsA(isA<BladeVideoError>()));
    });
  });

  group('bytesOf', () {
    test('三種輸入形狀', () {
      expect(BladeVideoFrames.bytesOf(null), isNull);
      expect(BladeVideoFrames.bytesOf(Uint8List(0)), isNull);
      expect(BladeVideoFrames.bytesOf(<int>[]), isNull);
      expect(BladeVideoFrames.bytesOf(Uint8List.fromList([1]))!.toList(), [1]);
      expect(BladeVideoFrames.bytesOf(<int>[2, 3])!.toList(), [2, 3]);
      expect(BladeVideoFrames.bytesOf('text'), isNull);
    });
  });
}
