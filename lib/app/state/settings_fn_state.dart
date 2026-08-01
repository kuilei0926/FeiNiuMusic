import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/feiniu/fn_models.dart';

/// 连接优先级设置（内网 / 公网 IPv6 / 公网 IPv4 / 中继 拖拽排序）与 HTTPS/HTTP 优先
///
/// 遵循与 AppLayoutSettings 相同的模式：
/// - ValueNotifier 驱动 UI 响应式更新
/// - SharedPreferences 持久化用户选择
class AppFnConnectionSettings {
  static const String _prefsConnectionOrder = 'fn_connection_order';
  static const String _prefsConnectionPreference = 'fn_connection_preference';
  static const String _prefsLastFnId = 'fn_last_fnid';
  static const String _prefsConnectionUrl = 'fn_connection_url';
  static const String _prefsConnectionMethod = 'fn_connection_method';
  static const String _prefsIsRelay = 'fn_connection_is_relay';
  static const String _prefsIgnoreSsl = 'fn_connection_ignore_ssl';
  static const String _prefsAccessCode = 'fn_access_code';

  /// 服务器是否可达（false 时在顶部显示连接失败横幅）
  static final ValueNotifier<bool> serverConnected = ValueNotifier(true);

  /// 当前连接优先级顺序（可拖拽自定义）
  static final ValueNotifier<List<ProbeCandidateGroup>> connectionOrder =
      ValueNotifier(List.of(kDefaultConnectionOrder));

  /// 上次使用的 FNID（用于启动时自动探测）
  static String? lastFnId;

  /// 当前实际使用的连接 URL（探测成功后设置）
  static final ValueNotifier<String?> currentConnectionUrl = ValueNotifier(
    null,
  );

  /// 当前连接方式的描述（如"内网 IPv4 HTTPS (192.168.11.200:5667)"）
  static final ValueNotifier<String?> currentConnectionMethod = ValueNotifier(
    null,
  );

  /// 最后的连接是否为中继模式
  static bool lastIsRelay = false;

  /// 是否忽略 SSL 证书校验（默认开启）
  static final ValueNotifier<bool> ignoreSsl = ValueNotifier(true);

  /// 安全码（原始字符串，未 base64）
  ///
  /// 登录时验证并写入；此后所有 API / 图片 / 音频流请求自动携带
  /// `x-access-code: base64(安全码)`。登出时随 [clearConnection] 清除，
  /// 下次登录重新询问。
  static String? accessCode;

  /// 最近一次全量探测结果（每个候选链路的状态）
  ///
  /// 用于「FN Connect」设置页展示完整列表，null 表示从未全量探测过。
  static final ValueNotifier<List<ProbeCandidateResult>?>
  currentCandidateResults = ValueNotifier(null);

  /// FnConnectionParams 摘要字符串（用于判断是否需要重新探测）
  static String? lastProbedFingerprint;

  static Future<void>? _loading;

  /// 懒惰加载：首次调用时从 SharedPreferences 读取
  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  /// 测试用：重置懒加载与内存状态，使 ensureLoaded 可重新读取
  @visibleForTesting
  static void resetForTest() {
    _loading = null;
    connectionOrder.value = List.of(kDefaultConnectionOrder);
    accessCode = null;
  }

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();

    // 连接优先级（含旧「公网/中继优先」偏好迁移）
    final storedOrder = prefs.getStringList(_prefsConnectionOrder);
    if (storedOrder != null) {
      connectionOrder.value = _normalizeOrder(storedOrder);
    } else {
      // 迁移：旧 relayFirst = 内网 → 中继 → 公网 IPv6 → 公网 IPv4
      final legacy = prefs.getString(_prefsConnectionPreference);
      if (legacy == 'relayFirst') {
        connectionOrder.value = const [
          ProbeCandidateGroup.internal,
          ProbeCandidateGroup.relay,
          ProbeCandidateGroup.publicIPv6,
          ProbeCandidateGroup.publicIPv4,
        ];
      } else {
        connectionOrder.value = List.of(kDefaultConnectionOrder);
      }
      await prefs.setStringList(
        _prefsConnectionOrder,
        connectionOrder.value.map((g) => g.name).toList(),
      );
      await prefs.remove(_prefsConnectionPreference);
    }

    // 上次 FNID
    lastFnId = prefs.getString(_prefsLastFnId);

