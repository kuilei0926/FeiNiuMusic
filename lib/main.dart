import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'app/services/debug_log_service.dart';
import 'app/services/fn_auto_reconnect_service.dart';
import 'app/services/media_notification_service.dart';
import 'app/services/feiniu/api_client.dart';
import 'app/services/feiniu/auth_service.dart';
import 'app/services/feiniu/fn_connection_probe_service.dart';
import 'app/state/settings_fn_state.dart';
import 'app/state/settings_state.dart';

Future<void> main() async {
  // 在一切之前安装进程级 SSL 拦截钩子
  // 此钩子覆盖进程内所有 HttpClient（Dio、CachedNetworkImage/flutter_cache_manager 等共用），
  // 使 SSL 忽略开关全局生效，无需逐处配置。
  if (HttpOverrides.current == null) {
    HttpOverrides.global = _SslOverride();
  }

  WidgetsFlutterBinding.ensureInitialized();
  await DebugLogService.instance.ensureLoaded();
  await FlutterDisplayMode.setHighRefreshRate();
  // 必须先恢复认证信息（token / 服务器地址）再初始化播放相关服务：
  // MediaNotificationService.init() 会实例化 PlayerService，其启动恢复流程
  // （含「进入应用自动播放」）依赖 FeiNiuApiClient.baseUrl 已就绪，
  // 否则流地址解析失败，自动播放会被静默吞掉。
  await AuthService.instance.init();
  await MediaNotificationService.init();
  await AppThemeSettings.ensureLoaded();
  await AppLayoutSettings.ensureLoaded();
  await AppBackgroundSettings.ensureLoaded();
  await AppFnConnectionSettings.ensureLoaded();
  await PlayerStyleSettings.ensureLoaded();
  await AppLaunchNavigationSettings.ensureLoaded();
  // 初始化自动重连服务（监听网络变化 + API 失败）
  FnAutoReconnectService.instance.init();
  runApp(const FeiNiuMusicApp());
  // Fire-and-forget warm-ups that run in parallel with the first frame so
  // per-page initState calls don't have to pay for these cold starts:
  //   - SharedPreferences.getInstance() reads its backing file once, then
  //     serves subsequent callers from the in-memory instance.
  SharedPreferences.getInstance();
  // 后台连接预热：静默验证缓存连接的可用性，不可用时自动回退完整探测
  // 不阻塞首页渲染，首页首次请求走已有连接，预热找到更好的 URL 会无缝切换。
  _warmupConnection();
}

/// 进程级 SSL 证书校验覆盖
///
/// 通过 [HttpOverrides.global] 安装，拦截进程内所有 [HttpClient]，
/// 覆盖 Dio、CachedNetworkImage / flutter_cache_manager 等所有基于 [HttpClient] 的请求。
///
/// [badCertificateCallback] 实时读取 [AppFnConnectionSettings.ignoreSsl]，
/// 开关动态度生效，无需重启 APP。
class _SslOverride extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (_, __, ___) {
      // 实时读取用户 SSL 忽略偏好
      return AppFnConnectionSettings.ignoreSsl.value;
    };
    return client;
  }
}

/// 后台连接预热——不阻塞首页渲染，静默验证缓存连接的可用性
void _warmupConnection() {
  final fnId = AppFnConnectionSettings.lastFnId;
  if (fnId == null || fnId.isEmpty) return;

  final cache = AppFnConnectionSettings.cachedConnection;
  if (cache == null) return;

  final preference = AppFnConnectionSettings.connectionPreference.value;

  // fire-and-forget：不 await，不抛异常到顶层
  FnConnectionProbeService.instance
      .probeWithCache(
        cachedUrl: cache.url,
        cachedIsRelay: cache.isRelay,
        fnId: fnId,
        preference: preference,
      )
      .then((result) {
        // 缓存验证成功且 URL 没变，不做任何事
        if (result.serverUrl == cache.url) return;

        // 缓存失效且探测到了新 URL → 静默更新
        AppFnConnectionSettings.saveProbeResult(
          fnId: fnId,
          url: result.serverUrl,
          method: result.probeMethod,
          isRelay: result.isRelay,
        );
        final currentBase = FeiNiuApiClient.instance.baseUrl;
        if (currentBase != result.serverUrl) {
          FeiNiuApiClient.instance.setBaseUrl(result.serverUrl);
        }
        FeiNiuApiClient.instance.setRelayMode(result.isRelay);
      })
      .catchError((_) {
        // 后台预热失败不报错：标记服务器不可达让横幅显示，
        // 并立即触发自动重连（失败后保持周期重试直到恢复）
        FnAutoReconnectService.instance.onConnectionLost(reason: '启动预热连接失败');
      });
}
