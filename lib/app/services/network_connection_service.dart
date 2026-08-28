import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// 维护当前设备的网络连接类型，供播放策略等需要同步读取网络类型的场景使用。
///
/// `connectivity_plus` 只表示可用的网络接口，不保证互联网实际可达；这里仅用它
/// 区分 Wi-Fi 与蜂窝网络。只有明确包含 [ConnectivityResult.wifi] 才视为 Wi-Fi，
/// VPN/未知网络按非 Wi-Fi 处理，避免误判后消耗蜂窝流量。
class NetworkConnectionService {
  NetworkConnectionService._();

  static final NetworkConnectionService instance = NetworkConnectionService._();

  final ValueNotifier<List<ConnectivityResult>> results =
      ValueNotifier<List<ConnectivityResult>>(const []);
  final ValueNotifier<bool> wifiConnected = ValueNotifier<bool>(false);

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Future<void>? _initializing;

  bool get isWifiConnected => wifiConnected.value;

  Future<void> init() => _initializing ??= _doInit();

  Future<void> _doInit() async {
    try {
      _update(await Connectivity().checkConnectivity());
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[NetworkConnection] Initial check failed: $e');
      }
    }
    _subscription ??= Connectivity().onConnectivityChanged.listen(
      _update,
      onError: (Object error) {
        if (kDebugMode) {
          debugPrint('[NetworkConnection] Change stream failed: $error');
        }
      },
    );
  }

  void _update(List<ConnectivityResult> value) {
    results.value = List<ConnectivityResult>.unmodifiable(value);
    wifiConnected.value = value.contains(ConnectivityResult.wifi);
    if (kDebugMode) {
      debugPrint('[NetworkConnection] changed: $value, wifi=$isWifiConnected');
    }
  }

  @visibleForTesting
  void setResultsForTest(List<ConnectivityResult> value) => _update(value);

  @visibleForTesting
  void resetForTest() {
    results.value = const [];
    wifiConnected.value = false;
  }
}
