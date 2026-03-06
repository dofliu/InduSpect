import 'dart:typed_data';

/// Stub implementation — should never be reached at runtime.
/// The conditional import selects web or mobile.
Future<void> saveFile({
  required Uint8List bytes,
  required String fileName,
}) async {
  throw UnsupportedError('Platform not supported');
}
