import 'package:flutter/material.dart';

import '../../pages/home/home_page.dart';
import '../../pages/login/login_page.dart';
import '../../pages/account/account_switch_page.dart';
import '../../pages/songs/songs_page.dart';
import '../../pages/home/recent_playback_page.dart';
import '../../pages/home/favorite_page.dart';
import '../../pages/player/player_page.dart';
import '../../pages/player/lyrics/lyric_page.dart';
import '../../pages/profile/profile_page.dart';
import '../../pages/settings/gradient_settings_page.dart';
import '../../pages/settings/lyrics_settings_page.dart';
import '../../pages/settings/notification_settings_page.dart';
import '../../pages/settings/permission_settings_page.dart';
import '../../pages/settings/app_appearance_settings_page.dart';
import '../../pages/settings/player_controls_settings_page.dart';
import '../../pages/settings/player_appearance_settings_page.dart';
import '../../pages/settings/cache_settings_page.dart';
import '../../pages/settings/fn_connect_settings_page.dart';
import '../../pages/settings/listening_stats_page.dart';
import '../../pages/settings/backup_restore_page.dart';
import '../../pages/report/listening_report_page.dart';
import '../../pages/settings/settings_page.dart';
import '../../pages/settings/version_info_page.dart';
import '../../pages/settings/volume_settings_page.dart';
import '../../pages/settings/launch_settings_page.dart';
import '../../pages/settings/transcode_settings_page.dart';
import '../../pages/settings/search_source_page.dart';
import '../../pages/settings/match_settings_page.dart';
import '../../pages/settings/metadata_match_settings_page.dart';
import '../../pages/settings/dlna_settings_page.dart';
import '../../pages/library/albums_page.dart';
import '../../pages/library/artists_page.dart';
import '../../pages/library/playlists_page.dart';
import '../../pages/library/genres_page.dart';
import '../../pages/library/folders_page.dart';
import '../../pages/search/search_page.dart';
import '../../pages/songs/batch_match_page.dart';
import '../../app/state/settings_state.dart';
import '../../app/state/song_state.dart';
import '../../app/utils/primary_shell_scope.dart';
import '../../components/layout/modern_navigation_bar.dart';
import '../../components/list/song_multi_select_mixin.dart'
    show globalMultiSelectActive, requestCancelMultiSelect;

class AppRoutes {
  static const login = '/login';
  static const accounts = '/accounts';
  static const home = '/home';
  static const songs = '/songs';
  static const player = '/player';
  static const lyrics = '/player/lyrics';
  static const settings = '/settings';
  static const appAppearanceSettings = '/settings/app-appearance';
  static const gradientSettings = '/settings/gradient';
  static const lyricsSettings = '/settings/lyrics';
  static const notificationSettings = '/settings/notifications';
  static const permissionSettings = '/settings/permissions';
  static const playerControlsSettings = '/settings/player-controls';
  static const playerAppearanceSettings = '/settings/player-appearance';
  static const cacheSettings = '/settings/cache';
  static const listeningStats = '/settings/listening-stats';
  static const listeningReport = '/settings/listening-report';
  static const backupRestore = '/settings/backup-restore';
  static const versionInfo = '/settings/version-info';
  static const volumeScheduleSettings = '/settings/volume-schedule';
  static const fnConnectSettings = '/settings/fn-connect';
  static const launchSettings = '/settings/launch';
  static const artists = '/artists';
  static const albums = '/albums';
  static const playlists = '/playlists';
  static const genres = '/genres';
  static const folders = '/folders';
  static const recent = '/recent';
  static const favorites = '/favorites';
  static const search = '/search';
  static const profile = '/profile';
  static const batchMatch = '/songs/batch-match';
  static const dataSourceSettings = '/settings/data-sources';
  static const matchSettings = '/settings/match';
  static const metadataMatchSettings = '/settings/metadata-match';
  static const transcodeSettings = '/settings/transcode';
  static const dlnaSettings = '/settings/dlna';
}

class AppRouter {
  static String get initialRoute {
    // 如果已有 token 直接进首页，否则去登录页（由 app.dart 中 ValueListenableBuilder 控制）
    return AppRoutes.home;
  }

