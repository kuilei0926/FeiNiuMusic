import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/favorite_service.dart';
import '../../app/services/player/player_engine.dart';
import '../../app/services/player_service.dart';
import '../../app/state/settings_state.dart';
import '../../app/state/song_state.dart';
import '../../components/common/app_list_tile.dart';
import '../../components/feedback/app_toast.dart';
import '../library/library_detail_pages.dart';
import '../library/playlists_page.dart';

class SongDetailSheet extends StatefulWidget {
  final SongEntity song;
  final ValueChanged<SongEntity>? onUpdated;
  final ValueChanged<String>? onOpenArtist;
  final ValueChanged<String>? onOpenAlbum;
  final VoidCallback? onOpenPlayerAppearanceSettings;

  /// 额外操作项（如「移出最近播放」），渲染在「添加到歌单」之后。
  /// 由调用方决定是否传，避免所有入口都显示。
  final List<AppListTile>? extraActions;

  const SongDetailSheet({
    super.key,
    required this.song,
    this.onUpdated,
    this.onOpenArtist,
    this.onOpenAlbum,
    this.onOpenPlayerAppearanceSettings,
    this.extraActions,
  });

  @override
  State<SongDetailSheet> createState() => _SongDetailSheetState();
}

class _SongDetailSheetState extends State<SongDetailSheet> {
  final FeiNiuFavoriteService _favoriteService =
      FeiNiuFavoriteService.instance;
  bool _isFavorite = false;
  bool _loadingFavorite = true;

  @override
  void initState() {
    super.initState();
    AppPlaybackVolumeSettings.ensureLoaded();
    _loadFavoriteState();
  }

