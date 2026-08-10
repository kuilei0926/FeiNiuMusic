import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../components/index.dart';

/// 权限管理页：Android 专属（permission_handler 的各权限 / 系统设置跳转）。
/// 桌面端（Windows）无对应权限模型，仅展示提示，不查询权限状态。
class PermissionSettingsPage extends StatefulWidget {
  const PermissionSettingsPage({super.key});

  @override
  State<PermissionSettingsPage> createState() => _PermissionSettingsPageState();
}

class _PermissionSettingsPageState extends State<PermissionSettingsPage>
    with WidgetsBindingObserver {
  /// 桌面端不进入权限查询分支（Windows 上 permission_handler 全部返回
  /// granted，展示出来会误导）。
  static bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  final Map<Permission, PermissionStatus> _statuses = {};
  bool _loading = true;

  List<_PermissionItem> get _items => const [
    _PermissionItem(
      permission: Permission.notification,
      title: '通知权限',
      description: '用于显示媒体播放通知和锁屏控制',
      icon: Icons.notifications_active_outlined,
    ),
    _PermissionItem(
      permission: Permission.audio,
      title: '音乐与音频',
      description: '用于扫描和读取本地音乐文件',
      icon: Icons.library_music_outlined,
    ),
    _PermissionItem(
      permission: Permission.storage,
      title: '文件存储',
      description: '用于旧版 Android 读取和保存音乐文件',
      icon: Icons.folder_open_outlined,
    ),
    _PermissionItem(
      permission: Permission.ignoreBatteryOptimizations,
      title: '后台播放保护',
      description: '建议在系统设置中允许后台活动和无限制电量策略',
      icon: Icons.battery_saver_outlined,
      openSettingsOnly: true,
    ),
    _PermissionItem(
      permission: Permission.systemAlertWindow,
      title: '悬浮窗权限',
      description: '用于后台播放时在系统层级显示切歌悬浮卡片',
      icon: Icons.picture_in_picture_alt_outlined,
      openSettingsOnly: true,
    ),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_isAndroid) {
      _loadStatuses();
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadStatuses();
    }
  }

  Future<void> _loadStatuses() async {
    setState(() => _loading = true);
    final entries = await Future.wait(
      _items.map((item) async {
        return MapEntry(item.permission, await item.permission.status);
      }),
    );
    if (!mounted) return;
    setState(() {
      _statuses
        ..clear()
        ..addEntries(entries);
      _loading = false;
    });
  }

  Future<void> _request(_PermissionItem item) async {
    if (item.openSettingsOnly) {
      await openAppSettings();
      return;
    }
    final status = await item.permission.request();
    if (!mounted) return;
    setState(() => _statuses[item.permission] = status);
    if (status.isPermanentlyDenied || status.isRestricted) {
      await openAppSettings();
    }
  }

  String _statusText(PermissionStatus? status) {
    if (status == null) return '未知';
    if (status.isGranted) return '已允许';
    if (status.isLimited) return '部分允许';
    if (status.isPermanentlyDenied) return '已永久拒绝';
    if (status.isRestricted) return '受系统限制';
    if (status.isDenied) return '未允许';
    if (status.isProvisional) return '临时允许';
    return '未知';
  }

  Color _statusColor(BuildContext context, PermissionStatus? status) {
    final scheme = Theme.of(context).colorScheme;
    if (status == null) return scheme.onSurfaceVariant;
    if (status.isGranted || status.isLimited || status.isProvisional) {
      return scheme.primary;
    }
    return scheme.error;
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding =
        AppPageScaffold.scrollableBottomPadding(context, showMiniPlayer: false);
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const AppTopBar(
        title: '权限管理',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      showMiniPlayer: false,
      body: !_isAndroid
          ? _buildDesktopPlaceholder(bottomPadding)
          : ListView(
              padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
              children: [
                AppSettingSection(
                  title: '应用权限',
                  children: [
                    if (_loading)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else
                      ..._items.map((item) {
                        final status = _statuses[item.permission];
                        final statusColor = _statusColor(context, status);
                        return AppSettingTile(
                          title: item.title,
                          subtitle: '${item.description}\n${_statusText(status)}',
                          leading: Icon(item.icon, color: statusColor),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => _request(item),
                        );
                      }),
                  ],
                ),
                const SizedBox(height: 16),
                AppSettingSection(
                  title: '系统设置',
                  children: [
                    AppSettingTile(
                      title: '打开应用设置',
                      subtitle: '管理通知、电量、后台活动等系统权限',
                      leading: const Icon(Icons.settings_applications_outlined),
                      trailing: const Icon(Icons.open_in_new_rounded),
                      onTap: openAppSettings,
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  /// 桌面端占位：Windows 无 Android 权限模型，直接说明而非展示误导性状态。
  Widget _buildDesktopPlaceholder(double bottomPadding) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: EdgeInsets.fromLTRB(24, 12, 24, bottomPadding),
      children: [
        const SizedBox(height: 32),
        Icon(
          Icons.security_outlined,
          size: 56,
          color: scheme.onSurfaceVariant,
        ),
        const SizedBox(height: 16),
        Text(
          '权限管理仅适用于 Android',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Windows 桌面版不涉及通知、悬浮窗、存储等系统权限，'
          '相关功能已在此平台禁用。',
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _PermissionItem {
  final Permission permission;
  final String title;
  final String description;
  final IconData icon;
  final bool openSettingsOnly;

  const _PermissionItem({
    required this.permission,
    required this.title,
    required this.description,
    required this.icon,
    this.openSettingsOnly = false,
  });
}