  static Map<String, WidgetBuilder> get routes => {
    AppRoutes.login: (_) => const LoginPage(),
    AppRoutes.accounts: (_) => const AccountSwitchPage(),
    AppRoutes.home: (_) => const _PrimaryNavigationShell(),
    AppRoutes.songs: (_) => const SongsPage(),
    AppRoutes.player: (_) => const PlayerPage(),
    AppRoutes.lyrics: (_) => LyricPage(),
    AppRoutes.settings: (_) => const SettingsPage(),
    AppRoutes.appAppearanceSettings: (_) => const AppAppearanceSettingsPage(),
    AppRoutes.gradientSettings: (_) => const GradientSettingsPage(),
    AppRoutes.lyricsSettings: (_) => const LyricsSettingsPage(),
    AppRoutes.notificationSettings: (_) => const NotificationSettingsPage(),
    AppRoutes.permissionSettings: (_) => const PermissionSettingsPage(),
    AppRoutes.playerControlsSettings: (_) => const PlayerControlsSettingsPage(),
    AppRoutes.playerAppearanceSettings: (_) =>
        const PlayerAppearanceSettingsPage(),
    AppRoutes.cacheSettings: (_) => const CacheSettingsPage(),
    AppRoutes.listeningStats: (_) => const ListeningStatsPage(),
    AppRoutes.listeningReport: (_) => const ListeningReportPage(),
    AppRoutes.backupRestore: (_) => const BackupRestorePage(),
    AppRoutes.versionInfo: (_) => const VersionInfoPage(),
    AppRoutes.volumeScheduleSettings: (_) => const VolumeSettingsPage(),
    AppRoutes.fnConnectSettings: (_) => const FnConnectSettingsPage(),
    AppRoutes.launchSettings: (_) => const LaunchSettingsPage(),
    AppRoutes.artists: (_) => const ArtistsPage(),
    AppRoutes.albums: (_) => const AlbumsPage(),
    AppRoutes.playlists: (_) => const PlaylistsPage(),
    AppRoutes.genres: (_) => const GenresPage(),
    AppRoutes.folders: (_) => const FoldersPage(),
    AppRoutes.search: (context) => SearchPage(
      initialCategory: (ModalRoute.of(context)?.settings.arguments as SearchCategory?) ?? SearchCategory.song,
    ),
    AppRoutes.profile: (_) => const ProfilePage(),
    AppRoutes.recent: (_) => const RecentPlaybackPage(),
    AppRoutes.favorites: (_) => const FavoritePage(),
    AppRoutes.batchMatch: (context) => BatchMatchPage(
      songs: (ModalRoute.of(context)?.settings.arguments as List<dynamic>? ?? const [])
          .cast<SongEntity>(),
    ),
    AppRoutes.dataSourceSettings: (_) => const SearchSourcePage(),
    AppRoutes.matchSettings: (_) => const MatchSettingsPage(),
    AppRoutes.metadataMatchSettings: (_) => const MetadataMatchSettingsPage(),
    AppRoutes.transcodeSettings: (_) => const TranscodeSettingsPage(),
    AppRoutes.dlnaSettings: (_) => const DlnaSettingsPage(),
  };
}

class _PrimaryNavigationShell extends StatefulWidget {
  const _PrimaryNavigationShell();

  @override
  State<_PrimaryNavigationShell> createState() =>
      _PrimaryNavigationShellState();
}

class _PrimaryNavigationShellState extends State<_PrimaryNavigationShell> {
  int _currentIndex = 0;
  final List<Widget?> _pages = <Widget?>[
    const HomePage(),
    null,
    null,
    null,
    null,
  ];
  bool _warmupScheduled = false;

  Widget _buildPage(int index) {
    return switch (index) {
      0 => const HomePage(),
      1 => const PlaylistsPage(),
      2 => const SongsPage(),
      3 => const FavoritePage(),
      4 => const ProfilePage(),
      _ => const SizedBox.shrink(),
    };
  }

