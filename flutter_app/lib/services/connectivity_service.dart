import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Service to monitor network connectivity status
class ConnectivityService {
  static final ConnectivityService _instance = ConnectivityService._internal();
  factory ConnectivityService() => _instance;
  ConnectivityService._internal();

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<ConnectivityResult>? _subscription;

  bool _isOnline = false;
  bool get isOnline => _isOnline;

  // Stream controller for connectivity changes
  final _connectivityController = StreamController<bool>.broadcast();
  Stream<bool> get onConnectivityChanged => _connectivityController.stream;

  /// Initialize connectivity monitoring
  Future<void> initialize() async {
    // Check initial connectivity
    await _updateConnectivityStatus();

    // Listen to connectivity changes
    _subscription = _connectivity.onConnectivityChanged.listen((result) {
      _handleConnectivityChange(result);
    });
  }

  /// Update connectivity status
  Future<void> _updateConnectivityStatus() async {
    try {
      final result = await _connectivity.checkConnectivity();
      _handleConnectivityChange(result);
    } catch (e) {
      debugPrint('Error checking connectivity: $e');
      _isOnline = false;
    }
  }

  /// Handle connectivity change
  void _handleConnectivityChange(ConnectivityResult result) {
    final wasOnline = _isOnline;
    _isOnline = result != ConnectivityResult.none;

    debugPrint('Connectivity changed: $result, isOnline: $_isOnline');

    // Notify listeners if status changed
    if (wasOnline != _isOnline) {
      _connectivityController.add(_isOnline);

      if (_isOnline) {
        debugPrint('Internet connection restored');
      } else {
        debugPrint('Internet connection lost');
      }
    }
  }

  /// Manually check if device is online
  Future<bool> checkConnection() async {
    await _updateConnectivityStatus();
    return _isOnline;
  }

  /// Dispose resources
  void dispose() {
    _subscription?.cancel();
    _connectivityController.close();
  }
}
