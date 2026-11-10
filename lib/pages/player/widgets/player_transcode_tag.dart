import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class PlayerTranscodeTag extends StatelessWidget {
  final ValueListenable<String?> playbackCodecListenable;
  final VoidCallback? onTap;

  const PlayerTranscodeTag({
    super.key,
    required this.playbackCodecListenable,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: playbackCodecListenable,
      builder: (context, codec, _) {
        final output = codec?.trim().toUpperCase();
        final isTranscoding = output != null && output.isNotEmpty;
        final label = output == null || output.isEmpty ? '直连' : output;
        final color = isTranscoding
            ? const Color(0xFFB08000)
            : const Color(0xFF607D8B);
        return InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        );
      },
    );
  }
}