  @override
  void initState() {
    super.initState();
    primaryNavigationShellActive = true;
    primaryNavigationIndex.value = _currentIndex;
    primaryNavigationIndex.addListener(_handleExternalSelection);
  }

  @override
  void dispose() {
    primaryNavigationIndex.removeListener(_handleExternalSelection);
    primaryNavigationShellActive = false;
    super.dispose();
  }

  void _handleExternalSelection() {
    _select(primaryNavigationIndex.value);
  }

  void _select(int index) {
    if (_currentIndex == index || index < 0 || index > 4) return;
    setState(() {
      _pages[index] ??= _buildPage(index);
      _currentIndex = index;
    });
    if (primaryNavigationIndex.value != index) {
      primaryNavigationIndex.value = index;
    }
  }

  /// Build the remaining tabs during idle time so their DB reads and first
  /// frame happen while the user is still looking at Home. Subsequent taps on
  /// the bottom bar just flip IndexedStack.index — no cold start.
  void _scheduleWarmup() {
    if (_warmupScheduled) return;
    _warmupScheduled = true;
    // Give Home one full frame to settle first.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Then spread the remaining pages across idle slots so we don't stall
      // the very next frame with three heavy initState() runs at once.
      _warmOne(1, delay: const Duration(milliseconds: 250));
      _warmOne(2, delay: const Duration(milliseconds: 700));
      _warmOne(3, delay: const Duration(milliseconds: 1100));
      _warmOne(4, delay: const Duration(milliseconds: 1500));
    });
  }

  void _warmOne(int index, {required Duration delay}) {
    Future<void>.delayed(delay, () {
      if (!mounted) return;
      if (_pages[index] != null) return;
      setState(() {
        _pages[index] = _buildPage(index);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppNavigationStyle>(
      valueListenable: AppLayoutSettings.navigationStyle,
      builder: (context, navigationStyle, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: AppLayoutSettings.effectiveTabletModeNotifier,
          builder: (context, effectiveTabletMode, _) {
            final useBottomNavigation =
                navigationStyle == AppNavigationStyle.bottomBar &&
                !effectiveTabletMode;
            if (!useBottomNavigation) return const HomePage();

            _scheduleWarmup();

            return PopScope(
              canPop: _currentIndex == 0,
              onPopInvokedWithResult: (didPop, result) {
                if (didPop) return;
                // 多选中：返回键语义是「取消多选、留在当前页」，不是切 tab。
                // bump 取消请求信号，多选页（歌曲/收藏）监听后退出多选。
                if (globalMultiSelectActive.value > 0) {
                  requestCancelMultiSelect.value += 1;
                  return;
                }
                if (_currentIndex != 0) _select(0);
              },
              child: PrimaryShellMarker(
                child: PrimaryNavigationScope(
                  currentIndex: _currentIndex,
                  onSelected: _select,
                  child: Stack(
                    children: [
                      IndexedStack(
                        index: _currentIndex,
                        children: List.generate(
                          _pages.length,
                          (index) =>
                              _pages[index] ?? const SizedBox.shrink(),
                        ),
                      ),
                      // 共享底栏：整个 shell 只渲染一份，跨 tab 切换保持常驻，
                      // TabIndicator 的内部弹簧状态（tabXAlign）因此始终连续——
                      // 点击时胶囊从「当前 tab」弹向目标 tab，与 demo 一致。
                      // 若每个 tab 页面各自渲染一份底栏（各自持有独立的
                      // TabIndicatorState），切换后胶囊会从各页预热/上次访问时
                      // 的过期位置起跳，看起来就像「闪一下之前的选中项」。
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: ValueListenableBuilder<int>(
                          valueListenable: globalMultiSelectActive,
                          builder: (context, multiSelectCount, _) {
                            // 多选时页面底部出现操作栏（歌曲/收藏等 tab 页），
                            // 共享底栏悬浮在内容上方会盖住它，与平板外壳对迷你
                            // 播放器的处理一致（见 tablet_layout_host.dart），
                            // 任一页面进入多选即整体隐藏底栏。
                            if (multiSelectCount > 0) {
                              return const SizedBox.shrink();
                            }
                            return ModernNavigationBar(onTap: _select);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
