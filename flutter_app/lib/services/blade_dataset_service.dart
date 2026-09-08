import '../models/wt_asset.dart';
import '../models/wt_capture_session.dart';
import '../models/wt_detection.dart';

/// 一份媒體在訓練語料裡的標記。
///
/// **標記的來源是人，不是演算法。** 演算法的 severity 是它自己的輸出，拿它當標籤
/// 訓練只會讓模型學會模仿演算法（包含它的誤報）。這個 App 唯一的真實標籤是
/// 第四步「人工確認」留下的 `humanStatus`——而那個訊號目前寫進 DB 之後
/// 沒有任何東西拿出來用。
enum BladeDatasetLabel {
  /// 人工**確認過**的缺陷。微調偵測器的正樣本。
  defect,

  /// 人工**駁回**的發現——演算法誤報。負樣本，而且是最有價值的那一種：
  /// 它標出演算法在哪裡會弄錯（塗裝接縫、LEP 邊緣、雲影）。
  falsePositive,

  /// 人工看過整個場次、對這份媒體沒有留下任何成立的發現，而且照片本身過了品質閘門。
  ///
  /// **PatchCore 的記憶庫只能用這一類。**「演算法沒報」不等於「人看過沒問題」，
  /// 混在一起的話記憶庫裡會摻進演算法漏檢的真缺陷——那正是讓異常偵測靜靜失效的
  /// 方式：它把缺陷學成正常。
  humanClean,

  /// 沒過品質閘門的媒體。不管有沒有人看過都不能用：從它算出來的數值不可採信，
  /// 而把模糊的畫面放進記憶庫等於教模型「模糊是正常的」。
  unusable,

  /// 沒有人簽核過這個場次。既不能當正樣本，也**不能**當健康樣本。
  unreviewed,
}

/// 語料裡的一筆。
class BladeDatasetItem {
  /// 相對於匯出目錄的路徑（`media/<sessionId>/<檔名>`）。
  /// 不存絕對路徑：語料要能搬到別的機器上訓練。
  final String relativePath;

  /// 原始檔案的絕對路徑（匯出時要複製；不寫進 manifest）
  final String sourcePath;

  final BladeDatasetLabel label;
  final String assetId;
  final String sessionId;
  final String? turbineModel;

  /// 拍攝當時的風機狀態。Phase 4 的健康樣本記憶庫要分開收：轉動中拍的全機照
  /// 有動態模糊與不同的葉片姿態，跟停機拍的不是同一種「正常」。
  final WtTurbineState turbineState;
  final DateTime capturedAt;
  final WtMediaKind kind;
  final WtMediaView view;
  final String? zone;
  final String? bladePosition;
  final String? leadingEdge;
  final double? zoom;

  /// 拍攝品質閘門的判定結果（原封不動帶出去）
  final Map<String, dynamic> qualityJson;

  /// 這份媒體上的每一筆發現：演算法的數值 + AI 的解讀 + **人的判定**。
  /// 逐筆帶出去而不只帶媒體層級的標記，因為微調偵測器要的是「哪一個區域是缺陷」。
  final List<Map<String, dynamic>> detections;

  const BladeDatasetItem({
    required this.relativePath,
    required this.sourcePath,
    required this.label,
    required this.assetId,
    required this.sessionId,
    required this.capturedAt,
    required this.kind,
    required this.view,
    this.turbineModel,
    this.turbineState = WtTurbineState.unknown,
    this.zone,
    this.bladePosition,
    this.leadingEdge,
    this.zoom,
    this.qualityJson = const {},
    this.detections = const [],
  });

  Map<String, dynamic> toJson() => {
        'path': relativePath,
        'label': label.name,
        'asset_id': assetId,
        'session_id': sessionId,
        if (turbineModel != null) 'turbine_model': turbineModel,
        // 未記錄就不寫，不要讓 manifest 看起來像「已知是 unknown」
        if (turbineState != WtTurbineState.unknown) 'turbine_state': turbineState.name,
        'captured_at': capturedAt.toIso8601String(),
        'kind': kind.name,
        'view': view.name,
        if (zone != null) 'zone': zone,
        if (bladePosition != null) 'blade_position': bladePosition,
        if (leadingEdge != null) 'leading_edge': leadingEdge,
        if (zoom != null) 'zoom': zoom,
        if (qualityJson.isNotEmpty) 'quality': qualityJson,
        if (detections.isNotEmpty) 'detections': detections,
      };
}

