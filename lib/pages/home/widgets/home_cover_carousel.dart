import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../app/services/feiniu/api_client.dart';
import '../../../app/state/settings_layout_state.dart';
import '../../../components/focus/tv_focusable.dart';

/// 横向封面轮播单项数据
class HomeCoverItem {
  final String? coverId;
  final int? updatedAt;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  const HomeCoverItem({
    required this.coverId,
    this.updatedAt,
    required this.title,
    required this.subtitle,
    this.onTap,
  });
}

/// 首页横向封面轮播 — 专辑/歌单两种模式，封面尺寸不同形成节奏。
///
/// - 专辑模式：coverSize 128、圆角 16
/// - 歌单模式：coverSize 100、圆角 14
///
/// 封面图片是这里的绝对主角，标题/数量只作辅助说明。
class HomeCoverCarousel extends StatelessWidget {
  final List<HomeCoverItem> items;
  final double coverSize;
  final double borderRadius;

  /// 标题/副标题是否居中。歌单卡片居中，专辑卡片左对齐。
  final bool centerText;

  const HomeCoverCarousel({
    super.key,
    required this.items,
    required this.coverSize,
    required this.borderRadius,
    this.centerText = false,
  });

  Map<String, String> _authHeaders() => FeiNiuApiClient.imageAuthHeaders();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 是否有副标题决定容器高度：封面 + 标题行（无副标题），或
    // 封面 + 标题 + 副标题两行（有副标题）。避免无副标题时仍预留
    // 副标题行高度，造成卡片下方大片空白。
    final hasSubtitle = items.any((i) => i.subtitle.isNotEmpty);
    final textHeight = hasSubtitle ? 38.0 : 22.0;
    return SizedBox(
      height: coverSize + textHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, i) => _CarouselCard(
          item: items[i],
          coverSize: coverSize,
          borderRadius: borderRadius,
          centerText: centerText,
          authHeaders: _authHeaders(),
          theme: theme,
        ),
      ),
    );
  }
}

class _CarouselCard extends StatelessWidget {
  final HomeCoverItem item;
  final double coverSize;
  final double borderRadius;
  final bool centerText;
  final Map<String, String> authHeaders;
  final ThemeData theme;

  const _CarouselCard({
    required this.item,
    required this.coverSize,
    required this.borderRadius,
    required this.centerText,
    required this.authHeaders,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final coverId = item.coverId;
    final isTv = AppLayoutSettings.tvMode.value;
    final card = SizedBox(
      width: coverSize,
      child: GestureDetector(
        onTap: item.onTap,
        child: Column(
          crossAxisAlignment: centerText
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          children: [
            Container(
              width: coverSize,
              height: coverSize,
              decoration: BoxDecoration(
                color: theme.cardColor,
                borderRadius: BorderRadius.circular(borderRadius),
              ),
              child: coverId != null && coverId.isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(borderRadius),
                      child: CachedNetworkImage(
                        imageUrl: FeiNiuApiClient.instance.coverUrl(
                          coverId,
                          size: FeiNiuApiClient.coverRequestSize,
                          updatedAt: item.updatedAt,
                        ),
                        httpHeaders: authHeaders,
                        width: coverSize,
                        height: coverSize,
                        fit: BoxFit.cover,
                        placeholder: (_, _) => _coverPlaceholder(),
                        errorWidget: (_, _, _) => _coverPlaceholder(),
                      ),
                    )
                  : _coverPlaceholder(),
            ),
            const SizedBox(height: 6),
            Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: centerText ? TextAlign.center : null,
              style: const TextStyle(
                fontSize: 13,
                height: 1.15,
                fontWeight: FontWeight.w600,
              ),
            ),
            // 副标题为空时不占行，避免标题下方留白
            if (item.subtitle.isNotEmpty) ...[
              const SizedBox(height: 1),
              Text(
                item.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: centerText ? TextAlign.center : null,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.15,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
    // TV：轮播卡是 GestureDetector（非 Material），需焦点环才能被遥控器聚焦；
    // Enter 触发同样的跳转。
    if (isTv) {
      return TvFocusable(
        borderRadius: BorderRadius.circular(borderRadius + 8),
        onActivate: item.onTap,
        child: card,
      );
    }
    return card;
  }

  Widget _coverPlaceholder() {
    final scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
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
          item.title.isNotEmpty ? item.title.characters.first : '?',
          style: TextStyle(
            fontSize: coverSize * 0.3,
            fontWeight: FontWeight.bold,
            color: scheme.primary.withValues(alpha: 0.55),
          ),
        ),
      ),
    );
  }
}