    // 上次连接信息（用于显示）
    final savedUrl = prefs.getString(_prefsConnectionUrl);
    final savedMethod = prefs.getString(_prefsConnectionMethod);
    if (savedUrl != null && savedUrl.isNotEmpty) {
      currentConnectionUrl.value = savedUrl;
    }
    if (savedMethod != null && savedMethod.isNotEmpty) {
      currentConnectionMethod.value = savedMethod;
    }
    lastIsRelay = prefs.getBool(_prefsIsRelay) ?? false;
    ignoreSsl.value = prefs.getBool(_prefsIgnoreSsl) ?? true;
    accessCode = prefs.getString(_prefsAccessCode);
  }

  /// 设置连接优先级顺序并持久化
  static Future<void> setConnectionOrder(
    List<ProbeCandidateGroup> order, {
    VoidCallback? onOrderChanged,
  }) async {
    final normalized = _normalizeOrder(order.map((g) => g.name).toList());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _prefsConnectionOrder,
      normalized.map((g) => g.name).toList(),
    );
    connectionOrder.value = normalized;
    onOrderChanged?.call();
  }

  /// 清洗连接优先级顺序：丢弃未知分组、去重、追加缺失的默认分组
  static List<ProbeCandidateGroup> _normalizeOrder(List<String>? raw) {
    final seen = <ProbeCandidateGroup>{};
    final result = <ProbeCandidateGroup>[];
    if (raw != null) {
      for (final name in raw) {
        for (final group in ProbeCandidateGroup.values) {
          if (group.name == name && seen.add(group)) {
            result.add(group);
            break;
          }
        }
      }
    }
    for (final group in kDefaultConnectionOrder) {
      if (seen.add(group)) {
        result.add(group);
      }
    }
    return result;
  }

  /// 保存本次探测结果（FNID + 连接 URL + 连接方式 + 候选链路列表）
  ///
  /// 同步更新 API 客户端持久化 key（feiniu_server_url / feiniu_relay_mode），
  /// 确保下次启动时 [FeiNiuApiClient.tryLoadAuth] 能直接读到最新可用 URL，
  /// 避免首页请求打到旧 URL 导致空数据。
  static Future<void> saveProbeResult({
    required String fnId,
    required String url,
    required String method,
    List<ProbeCandidateResult>? candidateResults,
    String? fingerprint,
    bool isRelay = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsLastFnId, fnId);
    await prefs.setString(_prefsConnectionUrl, url);
    await prefs.setString(_prefsConnectionMethod, method);
    await prefs.setBool(_prefsIsRelay, isRelay);
    // 同步更新 API 客户端的持久化 key，使启动时的 tryLoadAuth 拿到最新 URL
    await prefs.setString('feiniu_server_url', url);
    await prefs.setBool('feiniu_relay_mode', isRelay);
    lastFnId = fnId;
    lastIsRelay = isRelay;
    currentConnectionUrl.value = url;
    currentConnectionMethod.value = method;
    if (candidateResults != null) {
      currentCandidateResults.value = candidateResults;
    }
    if (fingerprint != null) {
      lastProbedFingerprint = fingerprint;
    }
  }

  /// 设置忽略 SSL 证书校验并持久化，同时通知监听器应用变更
  static Future<void> setIgnoreSsl(
    bool value, {
    VoidCallback? onChanged,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsIgnoreSsl, value);
    ignoreSsl.value = value;
    onChanged?.call();
  }

  /// 设置安全码并持久化（空值则清除）
  static Future<void> setAccessCode(String? code) async {
    final trimmed = code?.trim() ?? '';
    accessCode = trimmed.isEmpty ? null : trimmed;
    final prefs = await SharedPreferences.getInstance();
    if (accessCode == null) {
      await prefs.remove(_prefsAccessCode);
    } else {
      await prefs.setString(_prefsAccessCode, accessCode!);
    }
  }

  /// 获取上次成功探测的缓存连接信息（用于优先探测）
  ///
  /// 返回 (url, isRelay) 或 null（无缓存）
  static ({String url, bool isRelay})? get cachedConnection {
    final url = currentConnectionUrl.value;
    if (url == null || url.isEmpty) return null;
    return (url: url, isRelay: lastIsRelay);
  }

  /// 清除连接信息（登出时调用）
  ///
  /// 保留 FNID，便于退出登录后登录页继续显示 FNID 快速登录。
  static Future<void> clearConnection() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsConnectionUrl);
    await prefs.remove(_prefsConnectionMethod);
    await prefs.remove(_prefsIsRelay);
    await prefs.remove(_prefsIgnoreSsl);
    await prefs.remove(_prefsAccessCode);
    lastIsRelay = false;
    ignoreSsl.value = true;
    accessCode = null;
    currentConnectionUrl.value = null;
    currentConnectionMethod.value = null;
    serverConnected.value = true;
  }
}