  Future<void> _loadFavoriteState() async {
    try {
      final isFav = await _favoriteService.isFavorite(widget.song.id);
      if (!mounted) return;
      setState(() {
        _isFavorite = isFav;
        _loadingFavorite = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingFavorite = false);
    }
  }

  Future<void> _toggleFavorite() async {
    if (_loadingFavorite) return;
    try {
      if (_isFavorite) {
        await _favoriteService.unfavorite(widget.song.id);
        if (!mounted) return;
        setState(() => _isFavorite = false);
        AppToast.show(context, '已取消收藏');
      } else {
        await _favoriteService.favorite(widget.song.id);
        if (!mounted) return;
        setState(() => _isFavorite = true);
        AppToast.show(context, '已收藏');
      }
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, '操作失败', type: ToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = theme.scaffoldBackgroundColor;
    final secondaryTextColor = isDark
        ? Colors.white70
        : const Color.fromARGB(255, 100, 100, 100);
    final song = widget.song;
    final artist = song.artistDisplayName;
    final album = song.albumDisplayName;
    final primaryArtist = song.artistDisplayName;
    final canOpenAlbum = song.albumGuid != null;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 12),
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? Colors.grey[800] : Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: _buildCover(theme, song),
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
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '$artist · $album',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: secondaryTextColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      _isFavorite
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      color: _isFavorite ? theme.colorScheme.error : null,
                    ),
                    onPressed: _loadingFavorite ? null : _toggleFavorite,
                  ),
                ],
              ),
            ),
            const Divider(height: 1, thickness: 0.6),
            const _AppVolumeControl(),
            AppListTile(
              leading: const Icon(Icons.queue_play_next),
              title: '下一首播放',
              onTap: () async {
                final api = FeiNiuApiClient.instance;
                final streamUrl = api.baseUrl.isNotEmpty
                    ? '${api.baseUrl}/music/api/v1/track/stream?guid=${song.id}'
                    : song.uri;
                final playable = song.copyWith(uri: streamUrl ?? '');
                await PlayerService.instance.playNext(playable);
                if (!context.mounted) return;
                AppToast.show(context, '已添加到下一首');
                Navigator.of(context).pop();
              },
            ),
            AppListTile(
              leading: const Icon(Icons.add_to_photos_outlined),
              title: '添加到歌单',
              onTap: () async {
                await showAddToPlaylistDialog(context, songIds: [song.id]);
                if (!context.mounted) return;
                Navigator.of(context).pop();
              },
            ),
            if (widget.extraActions != null)
              ...widget.extraActions!,
            if (widget.onOpenPlayerAppearanceSettings != null)
              AppListTile(
                leading: const Icon(Icons.tune_rounded),
                title: '播放器界面设置',
                onTap: () {
                  final nav = Navigator.of(context);
                  nav.pop();
                  widget.onOpenPlayerAppearanceSettings?.call();
                },
              ),
            AppListTile(
              leading: const Icon(Icons.person),
              title: '歌手：$primaryArtist',
              onTap: () {
                final nav = Navigator.of(context);
                nav.pop();
                final callback = widget.onOpenArtist;
                if (callback != null) {
                  callback(primaryArtist);
                } else {
                  // 未提供回调时自行导航（默认行为，供未传回调的调用点使用）
                  final guid = song.firstArtistGuid;
                  if (guid != null) {
                    nav.push(
                      MaterialPageRoute(
                        builder: (_) => ArtistDetailPage(
                          artistName: primaryArtist,
                          artistGuid: guid,
                        ),
                      ),
                    );
                  }
                }
              },
            ),
            if (canOpenAlbum)
              AppListTile(
                leading: const Icon(Icons.album),
                title: '专辑：$album',
                onTap: () {
                  final nav = Navigator.of(context);
                  nav.pop();
                  final callback = widget.onOpenAlbum;
                  if (callback != null) {
                    callback(song.albumDisplayName);
                  } else {
                    // 未提供回调时自行导航（默认行为）
                    final guid = song.albumGuid;
                    if (guid != null) {
                      nav.push(
                        MaterialPageRoute(
                          builder: (_) => AlbumDetailPage(
                            albumName: song.albumDisplayName,
                            albumGuid: guid,
                          ),
                        ),
                      );
                    }
                  }
                },
              ),
            if (song.audioSpec != null && song.audioSpec!.isNotEmpty)
              AppListTile(
                leading: const Icon(Icons.info_outline),
                title: '音频规格',
                subtitle: song.audioSpec,
                trailing: ValueListenableBuilder<EngineKind>(
                  valueListenable: PlayerService.instance.decoderEngine,
                  builder: (context, engine, _) => _DecoderTag(
                    engine: engine,
                  ),
                ),
                onTap: () {
                  final nav = Navigator.of(context);
                  nav.pop();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildCover(ThemeData theme, SongEntity song) {
    if (song.coverId != null && song.coverId!.isNotEmpty) {
      final coverUrl =
          FeiNiuApiClient.instance.coverUrl(song.coverId!, size: 52, updatedAt: song.updatedAt);
      return CachedNetworkImage(
        imageUrl: coverUrl,
        httpHeaders: FeiNiuApiClient.imageAuthHeaders(),
        width: 52,
        height: 52,
        memCacheWidth: 52,
        memCacheHeight: 52,
        fit: BoxFit.cover,
        placeholder: (_, _) => _coverPlaceholder(theme, song.title),
        errorWidget: (_, _, _) => _coverPlaceholder(theme, song.title),
      );
    }
    return _coverPlaceholder(theme, song.title);
  }

  Widget _coverPlaceholder(ThemeData theme, String title) {
    final letter = title.trim().isEmpty ? '?' : title.trim().substring(0, 1);
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Text(
        letter.toUpperCase(),
        style: TextStyle(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _AppVolumeControl extends StatelessWidget {
  const _AppVolumeControl();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // 与下方 AppListTile 的标题对齐：同用 ListTileTheme 的 contentPadding，
    // leading（图标宽 24）与标题之间留 16（ListTile 默认 horizontalTitleGap）。
    final tilePadding = ListTileTheme.of(context).contentPadding?.resolve(
          Directionality.of(context),
        ) ??
        const EdgeInsets.symmetric(horizontal: 16);
    return Padding(
      padding: EdgeInsets.only(
        left: tilePadding.left,
        right: tilePadding.right,
        top: 8,
        bottom: 2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 24,
            child: Icon(
              Icons.volume_down_rounded,
              size: 24,
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: ValueListenableBuilder<double>(
              valueListenable: AppPlaybackVolumeSettings.volume,
              builder: (context, volume, _) {
                final percent = (volume * 100).round();
                return Row(
                  children: [
                    SizedBox(
                      width: 42,
                      child: Text(
                        '音量',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: colors.onSurface,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Slider(
                        value: volume,
                        min: 0,
                        max: 1,
                        divisions: 20,
                        label: '$percent%',
                        onChanged: AppPlaybackVolumeSettings.setVolume,
                      ),
                    ),
                    SizedBox(
                      width: 42,
                      child: Text(
                        '$percent%',
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 解码引擎标签：显示当前歌曲由哪个播放器解码。
class _DecoderTag extends StatelessWidget {
  final EngineKind engine;
  const _DecoderTag({required this.engine});

  @override
  Widget build(BuildContext context) {
    final isMediaKit = engine == EngineKind.mediaKit;
    final color = isMediaKit
        ? const Color(0xFF6750A4) // 紫：FFmpeg 软解
        : const Color(0xFF00897B); // 青绿：系统解码器
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        isMediaKit ? 'FFmpeg' : '系统解码',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
