import 'package:flutter/material.dart';

import '../../app/router/app_router.dart';
import '../../app/services/feiniu/account_store.dart';
import '../account/account_header_card.dart';
import 'base/app_page_scaffold.dart';

class SideMenu extends StatelessWidget {
  final ValueChanged<String>? onNavigate;
  final ValueChanged<String>? onPush;
  final VoidCallback? onCloseDrawer;

  const SideMenu({super.key, this.onNavigate, this.onPush, this.onCloseDrawer});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // 干净的中性渐变背景：表面色 → surfaceContainerLow，无彩色光晕，
    // 让统一的主题色点缀（图标/色条）成为唯一的彩色，协调不花哨。
    final surface = scheme.surface;
    final bottomColor = Color.alphaBlend(
      scheme.surfaceContainerLow.withValues(alpha: 0.45),
      surface,
    );

    // 三张导航卡片统一用表面色块，仅靠圆角/阴影/留白区分；
    // 颜色层次交给统一的主题色图标与标题色条，避免多色渐变杂乱。
    final cardColor = scheme.surfaceContainerHigh.withValues(alpha: 0.55);

    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [surface, bottomColor],
          ),
        ),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(context),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  children: [
                    // 当前账号卡片（点击进入账号切换页，走内容区导航：与
                    // 顶部头部一致，避免从根 Navigator 压栈盖住整个平板外壳）
                    AccountHeaderCard(
                      onTap: () => _pushAndClose(context, AppRoutes.accounts),
                    ),
                    const SizedBox(height: 10),
                    _GroupCard(
                      title: '浏览',
                      color: cardColor,
                      accent: scheme.primary,
                      children: [
                        _MenuItem(
                          icon: Icons.home_rounded,
                          label: '首页',
                          onTap: () =>
                              _navigateAndClose(context, AppRoutes.home),
                        ),
                        _MenuItem(
                          icon: Icons.music_note_rounded,
                          label: '歌曲',
                          onTap: () =>
                              _navigateAndClose(context, AppRoutes.songs),
                        ),
                        _MenuItem(
                          icon: Icons.history_rounded,
                          label: '最近',
                          onTap: () =>
                              _navigateAndClose(context, AppRoutes.recent),
                        ),
                        _MenuItem(
                          icon: Icons.favorite_rounded,
                          label: '收藏',
                          onTap: () =>
                              _navigateAndClose(context, AppRoutes.favorites),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _GroupCard(
                      title: '资源库',
                      color: cardColor,
                      accent: scheme.primary,
                      children: [
                        _MenuItem(
                          icon: Icons.album_rounded,
                          label: '专辑',
                          onTap: () =>
                              _navigateAndClose(context, AppRoutes.albums),
                        ),
                        _MenuItem(
                          icon: Icons.people_rounded,
                          label: '歌手',
                          onTap: () =>
                              _navigateAndClose(context, AppRoutes.artists),
                        ),
                        _MenuItem(
                          icon: Icons.music_video_rounded,
                          label: '风格',
                          onTap: () =>
                              _navigateAndClose(context, AppRoutes.genres),
                        ),
                        _MenuItem(
                          icon: Icons.queue_music_rounded,
                          label: '歌单',
                          onTap: () =>
                              _navigateAndClose(context, AppRoutes.playlists),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _GroupCard(
                      title: '更多',
                      color: cardColor,
                      accent: scheme.primary,
                      children: [
                        _MenuItem(
                          icon: Icons.bar_chart_rounded,
                          label: '统计',
                          onTap: () =>
                              _pushAndClose(context, AppRoutes.listeningStats),
                        ),
                        _MenuItem(
                          icon: Icons.settings_rounded,
                          label: '设置',
                          onTap: () => _pushAndClose(context, AppRoutes.settings),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 顶部头部 ──────────────────────────────────────────────
  // 服务器信息：第一行服务器名称（备注名，无备注则「飞牛音乐」），
  // 第二行 FNID 或服务器地址（FNID 只显示 id，否则显示主机名）。
  // 点击进入账号切换页。无当前账号时退回纯 logo + 应用名。

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ValueListenableBuilder<String?>(
      valueListenable: AccountStore.instance.currentAccountId,
      builder: (context, accountId, _) {
        final account = AccountStore.instance.currentAccount;
        final hasAccount = account != null;
        return Semantics(
          button: true,
          label: hasAccount ? '切换账号' : '返回首页',
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => hasAccount
                ? _pushAndClose(context, AppRoutes.accounts)
                : _navigateAndClose(context, AppRoutes.home),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
              child: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: scheme.primary.withValues(alpha: 0.22),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Image.asset(
                      'assets/icon/app_icon.png',
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: hasAccount
                          ? [
                              Text(
                                account.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.2,
                                  color: scheme.onSurface,
                                ),
                              ),
                              const SizedBox(height: 1),
                              Tooltip(
                                message: account.serverUrl,
                                child: Text(
                                  account.serverLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: scheme.onSurfaceVariant.withValues(
                                      alpha: 0.8,
                                    ),
                                  ),
                                ),
                              ),
                            ]
                          : [
                              Text(
                                '飞牛音乐',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.2,
                                  color: scheme.onSurface,
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                '第三方客户端',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant.withValues(
                                    alpha: 0.8,
                                  ),
                                ),
                              ),
                            ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _navigateAndClose(BuildContext context, String route) {
    if (onNavigate != null) {
      onNavigate?.call(route);
      return;
    }
    if (!context.mounted) return;
    _closeDrawer(context, immediate: true);
    if (route == AppRoutes.home) {
      // 首页是抽屉模式的根页面：弹回根路由即可，避免重复压栈。
      // 不要用 pushNamedAndRemoveUntil —— 那会清空整个路由栈，
      // 导致按返回直接退出而不是回到首页。
      Navigator.of(context).popUntil((r) => r.isFirst);
    } else {
      Navigator.pushNamed(context, route);
    }
  }

  void _pushAndClose(BuildContext context, String route) {
    if (onPush != null) {
      onPush?.call(route);
      return;
    }
    if (!context.mounted) return;
    _closeDrawer(context, immediate: true);
    Navigator.pushNamed(context, route);
  }

  void _closeDrawer(BuildContext context, {bool immediate = false}) {
    if (!context.mounted) return;
    final state = context.findAncestorStateOfType<AppPageScaffoldState>();
    if (immediate) {
      // 导航前同步收起：直接调 state，穿透 onCloseDrawer 回调，
      // 避免 240ms 反向动画被路由转场打断导致抽屉卡在半展开。
      state?.closeDrawerImmediately();
      return;
    }
    if (onCloseDrawer != null) {
      onCloseDrawer?.call();
      return;
    }
    state?.closeDrawer();
  }
}

/// 一组导航项卡片：统一表面色块 + 圆角 + 柔和阴影，无边框无分隔线。
/// 三张卡片用相同底色，靠留白区分；统一的主题色标题条 + 图标作点缀。
class _GroupCard extends StatelessWidget {
  final String title;
  final Color color;
  final Color accent;
  final List<Widget> children;

  const _GroupCard({
    required this.title,
    required this.color,
    required this.accent,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
            child: Row(
              children: [
                Container(
                  width: 4,
                  height: 12,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: accent.withValues(alpha: 0.9),
                  ),
                ),
              ],
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: onTap,
        hoverColor: scheme.primary.withValues(alpha: 0.05),
        highlightColor: scheme.primary.withValues(alpha: 0.05),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, size: 20, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 19,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
