import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/settings_fn_state.dart';
import 'feiniu/api_client.dart';
import 'feiniu/auth_service.dart';
import 'feiniu/fn_connection_probe_service.dart';
import 'feiniu/fn_models.dart';

/// 自动重连探测服务（单例）
///
/// 触发条件：
/// 1. 网络状态变更（WiFi / 移动数据断开后重连、IP 变更）
/// 2. 连续 API 请求失败（连接超时、连接拒绝、网络错误）
/// 3. App 从后台回到前台（网络环境可能已变化，静默校验当前连接）
/// 4. 连接断开期间的周期重试（服务器持续不可达时每隔一段时间自动再探测）
/// 5. 连接健康检查（处于"已连接"状态时周期验证当前连接 URL 仍可达，
///    一旦失效立即触发完整重连）——覆盖「内网 → 公网」这类无网络断开
///    事件、API 又无请求的静默失效场景
///
/// 触发后执行全链路 FN 探测，成功后更新连接信息。
class FnAutoReconnectService with WidgetsBindingObserver {
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

  /// 连接健康检查定时器（"已连接"时周期验证当前连接仍可用）
  Timer? _healthCheckTimer;

  /// 健康检查间隔
  static const Duration _healthCheckInterval = Duration(minutes: 1);

  /// 健康检查是否在途（防止与前一次检查重叠）
  bool _verifyInFlight = false;

  /// 是否有被推迟的重连（触发时探测正好在进行中）。
  ///
  /// 置位后在探测结束（isProbing 变 false）时由监听器补发一次，
  /// 避免「探测进行中 → 重连被跳过」的重连请求被静默吞掉。
  bool _pendingReconnect = false;

  /// 初始化：监听网络变化 + App 生命周期 + 注入 Dio 拦截器
  void init() {
    if (_initialized) return;
    _initialized = true;

    if (kDebugMode) {
      debugPrint('[AutoReconnect] Initializing...');
    }

    // 0. 注册 App 生命周期监听（后台 → 前台时静默校验当前连接）
    WidgetsBinding.instance.addObserver(this);

    // 1. 监听网络变化
    _connectivitySub = Connectivity().onConnectivityChanged.listen(
      _onConnectivityChanged,
    );

    // 2. 注入 Dio 拦截器监听 API 失败
    FeiNiuApiClient.instance.addReconnectMonitor(_onApiFailure);

    // 3. 注册 API 成功回调（重置断开状态）
    FeiNiuApiClient.instance.addRecoveryMonitor(_onApiRecovery);

    // 4. 探测结束补发被推迟的重连
    FnConnectionProbeService.instance.isProbing.addListener(_onProbeStateChanged);

    // 5. 启动连接健康检查（"已连接"时周期验证当前连接）
    _scheduleHealthCheck();

    if (kDebugMode) {
      debugPrint('[AutoReconnect] Initialized');
    }
  }

  /// 探测结束（isProbing 变 false）且存在被推迟的重连时补发一次。
  void _onProbeStateChanged() {
    if (FnConnectionProbeService.instance.isProbing.value) return;
    if (!_pendingReconnect) return;
    _pendingReconnect = false;
    _triggerReconnect(reason: '补发：上次重连被探测进行中推迟');
  }

