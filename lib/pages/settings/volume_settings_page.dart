import 'package:flutter/material.dart';

import '../../app/state/settings_state.dart';
import '../../components/index.dart';

class VolumeSettingsPage extends StatefulWidget {
  const VolumeSettingsPage({super.key});

  @override
  State<VolumeSettingsPage> createState() => _VolumeSettingsPageState();
}

class _VolumeSettingsPageState extends State<VolumeSettingsPage> {
  @override
  void initState() {
    super.initState();
    AppPlaybackVolumeSettings.ensureLoaded();
    AppVolumeScheduleSettings.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding =
        AppPageScaffold.scrollableBottomPadding(context, showMiniPlayer: false);
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const AppTopBar(
        title: '音量设置',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      showMiniPlayer: false,
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
        children: [
          AppSettingSection(
            title: '音量',
            children: [
              ValueListenableBuilder<double>(
                valueListenable: AppPlaybackVolumeSettings.volume,
                builder: (context, volume, _) {
                  final percent = (volume * 100).round();
                  return AppSettingSlider(
                    title: '应用音量',
                    description: '只调整 飞牛音乐 的播放音量，不改变系统音量',
                    value: volume,
                    min: 0,
                    max: 1,
                    divisions: 20,
                    valueText: '$percent%',
                    onChanged: AppPlaybackVolumeSettings.setVolume,
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          ValueListenableBuilder<bool>(
            valueListenable: AppVolumeScheduleSettings.enabled,
            builder: (context, enabled, _) {
              return AppSettingSwitchTile(
                title: '定时音量',
                subtitle: '在指定时间段内自动按设定音量输出',
                value: enabled,
                onChanged: AppVolumeScheduleSettings.setEnabled,
              );
            },
          ),
          const SizedBox(height: 16),
          _buildPeriodSection(context),
        ],
      ),
    );
  }

  Widget _buildPeriodSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<List<VolumeSchedulePeriod>>(
      valueListenable: AppVolumeScheduleSettings.periods,
      builder: (context, periods, _) {
        return AppSettingSection(
          title: '时间段',
          children: [
            if (periods.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                child: Text(
                  '暂无时间段，点下方「添加时间段」创建',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              )
            else
              ...periods.map((p) => _buildPeriodTile(context, p)),
            AppSettingTile(
              title: '添加时间段',
              leading: const Icon(Icons.add_rounded),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _openEditor(context),
            ),
            const AppSettingTile(
              title: '说明',
              subtitle: '开启后，到达指定时间段自动切换到对应音量，离开后恢复手动音量。'
                  '仅在应用前台运行或后台播放音乐时生效。',
            ),
          ],
        );
      },
    );
  }

  Widget _buildPeriodTile(BuildContext context, VolumeSchedulePeriod p) {
    final scheme = Theme.of(context).colorScheme;
    final activeNow = AppVolumeScheduleSettings.enabled.value &&
        AppVolumeScheduleSettings.activePeriodNow(DateTime.now())?.id == p.id;
    return AppSettingTile(
      title: _fmtRange(p),
      subtitle: '音量 ${(p.volume * 100).round()}%${activeNow ? ' · 生效中' : ''}',
      leading: Icon(
        Icons.schedule_rounded,
        color: activeNow ? scheme.primary : scheme.onSurfaceVariant,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.edit_rounded, size: 20),
            tooltip: '编辑',
            onPressed: () => _openEditor(context, period: p),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline_rounded, size: 20),
            tooltip: '删除',
            onPressed: () => _confirmDelete(context, p),
          ),
        ],
      ),
    );
  }

  // ---------- 添加 / 编辑弹层 ----------

  Future<void> _openEditor(
    BuildContext context, {
    VolumeSchedulePeriod? period,
  }) async {
    var startMin = period?.startMin ?? 22 * 60; // 默认 22:00
    var endMin = period?.endMin ?? 8 * 60; // 默认 08:00（跨午夜）
    var volume = period?.volume ?? 0.3;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  16,
                  16,
                  MediaQuery.of(ctx).viewInsets.bottom + 16,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      period == null ? '添加时间段' : '编辑时间段',
                      style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _buildTimePickerRow(
                      ctx,
                      label: '开始时间',
                      minutes: startMin,
                      onChanged: (m) => setSheetState(() => startMin = m),
                    ),
                    _buildTimePickerRow(
                      ctx,
                      label: '结束时间',
                      minutes: endMin,
                      onChanged: (m) => setSheetState(() => endMin = m),
                    ),
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Text(
                        '预览：${_fmtRangeManual(startMin, endMin)}',
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    AppSettingSlider(
                      title: '时间段音量',
                      value: volume,
                      min: 0,
                      max: 1,
                      divisions: 20,
                      valueText: '${(volume * 100).round()}%',
                      onChanged: (v) => setSheetState(() => volume = v),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('取消'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: () async {
                              if (startMin == endMin) {
                                AppToast.show(context, '开始与结束时间不能相同');
                                return;
                              }
                              if (period == null) {
                                await AppVolumeScheduleSettings.addPeriod(
                                  startMin: startMin,
                                  endMin: endMin,
                                  volume: volume,
                                );
                              } else {
                                await AppVolumeScheduleSettings.updatePeriod(
                                  period.id,
                                  startMin: startMin,
                                  endMin: endMin,
                                  volume: volume,
                                );
                              }
                              if (ctx.mounted) Navigator.pop(ctx);
                            },
                            child: const Text('确定'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildTimePickerRow(
    BuildContext context, {
    required String label,
    required int minutes,
    required ValueChanged<int> onChanged,
  }) {
    final time = _toTimeOfDay(minutes);
    return Row(
      children: [
        SizedBox(
          width: 90,
          child: Text(label, style: const TextStyle(fontSize: 15)),
        ),
        const Spacer(),
        TextButton.icon(
          onPressed: () async {
            final picked = await showTimePicker(
              context: context,
              initialTime: time,
            );
            if (picked != null) onChanged(picked.hour * 60 + picked.minute);
          },
          icon: const Icon(Icons.access_time_rounded, size: 18),
          label: Text('${_two(time.hour)}:${_two(time.minute)}'),
        ),
      ],
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    VolumeSchedulePeriod p,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除时间段'),
        content: Text('确定删除 ${_fmtRange(p)} 的时间段吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await AppVolumeScheduleSettings.removePeriod(p.id);
    }
  }

  // ---------- 格式化辅助 ----------

  String _fmtRange(VolumeSchedulePeriod p) => _fmtRangeManual(p.startMin, p.endMin);

  String _fmtRangeManual(int startMin, int endMin) {
    final s = _fmtMin(startMin);
    final e = _fmtMin(endMin);
    if (startMin <= endMin) return '$s – $e';
    return '$s – $e (次日)';
  }

  String _fmtMin(int m) => '${_two(m ~/ 60)}:${_two(m % 60)}';

  String _two(int n) => n.toString().padLeft(2, '0');

  TimeOfDay _toTimeOfDay(int m) => TimeOfDay(hour: m ~/ 60, minute: m % 60);
}
