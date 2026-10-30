import 'package:flutter/material.dart';

import '../../../app/state/settings_state.dart';
import '../../feedback/app_toast.dart';
import 'bottom_island_host.dart';
import 'bottom_island_layout.dart';

class BottomIslandStylePicker extends StatefulWidget {
  const BottomIslandStylePicker({super.key});

  @override
  State<BottomIslandStylePicker> createState() =>
      _BottomIslandStylePickerState();
}

class _BottomIslandStylePickerState extends State<BottomIslandStylePicker> {
  bool _saving = false;

  Future<void> _select(BottomIslandStyle value) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await BottomIslandSettings.setStyle(value);
    } catch (error) {
      if (mounted) AppToast.show(context, '样式保存失败，请重试', type: ToastType.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: AppLayoutSettings.effectiveTabletModeNotifier,
    builder: (context, largeLayout, _) {
      if (largeLayout || AppLayoutSettings.effectiveTabletMode) {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 16),
        child: _buildPicker(context),
      );
    },
  );

  Widget _buildPicker(BuildContext context) =>
      ValueListenableBuilder<BottomIslandStyle>(
        valueListenable: BottomIslandSettings.style,
        builder: (context, selected, _) {
          final scheme = Theme.of(context).colorScheme;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('底部播放器样式', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                '三种黑胶形态仅在手机布局下生效。C1 在窄屏或大字体下自动使用 C3，已保存的偏好不变。',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
              const SizedBox(height: 12),
              for (final style in BottomIslandStyle.values) ...[
                Builder(
                  builder: (context) {
                    final layout = BottomIslandLayout.resolve(
                      style: style,
                      width: 390,
                    );
                    final active = selected == style;
                    final label = switch (style) {
                      BottomIslandStyle.legacy => '现有经典样式',
                      BottomIslandStyle.c1 => 'C1 · 左置融合单岛',
                      BottomIslandStyle.c2 => 'C2 · 中置对称黑胶岛',
                      BottomIslandStyle.c3 => 'C3 · 悬浮微黑胶',
                    };
                    return Semantics(
                      selected: active,
                      button: true,
                      child: Material(
                        color: active
                            ? scheme.primaryContainer.withValues(alpha: .3)
                            : scheme.surfaceContainerLow,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                          side: BorderSide(
                            color: active
                                ? scheme.primary
                                : scheme.outlineVariant.withValues(alpha: .4),
                          ),
                        ),
                        child: InkWell(
                          key: ValueKey('island-style-${style.name}'),
                          borderRadius: BorderRadius.circular(20),
                          onTap: _saving ? null : () => _select(style),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        label,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    Icon(
                                      active
                                          ? Icons.check_circle_rounded
                                          : Icons.circle_outlined,
                                      color: active
                                          ? scheme.primary
                                          : scheme.outline,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                ExcludeSemantics(
                                  child: IgnorePointer(
                                    child: MediaQuery(
                                      data: MediaQuery.of(context).copyWith(
                                        size: const Size(390, 240),
                                        textScaler: TextScaler.noScaling,
                                        disableAnimations: true,
                                      ),
                                      child: SizedBox(
                                        height: layout.occupiedHeight * .7,
                                        child: FittedBox(
                                          fit: BoxFit.contain,
                                          child: SizedBox(
                                            width: 390,
                                            height: layout.occupiedHeight,
                                            child: BottomIslandView(
                                              layout: layout,
                                              preview: true,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                if (style == BottomIslandStyle.c1 ||
                                    style == BottomIslandStyle.c2)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Text(
                                      'C1/C2 极简模式下，歌曲库可从首页快捷入口或最新歌曲查看全部进入。',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),
              ],
            ],
          );
        },
      );
}
