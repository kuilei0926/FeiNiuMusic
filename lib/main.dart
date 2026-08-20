import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'app/theme/app_glass_theme.dart';
import 'app/services/audio/stream_cache_service.dart';
import 'app/services/backup/backup_service.dart';
import 'app/services/debug_log_service.dart';
import 'app/services/fn_auto_reconnect_service.dart';
import 'app/services/island_lyric_service.dart';
import 'app/services/media_notification_service.dart';
import 'app/services/portable_storage_service.dart';
import 'app/services/tv_detection.dart';
import 'app/services/track_change_overlay_service.dart';
import 'app/services/feiniu/account_store.dart';
import 'app/services/feiniu/api_client.dart';
import 'app/services/feiniu/auth_service.dart';
import 'app/services/feiniu/fn_connection_probe_service.dart';
import 'app/services/song_match/match_source_state.dart';
import 'app/state/settings_island_lyric.dart';
import 'app/state/settings_lyric_companion.dart';
import 'app/state/settings_match.dart';
import 'app/state/settings_state.dart';

Future<void> main() async {
  // 在一切之前安装进程级 SSL 拦截钩子
  // 此钩子覆盖进程内所有 HttpClient（Dio、CachedNetworkImage/flutter_cache_manager 等共用），
  // 使 SSL 忽略开关全局生效，无需逐处配置。
  if (HttpOverrides.current == null) {
    HttpOverrides.global = _SslOverride();
  }

  WidgetsFlutterBinding.ensureInitialized();
  // 便携模式：Windows 下把数据目录重定向到 exe 旁 `feiniumusic_data/`。
  // 必须在任何 SharedPreferences / path_provider 读取之前替换全局实例，
  // 否则 prefs/数据库/缓存会落回系统 %APPDATA%。
  AppPortableStorage.overridePathProviderForPortable();
  // 初始化 media_kit（加载 libmpv 原生库）。必须在任何 Player() 构造前调用；
  // 放在认证恢复之前，不依赖网络/账号状态。
  try {
    MediaKit.ensureInitialized();
  } catch (e) {
    debugPrint('MediaKit.ensureInitialized failed: $e');
  }
  await DebugLogService.instance.ensureLoaded();
  // TV 检测必须在 runApp 前完成，避免首帧后再切换布局造成闪变。
  // TV 面板固定 60Hz，强制高刷无意义甚至闪烁，因此高刷调用跳过 TV。
  await TvDetection.ensureLoaded();
  final isTvDevice = TvDetection.result.value;
  // flutter_displaymode 仅 Android 实现；Windows/桌面端跳过（无高刷概念）。
  if (!isTvDevice && Platform.isAndroid) {
    await FlutterDisplayMode.setHighRefreshRate();
  }
  // 先加载设置：确保持久化的「TV 模式」手动开关已就位，再合并检测结果。
  // 必须放在 syncTvMode() 之前，否则重启后已开启的开关读不进来，
  // tvMode 会被算成 false（设置不丢失，但布局不会切到 TV）。
  await AppLayoutSettings.ensureLoaded();
  // 合并自动检测 + 设置页手动强制开关，写入 tvMode。
  TvDetectionAutoValue.value = isTvDevice;
  AppLayoutSettings.syncTvMode();
  // 按设备类型锁定方向：TV 恒横屏；平板（或手动平板模式）四方向自由旋转；
  // 手机锁竖屏。运行中开关切换由 app.dart 的 _TvOrientationSync 负责再应用。
  await SystemChrome.setPreferredOrientations(
    AppLayoutSettings.orientationsForDevice(
      isTv: AppLayoutSettings.tvMode.value,
      shortestSide: AppLayoutSettings.currentShortestSide(),
      manualTabletMode: AppLayoutSettings.tabletMode.value,
    ),
  );
  // 必须先恢复认证信息（token / 服务器地址）再初始化播放相关服务：
  // MediaNotificationService.init() 会实例化 PlayerService，其启动恢复流程
  // （含「进入应用自动播放」）依赖 FeiNiuApiClient.baseUrl 已就绪，
  // 否则流地址解析失败，自动播放会被静默吞掉。
  //
  // 首次启动引导标记必须在 MediaNotificationService.init() 之前预加载：
  // isFirstLaunchSession 需在 PlayerService 启动恢复（_restorePlaybackState
  // 读 shouldAutoPlayOnAppLaunch）之前确定，否则首次启动引导页勾选的
  // 「进入应用自动播放」可能在本次启动就被自动播放（应等下次启动生效）。
  await AppOnboardingSettings.ensureLoaded();
  // 转码设置须在 PlayerService（MediaNotificationService.init）之前加载：
  // 启动恢复自动播放时 _sourceForSong 会同步读转码开关，未加载会读到默认关。
  await AppTranscodeSettings.ensureLoaded();
  // 便携模式·换机检测：数据目录跟随 exe，若文件夹被拷到另一台电脑运行，
  // 自动清空本机 NAS 密码/token/安全码（保留服务器地址与用户名），
  // 避免把本机凭据带到别的机器。须在 AuthService.init（恢复会话）之前执行。
  await AppPortableStorage.checkMachineOwner();
  await AuthService.instance.init();
  // 媒体通知（MediaSession/通知栏/Android Auto）仅 Android 有原生实现。
  // 桌面端跳过：PlayerService 由首个用到它的页面懒构造，无需在此初始化。
  if (Platform.isAndroid) {
    await MediaNotificationService.init();
  }
  // 切歌通知监听：PlayerService 已构造（MediaNotificationService.init 内），
  // AppLayoutSettings 已在上面 ensureLoaded，可安全订阅 currentSong。
  // AppThemeSettings 需先 ensureLoaded：TrackChangeOverlayService 在切歌时
  // 用主题设置计算悬浮窗卡片配色（computeCardColors），若未加载会读到默认值。
  await AppThemeSettings.ensureLoaded();
  // 切歌悬浮窗/灵动岛歌词均为 Android 系统级通知（SYSTEM_ALERT_WINDOW /
  // HyperOS 焦点通知），桌面端无对应实现，跳过启动避免无谓构造 PlayerService。
  if (Platform.isAndroid) {
    TrackChangeOverlayService.start();
  }
  // 通知歌词灵动岛监听：依赖 PlayerService 与 LyricsService 已就绪。
  // 设置懒加载（IslandLyricSettings.ensureLoaded）由设置页与 start 内部处理，
  // 默认关闭不打扰。
  await IslandLyricSettings.ensureLoaded();
  if (Platform.isAndroid) {
    IslandLyricService.start();
  }
  // 数据源匹配设置 + 服务端增强（FnMusicEnhance）设置：启动时加载。
  await MatchSettings.ensureLoaded();
  await MatchSourceState.instance.ensureLoaded();
  // 后台刷新可用平台（不阻塞启动）：首次运行拉取列表并默认全启用，
  // 后续启动读缓存；后端不可达时静默保留缓存。
  unawaited(() async {
    try {
      await MatchSourceState.instance.refresh();
    } catch (_) {
      // 后端不可达：保留缓存，不阻塞启动
    }
  }());
  await LyricCompanionSettings.ensureLoaded();
  await AppBackgroundSettings.ensureLoaded();
  // 液体玻璃设置需在首帧前加载：首帧即尊重持久化的关闭态，避免闪一帧玻璃。
  await AppGlassSettings.ensureLoaded();
  await AppFnConnectionSettings.ensureLoaded();
  // 已保存账号列表初始化：迁移/校正当前账号，并注册 401 token 同步回调。
  // 需在 AuthService.init（恢复激活槽位）与 AppFnConnectionSettings.ensureLoaded
  // （读取安全码/FNID）之后执行。
  await AccountStore.instance.init();
  await PlayerStyleSettings.ensureLoaded();
  await AppLaunchNavigationSettings.ensureLoaded();
  // DLNA 投屏设置（播放页投屏按钮据此显示/隐藏）
  await DlnaCastSettings.ensureLoaded();
  // 初始化自动重连服务（监听网络变化 + API 失败）
  FnAutoReconnectService.instance.init();
  // 迁移歌曲缓存到系统标准缓存目录后，启动时顺手清理旧版 app-support 目录中的
  // 缓存（仅首次运行执行一次，见 StreamCacheService.cleanupLegacyDirOnce）。
  unawaited(StreamCacheService.instance.cleanupLegacyDirOnce());
  // 自动备份：每天首次打开 App 时静默备份到已配置的 WebDAV 目标。
  // fire-and-forget，失败不阻塞启动。
  unawaited(BackupService.instance.maybeAutoBackupOnLaunch());
  // 液体玻璃：预热 shader（非阻塞异步磁盘 I/O，0.30.x 保证 runApp 前零 GPU
  // 调用，首帧不卡顿）。开关只决定渲染哪个组件分支，此处始终初始化。
  await LiquidGlassWidgets.initialize();
  // 用 LiquidGlassWidgets.wrap 包裹整个 App：
  // - brightnessResolver: Theme.maybeBrightnessOf —— MaterialApp 必须传，
  //   否则暗色模式下玻璃阴影/描边会消失；
  // - theme: 全局玻璃主题。监听主题种子色 + 玻璃可调参数（模糊/厚度），
  //   变化时重建 wrap（GlassTheme 是 InheritedWidget，重建安全、树形不变）；
  // - adaptiveQuality: 自动按设备性能封顶质量。
  runApp(
    ListenableBuilder(
      listenable: Listenable.merge([
        AppThemeSettings.themeSeedColor,
        AppGlassSettings.glassBlurStrength,
        AppGlassSettings.glassThickness,
      ]),
      builder: (context, _) => LiquidGlassWidgets.wrap(
        child: const FeiNiuMusicApp(),
        brightnessResolver: Theme.maybeBrightnessOf,
        theme: appGlassTheme(
          AppThemeSettings.themeSeedColor.value ?? const Color(0xFF3B82F6),
        ),
        adaptiveQuality: true,
      ),
    ),
  );
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
    client.badCertificateCallback = (_, _, _) {
      // 实时读取用户 SSL 忽略偏好
      return AppFnConnectionSettings.ignoreSsl.value;
    };
    // 浏览器 UA：网易云等平台 CDN 拒绝 Dart/Dio 默认 UA（HTTP 403），
    // 全局覆盖使封面加载（CachedNetworkImage/NetworkImage/Dio）统一带浏览器 UA。
    client.userAgent = _browserUserAgent;
    return client;
  }
}

/// 浏览器 User-Agent（外部平台封面/CDN 用）。
const String _browserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/// 后台连接预热——不阻塞首页渲染，静默验证缓存连接的可用性
void _warmupConnection() {
  final fnId = AppFnConnectionSettings.lastFnId;
  if (fnId == null || fnId.isEmpty) return;

  final cache = AppFnConnectionSettings.cachedConnection;
  if (cache == null) return;

  // fire-and-forget：不 await，不抛异常到顶层
  FnConnectionProbeService.instance
      .probeSmart(
        cachedUrl: cache.url,
        cachedIsRelay: cache.isRelay,
        fnId: fnId,
      )
      .then((result) async {
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
        // 把探测得到的连接信息回写当前账号，保持账号列表与连接一致
        await AccountStore.instance.syncActiveAccountConnection();
      })
      .catchError((_) {
        // 后台预热失败不报错：标记服务器不可达让横幅显示，
        // 并立即触发自动重连（失败后保持周期重试直到恢复）
        FnAutoReconnectService.instance.onConnectionLost(reason: '启动预热连接失败');
      });
}