/// 語料的統計與「還差多少」。
///
/// Phase 4 的估時在規格裡寫的是「視資料量」，但**沒有任何地方看得到資料量**。
/// 這個摘要就是把那句話變成一個數字。
class BladeDatasetSummary {
  final Map<BladeDatasetLabel, int> counts;

  /// 依視角分的 `humanClean` 數。PatchCore 要的是**分區段照**（葉片表面填滿畫面），
  /// 整機照上一片葉片只有幾個像素，放進記憶庫學不到表面紋理。
  final Map<WtMediaView, int> humanCleanByView;
  final Map<String, int> humanCleanByZone;
  final int assetCount;
  final int sessionCount;
  final int reviewedSessionCount;

  const BladeDatasetSummary({
    required this.counts,
    required this.humanCleanByView,
    required this.humanCleanByZone,
    required this.assetCount,
    required this.sessionCount,
    required this.reviewedSessionCount,
  });

  int of(BladeDatasetLabel l) => counts[l] ?? 0;

  /// 真正能進 PatchCore 記憶庫的張數
  int get memoryBankCandidates => humanCleanByView[WtMediaView.segment] ?? 0;

  /// 微調偵測器的正樣本數
  int get defectSamples => of(BladeDatasetLabel.defect);

  /// MVTec-AD 的 PatchCore 論文每類用約 200 張正常影像；降到數十張仍可運作但會退化。
  /// **這是文獻上的量級，不是這個專案量出來的**——本專案目前沒有任何真實語料可以
  /// 驗證那個數字在葉片上成不成立。
  static const int patchCoreReferenceNormals = 200;
  static const int patchCoreMinimumNormals = 30;

  /// 一句話講清楚「現在能不能訓練」。**不給樂觀的說法**：資料不夠就說不夠。
  String get readiness {
    final n = memoryBankCandidates;
    if (n == 0) {
      return '目前有 0 張人工確認過的乾淨分區段照，無法訓練健康樣本異常偵測。'
          '這一層的整個前提是「同一支手機、同一台風機」的健康 patch 記憶庫，'
          '沒有那些照片就沒有可學的東西——合成影像或別人拍的公開照片都不能替代'
          '（那樣訓出來的是「不像我的算圖器」而不是「不像健康葉片」）。';
    }
    if (n < patchCoreMinimumNormals) {
      return '目前有 $n 張人工確認過的乾淨分區段照。文獻上 PatchCore 每類約用 '
          '$patchCoreReferenceNormals 張正常影像，降到 $patchCoreMinimumNormals 張'
          '左右仍可運作但會明顯退化——現在還不足以訓練。';
    }
    if (n < patchCoreReferenceNormals) {
      return '目前有 $n 張人工確認過的乾淨分區段照，已超過可運作的下限'
          '（約 $patchCoreMinimumNormals 張），但低於文獻常用的 '
          '$patchCoreReferenceNormals 張。可以先做一版看效果，'
          '**評估時要留一批沒進記憶庫的照片當測試集**。';
    }
    return '目前有 $n 張人工確認過的乾淨分區段照，達到文獻常用的量級。'
        '缺陷正樣本 $defectSamples 張——微調偵測器需要的是這一類，'
        '而它比健康照難收集得多。';
  }

  Map<String, dynamic> toJson() => {
        'counts': {
          for (final l in BladeDatasetLabel.values) l.name: of(l),
        },
        'human_clean_by_view': {
          for (final e in humanCleanByView.entries) e.key.name: e.value,
        },
        'human_clean_by_zone': humanCleanByZone,
        'assets': assetCount,
        'sessions': sessionCount,
        'reviewed_sessions': reviewedSessionCount,
        'memory_bank_candidates': memoryBankCandidates,
        'defect_samples': defectSamples,
        'readiness': readiness,
      };
}

