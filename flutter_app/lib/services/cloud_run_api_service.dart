import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../models/auth_tokens.dart';
import '../models/inspection_job.dart';
import '../models/inspection_item.dart';
import '../models/analysis_result.dart';
import '../utils/constants.dart';

class UploadTicket {
  final String uploadUrl;
  final String objectPath;
  final String? contentType;

  UploadTicket({
    required this.uploadUrl,
    required this.objectPath,
    this.contentType,
  });
}

class CloudRunApiService {
  static final CloudRunApiService _instance = CloudRunApiService._internal();
  factory CloudRunApiService() => _instance;
  CloudRunApiService._internal();

  final Dio _dio = Dio();
  final Dio _uploadDio = Dio();
  AuthTokens? _tokens;
  bool _isRefreshing = false;
  String? _authBaseUrl;
  String? _taskBaseUrl;
  String? _uploadBaseUrl;

  Future<void> init({AuthTokens? tokens}) async {
    _tokens = tokens;
    _authBaseUrl = dotenv.env['CLOUD_RUN_AUTH_URL'] ?? dotenv.env['CLOUD_RUN_BASE_URL'];
    _taskBaseUrl =
        dotenv.env['CLOUD_RUN_TASK_URL'] ?? dotenv.env['CLOUD_RUN_BASE_URL'];
    _uploadBaseUrl =
        dotenv.env['CLOUD_RUN_UPLOAD_URL'] ?? dotenv.env['CLOUD_RUN_BASE_URL'];
    _taskBaseUrl ??= _authBaseUrl;
    _uploadBaseUrl ??= _authBaseUrl;

    if (_authBaseUrl == null || _authBaseUrl!.isEmpty) {
      throw Exception('CLOUD_RUN_BASE_URL or CLOUD_RUN_AUTH_URL is required.');
    }

    _dio.options = BaseOptions(
      connectTimeout: AppConstants.apiTimeout,
      receiveTimeout: AppConstants.apiTimeout,
      sendTimeout: AppConstants.apiTimeout,
    );

    _uploadDio.options = BaseOptions(
      connectTimeout: AppConstants.imageUploadTimeout,
      receiveTimeout: AppConstants.imageUploadTimeout,
      sendTimeout: AppConstants.imageUploadTimeout,
    );
  }

  void updateTokens(AuthTokens? tokens) {
    _tokens = tokens;
  }

  bool get hasValidToken => _tokens != null && !_tokens!.isExpired;

  Future<AuthTokens> login(String email, String password) async {
    final response = await _dio.post(
      '$_authBaseUrl/auth/login',
      data: {
        'email': email,
        'password': password,
      },
    );

    final data = response.data as Map<String, dynamic>;
    final tokens = AuthTokens(
      accessToken: data['accessToken'] as String,
      refreshToken: data['refreshToken'] as String,
      expiresAt: DateTime.parse(data['expiresAt'] as String),
    );
    _tokens = tokens;
    return tokens;
  }

  Future<bool> refreshToken() async {
    if (_tokens == null || _isRefreshing) return false;

    _isRefreshing = true;
    try {
      final response = await _dio.post(
        '$_authBaseUrl/auth/refresh',
        data: {'refreshToken': _tokens!.refreshToken},
      );
      final data = response.data as Map<String, dynamic>;
      _tokens = AuthTokens(
        accessToken: data['accessToken'] as String,
        refreshToken: data['refreshToken'] as String,
        expiresAt: DateTime.parse(data['expiresAt'] as String),
      );
      return true;
    } catch (_) {
      return false;
    } finally {
      _isRefreshing = false;
    }
  }

  Future<List<InspectionJob>> fetchJobs() async {
    await _ensureAuth();
    final response = await _dio.get(
      '$_taskBaseUrl/jobs',
      options: _authOptions(),
    );

    final List<dynamic> data = response.data as List<dynamic>;
    return data.map((json) => InspectionJob.fromJson(json as Map<String, dynamic>)).toList();
  }

  Future<List<InspectionItem>> fetchChecklist(String jobId) async {
    await _ensureAuth();
    final response = await _dio.get(
      '$_taskBaseUrl/jobs/$jobId/checklist',
      options: _authOptions(),
    );
    final List<dynamic> data = response.data as List<dynamic>;
    return data
        .map((json) => InspectionItem(
              id: json['id'] as String,
              description: json['description'] as String? ?? '未命名巡檢點',
              isCompleted: (json['status'] as String?) == 'inspected',
            ))
        .toList();
  }

  Future<UploadTicket> requestUploadTicket(String jobId, String pointId) async {
    await _ensureAuth();
    final response = await _dio.post(
      '$_uploadBaseUrl/jobs/$jobId/points/$pointId/upload-url',
      options: _authOptions(),
    );

    final data = response.data as Map<String, dynamic>;
    return UploadTicket(
      uploadUrl: data['uploadUrl'] as String,
      objectPath: data['objectPath'] as String,
      contentType: data['contentType'] as String?,
    );
  }

  Future<void> uploadBytesToSignedUrl(
    UploadTicket ticket,
    Uint8List bytes, {
    String contentType = 'image/jpeg',
  }) async {
    final headers = {
      'Content-Type': ticket.contentType ?? contentType,
    };
    await _uploadDio.put(
      ticket.uploadUrl,
      data: Stream.fromIterable(bytes.map((e) => [e])),
      options: Options(headers: headers),
    );
  }

  Future<void> notifyUploadComplete(
    String jobId,
    String pointId,
    String objectPath,
  ) async {
    await _ensureAuth();
    await _dio.post(
      '$_uploadBaseUrl/jobs/$jobId/points/$pointId/notify-upload',
      data: {'objectPath': objectPath},
      options: _authOptions(),
    );
  }

  Future<Map<String, dynamic>?> fetchAnalysisStatus(
    String jobId,
    String pointId,
  ) async {
    await _ensureAuth();
    final response = await _dio.get(
      '$_taskBaseUrl/jobs/$jobId/points/$pointId/analysis',
      options: _authOptions(),
    );
    if (response.data == null) return null;
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<AnalysisResult?> waitForAnalysis({
    required String jobId,
    required String pointId,
    required String photoPath,
    Duration timeout = const Duration(minutes: 2),
    Duration pollInterval = const Duration(seconds: 4),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final payload = await fetchAnalysisStatus(jobId, pointId);
      if (payload != null) {
        final status = payload['status'] as String?;
        if (status == 'completed' && payload['result'] != null) {
          return AnalysisResult.fromCloudRunJson(
            pointId,
            photoPath,
            Map<String, dynamic>.from(payload['result'] as Map),
          );
        } else if (status == 'error') {
          throw Exception(payload['message'] ?? '分析服務返回錯誤');
        }
      }
      await Future.delayed(pollInterval);
    }
    return null;
  }

  Options _authOptions() {
    return Options(
      headers: {
        if (_tokens != null) 'Authorization': 'Bearer ${_tokens!.accessToken}',
      },
    );
  }

  Future<void> _ensureAuth() async {
    if (_tokens == null) {
      throw Exception('尚未登入 Cloud Run API');
    }
    if (_tokens!.isExpired) {
      final refreshed = await refreshToken();
      if (!refreshed) {
        throw Exception('Token 已過期且無法刷新，請重新登入');
      }
    }
  }
}
