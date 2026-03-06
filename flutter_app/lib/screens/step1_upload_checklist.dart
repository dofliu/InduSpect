import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import '../providers/app_state_provider.dart';
import '../providers/inspection_provider.dart';
import '../utils/constants.dart';
import '../widgets/common/loading_widget.dart';
import '../widgets/common/cross_platform_image.dart';

class Step1UploadChecklist extends StatefulWidget {
  const Step1UploadChecklist({super.key});

  @override
  State<Step1UploadChecklist> createState() => _Step1UploadChecklistState();
}

class _Step1UploadChecklistState extends State<Step1UploadChecklist> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<AppStateProvider, InspectionProvider>(
      builder: (context, appState, inspection, child) {
        if (!inspection.isLoggedIn) {
          return _buildLoginForm(context, inspection);
        }

        if (inspection.isJobLoading && inspection.selectedJob == null) {
          return const LoadingWidget(message: '正在載入巡檢任務...');
        }

        if (inspection.selectedJob == null) {
          return _buildJobSelection(context, inspection);
        }

        if (inspection.inspectionItems.isEmpty) {
          return const LoadingWidget(message: '正在載入檢查表...');
        }

        return _buildItemsList(context, appState, inspection);
      },
    );
  }

  Widget _buildLoginForm(BuildContext context, InspectionProvider inspection) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('登入 Cloud Run 帳戶', style: AppTextStyles.heading2),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '使用派工帳號登入以取得您被指派的巡檢任務。',
            style: AppTextStyles.body2.copyWith(color: Colors.grey[600]),
          ),
          const SizedBox(height: AppSpacing.lg),
          Form(
            key: _formKey,
            child: Column(
              children: [
                TextFormField(
                  controller: _emailController,
                  decoration: const InputDecoration(
                    labelText: '公司電子郵件',
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                  keyboardType: TextInputType.emailAddress,
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return '請輸入電子郵件';
                    }
                    if (!value.contains('@')) {
                      return '電子郵件格式不正確';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText: '密碼',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscurePassword = !_obscurePassword;
                        });
                      },
                    ),
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return '請輸入密碼';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: AppSpacing.lg),
                LoadingButton(
                  text: '登入並載入任務',
                  isLoading: inspection.isAnalyzing,
                  onPressed: () => _submitLogin(context, inspection),
                  backgroundColor: AppColors.primary,
                ),
                if (inspection.errorMessage != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  _buildErrorBanner(inspection.errorMessage!),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildJobSelection(BuildContext context, InspectionProvider inspection) {
    final jobs = inspection.assignedJobs;

    if (jobs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.assignment_turned_in, size: 72, color: AppColors.primary),
              const SizedBox(height: AppSpacing.md),
              const Text('目前沒有分配的巡檢任務', style: AppTextStyles.heading3),
              const SizedBox(height: AppSpacing.sm),
              Text(
                inspection.errorMessage ?? '請向調度人員確認或稍後再試。',
                textAlign: TextAlign.center,
                style: AppTextStyles.body2.copyWith(color: Colors.grey[600]),
              ),
              const SizedBox(height: AppSpacing.lg),
              LoadingButton(
                text: '重新整理',
                isLoading: inspection.isJobLoading,
                onPressed: () => inspection.refreshAssignedJobs(forceRemote: true),
                backgroundColor: AppColors.primary,
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => inspection.refreshAssignedJobs(forceRemote: true),
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          const Text('選擇巡檢任務', style: AppTextStyles.heading2),
          const SizedBox(height: AppSpacing.md),
          ...jobs.map(
            (job) => Card(
              margin: const EdgeInsets.only(bottom: AppSpacing.md),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(job.title, style: AppTextStyles.heading3),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      job.location ?? '無位置資訊',
                      style: AppTextStyles.caption,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    LinearProgressIndicator(
                      value: job.progress,
                      backgroundColor: Colors.grey[200],
                      color: job.isCompleted
                          ? AppColors.success
                          : AppColors.primary,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '${job.completedPoints} / ${job.totalPoints} 個巡檢點',
                      style: AppTextStyles.caption,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Chip(
                          avatar: const Icon(Icons.bolt, size: 16),
                          label: Text(job.status.toUpperCase()),
                        ),
                        ElevatedButton(
                          onPressed: () => inspection.selectJob(job.id),
                          child: const Text('開始'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItemsList(
    BuildContext context,
    AppStateProvider appState,
    InspectionProvider inspection,
  ) {
    final job = inspection.selectedJob;

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          color: AppColors.backgroundLight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (job != null) ...[
                Text(job.title, style: AppTextStyles.heading2),
                const SizedBox(height: AppSpacing.xs),
                Text(job.location ?? '無位置資訊', style: AppTextStyles.caption),
                const SizedBox(height: AppSpacing.xs),
                Row(
                  children: [
                    Chip(
                      label: Text(job.status.toUpperCase()),
                      avatar: Icon(
                        job.isCompleted ? Icons.check_circle : Icons.timelapse,
                        color: job.isCompleted ? AppColors.success : AppColors.warning,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    if (inspection.hasPendingUploads)
                      Chip(
                        avatar: const Icon(Icons.cloud_upload, color: Colors.white),
                        backgroundColor: AppColors.warning,
                        label: Text(
                          '${inspection.pendingUploadTasks.length} 張照片待上傳',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                  ],
                ),
              ],
              if (inspection.errorMessage != null) ...[
                const SizedBox(height: AppSpacing.sm),
                _buildErrorBanner(inspection.errorMessage!),
              ],
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(AppSpacing.md),
            itemCount: inspection.inspectionItems.length,
            itemBuilder: (context, index) {
              final item = inspection.inspectionItems[index];
              return _PhotoItemCard(
                item: item,
                index: index,
                pendingError: inspection.getPendingUploadError(item.id),
                isPendingUpload:
                    inspection.pendingUploadItemIds.contains(item.id),
                onCapture: () => _capturePhoto(context, inspection, item.id),
              );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 4,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LoadingButton(
                text: inspection.hasPendingUploads
                    ? '同步 ${inspection.pendingUploadTasks.length} 張照片'
                    : '開始巡檢拍攝',
                onPressed: inspection.hasPendingUploads
                    ? () => inspection.processPendingUploads()
                    : () => appState.nextStep(),
                backgroundColor:
                    inspection.hasPendingUploads ? AppColors.info : AppColors.success,
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: () => inspection.clearSelectedJob(),
                child: const Text('切換巡檢工作'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildErrorBanner(String message) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.error.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: AppColors.error),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: AppColors.error),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _submitLogin(
    BuildContext context,
    InspectionProvider inspection,
  ) async {
    if (!_formKey.currentState!.validate()) return;
    await inspection.loginAndLoadJobs(
      _emailController.text.trim(),
      _passwordController.text,
    );
    if (inspection.errorMessage == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('登入成功，已載入最新任務')),
      );
    }
  }

  Future<void> _capturePhoto(
    BuildContext context,
    InspectionProvider inspection,
    String itemId,
  ) async {
    final source = await showDialog<ImageSource>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('選擇照片來源'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt, color: Colors.blue),
              title: const Text('拍攝照片'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: Colors.green),
              title: const Text('從圖庫選擇'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );

    if (source != null) {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1080,
      );
      if (image != null) {
        await inspection.addPhotoToItemFromXFile(itemId, image);
      }
    }
  }
}

class _PhotoItemCard extends StatelessWidget {
  final InspectionItem item;
  final int index;
  final VoidCallback onCapture;
  final bool isPendingUpload;
  final String? pendingError;

  const _PhotoItemCard({
    required this.item,
    required this.index,
    required this.onCapture,
    required this.isPendingUpload,
    required this.pendingError,
  });

  @override
  Widget build(BuildContext context) {
    final isCompleted = item.isCompleted;

    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                backgroundColor:
                    isCompleted ? AppColors.success : AppColors.primary,
                child: isCompleted
                    ? const Icon(Icons.check, color: Colors.white)
                    : Text('${index + 1}'),
              ),
              title: Text(item.description),
              subtitle: Text(
                isCompleted ? '已拍攝' : '待拍攝',
                style: TextStyle(
                  color: isCompleted ? AppColors.success : Colors.grey[600],
                ),
              ),
              trailing: isPendingUpload
                  ? const Icon(Icons.cloud_upload, color: AppColors.warning)
                  : null,
            ),
            if (isCompleted && item.photoPath != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CrossPlatformImage(
                    imagePath: item.photoPath!,
                    height: 180,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            const SizedBox(height: AppSpacing.sm),
            if (pendingError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Text(
                  pendingError!,
                  style: const TextStyle(color: AppColors.error, fontSize: 12),
                ),
              ),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onCapture,
                icon: Icon(isCompleted ? Icons.camera_alt : Icons.add_a_photo),
                label: Text(isCompleted ? '重新拍攝' : '拍攝照片'),
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      isCompleted ? AppColors.warning : AppColors.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
