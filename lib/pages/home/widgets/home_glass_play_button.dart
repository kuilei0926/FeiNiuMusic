import 'package:flutter/material.dart';

class HomeGlassPlayButton extends StatelessWidget {
  final VoidCallback onPlay;
  final double size;
  final Color? color;
  const HomeGlassPlayButton({
    super.key,
    required this.onPlay,
    this.size = 48,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? Theme.of(context).colorScheme.onSurface;
    return SizedBox(
      width: size,
      height: size,
      child: Material(
        color: foreground.withValues(alpha: .12),
        shape: CircleBorder(
          side: BorderSide(color: foreground.withValues(alpha: .25), width: .8),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPlay,
          child: Tooltip(
            message: '播放',
            child: Icon(
              Icons.play_arrow_rounded,
              color: foreground,
              size: size * .54,
            ),
          ),
        ),
      ),
    );
  }
}