/// 把 App 累積下來的拍攝與人工確認整理成訓練語料（規格 §9 Phase 4 的前置）。
///
/// **這一層純邏輯、不碰檔案系統與 DB**，所以標記規則測得到。複製檔案與打包由
/// `blade_dataset_export.dart` 負責。
///
/// Phase 4 的方法（PatchCore 類，只用正常 patch 訓練）本身**還做不了**：它需要
/// 目標領域的健康 patch 記憶庫，而這個專案目前一張都沒有。這一層做的是讓那件事
/// 變得可能——把 App 已經在收集但沒有出口的訊號整理出來。
class BladeDatasetService {
  BladeDatasetService._();

  /// manifest 的格式版本。改欄位語意時要加一，訓練腳本才知道自己讀的是什麼。
  static const int schemaVersion = 1;

  /// 人工簽核過的場次狀態。只有這些場次的媒體才有「人看過」這個保證。
  static const Set<WtSessionStatus> reviewedStatuses = {
    WtSessionStatus.confirmed,
    WtSessionStatus.shared,
  };

  /// 判定一份媒體的標記。規則的順序有意義，見各分支的說明。
  static BladeDatasetLabel labelOf({
    required WtMedia media,
    required WtCaptureSession session,
    required List<WtDetection> mediaDetections,
  }) {
    // ①品質閘門優先。這是影像本身的性質，在任何人看它之前就決定了；
    // 沒過閘門的照片算出來的數值不可採信，也不能當健康樣本。
    // `qualityOk` 未分析時是 null，這裡用 `!= true`：「沒驗過」不算「驗過了」。
    if (media.qualityOk != true) return BladeDatasetLabel.unusable;

    // ②沒有人簽核過的場次，媒體一律未標記。
    if (!reviewedStatuses.contains(session.status)) {
      return BladeDatasetLabel.unreviewed;
    }

    // ③簽核過的場次裡竟然還有待確認的發現 → 不信任這個場次的簽核。
    // `_finishReview` 有守門所以理論上不會發生，但語料的正確性比防禦性程式碼的
    // 整潔重要：這裡寧可少收一筆，不要收一筆錯的。
    if (mediaDetections.any((d) => d.humanStatus == WtHumanStatus.pending)) {
      return BladeDatasetLabel.unreviewed;
    }

    // ④有任何一筆被人工確認 → 這份媒體含真缺陷。
    // （同一份媒體可以同時有確認與駁回的發現；那仍然是缺陷樣本，
    //   被駁回的那幾筆在 `detections` 裡逐筆帶出去，不會消失。）
    if (mediaDetections.any((d) => d.humanStatus == WtHumanStatus.confirmed)) {
      return BladeDatasetLabel.defect;
    }

    // ⑤全部被駁回 → 演算法誤報樣本。
    if (mediaDetections.isNotEmpty) return BladeDatasetLabel.falsePositive;

    // ⑥人看過、沒有任何發現、照片可用 → 唯一能進記憶庫的那一類。
    return BladeDatasetLabel.humanClean;
  }

  /// 整理成語料。[detectionsBySession] 的 key 是 `sessionId`。
  static List<BladeDatasetItem> collect({
    required List<WtCaptureSession> sessions,
    required Map<String, List<WtDetection>> detectionsBySession,
    Map<String, WtAsset> assets = const {},
    Set<BladeDatasetLabel>? onlyLabels,
  }) {
    final out = <BladeDatasetItem>[];
    for (final session in sessions) {
      final all = detectionsBySession[session.sessionId] ?? const [];
      for (final media in session.media) {
        final mine =
            all.where((d) => d.mediaPath == media.path).toList(growable: false);
        final label = labelOf(
            media: media, session: session, mediaDetections: mine);
        if (onlyLabels != null && !onlyLabels.contains(label)) continue;
        out.add(BladeDatasetItem(
          relativePath: _relativePathOf(session.sessionId, media.path),
          sourcePath: media.path,
          label: label,
          assetId: session.assetId,
          sessionId: session.sessionId,
          turbineModel: assets[session.assetId]?.model,
          turbineState: session.turbineState,
          capturedAt: media.capturedAt,
          kind: media.kind,
          view: media.view,
          zone: media.zone,
          bladePosition: media.bladePosition,
          leadingEdge: media.leadingEdge,
          zoom: media.zoom,
          qualityJson: media.qualityJson,
          detections: mine.map(_detectionJson).toList(growable: false),
        ));
      }
    }
    return out;
  }

