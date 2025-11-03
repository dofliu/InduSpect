import 'package:flutter/material.dart';
import '../utils/constants.dart';

/// 步驟指示器組件
class StepperWidget extends StatelessWidget {
  final int currentStep;
  final List<String> stepTitles;

  const StepperWidget({
    super.key,
    required this.currentStep,
    required this.stepTitles,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: List.generate(stepTitles.length, (index) {
          final stepNumber = index + 1;
          final isActive = stepNumber == currentStep;
          final isCompleted = stepNumber < currentStep;

          return Expanded(
            child: _StepItem(
              stepNumber: stepNumber,
              title: stepTitles[index],
              isActive: isActive,
              isCompleted: isCompleted,
              isLast: index == stepTitles.length - 1,
            ),
          );
        }),
      ),
    );
  }
}

class _StepItem extends StatelessWidget {
  final int stepNumber;
  final String title;
  final bool isActive;
  final bool isCompleted;
  final bool isLast;

  const _StepItem({
    required this.stepNumber,
    required this.title,
    required this.isActive,
    required this.isCompleted,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    Color getColor() {
      if (isCompleted) return AppColors.stepCompleted;
      if (isActive) return AppColors.stepActive;
      return AppColors.stepInactive;
    }

    return Row(
      children: [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 圓圈
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: getColor(),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: isCompleted
                      ? const Icon(Icons.check, color: Colors.white, size: 20)
                      : Text(
                          '$stepNumber',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              // 標題
              Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                  color: getColor(),
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        // 連接線
        if (!isLast)
          Expanded(
            child: Container(
              height: 2,
              color: isCompleted ? AppColors.stepCompleted : AppColors.stepInactive,
              margin: const EdgeInsets.only(bottom: 30),
            ),
          ),
      ],
    );
  }
}
