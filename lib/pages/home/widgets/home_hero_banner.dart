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

  /// 自定义宽高比（宽/高）。默认按设备自适应：
  /// TV/平板 12:5、手机 16:9。调用方（如大屏首页布局）可传更扁的值
  /// 让 Banner 变矮变长方形，避免占满整屏。
  final double? aspectRatio;

  /// 固定高度模式：与 [aspectRatio] 二选一。传值时 Banner 用固定高度
  /// （如与右侧四宫格等高），不随宽度按比例缩放。
  final double? height;

  const HomeHeroBanner({
    super.key,
    required this.song,
    required this.onPlay,
    this.label = '漫游 · 随心听',
    this.onRefresh,
    this.aspectRatio,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coverId = song?.coverId;
    // TV 端：16:9 全宽卡在横屏下会占满整屏。改 12:5 并限制最大宽度，
    // 让 Banner 仍是大视觉但不再"漫游区几乎全屏"；整卡可聚焦，Enter 即播放。
    // 平板（非 TV）：同样限制宽度并居中，避免横屏下占满整屏高度。
    final isTv = AppLayoutSettings.tvMode.value;
    final isTablet = AppLayoutSettings.effectiveTabletMode && !isTv;
    final useLarge = isTv || isTablet;
    final bannerStack = Stack(
      fit: StackFit.expand,
      children: [
          // 封面铺满
          if (coverId != null && coverId.isNotEmpty)
            CachedNetworkImage(
              imageUrl: FeiNiuApiClient.instance.coverUrl(
                coverId,
                size: FeiNiuApiClient.coverRequestSize,
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
                _TvPlayButton(
                  onPlay: onPlay,
                  primary: theme.colorScheme.primary,
                ),
              ],
            ),
          ),
        ],
      );
    final Widget banner = ClipRRect(
      borderRadius: BorderRadius.circular(isTv ? 28 : 24),
      child: height != null
          ? SizedBox(height: height, child: bannerStack)
          : AspectRatio(
              aspectRatio: aspectRatio ?? (useLarge ? 12 / 5 : 16 / 9),
              child: bannerStack,
            ),
    );

    if (!useLarge) return banner;
    // 自定义 aspectRatio / height（大屏首页布局）→ 直接通栏全宽，不限制宽度居中。
    if (aspectRatio != null || height != null) {
      if (isTv) {
        return TvFocusable(
          borderRadius: BorderRadius.circular(28),
          onActivate: onPlay,
          child: banner,
        );
      }
      return banner;
    }
    // TV/平板大屏：限制最大宽度避免全屏占比，居中显示。
    // TV 额外包 TvFocusable（遥控器整卡可聚焦，Enter 即播放）。
    final centered = Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isTv ? 960 : 720),
        child: isTv
            ? TvFocusable(
                borderRadius: BorderRadius.circular(28),
                onActivate: onPlay,
                child: banner,
              )
            : banner,
      ),
    );
    return centered;
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
          child: Icon(Icons.play_arrow_rounded, color: primary, size: 36),
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
