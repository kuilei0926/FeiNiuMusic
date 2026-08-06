import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../app/services/feiniu/api_client.dart';
import '../../../app/state/settings_layout_state.dart';
import '../../../app/state/song_state.dart';
import '../../../components/focus/tv_focusable.dart';

/// 首页顶部 100% 宽 Hero Banner。
///
/// 漫游/今日推荐歌曲封面铺满整卡，底部渐变遮罩保证文字可读，
/// 右下角大播放按钮进入播放。封面是首页最关键的视觉元素。
class HomeHeroBanner extends StatelessWidget {
  final SongEntity? song;
  final VoidCallback onPlay;
  final String label;

  /// 换一首按钮回调。为 null 时不显示刷新按钮。
  final VoidCallback? onRefresh;

  const HomeHeroBanner({
    super.key,
    required this.song,
    required this.onPlay,
    this.label = '漫游 · 随心听',
    this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coverId = song?.coverId;
    // TV 端：16:9 全宽卡在横屏下会占满整屏。改 12:5 并限制最大宽度，
    // 让 Banner 仍是大视觉但不再"漫游区几乎全屏"；整卡可聚焦，Enter 即播放。
    final isTv = AppLayoutSettings.tvMode.value;
    final banner = ClipRRect(
      borderRadius: BorderRadius.circular(isTv ? 28 : 24),
      child: AspectRatio(
        aspectRatio: isTv ? 12 / 5 : 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 封面铺满
            if (coverId != null && coverId.isNotEmpty)
              CachedNetworkImage(
                imageUrl: FeiNiuApiClient.instance.coverUrl(
                  coverId,
                  size: 800,
                  updatedAt: song?.updatedAt,
                ),
                httpHeaders: FeiNiuApiClient.imageAuthHeaders(),
                fit: BoxFit.cover,
                placeholder: (_, _) => _HeroFallback(song: song),
                errorWidget: (_, _, _) => _HeroFallback(song: song),
              )
            else
              _HeroFallback(song: song),

            // 底部渐变遮罩
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black54, Colors.black87],
                  stops: [0.45, 0.8, 1.0],
                ),
              ),
            ),

            // 左上角标签
            Positioned(
              left: 16,
              top: 14,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.32),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.25),
                    width: 0.6,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.auto_awesome_rounded,
                      size: 13,
                      color: Colors.white.withValues(alpha: 0.9),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withValues(alpha: 0.92),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // 右上角换一首按钮
            if (onRefresh != null)
              Positioned(
                right: 12,
                top: 12,
                child: _TvRefreshButton(onRefresh: onRefresh!),
              ),

            // 左下角：歌名 + 歌手
            Positioned(
              left: 16,
              right: 16,
              bottom: 14,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          song?.title ?? '随机播放',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                            letterSpacing: -0.2,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          song?.artistDisplayName ?? '今天想听点什么',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.75),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 大播放按钮
                  _TvPlayButton(onPlay: onPlay, primary: theme.colorScheme.primary),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    if (!isTv) return banner;
    // TV：整卡可聚焦 → Enter 播放；同时限制最大宽度避免全屏占比。
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: TvFocusable(
          borderRadius: BorderRadius.circular(28),
          onActivate: onPlay,
          child: banner,
        ),
      ),
    );
  }
}

/// 播放按钮：Material 自身已可聚焦（主题 focusColor 染出焦点）。
class _TvPlayButton extends StatelessWidget {
  final VoidCallback onPlay;
  final Color primary;

  const _TvPlayButton({required this.onPlay, required this.primary});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPlay,
          child: Icon(
            Icons.play_arrow_rounded,
            color: primary,
            size: 36,
          ),
        ),
      ),
    );
  }
}

/// 换一首按钮：同样可聚焦（圆形 Material）。
class _TvRefreshButton extends StatelessWidget {
  final VoidCallback onRefresh;

  const _TvRefreshButton({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.32),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onRefresh,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            Icons.refresh_rounded,
            size: 20,
            color: Colors.white.withValues(alpha: 0.9),
          ),
        ),
      ),
    );
  }
}

/// 无封面/加载失败时的占位：主题色渐变 + 音乐图标
class _HeroFallback extends StatelessWidget {
  final SongEntity? song;

  const _HeroFallback({required this.song});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primary.withValues(alpha: 0.85),
            scheme.primary.withValues(alpha: 0.55),
            scheme.secondary.withValues(alpha: 0.5),
          ],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.music_note_rounded,
          size: 64,
          color: Colors.white.withValues(alpha: 0.85),
        ),
      ),
    );
  }
}
