import 'package:flutter/material.dart';

import '../../../app/state/settings_state.dart';
import '../../feedback/app_toast.dart';

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
              '黑胶样式使用旋转唱片与轻量边框，保留歌词、播放进度和队列。',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<DesktopMiniPlayerStyle>(
              valueListenable: DesktopMiniPlayerSettings.style,
              builder: (context, selected, _) =>
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
            ),
          ],
        ),
      );
    },
  );
}
