import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;
import 'package:media_cast_dlna/media_cast_dlna.dart';

import '../../../app/services/cast/dlna_cast_service.dart';
import '../../../app/services/player_service.dart';
import '../../../app/state/settings_cast_state.dart';
import '../../../app/state/song_state.dart';
import '../../../components/feedback/app_toast.dart';

/// 播放页右上角 DLNA 投屏按钮。
///
/// - 未投屏：`Icons.cast`，点开设备列表底部面板；
/// - 投屏中：`Icons.cast_connected`（主色高亮），点开面板可切换设备或断开。
/// 仅 Android 平台显示（media_cast_dlna 不支持 iOS）。
class CastButton extends StatelessWidget {
  final Signal<SongEntity?> songSignal;

  const CastButton({super.key, required this.songSignal});

  bool get _isAndroid =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android || Platform.isAndroid);

  @override
  Widget build(BuildContext context) {
    // 非 Android 平台不显示投屏按钮
    if (!_isAndroid) return const SizedBox.shrink();
    return ValueListenableBuilder<bool>(
      valueListenable: DlnaCastSettings.enabled,
      builder: (context, enabled, _) {
        if (!enabled) return const SizedBox.shrink();
        return ValueListenableBuilder<DlnaCastState>(
          valueListenable: DlnaCastService.instance.state,
          builder: (context, state, _) {
            final casting = DlnaCastService.instance.isCasting;
            final scheme = Theme.of(context).colorScheme;
            return IconButton(
              visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 40, height: 40),
              tooltip: casting ? '正在投屏' : '投屏',
              icon: Icon(
                casting ? Icons.cast_connected : Icons.cast,
                size: 24,
                color: casting
                    ? scheme.primary
                    : scheme.onSurface.withValues(alpha: 0.72),
              ),
              onPressed: () => _showCastSheet(context),
            );
          },
        );
      },
    );
  }

  /// 打开投屏设备面板：开始搜索 → 设备列表 → 连接/断开。
  ///
  /// 未投屏：点开搜索设备并选择连接；
  /// 投屏中：点开面板显示当前设备 + 其他设备（可切换）+ 断开按钮。
  ///
  /// SSDP 组播发现只依赖组播锁（CHANGE_WIFI_MULTICAST_STATE），不需要
  /// 「附近的设备」运行时权限，因此不在这里弹权限请求。
  Future<void> _showCastSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const _CastDeviceSheet(),
    );
  }
}

/// 投屏设备选择底部面板。
class _CastDeviceSheet extends StatefulWidget {
  const _CastDeviceSheet();

  @override
  State<_CastDeviceSheet> createState() => _CastDeviceSheetState();
}

class _CastDeviceSheetState extends State<_CastDeviceSheet> {
  final DlnaCastService _cast = DlnaCastService.instance;
  late final Listenable _castChanges = Listenable.merge([
    _cast.devices,
    _cast.state,
    _cast.currentDevice,
  ]);
  Timer? _stopSearchTimer;

  /// 正在连接的设备 UDN；连接期间忽略其他点击，避免重复投送。
  String? _connectingUdn;
  bool _disconnecting = false;

  bool get _busy => _connectingUdn != null || _disconnecting;

  @override
  void initState() {
    super.initState();
    // 面板打开期间监听设备列表、搜索状态与当前设备（搜索结束、被动断开
    // 都要刷新，否则「正在搜索」会一直转）。
    _castChanges.addListener(_onCastChanged);
    _startSearch();
  }

  @override
  void dispose() {
    _castChanges.removeListener(_onCastChanged);
    _stopSearchTimer?.cancel();
    unawaited(_cast.stopDiscovery());
    super.dispose();
  }

  void _onCastChanged() {
    if (mounted) setState(() {});
  }

  /// 搜索 10 秒后自动停止（保持设备列表稳定，避免一直占用组播锁）。
  void _startSearch() {
    _stopSearchTimer?.cancel();
    _stopSearchTimer = Timer(const Duration(seconds: 10), () {
      unawaited(_cast.stopDiscovery());
    });
    unawaited(_cast.startDiscovery());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isCasting = _cast.isCasting;
    final devices = _cast.devices.value;
    final current = _cast.currentDevice.value;
    final discovering = _cast.isDiscovering;

    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          // 用主题的 surfaceContainerHigh（M3 底部面板标准表面色），
          // 深色模式下自动适配，不硬编码白色。
          color: scheme.surfaceContainerHigh,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '投屏到设备',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                if (discovering)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  IconButton(
                    tooltip: '重新搜索',
                    icon: const Icon(Icons.refresh_rounded),
                    onPressed: _busy ? null : _startSearch,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              isCasting && current != null
                  ? '正在投屏到「${current.friendlyName}」'
                  : discovering
                  ? '正在搜索局域网内的 DLNA 设备…'
                  : '选择要投屏的设备',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: discovering && devices.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(strokeWidth: 3),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '正在搜索设备…',
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    )
                  : devices.isEmpty
                  ? Center(
                      child: Text(
                        '未发现 DLNA 设备\n请确保设备与本机在同一局域网',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 14,
                          height: 1.5,
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: devices.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final device = devices[index];
                        final isCurrent =
                            current != null &&
                            current.udn.value == device.udn.value;
                        final connecting = _connectingUdn == device.udn.value;
                        return ListTile(
                          leading: Icon(
                            Icons.cast,
                            color: isCurrent
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                          ),
                          title: Text(
                            device.friendlyName,
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontWeight: isCurrent
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          subtitle: Text(
                            device.displayInfo,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                          trailing: connecting
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : isCurrent
                              ? Text(
                                  '正在投屏',
                                  style: TextStyle(
                                    color: scheme.primary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                )
                              : null,
                          enabled: !_busy || connecting,
                          onTap: connecting
                              ? null
                              : () => _onSelectDevice(device),
                        );
                      },
                    ),
            ),
            if (isCasting)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    onPressed: _busy ? null : _onDisconnect,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('断开投屏'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _onSelectDevice(DlnaDevice device) async {
    if (_busy) return;
    // 点当前设备不重新投送（否则会停播再重推一遍）。
    if (_cast.currentDevice.value?.udn.value == device.udn.value) {
      Navigator.pop(context);
      return;
    }
    final song = PlayerService.instance.currentSong.value;
    if (song == null) {
      AppToast.show(context, '当前没有正在播放的歌曲');
      return;
    }
    setState(() => _connectingUdn = device.udn.value);
    _stopSearchTimer?.cancel();
    await _cast.stopDiscovery();
    final ok = await _cast.castTo(device, song);
    if (!mounted) return;
    setState(() => _connectingUdn = null);
    if (ok) {
      AppToast.show(context, '已投屏到「${device.friendlyName}」');
      Navigator.pop(context);
    } else {
      AppToast.show(context, _cast.lastCastError ?? '投屏失败，请检查设备是否支持');
    }
  }

  Future<void> _onDisconnect() async {
    setState(() => _disconnecting = true);
    await _cast.disconnect(reason: null);
    if (!mounted) return;
    AppToast.show(context, '已断开投屏');
    Navigator.pop(context);
  }
}
