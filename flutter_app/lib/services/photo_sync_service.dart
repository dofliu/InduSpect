import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/photo_sync_task.dart';
import '../models/template_inspection_record.dart';
import 'database_service.dart';
import 'connectivity_service.dart';
import 'gemini_service.dart';

/// Service to handle background photo synchronization and AI analysis
class PhotoSyncService {
  static final PhotoSyncService _instance = PhotoSyncService._internal();
  factory PhotoSyncService() => _instance;
  PhotoSyncService._internal();

  final DatabaseService _databaseService = DatabaseService();
  final ConnectivityService _connectivityService = ConnectivityService();
  final GeminiService _geminiService = GeminiService();

  bool _isProcessing = false;
  StreamSubscription<bool>? _connectivitySubscription;

  // Stream controller for sync progress
  final _syncProgressController = StreamController<SyncProgress>.broadcast();
  Stream<SyncProgress> get onSyncProgress => _syncProgressController.stream;

  /// Initialize the sync service
  Future<void> initialize() async {
    // Listen to connectivity changes
    _connectivitySubscription = _connectivityService.onConnectivityChanged.listen((isOnline) {
      if (isOnline) {
        debugPrint('Connection restored, starting photo sync...');
        processPendingTasks();
      }
    });

    // Process any pending tasks if already online
    if (_connectivityService.isOnline) {
      processPendingTasks();
    }
  }

