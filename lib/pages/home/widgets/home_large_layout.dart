import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../../app/services/feiniu/api_client.dart';
import '../../../app/services/feiniu/api_models.dart';
import '../../../app/state/settings_layout_state.dart';
import '../../../app/state/song_state.dart';
import '../../../app/tv/tv_layout.dart';
import '../../../components/common/artwork_widget.dart';
import '../../../components/common/cover_image_cache.dart';
import '../../../components/focus/tv_focusable.dart';
import 'home_cover_carousel.dart';
import 'home_hero_banner.dart';
import 'home_panel.dart';
import 'home_section_header.dart';
import 'home_section_feedback.dart';
import 'home_shortcut_menu.dart';

/// 首页大屏布局（平板 / TV / Windows）。
///
/// 模块从上到下：
///   1. 顶部 — 漫游 Banner + 四分类快捷四宫格，窄屏上下排列
///   2. 中部 — 根据可用宽度排列 1–3 栏，列表各自可上下滚动
///   3. 底部 — 推荐歌单 + 最新专辑 横向滑动（左右可滚动）
///
/// 手机端保持原有滚动布局，不进本组件。所有数据与回调由 HomePage 传入。
class HomeLargeLayout extends StatelessWidget {
  final SongEntity? heroSong;
  final Map<HomeSection, Widget> sectionFeedback;
  final VoidCallback onPlayRoam;
  final VoidCallback onRefreshRoam;
  final List<HomeShortcutItem> shortcutItems;
  final List<SongEntity> recentSongs;
  final VoidCallback onPlayRecent;
  final VoidCallback onOpenRecent;
  final ValueChanged<SongEntity> onTapRecent;
  final ValueChanged<SongEntity>? onLongPressRecent;
  final List<FeiNiuPlaylist> playlists;
  final VoidCallback onOpenPlaylists;
  final void Function(FeiNiuPlaylist) onTapPlaylist;
  final List<FeiNiuAlbum> recentAlbums;
  final VoidCallback onOpenAlbums;
  final void Function(FeiNiuAlbum) onTapAlbum;
  final List<SongEntity> recentTracks;
  final VoidCallback onOpenSongs;
  final ValueChanged<SongEntity> onTapTrack;
  final ValueChanged<SongEntity>? onLongPressTrack;
  final List<SongEntity> favoriteSongs;
  final VoidCallback onOpenFavorite;
  final ValueChanged<SongEntity> onTapFavorite;

