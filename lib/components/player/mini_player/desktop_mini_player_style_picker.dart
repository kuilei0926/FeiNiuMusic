import 'package:flutter/material.dart';

import '../../../app/state/settings_state.dart';
import '../../feedback/app_toast.dart';
import 'mini_player_bar.dart';

class DesktopMiniPlayerStylePicker extends StatefulWidget {
  const DesktopMiniPlayerStylePicker({super.key});

  @override
  State<DesktopMiniPlayerStylePicker> createState() =>
      _DesktopMiniPlayerStylePickerState();
}

class _DesktopMiniPlayerStylePickerState
    extends State<DesktopMiniPlayerStylePicker> {
  bool _saving = false;

  Future<void> _select(DesktopMiniPlayerStyle style) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await DesktopMiniPlayerSettings.setStyle(style);
    } catch (error) {
      if (mounted) AppToast.show(context, '样式保存失败，请重试', type: ToastType.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: AppLayoutSettings.tvMode,
    builder: (context, tvMode, _) {
      if (!AppLayoutSettings.isDesktop || tvMode) {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('桌面播放条', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '经典播放条，或更轻盈的黑胶播放坞。',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<DesktopMiniPlayerStyle>(
              valueListenable: DesktopMiniPlayerSettings.style,
              builder: (context, selected, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<DesktopMiniPlayerStyle>(
                    segments: const [
                      ButtonSegment(
                        value: DesktopMiniPlayerStyle.classic,
                        icon: Icon(Icons.album_outlined),
                        label: Text('经典'),
                      ),
                      ButtonSegment(
                        value: DesktopMiniPlayerStyle.vinyl,
                        icon: Icon(Icons.album_rounded),
                        label: Text('黑胶'),
                      ),
                    ],
                    selected: {selected},
                    onSelectionChanged: _saving
                        ? null
                        : (values) => _select(values.single),
                  ),
                  const SizedBox(height: 16),
                  ExcludeSemantics(
                    child: IgnorePointer(
                      child: TickerMode(
                        enabled: false,
                        child: MediaQuery(
                          data: MediaQuery.of(
                            context,
                          ).copyWith(disableAnimations: true),
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(24),
                            ),
                            child: MiniPlayerBar(
                              vinyl: selected == DesktopMiniPlayerStyle.vinyl,
                              padding: EdgeInsets.zero,
                              enableSwipe: false,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}
