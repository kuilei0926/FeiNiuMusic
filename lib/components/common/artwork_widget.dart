import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../../app/services/feiniu/api_client.dart';
import '../../app/state/song_state.dart';

class ArtworkWidget extends StatefulWidget {
  final SongEntity song;
  final double size;
  final double borderRadius;
  final Widget? placeholder;

  /// 封面显示状态回调：true = 正在显示真实封面图；
  /// false = 无封面 / 加载中 / 加载失败（占位文字图或骨架）。
  ///
  /// 用于播放页封面旋转：只有真实封面才旋转，占位文字图保持静止。
  final ValueChanged<bool>? onCoverAvailableChanged;

  const ArtworkWidget({
    super.key,
    required this.song,
    required this.size,
    required this.borderRadius,
    this.placeholder,
    this.onCoverAvailableChanged,
  });

  @override
  State<ArtworkWidget> createState() => _ArtworkWidgetState();
}

class _ArtworkWidgetState extends State<ArtworkWidget> with SignalsMixin {
  /// 上一次上报的封面显示状态（避免重复触发回调）
  bool? _lastReportedAvailable;

  Map<String, String> _authHeaders() => FeiNiuApiClient.imageAuthHeaders();

  /// 封面来源变化时重置上报状态。
  ///
  /// 切歌后新歌 coverId / updatedAt 变了，但 State 复用、_lastReportedAvailable
  /// 仍是旧歌的值：若旧歌上报过 true，新封面加载完成时 imageBuilder 再上报
  /// true 会被去重吞掉，导致播放页认为始终无封面而不再旋转。
  /// 因此在封面来源变化时清空去重标记，让新封面的上报能重新生效。
  @override
  void didUpdateWidget(ArtworkWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.id != widget.song.id ||
        oldWidget.song.coverId != widget.song.coverId ||
        oldWidget.song.updatedAt != widget.song.updatedAt) {
      _lastReportedAvailable = null;
    }
  }

  /// 上报封面显示状态：true = 正在显示真实封面图；
  /// false = 无封面 / 加载失败（文字占位图 / 骨架）。
  ///
  /// 此方法可能在 build 期间被调用（imageBuilder / errorWidget / 无封面
  /// 分支），父组件收到回调后会 setState，因此延迟到帧后执行，避免
  /// 「markNeedsBuild called during build」断言。
  void _report(bool available) {
    final cb = widget.onCoverAvailableChanged;
    if (cb == null) return;
    if (_lastReportedAvailable == available) return;
    _lastReportedAvailable = available;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      cb(available);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coverId = widget.song.coverId;
    final size = widget.size;
    final borderRadius = widget.borderRadius;

    final placeholder =
        widget.placeholder ??
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: theme.cardColor,
            borderRadius: BorderRadius.circular(borderRadius),
          ),
        );

    Widget child;
    if (coverId != null && coverId.isNotEmpty) {
      // 封面源图统一用 canonical 尺寸（800px）请求：全 App 同一 coverId 永远
      // 构造同一个 URL → 共享同一份磁盘缓存与解码缓存。此前按显示尺寸×DPR
      // 动态请求（列表 120 起步、播放页 800），同一封面在不同页面产生多个
      // 不同 URL 的缓存，已显示过的地方命中缓存、另一处仍在转圈下载。
      final coverUrl =
          FeiNiuApiClient.instance.coverUrl(
            coverId,
            size: FeiNiuApiClient.coverRequestSize,
            updatedAt: widget.song.updatedAt,
          );
      child = ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: CachedNetworkImage(
          imageUrl: coverUrl,
          httpHeaders: _authHeaders(),
          width: size,
          height: size,
          fit: BoxFit.cover,
          // 真实封面解码成功 → 上报可用（供播放页判断是否旋转）
          imageBuilder: (context, imageProvider) {
            _report(true);
            return Image(
              image: imageProvider,
              width: size,
              height: size,
              fit: BoxFit.cover,
            );
          },
          placeholder: (context, url) => SizedBox(
            width: size,
            height: size,
            child: Center(
              child: SizedBox(
                width: size * 0.35,
                height: size * 0.35,
                child: const CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
          errorWidget: (context, url, error) {
            _report(false);
            return placeholder;
          },
        ),
      );
    } else {
      _report(false);
      child = placeholder;
    }

    // 失效歌曲（音频文件已删除）：封面叠加灰色遮罩 + 「已失效」标记
    if (widget.song.isAudioFileDeleted) {
      return SizedBox(
        width: size,
        height: size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            child,
            ColoredBox(color: Colors.black.withValues(alpha: 0.45)),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.error_outline_rounded,
                    size: size * 0.30,
                    color: Colors.white,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '已失效',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: size * 0.16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return SizedBox(width: size, height: size, child: child);
  }
}