  /// Add a photo to sync queue
  Future<PhotoSyncTask> queuePhotoForSync({
    required String recordId,
    required String fieldId,
    required String photoPath,
  }) async {
    final task = PhotoSyncTask(
      taskId: const Uuid().v4(),
      recordId: recordId,
      fieldId: fieldId,
      photoPath: photoPath,
      status: SyncStatus.pending,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    final id = await _databaseService.saveSyncTask(task);
    final savedTask = task.copyWith(id: id.toString());

    debugPrint('Photo queued for sync: ${savedTask.taskId}');

    // Try to process immediately if online
    if (_connectivityService.isOnline) {
      processPendingTasks();
    }

    return savedTask;
  }

  /// Process all pending sync tasks
  Future<void> processPendingTasks() async {
    if (_isProcessing) {
      debugPrint('Sync already in progress, skipping...');
      return;
    }

    if (!_connectivityService.isOnline) {
      debugPrint('Offline, cannot process sync tasks');
      return;
    }

    _isProcessing = true;

    try {
      final pendingTasks = await _databaseService.getPendingSyncTasks();
      final failedTasks = await _databaseService.getFailedSyncTasks();
      final allTasks = [...pendingTasks, ...failedTasks];

      if (allTasks.isEmpty) {
        debugPrint('No pending sync tasks');
        return;
      }

      debugPrint('Processing ${allTasks.length} sync tasks...');

      _syncProgressController.add(SyncProgress(
        total: allTasks.length,
        completed: 0,
        current: null,
      ));

      for (int i = 0; i < allTasks.length; i++) {
        final task = allTasks[i];

        _syncProgressController.add(SyncProgress(
          total: allTasks.length,
          completed: i,
          current: task,
        ));

        await _processTask(task);

        // Small delay between tasks to avoid rate limiting
        if (i < allTasks.length - 1) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }

      _syncProgressController.add(SyncProgress(
        total: allTasks.length,
        completed: allTasks.length,
        current: null,
      ));

      debugPrint('Finished processing sync tasks');
    } catch (e) {
      debugPrint('Error processing sync tasks: $e');
    } finally {
      _isProcessing = false;
    }
  }

  /// Process a single sync task
  Future<void> _processTask(PhotoSyncTask task) async {
    debugPrint('Processing task: ${task.taskId}');

    try {
      // Update status to syncing
      await _databaseService.updateSyncTaskStatus(
        taskId: task.taskId,
        status: SyncStatus.syncing,
      );

      // Check if photo file exists
      final photoFile = File(task.photoPath);
      if (!await photoFile.exists()) {
        throw Exception('Photo file not found: ${task.photoPath}');
      }

      // Read image bytes
      final imageBytes = await photoFile.readAsBytes();

      // Perform AI analysis using quickAnalyze
      final analysisResult = await _geminiService.quickAnalyze(
        itemId: task.fieldId,
        imageBytes: imageBytes,
        photoPath: task.photoPath,
      );

      // Convert AnalysisResult to Map for storage
      final aiResultMap = {
        'status': analysisResult.status.toString(),
        'condition': analysisResult.condition,
        'severity': analysisResult.severity,
        'description': analysisResult.description,
        'suggestions': analysisResult.suggestions,
        'measuredValues': analysisResult.measuredValues,
        'analysisError': analysisResult.analysisError,
      };

      // Update task as completed with AI result
      await _databaseService.updateSyncTaskStatus(
        taskId: task.taskId,
        status: SyncStatus.completed,
        aiResult: aiResultMap,
      );

      // Update the inspection record with AI results
      await _updateRecordWithAIResults(task.recordId, task.fieldId, aiResultMap);

      debugPrint('Task completed successfully: ${task.taskId}');
    } catch (e) {
      debugPrint('Task failed: ${task.taskId}, error: $e');

      // Update task as failed with error message
      await _databaseService.updateSyncTaskStatus(
        taskId: task.taskId,
        status: SyncStatus.failed,
        errorMessage: e.toString(),
      );
    }
  }

  /// Update inspection record with AI analysis results
  Future<void> _updateRecordWithAIResults(
    String recordId,
    String fieldId,
    Map<String, dynamic> aiResult,
  ) async {
    final record = await _databaseService.getRecordByRecordId(recordId);
    if (record == null) {
      debugPrint('Record not found: $recordId');
      return;
    }

    // Merge AI results into filled data
    final updatedFilledData = Map<String, dynamic>.from(record.filledData);
    aiResult.forEach((key, value) {
      if (value != null) {
        updatedFilledData[key] = value;
      }
    });

    // Update record
    final updatedRecord = record.copyWith(
      filledData: updatedFilledData,
      updatedAt: DateTime.now(),
    );

    await _databaseService.saveRecord(updatedRecord);
    debugPrint('Record updated with AI results: $recordId');
  }

  /// Get sync statistics
  Future<SyncStats> getSyncStats() async {
    final pendingCount = await _databaseService.getSyncTaskCount(status: SyncStatus.pending);
    final syncingCount = await _databaseService.getSyncTaskCount(status: SyncStatus.syncing);
    final completedCount = await _databaseService.getSyncTaskCount(status: SyncStatus.completed);
    final failedCount = await _databaseService.getSyncTaskCount(status: SyncStatus.failed);

    return SyncStats(
      pending: pendingCount,
      syncing: syncingCount,
      completed: completedCount,
      failed: failedCount,
    );
  }

  /// Retry failed tasks
  Future<void> retryFailedTasks() async {
    final failedTasks = await _databaseService.getFailedSyncTasks();

    for (final task in failedTasks) {
      await _databaseService.updateSyncTaskStatus(
        taskId: task.taskId,
        status: SyncStatus.pending,
        errorMessage: null,
      );
    }

    processPendingTasks();
  }

  /// Clear completed tasks
  Future<void> clearCompletedTasks() async {
    await _databaseService.deleteCompletedSyncTasks();
    debugPrint('Cleared completed sync tasks');
  }

  /// Dispose resources
  void dispose() {
    _connectivitySubscription?.cancel();
    _syncProgressController.close();
  }
}

/// Sync progress information
class SyncProgress {
  final int total;
  final int completed;
  final PhotoSyncTask? current;

  SyncProgress({
    required this.total,
    required this.completed,
    this.current,
  });

  double get percentage => total > 0 ? (completed / total * 100) : 0;
  bool get isComplete => completed >= total;
}

/// Sync statistics
class SyncStats {
  final int pending;
  final int syncing;
  final int completed;
  final int failed;

  SyncStats({
    required this.pending,
    required this.syncing,
    required this.completed,
    required this.failed,
  });

  int get totalActive => pending + syncing;
  int get total => pending + syncing + completed + failed;
}
