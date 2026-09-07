import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// `package:image` 的解碼**會丟例外，不只回 null**。
///
/// 位元組太短時它在格式嗅探階段就炸了——GIF 的 `isValidFile` 會讀一段字串長度，
/// 讀過界變成 `RangeError`，那時連「這是什麼格式」都還沒判斷出來。
/// 所以 `decodeImage(bytes) == null` 這個寫法只擋得住「格式認得出來但內容壞掉」，
/// 擋不住「檔案根本不完整」。
///
/// 現場會遇到的正是後者：外接儲存寫一半被拔掉、複製中斷、使用者從相簿選到非影像檔。
/// 每個呼叫端各自 try/catch 也可以，但那樣「多短算太短」會有好幾套答案，
/// 所以收在這裡一份。
///
/// 放在 `utils/` 而不是任何一個 service 裡是刻意的：定檢與葉片是兩條獨立的功能線，
/// 從其中一條 import 另一條的檔案只為了拿一個解碼 helper，會把兩者黏起來。
///
/// 無法解碼時回 `null`，**不丟例外**。
img.Image? safeDecodeImage(Uint8List bytes) {
  // 連格式標頭都不夠長（PNG 8 / JPEG 2 / GIF 6 bytes，取保守值）。
  // 先擋掉最短的一段，剩下的靠 try/catch——解碼器內部還有很多讀過界的路徑。
  if (bytes.length < minDecodableBytes) return null;
  try {
    return img.decodeImage(bytes);
  } catch (_) {
    return null;
  }
}

/// 小於這個長度一律視為無法解碼
const int minDecodableBytes = 16;