  /// App 生命周期回调：从后台回到前台时静默校验当前连接。
  ///
  /// 后台期间 Dart isolate 被挂起，网络变化事件可能丢失（如内网 → 公网
  /// 切换恰好发生在后台），恢复时重新探测能覆盖这一盲区。走轻量健康
  /// 检查（只探当前 URL），失败再完整重连，避免每次回前台都全量探测。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (FnConnectionProbeService.instance.isProbing.value) return;
    final fnId = AppFnConnectionSettings.lastFnId;
    if (fnId == null || fnId.isEmpty) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDelay, () {
      _verifyCurrentConnection(reason: 'App 回到前台，重新校验连接');
    });
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

    // 探测进行中（如启动预热 / 用户手动全量探测 / 另一次重连）时先不打扰，
    // 置位待发标记，探测结束后由监听器补发，避免本次重连请求被静默吞掉。
    if (FnConnectionProbeService.instance.isProbing.value) {
      _pendingReconnect = true;
      if (kDebugMode) {
        debugPrint('[AutoReconnect] Probe in progress, deferring reconnect');
      }
      return;
    }

    if (kDebugMode) {
      debugPrint('[AutoReconnect] Triggering reconnect, reason: $reason');
    }

    // 异步执行，不阻塞
    _doReconnect(fnId);
  }

  Future<void> _doReconnect(String fnId) async {
    try {
      final result = await FnConnectionProbeService.instance.probe(fnId: fnId);

      if (kDebugMode) {
        debugPrint(
          '[AutoReconnect] Reconnect succeeded: ${result.serverUrl} (${result.probeMethod})',
        );
      }

      await _applyProbeResult(fnId, result);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AutoReconnect] Reconnect failed: $e');
      }
      _scheduleRetryIfDisconnected();
    }
  }

  /// 应用探测结果：更新连接信息、API 客户端 baseUrl / relay 模式，并恢复连接状态。
  Future<void> _applyProbeResult(String fnId, ConnectionProbeResult result) async {
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
    _pendingReconnect = false;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// 启动连接健康检查。
  ///
  /// "已连接"时周期验证当前连接 URL 仍可达，失效即触发完整重连——
  /// 覆盖「内网 → 公网」这类没有网络断开事件、API 又无请求的静默失效。
  /// [serverConnected] 复位为 true（恢复连接 / 登录成功）时会再次调度。
  void _scheduleHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer(_healthCheckInterval, _onHealthCheckTick);
  }

  Future<void> _onHealthCheckTick() async {
    _healthCheckTimer = null;
    // 未连接状态由断开重试负责，这里只检查"已连接"是否已悄悄失效
    if (!AppFnConnectionSettings.serverConnected.value) {
      _scheduleHealthCheck();
      return;
    }
    _verifyCurrentConnection(reason: '健康检查');
  }

  /// 轻量校验当前连接：用 200ms 快探探测当前 baseUrl。
  ///
  /// 可达 → 连接正常；不可达 → 标记断开并触发完整重连（成功后保持
  /// 周期检查 / 断开重试）。被完整探测占用（isProbing）或并发重叠时
  /// 跳过本次，避免相互干扰。
  void _verifyCurrentConnection({required String reason}) {
    if (FnConnectionProbeService.instance.isProbing.value) return;
    if (_verifyInFlight) return;
    if (AppFnConnectionSettings.lastFnId == null ||
        AppFnConnectionSettings.lastFnId!.isEmpty) {
      return;
    }
    final current = FeiNiuApiClient.instance.baseUrl;
    if (current.isEmpty) return;

    _verifyInFlight = true;
    unawaited(() async {
      try {
        final reachable = await FnConnectionProbeService.instance
            .isAddressReachable(
              current,
              isRelay: FeiNiuApiClient.instance.relayMode,
            );
        // 探测被并发占用（返回 null）或确认可达 → 连接仍有效
        if (reachable != false) {
          if (kDebugMode) {
            debugPrint('[AutoReconnect] $reason OK: $current');
          }
          return;
        }

        // 当前连接失效 → 标记断开并触发完整重连
        if (kDebugMode) {
          debugPrint(
            '[AutoReconnect] $reason failed: $current, reconnecting...',
          );
        }
        AppFnConnectionSettings.serverConnected.value = false;
        _triggerReconnect(reason: '$reason发现连接失效');
        _scheduleRetryIfDisconnected();
      } finally {
        _verifyInFlight = false;
        _scheduleHealthCheck();
      }
    }());
  }

  /// 释放资源
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FnConnectionProbeService.instance.isProbing
        .removeListener(_onProbeStateChanged);
    _connectivitySub?.cancel();
    _debounceTimer?.cancel();
    _retryTimer?.cancel();
    _healthCheckTimer?.cancel();
    _initialized = false;
  }
}
