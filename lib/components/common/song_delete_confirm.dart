import 'package:flutter/material.dart';

/// 删除确认弹窗 —— **列表多选**与**播放页控制栏**共用。
///
/// 两个入口做的是同一件事（物理删除 NAS 上的音频文件 + 清库记录），
/// 所以文案、按钮、危险色必须完全一致；否则用户会以为「手机上的删除」和
/// 「列表里的删除」是两种功能，甚至怀疑按错了地方。
///
/// 参数：
/// - [count] 参与删除的曲目数，用于标题；
/// - [lines] 展示给用户的曲目清单（每行一条，建议已带 `· ` 前缀）；
/// - [subtitle] 可选补充说明，例如播放页的「当前正在播放：xxx」。
///
/// 返回 `true` 表示用户确认删除；对话框被系统返回键关掉时返回 `false`。
Future<bool> confirmSongDelete(
  BuildContext context, {
  required int count,
  required List<String> lines,
  String? subtitle,
}) async {
  final theme = Theme.of(context);
  final shown = lines.take(20).join('\n');
  final rest = count > 20 ? '\n… 以及其余 ${count - 20} 首' : '';
  final head = (subtitle == null || subtitle.isEmpty) ? '' : '$subtitle\n\n';
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: Icon(Icons.delete_forever_rounded, color: theme.colorScheme.error),
      title: Text('删除 $count 首歌曲？'),
      content: SingleChildScrollView(
        child: Text(
          '$head将从 NAS 上【物理删除】以下歌曲的文件，删除后无法恢复。\n\n$shown$rest',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: theme.colorScheme.error),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
