import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state_provider.dart';
import '../providers/inspection_provider.dart';
import '../utils/constants.dart';
import '../widgets/stepper_widget.dart';
import 'step1_upload_checklist.dart';
import 'step2_capture_photos.dart';
import 'step3_review_results.dart';
import 'step4_records_report.dart';
import 'quick_analysis_screen.dart';

/// 主頁面 - 包含步驟導航和主要流程
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    final appState = context.read<AppStateProvider>();
    final inspection = context.read<InspectionProvider>();

    await appState.init();
    await inspection.init();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppStateProvider>(
      builder: (context, appState, child) {
        // 如果是快速分析模式，顯示快速分析頁面
        if (appState.isQuickAnalysisMode) {
          return const QuickAnalysisScreen();
        }

        // 否則顯示主流程
        return Scaffold(
          appBar: AppBar(
            title: const Text('InduSpect AI - 智慧巡檢'),
            actions: [
              // 重置按鈕
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () => _showResetDialog(context),
                tooltip: '重置應用',
              ),
            ],
          ),
          body: Column(
            children: [
              // 步驟指示器
              StepperWidget(
                currentStep: appState.currentStep.number,
                stepTitles: InspectionStep.values.map((e) => e.title).toList(),
              ),
              const Divider(),
              // 主要內容區域
              Expanded(
                child: _buildStepContent(appState.currentStep),
              ),
            ],
          ),
          // 快速分析按鈕（浮動按鈕）
          floatingActionButton: appState.currentStep == InspectionStep.uploadChecklist
              ? FloatingActionButton.extended(
                  onPressed: () => _enterQuickAnalysisMode(context),
                  icon: const Icon(Icons.flash_on),
                  label: const Text('快速分析'),
                  backgroundColor: AppColors.info,
                )
              : null,
        );
      },
    );
  }

  /// 根據當前步驟顯示對應內容
  Widget _buildStepContent(InspectionStep step) {
    switch (step) {
      case InspectionStep.uploadChecklist:
        return const Step1UploadChecklist();
      case InspectionStep.capturePhotos:
        return const Step2CapturePhotos();
      case InspectionStep.reviewResults:
        return const Step3ReviewResults();
      case InspectionStep.viewRecords:
        return const Step4RecordsReport();
    }
  }

  /// 進入快速分析模式
  Future<void> _enterQuickAnalysisMode(BuildContext context) async {
    final appState = context.read<AppStateProvider>();
    await appState.enterQuickAnalysisMode();
  }

  /// 顯示重置確認對話框
  Future<void> _showResetDialog(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('確認重置'),
        content: const Text('這將清除所有巡檢數據和記錄。確定要繼續嗎？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('確定'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      final appState = context.read<AppStateProvider>();
      final inspection = context.read<InspectionProvider>();

      await appState.resetApp();
      await inspection.clearAllData();

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已重置應用')),
        );
      }
    }
  }
}
