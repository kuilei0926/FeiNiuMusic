import 'package:flutter/material.dart';

import '../../../app/state/song_state.dart';
import '../../common/artwork_widget.dart';

class MiniPlayerArtwork extends StatelessWidget {
  final SongEntity? song;
  final double size;
  final double borderRadius;

  const MiniPlayerArtwork({
    super.key,
    required this.song,
    required this.size,
    required this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (song == null) {
      return _ArtworkFallback(
        size: size,
        borderRadius: borderRadius,
        color: scheme.surfaceContainerHighest,
      );
    }
    return ArtworkWidget(
      song: song!,
      size: size,
      borderRadius: borderRadius,
      placeholder: _ArtworkFallback(
        size: size,
        borderRadius: borderRadius,
        color: scheme.surfaceContainerHighest,
      ),
    );
  }
}

class _ArtworkFallback extends StatelessWidget {
  final double size;
  final double borderRadius;
  final Color color;

  const _ArtworkFallback({
    required this.size,
    required this.borderRadius,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: Center(
        child: Icon(Icons.music_note, color: scheme.onSurfaceVariant),
      ),
    );
  }
}
