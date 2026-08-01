import 'package:flutter/material.dart';

import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/fn_connection_probe_service.dart';
import '../../app/services/feiniu/fn_models.dart';
import '../../app/state/settings_fn_state.dart';
import '../../components/index.dart';

/// FN Connect 连接设置页
///
/// 展示当前连接详情、连接偏好、以及本次 FNID 返回的所有候选链路及其状态，
/// 允许用户手动选中任意可用链路进行切换。
class FnConnectSettingsPage extends StatefulWidget {
  const FnConnectSettingsPage({super.key});

  @override
  State<FnConnectSettingsPage> createState() => _FnConnectSettingsPageState();
}

class _FnConnectSettingsPageState extends State<FnConnectSettingsPage> {
  bool _probing = false;

  /// 已展开不可用连接的分组
  final Set<ProbeCandidateGroup> _expandedUnreachableGroups = {};

  @override
  void initState() {
    super.initState();
    AppFnConnectionSettings.ensureLoaded();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _startFullProbe();
    });
  }

  /// 执行全量探测
  Future<void> _startFullProbe({
    List<ProbeCandidateGroup>? overrideOrder,
  }) async {
    final fnId = AppFnConnectionSettings.lastFnId;
    if (fnId == null || fnId.isEmpty) {
      AppToast.show(context, '没有可用的 FNID，请先使用 FNID 登录', type: ToastType.error);
      return;
    }

    setState(() {
      _probing = true;
    });

    try {
      final result = await FnConnectionProbeService.instance.probeAllCandidates(
        fnId: fnId,
        order: overrideOrder,
      );

      if (!mounted) return;

      // 保存探测结果
      if (result.firstSuccess != null) {
        final success = result.firstSuccess!;
        await AppFnConnectionSettings.saveProbeResult(
          fnId: fnId,
          url: success.serverUrl,
          method: success.probeMethod,
          candidateResults: result.candidates,
          isRelay: success.isRelay,
        );

        // 更新 API 客户端
        final currentBase = FeiNiuApiClient.instance.baseUrl;
        if (currentBase != success.serverUrl) {
          await FeiNiuApiClient.instance.setBaseUrl(success.serverUrl);
        }
        FeiNiuApiClient.instance.setRelayMode(success.isRelay);

        if (mounted) {
          AppToast.show(
            context,
            '已切换至: ${success.probeMethod}',
            type: ToastType.success,
          );
        }
      } else {
        // 全部不可达
        AppFnConnectionSettings.currentCandidateResults.value =
            result.candidates;
        if (mounted) {
          AppToast.show(context, '所有链路均无法连接', type: ToastType.error);
        }
      }
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        e.toString().replaceFirst('Exception: ', ''),
        type: ToastType.error,
      );
    } finally {
      if (mounted) {
        setState(() => _probing = false);
      }
    }
  }

  /// 切换到指定候选地址
  Future<void> _switchToCandidate(ProbeCandidateResult candidate) async {
    final fnId = AppFnConnectionSettings.lastFnId;
    if (fnId == null || fnId.isEmpty) return;

    try {
      await FeiNiuApiClient.instance.setBaseUrl(candidate.address);
      FeiNiuApiClient.instance.setRelayMode(candidate.isRelay);
      await AppFnConnectionSettings.saveProbeResult(
        fnId: fnId,
        url: candidate.address,
        method: candidate.description,
        isRelay: candidate.isRelay,
      );

      if (!mounted) return;
      AppToast.show(
        context,
        '已切换至: ${candidate.description}',
        type: ToastType.success,
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, '切换失败: $e', type: ToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomPadding = AppPageScaffold.scrollableBottomPadding(context);

    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const AppTopBar(
        title: 'FN Connect',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
        children: [
          // === 当前连接 ===
          ValueListenableBuilder<String?>(
            valueListenable: AppFnConnectionSettings.currentConnectionUrl,
            builder: (context, url, _) {
              final displayUrl = (url != null && url.isNotEmpty)
                  ? url
                  : FeiNiuApiClient.instance.baseUrl;
              if (displayUrl.isEmpty) {
                return const SizedBox.shrink();
              }
              return ValueListenableBuilder<String?>(
                valueListenable:
                    AppFnConnectionSettings.currentConnectionMethod,
                builder: (context, _, _) {
                  // 用真实的中继标记判断（探测时由 relayMode 写入），
                  // 不能靠描述文字（如 HTTPS (xxx.5ddd.com) 不含「中继」字样）
                  final isRelay = AppFnConnectionSettings.lastIsRelay;
                  return Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isRelay
                              ? Icons.swap_horiz_rounded
                              : Icons.link_rounded,
                          size: 22,
                          color: isRelay ? Colors.orange : Colors.green,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    isRelay ? '中继连接' : '直连',
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isRelay
                                          ? Colors.orange.withValues(
                                              alpha: 0.15,
                                            )
                                          : Colors.green.withValues(
                                              alpha: 0.15,
                                            ),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      isRelay ? '中继' : '直连',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: isRelay
                                            ? Colors.orange.shade700
                                            : Colors.green.shade700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                displayUrl,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
          const SizedBox(height: 16),

          // === 连接优先级 ===
          AppSettingSection(
            title: '连接优先级',
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                child: Text(
                  '拖拽调整顺序，排在上方的连接优先尝试',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              ValueListenableBuilder<List<ProbeCandidateGroup>>(
                valueListenable: AppFnConnectionSettings.connectionOrder,
                builder: (context, order, _) {
                  return ReorderableListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    onReorderItem: (oldIndex, newIndex) {
                      final next = List<ProbeCandidateGroup>.from(order);
                      final item = next.removeAt(oldIndex);
                      next.insert(newIndex, item);
                      _setConnectionOrder(next);
                    },
                    itemCount: order.length,
                    itemBuilder: (context, index) {
                      final group = order[index];
                      return AppSettingTile(
                        key: ValueKey('conn_order_${group.name}'),
                        title: group.title,
                        subtitle: group.subtitle,
                        trailing: ReorderableDragStartListener(
                          index: index,
                          child: const Padding(
                            padding: EdgeInsets.only(left: 8),
                            child: Icon(Icons.drag_handle_rounded),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),

          // === 忽略 SSL 证书校验 ===
          AppSettingSection(
            title: '安全',
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: AppFnConnectionSettings.ignoreSsl,
                builder: (context, ignoreSsl, _) {
                  return SwitchListTile(
                    title: const Text('忽略 SSL 证书校验'),
                    subtitle: const Text('自签名证书或 IP 直连时开启'),
                    value: ignoreSsl,
                    onChanged: (value) {
                      AppFnConnectionSettings.setIgnoreSsl(value);
                    },
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),

          // === 候选链路列表 ===
          AppSettingSection(
            title: '候选链路',
            children: [
              ValueListenableBuilder<List<ProbeCandidateResult>?>(
                valueListenable:
                    AppFnConnectionSettings.currentCandidateResults,
                builder: (context, results, _) {
                  if (results == null || results.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        '尚未探测，点击下方按钮开始全量探测',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }

                  // 按分组排序并分组显示（可达组在前，组间按用户优先级排序）
                  final userOrder =
                      AppFnConnectionSettings.connectionOrder.value;
                  final grouped =
                      <ProbeCandidateGroup, List<ProbeCandidateResult>>{};
                  for (final r in results) {
                    grouped.putIfAbsent(r.group, () => []).add(r);
                  }
                  final sortedGroups = grouped.entries.toList()
                    ..sort((a, b) {
                      final aReachable = a.value.any((r) => r.isReachable)
                          ? 0
                          : 1;
                      final bReachable = b.value.any((r) => r.isReachable)
                          ? 0
                          : 1;
                      if (aReachable != bReachable) {
                        return aReachable.compareTo(bReachable);
                      }
                      final aOrder = userOrder.indexWhere((g) => g == a.key);
                      final bOrder = userOrder.indexWhere((g) => g == b.key);
                      if (aOrder != bOrder) return aOrder.compareTo(bOrder);
                      return a.value.first.groupOrder.compareTo(
                        b.value.first.groupOrder,
                      );
                    });

                  return ValueListenableBuilder<String?>(
                    valueListenable:
                        AppFnConnectionSettings.currentConnectionUrl,
                    builder: (context, currentUrl, _) {
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: sortedGroups.expand((entry) {
                          final items = <Widget>[];

                          // 组标题
                          items.add(
                            Padding(
                              padding: const EdgeInsets.fromLTRB(4, 12, 0, 6),
                              child: Text(
                                entry.value.first.groupTitle,
                                style: theme.textTheme.labelLarge?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          );

                          // 可用连接直接展示
                          final reachable = entry.value
                              .where((r) => r.isReachable)
                              .toList();
                          items.addAll(
                            _buildCandidateTiles(reachable, currentUrl),
                          );

                          // 不可用连接默认折叠
                          final unreachable = entry.value
                              .where((r) => !r.isReachable)
                              .toList();
                          if (unreachable.isNotEmpty) {
                            final expanded = _expandedUnreachableGroups
                                .contains(entry.key);
                            items.add(
                              _UnreachableToggle(
                                count: unreachable.length,
                                expanded: expanded,
                                onTap: () => _toggleUnreachableGroup(entry.key),
                              ),
                            );
                            if (expanded) {
                              items.addAll(
                                _buildCandidateTiles(unreachable, currentUrl),
                              );
                            }
                          }
                          return items;
                        }).toList(),
                      );
                    },
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),

          // === 重新探测按钮 ===
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _probing ? null : _startFullProbe,
              icon: _probing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.refresh_rounded),
              label: Text(_probing ? '正在探测中...' : '重新探测'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // === FNID 信息（非交互，仅供参考） ===
          if (AppFnConnectionSettings.lastFnId != null)
            Center(
              child: Text(
                'FNID: ${AppFnConnectionSettings.lastFnId}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _setConnectionOrder(List<ProbeCandidateGroup> order) {
    if (FnConnectionProbeService.instance.isProbing.value) {
      FnConnectionProbeService.instance.cancel();
    }
    // 保存顺序，下次连接（启动 / 登录 / 自动重连）时按新顺序生效
    AppFnConnectionSettings.setConnectionOrder(order);
  }

  void _toggleUnreachableGroup(ProbeCandidateGroup group) {
    setState(() {
      if (!_expandedUnreachableGroups.remove(group)) {
        _expandedUnreachableGroups.add(group);
      }
    });
  }

  /// 将一组候选链路按 ipLabel 分组渲染（组间加分隔线）
  List<Widget> _buildCandidateTiles(
    List<ProbeCandidateResult> candidates,
    String? currentUrl,
  ) {
    final theme = Theme.of(context);
    final byIp = <String?, List<ProbeCandidateResult>>{};
    for (final r in candidates) {
      byIp.putIfAbsent(r.ipLabel, () => []).add(r);
    }
    final ipEntries = byIp.entries.toList();
    final items = <Widget>[];
    for (var i = 0; i < ipEntries.length; i++) {
      final ipEntry = ipEntries[i];
      // IP 分割线（中继无 ipLabel，不加）
      if (i > 0) {
        items.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Divider(
              height: 4,
              indent: 32,
              endIndent: 32,
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
        );
      }
      items.addAll(
        ipEntry.value.map((candidate) {
          final isActive = candidate.address == currentUrl;
          return _CandidateTile(
            candidate: candidate,
            isActive: isActive,
            onTap: (candidate.isReachable && !isActive)
                ? () => _switchToCandidate(candidate)
                : null,
          );
        }),
      );
    }
    return items;
  }
}

/// 单条候选链路 Tile
class _CandidateTile extends StatelessWidget {
  final ProbeCandidateResult candidate;
  final bool isActive;
  final VoidCallback? onTap;

  const _CandidateTile({
    required this.candidate,
    this.isActive = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isReachable = candidate.isReachable;

    return Opacity(
      opacity: isReachable ? 1.0 : 0.55,
      child: AppSettingTile(
        title: candidate.description,
        subtitle: isReachable ? '可连接' : candidate.error ?? '不可达',
        leading: Icon(
          isReachable ? Icons.check_circle_rounded : Icons.cancel_rounded,
          size: 20,
          color: isReachable ? Colors.green : theme.colorScheme.error,
        ),
        trailing: isActive
            ? Icon(
                Icons.check_rounded,
                size: 20,
                color: theme.colorScheme.primary,
              )
            : (isReachable
                  ? const Icon(Icons.swap_horiz_rounded, size: 18)
                  : null),
        onTap: onTap,
      ),
    );
  }
}

/// 展开/折叠不可用连接的切换行
class _UnreachableToggle extends StatelessWidget {
  final int count;
  final bool expanded;
  final VoidCallback onTap;

  const _UnreachableToggle({
    required this.count,
    required this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppSettingTile(
      title: expanded ? '收起不可用连接' : '展开 $count 个不可用连接',
      leading: Icon(
        expanded ? Icons.unfold_less_rounded : Icons.unfold_more_rounded,
        size: 20,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      trailing: Icon(
        expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
        size: 18,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      onTap: onTap,
    );
  }
}
