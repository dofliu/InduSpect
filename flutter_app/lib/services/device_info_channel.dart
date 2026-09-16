import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 裝置總記憶體（MB）。只有 Android 有原生實作（`DeviceInfo.kt`）；
/// 其他平台或原生沒接上一律回 null——`deviceEligibleForLocalModel(null)` 是 false，
/// 查不到就不開端側模型，不猜。
class DeviceInfoChannel {
  DeviceInfoChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('com.induspect/device');

  final MethodChannel _channel;

  Future<int?> totalMemoryMb() async {
    if (kIsWeb) return null;
    try {
      final v = await _channel.invokeMethod<num>('totalMemMb');
      return v?.toInt();
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// App 私有目錄所在儲存的剩餘空間（bytes）；查不到回 null。
  Future<int?> freeStorageBytes() async {
    if (kIsWeb) return null;
    try {
      final v = await _channel.invokeMethod<num>('freeBytes');
      return v?.toInt();
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
