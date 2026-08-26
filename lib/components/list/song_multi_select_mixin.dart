import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../app/services/feiniu/favorite_service.dart';
import '../../app/services/player_service.dart';
import '../../app/services/song_match/song_match_service.dart';
import '../../app/state/song_state.dart';
import '../../pages/library/playlists_page.dart' show showAddToPlaylistDialog;
import '../../app/router/app_router.dart';
import '../feedback/app_toast.dart';
import 'multi_select_bottom_bar.dart';
/// 全局多选活动计数：当前有多少个页面处于多选状态。
///
/// 平板/TV/Windows 布局的迷你播放器由 [TabletLayoutHost] 统一渲染，不感知
/// 各页面自己的多选状态。多选时底部会出现操作栏，迷你播放器会挡住它，
/// 所以用这个全局计数让外壳在任一页面多选时隐藏迷你播放器（手机端各页
/// 已用 `showMiniPlayer: !isMultiSelecting` 自行控制，互不影响）。
final ValueNotifier<int> globalMultiSelectActive = ValueNotifier(0);

/// 底栏 shell 返回键多选时的取消请求信号。
///
/// shell 的 PopScope 收到返回键且发现任一页面多选时 bump 一次：返回键在多选
/// 状态下的语义是「取消多选、留在当前页」，而不是切 tab / 退出页面。各多选页
/// （[SongMultiSelectMixin] 内）监听后退出多选；详情页是独立路由，由各自的
/// PopScope 处理，不需要此信号。
final ValueNotifier<int> requestCancelMultiSelect = ValueNotifier(0);

