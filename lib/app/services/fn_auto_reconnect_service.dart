import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/settings_fn_state.dart';
import 'feiniu/api_client.dart';
import 'feiniu/auth_service.dart';
import 'feiniu/fn_connection_probe_service.dart';

/// 自动重连探测服务（单例）
///
/// 两个触发条件：
/// 1. 网络状态变更（WiFi / 移动数据断开后重连、IP 变更）
/// 2. 连续 API 请求失败（连接超时、连接拒绝、网络错误）
///
/// 触发后执行全链路 FN 探测，成功后更新连接信息。
class FnAutoReconnectService {
  FnAutoReconnectService._();

  static final FnAutoReconnectService instance = FnAutoReconnectService._();

  /// 是否已初始化
  bool _initialized = false;

  /// 网络状态流订阅
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  /// 连续失败计数器
  int _consecutiveFailures = 0;

  /// 连续失败阈值（达到此值触发重连）
  static const int _failureThreshold = 3;

  /// 重连防抖定时器（网络频繁变化时不重复触发）
  Timer? _debounceTimer;

  /// 重连防抖延迟
  static const Duration _debounceDelay = Duration(seconds: 3);

  /// 断开后周期重试定时器（服务器持续不可达时每隔一段时间自动再探测）
  Timer? _retryTimer;

  /// 断开重试间隔
  static const Duration _retryInterval = Duration(seconds: 5);

  /// 初始化：监听网络变化 + 注入 Dio 拦截器
  void init() {
    if (_initialized) return;
    _initialized = true;

    if (kDebugMode) {
      debugPrint('[AutoReconnect] Initializing...');
    }

    // 1. 监听网络变化
    _connectivitySub = Connectivity().onConnectivityChanged.listen(
      _onConnectivityChanged,
    );

    // 2. 注入 Dio 拦截器监听 API 失败
    FeiNiuApiClient.instance.addReconnectMonitor(_onApiFailure);

    // 3. 注册 API 成功回调（重置断开状态）
    FeiNiuApiClient.instance.addRecoveryMonitor(_onApiRecovery);

    if (kDebugMode) {
      debugPrint('[AutoReconnect] Initialized');
    }
  }

  /// 网络状态变化回调
  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final hasConnection = results.any((r) => r != ConnectivityResult.none);

    if (kDebugMode) {
      debugPrint(
        '[AutoReconnect] Connectivity changed: $results → ${hasConnection ? "connected" : "disconnected"}',
      );
    }

    if (hasConnection) {
      // 网络恢复后再等一会，让网络稳定下来
      _debounceTimer?.cancel();
      _debounceTimer = Timer(_debounceDelay, () {
        _triggerReconnect(reason: '网络已恢复');
      });
    } else {
      // 网络断开，重置连续失败计数器
      _consecutiveFailures = 0;
    }
  }

  /// 连接被标记为断开时调用（如启动预热失败），立即触发一次重连，
  /// 失败后保持周期重试直到恢复。
  void onConnectionLost({String reason = '服务器连接失败'}) {
    AppFnConnectionSettings.serverConnected.value = false;
    _triggerReconnect(reason: reason);
    _scheduleRetryIfDisconnected();
  }

  /// 断开期间周期重试：每 [_retryInterval] 探测一次，直到连接恢复
  void _scheduleRetryIfDisconnected() {
    if (AppFnConnectionSettings.serverConnected.value) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(_retryInterval, _onRetryTick);
  }

  void _onRetryTick() {
    if (AppFnConnectionSettings.serverConnected.value) return;
    _triggerReconnect(reason: '连接断开自动重试');
    _scheduleRetryIfDisconnected();
  }

  /// API 请求成功回调：恢复连接状态
  void _onApiRecovery() {
    if (!AppFnConnectionSettings.serverConnected.value) {
      AppFnConnectionSettings.serverConnected.value = true;
      if (kDebugMode) {
        debugPrint('[AutoReconnect] API recovered, connection restored');
      }
    }
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// API 请求失败回调
  void _onApiFailure(DioException error) {
    // 只关注网络层面的错误（超时、连接拒绝、DNS 等）
    final isNetworkError = switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError => true,
      _ => false,
    };

    if (!isNetworkError) return;

    _consecutiveFailures++;

    if (kDebugMode) {
      debugPrint(
        '[AutoReconnect] API failure #$_consecutiveFailures: ${error.type}',
      );
    }

    if (_consecutiveFailures >= _failureThreshold) {
      _consecutiveFailures = 0;
      AppFnConnectionSettings.serverConnected.value = false;
      _triggerReconnect(reason: '连接连续失败 $_failureThreshold 次');
      _scheduleRetryIfDisconnected();
    }
  }

  /// 触发重连
  void _triggerReconnect({required String reason}) {
    // 只有已登录且有上次 FNID 时才自动重连
    if (!AuthService.instance.isLoggedIn.value) return;
    final fnId = AppFnConnectionSettings.lastFnId;
    if (fnId == null || fnId.isEmpty) return;

    // 防止重复触发
    if (FnConnectionProbeService.instance.isProbing.value) return;

    if (kDebugMode) {
      debugPrint('[AutoReconnect] Triggering reconnect, reason: $reason');
    }

    // 异步执行，不阻塞
    _doReconnect(fnId);
  }

  Future<void> _doReconnect(String fnId) async {
    try {
      final preference = AppFnConnectionSettings.connectionPreference.value;
      final result = await FnConnectionProbeService.instance.probe(
        fnId: fnId,
        preference: preference,
      );

      if (kDebugMode) {
        debugPrint(
          '[AutoReconnect] Reconnect succeeded: ${result.serverUrl} (${result.probeMethod})',
        );
      }

      // 更新连接信息
      await AppFnConnectionSettings.saveProbeResult(
        fnId: fnId,
        url: result.serverUrl,
        method: result.probeMethod,
        isRelay: result.isRelay,
      );

      // 如果 baseUrl 变了，更新 API 客户端的 baseUrl
      final currentBase = FeiNiuApiClient.instance.baseUrl;
      if (currentBase != result.serverUrl) {
        await FeiNiuApiClient.instance.setBaseUrl(result.serverUrl);
      }

      // 如果是中继模式，确保 relayMode 开启
      if (result.isRelay) {
        FeiNiuApiClient.instance.setRelayMode(true);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('feiniu_relay_mode', true);
      } else {
        FeiNiuApiClient.instance.setRelayMode(false);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('feiniu_relay_mode', false);
      }

      AppFnConnectionSettings.serverConnected.value = true;
      _consecutiveFailures = 0;
      _retryTimer?.cancel();
      _retryTimer = null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AutoReconnect] Reconnect failed: $e');
      }
      _scheduleRetryIfDisconnected();
    }
  }

  /// 释放资源
  void dispose() {
    _connectivitySub?.cancel();
    _debounceTimer?.cancel();
    _retryTimer?.cancel();
    _initialized = false;
  }
}
