import 'package:flutter/material.dart';

/// 應用常量定義
class AppConstants {
  // Gemini API 模型名稱
  static const String geminiFlashModel = 'gemini-2.5-flash';
  static const String geminiProModel = 'gemini-2.5-pro';

  // 本地存儲 keys
  static const String keyInspectionItems = 'inspection_items';
  static const String keyInspectionRecords = 'inspection_records';
  static const String keyCurrentStep = 'current_step';
  static const String keyAppState = 'app_state';
  static const String keyAuthTokens = 'auth_tokens';
  static const String keyAssignedJobs = 'assigned_jobs';
  static const String keySelectedJobId = 'selected_job_id';
  static const String keyPendingUploads = 'pending_uploads';

  // 圖片壓縮設置
  static const int maxImageWidth = 1920;
  static const int maxImageHeight = 1080;
  static const int imageQuality = 85;

  // 參考物體尺寸（信用卡標準尺寸）
  static const double creditCardWidthMm = 85.6;
  static const double creditCardHeightMm = 53.98;

  // 超時設置
  static const Duration apiTimeout = Duration(seconds: 60);
  static const Duration imageUploadTimeout = Duration(seconds: 120);
}

/// 應用顏色定義
class AppColors {
  static const Color primary = Color(0xFF1976D2);
  static const Color secondary = Color(0xFF424242);
  static const Color success = Color(0xFF4CAF50);
  static const Color warning = Color(0xFFFFC107);
  static const Color error = Color(0xFFF44336);
  static const Color info = Color(0xFF2196F3);

  // 步驟指示器顏色
  static const Color stepActive = primary;
  static const Color stepCompleted = success;
  static const Color stepInactive = Color(0xFFBDBDBD);

  // 狀態顏色
  static const Color statusNormal = success;
  static const Color statusAbnormal = error;
  static const Color statusPending = warning;

  // 背景顏色
  static const Color backgroundLight = Color(0xFFF5F5F5);
  static const Color backgroundWhite = Colors.white;
}

/// 文字樣式
class AppTextStyles {
  static const TextStyle heading1 = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.bold,
    color: AppColors.secondary,
  );

  static const TextStyle heading2 = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.bold,
    color: AppColors.secondary,
  );

  static const TextStyle heading3 = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    color: AppColors.secondary,
  );

  static const TextStyle body1 = TextStyle(
    fontSize: 16,
    color: AppColors.secondary,
  );

  static const TextStyle body2 = TextStyle(
    fontSize: 14,
    color: AppColors.secondary,
  );

  static const TextStyle caption = TextStyle(
    fontSize: 12,
    color: Colors.grey,
  );

  static const TextStyle buttonText = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
  );
}

/// 間距定義
class AppSpacing {
  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 16.0;
  static const double lg = 24.0;
  static const double xl = 32.0;
  static const double xxl = 48.0;
}

/// 步驟定義
enum InspectionStep {
  uploadChecklist(1, '上傳定檢表'),
  capturePhotos(2, '拍攝巡檢照片'),
  reviewResults(3, '分析與審核結果'),
  viewRecords(4, '檢視記錄與報告');

  final int number;
  final String title;

  const InspectionStep(this.number, this.title);
}

/// 分析狀態
enum AnalysisStatus {
  pending('待分析'),
  analyzing('分析中'),
  completed('已完成'),
  error('錯誤');

  final String label;

  const AnalysisStatus(this.label);
}

/// 設備狀況
enum EquipmentCondition {
  normal('正常'),
  warning('警告'),
  abnormal('異常'),
  unknown('未知');

  final String label;

  const EquipmentCondition(this.label);

  Color get color {
    switch (this) {
      case EquipmentCondition.normal:
        return AppColors.statusNormal;
      case EquipmentCondition.warning:
        return AppColors.warning;
      case EquipmentCondition.abnormal:
        return AppColors.statusAbnormal;
      case EquipmentCondition.unknown:
        return AppColors.statusPending;
    }
  }
}
