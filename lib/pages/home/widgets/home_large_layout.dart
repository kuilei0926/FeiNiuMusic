import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../app/services/feiniu/api_client.dart';
import '../../../app/services/feiniu/api_models.dart';
import '../../../app/state/settings_layout_state.dart';
import '../../../app/state/song_state.dart';
import '../../../components/common/artwork_widget.dart';
import '../../../components/focus/tv_focusable.dart';
import 'home_cover_carousel.dart';
import 'home_hero_banner.dart';
import 'home_section_header.dart';
import 'home_shortcut_menu.dart';

/// 首页大屏布局（平板 / TV / Windows）。
///
/// 模块从上到下：
///   1. 顶部 — 漫游 Banner（左 7） + 四分类快捷四宫格（右 3）
///   2. 中部三栏 — 「最近播放」「最新歌曲」「收藏」各占 1/3，列表各自可上下滚动
///   3. 底部 — 推荐歌单 + 最新专辑 横向滑动（左右可滚动）
///
/// 手机端保持原有滚动布局，不进本组件。所有数据与回调由 HomePage 传入。
class HomeLargeLayout extends StatelessWidget {
  final SongEntity? heroSong;
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
    // TV/平板/Windows 统一布局与尺寸；TV 仅额外保留焦点环（TvFocusable）。
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        // 1. 顶部 — 左：漫游 Banner（7） / 右：四分类四宫格（3）
        if (heroSong != null)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 左 — 漫游 Banner（高度与右侧四宫格一致）
                Expanded(
                  flex: 7,
                  child: HomeHeroBanner(
                    song: heroSong,
                    onPlay: onPlayRoam,
                    onRefresh: onRefreshRoam,
                    // 用固定高度让 Banner 与四宫格等高（由 IntrinsicHeight 定高）。
                    height: 200,
                  ),
                ),
                const SizedBox(width: 16),
                // 右 — 四分类 2×2 四宫格
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
        else
          // 漫游数据缺失时，四宫格独立成行
          _LargeCard(
            padding: const EdgeInsets.all(14),
            child: HomeShortcutMenu(items: shortcutItems, grid2x2: true),
          ),
        const SizedBox(height: 16),
        // 2. 中部三栏 — 「最近播放」「最新歌曲」「收藏」各 1/3，列表各自可上下滚动。
        // 固定行高（外层整页 ListView 纵滚，底部推荐歌单/专辑在其下方），
        // 让每栏卡片高度有界 → 内嵌 ListView 才能独立纵滚。
        SizedBox(
          height: 460,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 1,
                child: _LargeCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      HomeSectionHeader(
                        title: '最近播放',
                        onViewAll: onOpenRecent,
                      ),
                      const SizedBox(height: 4),
                      Expanded(
                        child: recentSongs.isEmpty
                            ? const _LargeEmpty(text: '暂无最近播放')
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
              const SizedBox(width: 16),
              Expanded(
                flex: 1,
                child: _LargeCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      HomeSectionHeader(
                        title: '最新歌曲',
                        onViewAll: onOpenSongs,
                      ),
                      const SizedBox(height: 4),
                      Expanded(
                        child: recentTracks.isEmpty
                            ? const _LargeEmpty(text: '暂无最新歌曲')
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
              const SizedBox(width: 16),
              Expanded(
                flex: 1,
                child: _LargeCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      HomeSectionHeader(
                        title: '收藏',
                        onViewAll: onOpenFavorite,
                      ),
                      const SizedBox(height: 4),
                      Expanded(
                        child: favoriteSongs.isEmpty
                            ? const _LargeEmpty(text: '暂无收藏')
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
        ),
        const SizedBox(height: 16),
        // 3. 底部 — 推荐歌单 + 最新专辑 横向滑动区（各自独立横向 ListView）。
        if (playlists.isNotEmpty)
          _LargeCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                HomeSectionHeader(title: '推荐歌单', onViewAll: onOpenPlaylists),
                const SizedBox(height: 4),
                _LargeScrollablePlaylistRow(
                  playlists: playlists,
                  isTv: AppLayoutSettings.tvMode.value,
                  onTap: onTapPlaylist,
                ),
              ],
            ),
          ),
        if (recentAlbums.isNotEmpty) ...[
          const SizedBox(height: 16),
          _LargeCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                HomeSectionHeader(title: '最新专辑', onViewAll: onOpenAlbums),
                const SizedBox(height: 4),
                HomeCoverCarousel(
                  coverSize: 128,
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
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
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
    final artworkSize = 48.0;
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: songs.length,
      separatorBuilder: (_, _) => const SizedBox(height: 2),
      itemBuilder: (context, i) {
        final song = songs[i];
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => onTap(song),
            onLongPress: onLongPress == null
                ? null
                : () => onLongPress!(song),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Row(
                children: [
                  ArtworkWidget(
                    song: song,
                    size: artworkSize,
                    borderRadius: 10,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          song.artistDisplayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (song.durationMs != null)
                    Text(
                      _formatDuration(song.durationMs!),
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
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
    return SizedBox(
      height: 214,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: playlists.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, i) => _PlaylistCard(
          playlist: playlists[i],
          isTv: isTv,
          onTap: onTap,
        ),
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
    final coverId = playlist.coverId;
    final card = SizedBox(
      width: 150,
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
                        size: 400,
                        updatedAt: playlist.updatedAt,
                      ),
                      httpHeaders: FeiNiuApiClient.imageAuthHeaders(),
                      fit: BoxFit.cover,
                      placeholder: (_, _) => _placeholder(context),
                      errorWidget: (_, _, _) => _placeholder(context),
                    ),
                  )
                : _placeholder(context),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          playlist.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 1),
        Text(
          '${playlist.trackCount} 首',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
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
            fontSize: 28,
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

