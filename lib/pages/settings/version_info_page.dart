import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/services/app_update_service.dart';
import '../../app/services/debug_log_service.dart';
import '../../app/state/settings_state.dart';
import '../../components/dialog/app_update_dialog.dart';
import '../../components/index.dart';

class VersionInfoPage extends StatefulWidget {
  const VersionInfoPage({super.key});

  @override
  State<VersionInfoPage> createState() => _VersionInfoPageState();
}

class _VersionInfoPageState extends State<VersionInfoPage> {
  static const String _appName = '飞牛音乐';
  static const String _iconAsset = 'assets/icon/app_icon.png';
  static const String _projectUrl = 'https://github.com/kuilei0926/FeiNiuMusic';

  final DebugLogService _debugLogs = DebugLogService.instance;

  bool _checking = false;
  String _version = '...';
  AppUpdateInfo? _updateInfo;

  @override
  void initState() {
    super.initState();
    _debugLogs.ensureLoaded();
    AppLaunchUpdateSettings.ensureLoaded();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final v = await AppUpdateService.instance.currentVersion();
    if (!mounted) return;
    setState(() => _version = v);
  }

  Future<void> _checkUpdate() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final current = await AppUpdateService.instance.currentVersion();
      final info = await AppUpdateService.instance.checkLatest(current);
      if (!mounted) return;
      setState(() => _updateInfo = info);
      if (info.hasUpdate) {
        await showAppUpdateDialog(context, info: info, currentVersion: current);
      } else {
        await showLatestVersionDialog(context, currentVersion: current);
      }
    } catch (_) {
      if (!mounted) return;
      await showUpdateFailedDialog(context);
    } finally {
      if (mounted) {
        setState(() => _checking = false);
      }
    }
  }

  Future<void> _clearLogs() async {
    await _debugLogs.clear();
    if (!mounted) return;
    AppToast.show(context, '日志已清空');
  }

  Future<void> _copyLogs() async {
    final text = _debugLogs.exportText();
    if (text.trim().isEmpty) {
      AppToast.show(context, '暂无日志');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    AppToast.show(context, '日志已复制');
  }

  Future<void> _openProjectUrl() async {
    final uri = Uri.parse(_projectUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      await Clipboard.setData(ClipboardData(text: _projectUrl));
      if (mounted) {
        AppToast.show(context, '无法打开浏览器，地址已复制');
      }
    }
  }

  Future<void> _exportLogs() async {
    await _debugLogs.ensureLoaded();
    final text = _debugLogs.exportText();
    if (!mounted) return;
    if (text.trim().isEmpty) {
      AppToast.show(context, '暂无日志');
      return;
    }
    final now = DateTime.now();
    final filename =
        'feiniu-music-debug-${now.year}${_two(now.month)}${_two(now.day)}-${_two(now.hour)}${_two(now.minute)}${_two(now.second)}.txt';
    // 让用户选保存位置（Android 走系统"另存为"对话框，写入外部存储用户可访问）
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出日志',
      fileName: filename,
      type: FileType.any,
      bytes: Uint8List.fromList(utf8.encode(text)),
    );
    if (path == null) return; // 用户取消
    if (!mounted) return;
    AppToast.show(context, '日志已导出');
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding =
        AppPageScaffold.scrollableBottomPadding(context, showMiniPlayer: false);
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const AppTopBar(
        title: '版本信息',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      showMiniPlayer: false,
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
        children: [
          AppSettingSection(
            title: '应用信息',
            children: [
              AppSettingTile(
                title: '应用名称',
                subtitle: _appName,
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset(
                    _iconAsset,
                    width: 32,
                    height: 32,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              AppSettingTile(
                title: '当前版本',
                subtitle: _version,
                leading: const Icon(Icons.info_outline_rounded),
              ),
              AppSettingTile(
                title: '项目地址',
                subtitle: 'GitHub 开源仓库，欢迎 Star',
                leading: const Icon(Icons.link_rounded),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _openProjectUrl,
              ),
              AppSettingTile(
                title: '检查更新',
                subtitle: _updateSubtitle(),
                leading: const Icon(Icons.system_update_alt_rounded),
                trailing: _checking
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.chevron_right_rounded),
                onTap: _checking ? null : _checkUpdate,
              ),
              ValueListenableBuilder<bool>(
                valueListenable:
                    AppLaunchUpdateSettings.autoCheckUpdateOnLaunch,
                builder: (context, enabled, _) {
                  return AppSettingSwitchTile(
                    title: '启动时自动检查更新',
                    subtitle: '打开应用时在后台检查，有新版本会弹窗提示',
                    value: enabled,
                    onChanged:
                        AppLaunchUpdateSettings.setAutoCheckUpdateOnLaunch,
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          AppSettingSection(
            title: '调试',
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: _debugLogs.enabled,
                builder: (context, enabled, _) {
                  return AppSettingSwitchTile(
                    title: '调试模式',
                    subtitle: '开启后记录最近的调试日志，便于排查卡顿和异常',
                    value: enabled,
                    onChanged: _debugLogs.setEnabled,
                  );
                },
              ),
              AppSettingTile(
                title: '清空日志',
                subtitle: '删除已记录的本地调试日志',
                leading: const Icon(Icons.delete_outline_rounded),
                onTap: _clearLogs,
              ),
              AppSettingTile(
                title: '导出日志',
                subtitle: '生成日志文件，便于发送给开发者',
                leading: const Icon(Icons.download_rounded),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _exportLogs,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildLogViewer(context),
        ],
      ),
    );
  }

  Widget _buildLogViewer(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<List<String>>(
      valueListenable: _debugLogs.entries,
      builder: (context, logs, _) {
        return AppSettingSection(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '最近日志 (${logs.length})',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (logs.isNotEmpty)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    tooltip: '复制全部',
                    onPressed: _copyLogs,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (logs.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Center(
                  child: Text(
                    _debugLogs.enabled.value ? '暂无日志' : '调试模式未开启',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              )
            else
              Container(
                constraints: const BoxConstraints(maxHeight: 300),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Scrollbar(
                  child: ListView.separated(
                    padding: const EdgeInsets.all(10),
                    shrinkWrap: true,
                    // Newest first.
                    itemCount: logs.length,
                    separatorBuilder: (_, _) => Divider(
                      height: 10,
                      thickness: 0.5,
                      color: scheme.outlineVariant.withValues(alpha: 0.3),
                    ),
                    itemBuilder: (context, i) {
                      final line = logs[logs.length - 1 - i];
                      return SelectableText(
                        line,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11.5,
                          height: 1.4,
                          color: scheme.onSurface.withValues(alpha: 0.88),
                        ),
                      );
                    },
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  String _updateSubtitle() {
    final info = _updateInfo;
    if (info == null) return '检查是否有新版本';
    if (info.hasUpdate) {
      return '发现新版本 ${info.latestVersion}';
    }
    return '当前已是最新版本';
  }

  String _two(int value) => value.toString().padLeft(2, '0');
}
