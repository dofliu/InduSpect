// 條件導入：Web 用 stub（回 null），io 平台用 ML Kit 實作
// （ML Kit 僅 Android/iOS 有原生實作；Windows 桌面會 MissingPluginException，
//  由實作內的 try/catch 降級回 null）
import 'meter_ocr_service_stub.dart'
    if (dart.library.io) 'meter_ocr_service_io.dart' as impl;

/// 裝置端儀表 OCR（Tier 1a：離線讀值備援）
///
/// 薄 adapter — 只負責「照片路徑 → OCR 原始文字」，
/// 讀值解析與挑選邏輯全部在 OcrReadingParser（可單元測試）。
/// 任何平台/引擎錯誤一律回傳 null，由呼叫端走原本的失敗路徑。
class MeterOcrService {
  Future<String?> recognizeText(String imagePath) {
    return impl.recognizeText(imagePath);
  }
}
