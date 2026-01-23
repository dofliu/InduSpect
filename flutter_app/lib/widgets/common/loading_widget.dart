import 'package:flutter/material.dart';
import '../../utils/constants.dart';

/// 載入動畫組件
class LoadingWidget extends StatelessWidget {
  final String? message;
  final bool showOverlay;

  const LoadingWidget({
    super.key,
    this.message,
    this.showOverlay = false,
  });

  @override
  Widget build(BuildContext context) {
    final widget = Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (message != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              message!,
              style: AppTextStyles.body2,
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );

    if (showOverlay) {
      return Container(
        color: Colors.black54,
        child: widget,
      );
    }

    return widget;
  }
}

/// 按鈕載入狀態
class LoadingButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final bool isLoading;
  final Color? backgroundColor;
  final Color? foregroundColor;

  const LoadingButton({
    super.key,
    required this.text,
    this.onPressed,
    this.isLoading = false,
    this.backgroundColor,
    this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: isLoading ? null : onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: backgroundColor,
        foregroundColor: foregroundColor ?? Colors.white,
        minimumSize: const Size(double.infinity, 48),
      ),
      child: isLoading
          ? const SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            )
          : Text(text, style: AppTextStyles.buttonText),
    );
  }
}