  static BladeDatasetSummary summarize({
    required List<BladeDatasetItem> items,
    required List<WtCaptureSession> sessions,
  }) {
    final counts = <BladeDatasetLabel, int>{};
    final byView = <WtMediaView, int>{};
    final byZone = <String, int>{};
    for (final it in items) {
      counts[it.label] = (counts[it.label] ?? 0) + 1;
      if (it.label != BladeDatasetLabel.humanClean) continue;
      byView[it.view] = (byView[it.view] ?? 0) + 1;
      final z = it.zone;
      if (z != null) byZone[z] = (byZone[z] ?? 0) + 1;
    }
    return BladeDatasetSummary(
      counts: counts,
      humanCleanByView: byView,
      humanCleanByZone: byZone,
      assetCount: sessions.map((s) => s.assetId).toSet().length,
      sessionCount: sessions.length,
      reviewedSessionCount:
          sessions.where((s) => reviewedStatuses.contains(s.status)).length,
    );
  }

  /// 自我描述的 manifest。訓練腳本只讀這一份就知道每張照片是什麼、標記從哪來。
  static Map<String, dynamic> buildManifest({
    required List<BladeDatasetItem> items,
    required BladeDatasetSummary summary,
    DateTime? exportedAt,
  }) =>
      {
        'schema_version': schemaVersion,
        'exported_at': (exportedAt ?? DateTime.now()).toIso8601String(),
        '_readme': [
          'InduSpect 葉片檢測語料。標記來源是**人工確認**（第四步）而不是演算法輸出：',
          '拿演算法的 severity 當標籤訓練，只會讓模型學會模仿演算法，包含它的誤報。',
          'label 的語意：',
          '  defect        = 人工確認過的缺陷（正樣本）',
          '  falsePositive = 人工駁回的發現（演算法誤報，負樣本）',
          '  humanClean    = 人看過整個場次、這份媒體沒有成立的發現，且過了品質閘門',
          '  unusable      = 沒過拍攝品質閘門，數值不可採信',
          '  unreviewed    = 沒有人簽核過這個場次',
          '**健康樣本異常偵測（PatchCore 類）的記憶庫只能用 humanClean 的分區段照。**',
          '「演算法沒報」不等於「人看過沒問題」——混用會把演算法漏檢的真缺陷學成正常。',
        ],
        'summary': summary.toJson(),
        'items': items.map((i) => i.toJson()).toList(),
      };

  static String _relativePathOf(String sessionId, String sourcePath) {
    final name = sourcePath.split(RegExp(r'[/\\]')).last;
    return 'media/$sessionId/$name';
  }

  static Map<String, dynamic> _detectionJson(WtDetection d) => {
        'detection_id': d.detectionId,
        'layer': d.layer.name,
        if (d.blade != null) 'blade': d.blade,
        if (d.zone != null) 'zone': d.zone,
        if (d.defectClass != null) 'defect_class': d.defectClass,
        // 演算法／AI 的輸出與人的判定分開存，訓練時才分得清哪個是標籤
        'algorithm_severity': d.severity,
        'source': d.source.name,
        'human_status': d.humanStatus.name,
        if (d.humanNote != null) 'human_note': d.humanNote,
        if (d.aiDescription != null) 'ai_description': d.aiDescription,
        if (d.metricJson.isNotEmpty) 'metrics': d.metricJson,
        if (d.bboxJson.isNotEmpty) 'bbox': d.bboxJson,
      };
}
