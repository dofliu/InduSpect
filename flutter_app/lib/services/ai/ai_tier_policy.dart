/// 選層——純函式，沒有任何平台相依，所以測得到。
///
/// 四層的定義在 `LAUNCH_PLAN.md` §5.3：
/// Tier 2 雲端 Gemini（連得上就用它）→ Tier 1b 端側 VLM（離線且模型就位）
/// → Tier 1a 裝置端 OCR（讀值備援，既有路徑）→ 手動。
enum AiTier { cloud, localLlm, ocrOnly, manual }

/// 端側模型的硬需求。數字來源：HF `google/gemma-3n-E2B-it-litert-lm`
/// `gemma-3n-E2B-it-int4.litertlm` 3.66 GB（2026-09-16 查）；常駐 2–3 GB，
/// 加上 App 與相機，8 GB RAM 才穩（`LAUNCH_PLAN.md` §5.4）。
class LocalModelRequirements {
  const LocalModelRequirements._();

  static const String modelId = 'gemma-3n-E2B-it-int4.litertlm';
  static const String displayName = 'Gemma 3n E2B（int4）';
  static const int approxSizeBytes = 3660000000; // 3.66 GB
  static const int minTotalRamMb = 7000; // 名目 8 GB 的機型回報值常在 7.2–7.8 GB
  static const String licenseUrl = 'https://ai.google.dev/gemma/terms';
  static const String huggingFaceRepo = 'google/gemma-3n-E2B-it-litert-lm';

  /// 下載後還要留這麼多空間給照片與 DB。
  static const int freeSpaceMarginBytes = 1000000000; // 1 GB
}

/// 這台裝置能不能跑端側模型。`totalRamMb` 為 null 代表查不到（非 Android），
/// 查不到就當不能——寧可少開一個功能，不要讓使用者下載 3.7 GB 之後閃退。
bool deviceEligibleForLocalModel(int? totalRamMb) =>
    totalRamMb != null && totalRamMb >= LocalModelRequirements.minTotalRamMb;

/// 現在能不能開始下載。
/// [wifiOnly] 是使用者設定；預設 true——3.7 GB 走行動網路是會被罵的。
bool downloadAllowed({
  required bool onWifi,
  required bool wifiOnly,
  required int? freeBytes,
}) {
  if (wifiOnly && !onWifi) return false;
  if (freeBytes == null) return false;
  return freeBytes >=
      LocalModelRequirements.approxSizeBytes +
          LocalModelRequirements.freeSpaceMarginBytes;
}

/// 這一次分析該走哪一層。
///
/// - 連得上雲端就用雲端：端側只是備援，不是取代（初判品質比不上、而且要覆核）。
/// - 離線時，使用者開了離線 AI **且**模型就位 **且**裝置夠 → 端側。
/// - 否則 OCR 備援（既有 Tier 1a）；OCR 不可用時手動。
AiTier chooseAiTier({
  required bool online,
  required bool cloudConfigured,
  required bool localEnabled,
  required bool localModelReady,
  required bool deviceEligible,
  bool ocrAvailable = true,
}) {
  if (online && cloudConfigured) return AiTier.cloud;
  if (localEnabled && localModelReady && deviceEligible) return AiTier.localLlm;
  return ocrAvailable ? AiTier.ocrOnly : AiTier.manual;
}