  const HomeLargeLayout({
    super.key,
    this.heroSong,
    this.sectionFeedback = const {},
    required this.onPlayRoam,
    required this.onRefreshRoam,
    required this.shortcutItems,
    required this.recentSongs,
    required this.onPlayRecent,
    required this.onOpenRecent,
    required this.onTapRecent,
    this.onLongPressRecent,
    required this.playlists,
    required this.onOpenPlaylists,
    required this.onTapPlaylist,
    required this.recentAlbums,
    required this.onOpenAlbums,
    required this.onTapAlbum,
    required this.recentTracks,
    required this.onOpenSongs,
    required this.onTapTrack,
    this.onLongPressTrack,
    required this.favoriteSongs,
    required this.onOpenFavorite,
    required this.onTapFavorite,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double?>(
      valueListenable: AppLayoutSettings.tvUiScaleOverride,
      builder: (context, _, _) => _buildScaled(context),
    );
  }

  Widget _buildScaled(BuildContext context) {
    final scale = AppLayoutSettings.tvMode.value
        ? TvLayout.uiScale(context)
        : 1.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(17) / 17;
        final layoutScale = scale * textScale.clamp(1.0, 2.0);
        final availableWidth = constraints.maxWidth - 48 * scale;
        final columns =
            ((availableWidth + 16 * scale) / (300 * layoutScale + 16 * scale))
                .floor()
                .clamp(1, 3);
        final cardWidth =
            (availableWidth - (columns - 1) * 16 * scale) / columns;
        return ListView(
          padding: EdgeInsets.fromLTRB(
            24 * scale,
            8 * scale,
            24 * scale,
            24 * scale,
          ),
          children: [
            if (sectionFeedback[HomeSection.roam] case final Widget feedback)
              feedback,
            // 1. 顶部 — 左：漫游 Banner（7） / 右：四分类四宫格（3）
            if (heroSong != null)
              if (availableWidth >= 900 * layoutScale)
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        flex: 7,
                        child: HomeHeroBanner(
                          song: heroSong,
                          onPlay: onPlayRoam,
                          onRefresh: onRefreshRoam,
                          height: 240 * layoutScale,
                        ),
                      ),
                      SizedBox(width: 16 * scale),
                      Expanded(
                        flex: 3,
                        child: _LargeCard(
                          padding: const EdgeInsets.all(14),
                          child: HomeShortcutMenu(
                            items: shortcutItems,
                            grid2x2: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else ...[
                HomeHeroBanner(
                  song: heroSong,
                  onPlay: onPlayRoam,
                  onRefresh: onRefreshRoam,
                  height: 240 * layoutScale,
                ),
                SizedBox(height: 16 * scale),
                _LargeCard(
                  padding: const EdgeInsets.all(14),
                  child: HomeShortcutMenu(items: shortcutItems, grid2x2: true),
                ),
              ]
            else
              _LargeCard(
                padding: const EdgeInsets.all(14),
                child: HomeShortcutMenu(items: shortcutItems, grid2x2: true),
              ),
            SizedBox(height: 16 * scale),
            // 2. 按缩放后的最小卡片宽度换行，避免文字和操作按钮互相挤压。
            // 固定行高（外层整页 ListView 纵滚，底部推荐歌单/专辑在其下方），
            // 让每栏卡片高度有界 → 内嵌 ListView 才能独立纵滚。
            Wrap(
              key: const ValueKey('home-song-sections'),
              spacing: 16 * scale,
              runSpacing: 16 * scale,
              children: [
                SizedBox(
                  width: cardWidth,
                  height: 460 * layoutScale,
                  child: _LargeCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        HomeSectionHeader(
                          title: '最近播放',
                          onViewAll: onOpenRecent,
                        ),
                        if (recentSongs.isNotEmpty &&
                            sectionFeedback[HomeSection.history] != null)
                          sectionFeedback[HomeSection.history]!,
                        const SizedBox(height: 4),
                        Expanded(
                          child: recentSongs.isEmpty
                              ? (sectionFeedback[HomeSection.history] ??
                                    const _LargeEmpty(text: '暂无最近播放'))
                              : _LargeScrollableSongList(
                                  songs: recentSongs,
                                  onTap: onTapRecent,
                                  onLongPress: onLongPressRecent,
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: cardWidth,
                  height: 460 * layoutScale,
                  child: _LargeCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        HomeSectionHeader(
                          title: '最新歌曲',
                          onViewAll: onOpenSongs,
                        ),
                        if (recentTracks.isNotEmpty &&
                            sectionFeedback[HomeSection.tracks] != null)
                          sectionFeedback[HomeSection.tracks]!,
                        const SizedBox(height: 4),
                        Expanded(
                          child: recentTracks.isEmpty
                              ? (sectionFeedback[HomeSection.tracks] ??
                                    const _LargeEmpty(text: '暂无最新歌曲'))
                              : _LargeScrollableSongList(
                                  songs: recentTracks,
                                  onTap: onTapTrack,
                                  onLongPress: onLongPressTrack,
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: cardWidth,
                  height: 460 * layoutScale,
                  child: _LargeCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        HomeSectionHeader(
                          title: '收藏',
                          onViewAll: onOpenFavorite,
                        ),
                        if (favoriteSongs.isNotEmpty &&
                            sectionFeedback[HomeSection.favorites] != null)
                          sectionFeedback[HomeSection.favorites]!,
                        const SizedBox(height: 4),
                        Expanded(
                          child: favoriteSongs.isEmpty
                              ? (sectionFeedback[HomeSection.favorites] ??
                                    const _LargeEmpty(text: '暂无收藏'))
                              : _LargeScrollableSongList(
                                  songs: favoriteSongs,
                                  onTap: onTapFavorite,
                                  onLongPress: onLongPressTrack,
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: 16 * scale),
            // 3. 底部 — 推荐歌单 + 最新专辑 横向滑动区（各自独立横向 ListView）。
            if (playlists.isNotEmpty ||
                sectionFeedback.containsKey(HomeSection.playlists))
              _LargeCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    HomeSectionHeader(
                      title: '推荐歌单',
                      onViewAll: onOpenPlaylists,
                    ),
                    const SizedBox(height: 4),
                    if (sectionFeedback[HomeSection.playlists]
                        case final Widget feedback)
                      feedback,
                    if (playlists.isNotEmpty)
                      _LargeScrollablePlaylistRow(
                        playlists: playlists,
                        isTv: AppLayoutSettings.tvMode.value,
                        onTap: onTapPlaylist,
                      ),
                  ],
                ),
              ),
            if (recentAlbums.isNotEmpty ||
                sectionFeedback.containsKey(HomeSection.albums)) ...[
              SizedBox(height: 16 * scale),
              _LargeCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    HomeSectionHeader(title: '最新专辑', onViewAll: onOpenAlbums),
                    const SizedBox(height: 4),
                    if (sectionFeedback[HomeSection.albums]
                        case final Widget feedback)
                      feedback,
                    if (recentAlbums.isNotEmpty)
                      HomeCoverCarousel(
                        coverSize: 128 * scale,
                        borderRadius: 16,
                        items: [
                          for (final a in recentAlbums)
                            HomeCoverItem(
                              coverId: a.coverId,
                              title: a.name,
                              subtitle: a.trackCount != null
                                  ? '${a.trackCount} 首'
                                  : '',
                              onTap: () => onTapAlbum(a),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// 大屏布局统一卡片容器：与四分类快捷入口同款样式 —
/// `surfaceContainerLow` 底色 + 圆角，无边框。
class _LargeCard extends StatelessWidget {
  final Widget child;

  /// 卡片内边距。默认 (20,18,20,20)；四宫格等紧凑场景可传更小值。
  final EdgeInsets padding;

  const _LargeCard({
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(20, 18, 20, 20),
  });

  @override
  Widget build(BuildContext context) {
    final scale = AppLayoutSettings.tvMode.value
        ? TvLayout.uiScale(context)
        : 1.0;
    return HomePanel(
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding * scale, child: child),
    );
  }
}

/// 大屏歌曲竖列表 — 封面 + 歌名/歌手 + 时长，可上下滚动。
class _LargeScrollableSongList extends StatelessWidget {
  final List<SongEntity> songs;
  final ValueChanged<SongEntity> onTap;
  final ValueChanged<SongEntity>? onLongPress;

  const _LargeScrollableSongList({
    required this.songs,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scale = AppLayoutSettings.tvMode.value
        ? TvLayout.uiScale(context)
        : 1.0;
    final artworkSize = 48.0 * scale;
    final isTv = AppLayoutSettings.tvMode.value;
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(12) / 12;
        final trailingDuration =
            constraints.maxWidth >= 240 * scale * textScale;
        return ListView.separated(
          // TV：加大预建范围，保证方向键能遍历到视口外的行（不会因行未 build
          // 而找不到下一焦点目标，误跳出列表跳到下方专辑）。
          scrollCacheExtent: isTv
              ? const ScrollCacheExtent.pixels(600)
              : const ScrollCacheExtent.pixels(0),
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: songs.length,
          separatorBuilder: (_, _) => SizedBox(height: 2 * scale),
          itemBuilder: (context, i) {
            final song = songs[i];
            final row = Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => onTap(song),
                onLongPress: onLongPress == null
                    ? null
                    : () => onLongPress!(song),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: 4 * scale,
                    vertical: 6 * scale,
                  ),
                  child: Row(
                    children: [
                      ArtworkWidget(
                        song: song,
                        size: artworkSize,
                        borderRadius: 10,
                      ),
                      SizedBox(width: 12 * scale),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              song.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14 * scale,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            SizedBox(height: 2 * scale),
                            Text(
                              song.artistDisplayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12 * scale,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            if (!trailingDuration && song.durationMs != null)
                              Text(
                                _formatDuration(song.durationMs!),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12 * scale,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (trailingDuration && song.durationMs != null)
                        Text(
                          _formatDuration(song.durationMs!),
                          style: TextStyle(
                            fontSize: 12 * scale,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
            // TV：整行可聚焦（焦点环 + Enter 播放）；onLongPress 保留在手势层，
            // 与 Touch 设备行为一致。TvFocusable 屏蔽行内 InkWell 的焦点节点，
            // 保证方向键遍历时每行是唯一焦点目标。
            if (isTv) {
              return TvFocusable(
                borderRadius: BorderRadius.circular(12),
                onActivate: () => onTap(song),
                child: row,
              );
            }
            return row;
          },
        );
      },
    );
  }

  static String _formatDuration(int ms) {
    final totalSec = (ms / 1000).round();
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

/// 大屏「推荐歌单」— 等宽方形卡片横向滑动列表（左右可滚动）。
class _LargeScrollablePlaylistRow extends StatelessWidget {
  final List<FeiNiuPlaylist> playlists;
  final bool isTv;
  final void Function(FeiNiuPlaylist) onTap;

  const _LargeScrollablePlaylistRow({
    required this.playlists,
    required this.isTv,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scale = isTv ? TvLayout.uiScale(context) : 1.0;
    return SizedBox(
      height: 214 * scale,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: playlists.length,
        separatorBuilder: (_, _) => SizedBox(width: 12 * scale),
        itemBuilder: (context, i) =>
            _PlaylistCard(playlist: playlists[i], isTv: isTv, onTap: onTap),
      ),
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  final FeiNiuPlaylist playlist;
  final bool isTv;
  final void Function(FeiNiuPlaylist) onTap;

  const _PlaylistCard({
    required this.playlist,
    required this.isTv,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scale = isTv ? TvLayout.uiScale(context) : 1.0;
    final coverId = playlist.coverId;
    final memoryCacheSize = coverMemoryCacheDimensionOf(context, 150 * scale);
    final card = SizedBox(
      width: 150 * scale,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 方形封面（宽 150 → 高 150 正方形）
          AspectRatio(
            aspectRatio: 1,
            child: Container(
              decoration: BoxDecoration(
                color: theme.cardColor,
                borderRadius: BorderRadius.circular(14),
              ),
              child: coverId != null && coverId.isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: CachedNetworkImage(
                        imageUrl: FeiNiuApiClient.instance.coverUrl(
                          coverId,
                          size: FeiNiuApiClient.coverRequestSize,
                          updatedAt: playlist.updatedAt,
                        ),
                        httpHeaders: FeiNiuApiClient.imageAuthHeaders(),
                        memCacheWidth: memoryCacheSize,
                        memCacheHeight: memoryCacheSize,
                        fit: BoxFit.cover,
                        placeholder: (_, _) => _placeholder(context),
                        errorWidget: (_, _, _) => _placeholder(context),
                      ),
                    )
                  : _placeholder(context),
            ),
          ),
          SizedBox(height: 6 * scale),
          Text(
            playlist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13 * scale, fontWeight: FontWeight.w600),
          ),
          // 接口不返回歌单数量（trackCount 恒为 0），不显示「0 首」。
        ],
      ),
    );
    final wrapped = GestureDetector(onTap: () => onTap(playlist), child: card);
    if (isTv) {
      return TvFocusable(
        borderRadius: BorderRadius.circular(22),
        onActivate: () => onTap(playlist),
        child: wrapped,
      );
    }
    return wrapped;
  }

  Widget _placeholder(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scale = isTv ? TvLayout.uiScale(context) : 1.0;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primary.withValues(alpha: 0.18),
            scheme.primary.withValues(alpha: 0.08),
          ],
        ),
      ),
      child: Center(
        child: Text(
          playlist.name.isNotEmpty ? playlist.name.characters.first : '?',
          style: TextStyle(
            fontSize: 28 * scale,
            fontWeight: FontWeight.bold,
            color: scheme.primary.withValues(alpha: 0.55),
          ),
        ),
      ),
    );
  }
}

/// 大屏空状态占位。
class _LargeEmpty extends StatelessWidget {
  final String text;

  const _LargeEmpty({required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Text(text, style: TextStyle(color: scheme.onSurfaceVariant)),
      ),
    );
  }
}