/// 歌曲列表页多选通用能力。
///
/// 为歌曲/收藏/最近播放/歌手详情/专辑详情/风格详情等页面提供：
///   - 多选状态（`_multiSelect` / `_selectedIds`，按 `song.id` 存 `Set`，天然跨分页保留）；
///   - 全选 / 取消全选 / 点选单个；
///   - 三个共享操作：添加到播放队列（复用 [PlayerService.insertNext]）、
///     添加到歌单（[showAddToPlaylistDialog]）、添加到收藏（循环 favorite）。
///
/// 依赖 [SignalsMixin] 的自动重建：signal 变化即触发 setState，与各页现有渲染一致。
/// 页面需实现 [multiSelectSongs]（当前可见歌曲列表，收藏/最近页为过滤后的列表）。
mixin SongMultiSelectMixin<T extends StatefulWidget>
    on State<T>, SignalsMixin<T> {
  /// 页面提供：当前可见歌曲列表（收藏/最近页为过滤后的 `_songs`）。
  List<SongEntity> get multiSelectSongs;

  /// 页面提供：操作成功后的收尾（默认退出多选并清空选中）。
  ///
  /// 各页面按需 override，如歌单详情页「移出」需先 reload 再退出。
  Future<void> Function()? get onMultiSelectDone => _defaultMultiSelectDone;

  Future<void> _defaultMultiSelectDone() async {
    if (!mounted) return;
    exitMultiSelect();
  }

  /// 页面提供：移除收藏成功后收到被移除的 id 列表（收藏页据此清理本地列表）。
  void Function(List<String> removedIds)? get onSongsRemovedFromFavorite => null;
  late final _multiSelect = createSignal(false);
  late final _selectedIds = createSignal<Set<String>>({});

  bool get isMultiSelecting => _multiSelect.value;
  int get selectedCount => _selectedIds.value.length;
  bool isSongSelected(String id) => _selectedIds.value.contains(id);
  List<SongEntity> get selectedSongs =>
      multiSelectSongs.where((s) => _selectedIds.value.contains(s.id)).toList();

  void toggleMultiSelect() {
    _multiSelect.value = !_multiSelect.value;
    _selectedIds.value = {};
    // 同步全局多选计数（平板/TV/Windows 外壳据此隐藏迷你播放器）。
    globalMultiSelectActive.value += _multiSelect.value ? 1 : -1;
    if (globalMultiSelectActive.value < 0) globalMultiSelectActive.value = 0;
  }

  @override
  void initState() {
    super.initState();
    // 底栏 shell 返回键多选时的取消请求（见 requestCancelMultiSelect）。
    requestCancelMultiSelect.addListener(_handleCancelMultiSelectRequest);
  }

  void _handleCancelMultiSelectRequest() {
    // 返回键语义 = 取消多选，留在当前页（不切 tab、不退出页面）。
    if (_multiSelect.value) exitMultiSelect();
  }

  @override
  void dispose() {
    requestCancelMultiSelect.removeListener(_handleCancelMultiSelectRequest);
    // 页面在多选状态下被销毁（如切换账号重建外壳/直接返回）时，释放全局
    // 计数，避免迷你播放器被永久隐藏。页面自身的 dispose 走 super 到这里。
    // 延迟到帧后：dispose 常在 widget tree 锁定期执行，同步 notify 会触发
    // "setState when widget tree was locked"。
    if (_multiSelect.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        globalMultiSelectActive.value =
            (globalMultiSelectActive.value - 1).clamp(0, 1 << 30);
      });
    }
    super.dispose();
  }

  void exitMultiSelect() {
    if (_multiSelect.value) toggleMultiSelect();
  }

  void toggleSelectAll() {
    final songs = multiSelectSongs;
    if (songs.isEmpty) return;
    _selectedIds.value = _selectedIds.value.length == songs.length
        ? <String>{}
        : songs.map((e) => e.id).toSet();
  }

  void toggleSongSelection(String id) {
    final next = _selectedIds.value.toSet();
    if (next.contains(id)) {
      next.remove(id);
    } else {
      next.add(id);
    }
    _selectedIds.value = next;
  }

  /// tile 左侧：多选中显示勾选圈（保留原封面在右侧）。
  Widget selectionLeading(BuildContext context, Widget? original, bool selected) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          selected ? Icons.check_circle : Icons.circle_outlined,
          size: 20,
          color: selected
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).disabledColor,
        ),
        const SizedBox(width: 12),
        original ?? const SizedBox.shrink(),
      ],
    );
  }

  /// 添加到播放队列：把选中的歌曲插入当前曲目之后（下一首播放）。
  Future<void> addSelectedToQueue() async {
    final songs = selectedSongs;
    if (songs.isEmpty) return;
    await PlayerService.instance.insertNext(songs);
    if (!mounted) return;
    AppToast.show(context, '已将 ${songs.length} 首歌曲加入下一首播放');
    await onMultiSelectDone?.call();
  }

  /// 添加到歌单：弹出歌单选择，批量添加选中的歌曲。
  Future<void> addSelectedToPlaylist() async {
    final ids = _selectedIds.value.toList();
    if (ids.isEmpty) return;
    final added = await showAddToPlaylistDialog(context, songIds: ids);
    if (!mounted) return;
    if (added) await onMultiSelectDone?.call();
  }

  /// 添加到收藏：逐首收藏（接口无批量）。部分失败时提示失败数量。
  Future<void> addSelectedToFavorite() async {
    final ids = _selectedIds.value.toList();
    if (ids.isEmpty) return;
    final failed =
        await FeiNiuFavoriteService.instance.favoriteAll(ids);
    if (!mounted) return;
    final ok = ids.length - failed;
    AppToast.show(
      context,
      failed == 0
          ? '已收藏 $ok 首歌曲'
          : '已收藏 $ok 首，$failed 首失败',
      type: failed == 0 ? ToastType.success : ToastType.error,
    );
    await onMultiSelectDone?.call();
  }

  /// 移除收藏（收藏页多选用）：逐首取消收藏（接口无批量）。部分失败时提示失败数量。
  Future<void> removeSelectedFromFavorite() async {
    final ids = _selectedIds.value.toList();
    if (ids.isEmpty) return;
    final failed =
        await FeiNiuFavoriteService.instance.unfavoriteAll(ids);
    if (!mounted) return;
    final removed = ids.length - failed;
    onSongsRemovedFromFavorite?.call(ids);
    AppToast.show(
      context,
      failed == 0
          ? '已移除收藏 $removed 首歌曲'
          : '已移除收藏 $removed 首，$failed 首失败',
      type: failed == 0 ? ToastType.success : ToastType.error,
    );
    await onMultiSelectDone?.call();
  }

  /// 批量匹配数据：用 Lyrico 数据源插件为选中的歌曲匹配信息并回传 NAS。
  Future<void> matchSelectedSongs() async {
    final songs = selectedSongs;
    if (songs.isEmpty) return;
    if (!mounted) return;

    // 批量匹配会并发请求第三方平台并批量回写 NAS 元数据，尚未经过大量测试。
    // 进入前弹窗确认，避免误操作大规模改动曲库。
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded),
        title: const Text('批量匹配警告'),
        content: const Text(
          '此功能尚处于实验阶段，未经大量测试。\n\n'
          '批量匹配会同时处理所选歌曲，并可能批量修改 NAS 上的曲目信息'
          '（标题 / 歌手 / 专辑 / 年份 / 封面 / 歌词）。\n\n'
          '建议先在少量歌曲上试用，确认结果符合预期后再全量使用。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final nav = Navigator.of(context);
    nav.pushNamed(AppRoutes.batchMatch, arguments: songs);
  }

  /// 构建多选底部操作栏。
  ///
  /// [includeFavorite] 为 false 时隐藏「添加到收藏」（收藏页已收藏）；
  /// [includeRemoveFavorite] 为 true 时增加「移除收藏」（仅收藏页）。
  Widget buildMultiSelectBar({
    bool includeFavorite = true,
    bool includeRemoveFavorite = false,
  }) {
    final empty = _selectedIds.value.isEmpty;
    final actions = <MultiSelectAction>[
      MultiSelectAction(
        icon: Icons.queue_play_next,
        label: '添加到播放队列',
        onTap: empty ? null : () => addSelectedToQueue(),
      ),
      MultiSelectAction(
        icon: Icons.playlist_add,
        label: '添加到歌单',
        onTap: empty ? null : () => addSelectedToPlaylist(),
      ),
      // 「批量匹配」依赖服务端增强（FnMusicEnhance）数据源，后端不可达时隐藏。
      if (SongMatchService.instance.available)
        MultiSelectAction(
          icon: Icons.travel_explore_rounded,
          label: '批量匹配',
          onTap: empty ? null : () => matchSelectedSongs(),
        ),
      if (includeFavorite)
        MultiSelectAction(
          icon: Icons.favorite_border_rounded,
          label: '添加到收藏',
          onTap: empty ? null : () => addSelectedToFavorite(),
        ),
      if (includeRemoveFavorite)
        MultiSelectAction(
          icon: Icons.favorite_rounded,
          label: '移除收藏',
          isDestructive: true,
          onTap: empty ? null : () => removeSelectedFromFavorite(),
        ),
    ];
    return MultiSelectBottomBar(actions: actions);
  }
}
