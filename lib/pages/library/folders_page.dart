import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../app/router/app_router.dart';
import '../../app/services/companion/folder_companion_service.dart';
import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/folder_models.dart';
import '../../app/services/player_service.dart';
import '../../app/state/settings_lyric_companion.dart';
import '../../app/state/song_state.dart';
import '../../app/utils/natural_sort.dart';
import '../../components/index.dart';
import '../songs/song_detail_sheet.dart';
import 'library_detail_pages.dart';

/// 文件夹视图 —— 按 NAS 文件系统目录层级浏览音乐文件。
///
/// 目录数据来自服务端增强（FnMusicEnhance，38200 端口）的
/// `GET /music/api/v1/folder/list`，路径为库内相对路径（不含 /vol3/...）。
/// 第一层是库根目录（如 `/Music`），根请求 `/` 只显示库根入口。
/// 需要已开启「服务端增强」（[LyricCompanionSettings.enabled]）且非中继连接。
class FoldersPage extends StatefulWidget {
  /// 初始目录（库内相对路径，`/` 为根目录）。
  final String initialPath;

  const FoldersPage({super.key, this.initialPath = '/'});

  @override
  State<FoldersPage> createState() => _FoldersPageState();
}

class _FoldersPageState extends State<FoldersPage>
    with SignalsMixin, SongMultiSelectMixin {
  static const String _prefsSortKey = 'folders_sort_key';
  static const String _prefsSortAsc = 'folders_sort_asc';
  static const int _pageSize = 100;

  @override
  List<SongEntity> get multiSelectSongs => _allSongs;

  final FolderCompanionService _service = FolderCompanionService.instance;
  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  final PlayerService _player = PlayerService.instance;

  /// 当前目录路径（单页内导航，随面包屑/进入/返回变化）。
  late final _path = createSignal<String>(widget.initialPath);

  late final _loading = createSignal(true);
  late final _error = createSignal<String?>(null);

  /// 当前目录的文件夹列表 + 根信息（不分页）。
  late final _listing = createSignal<FolderListing?>(null);

  /// 已加载的文件列表（跨分页累积）。
  late final _files = createSignal<List<FolderFile>>([]);

  /// 当前目录歌曲总数（拆分后，服务端 total，用于显示）。
  late final _total = createSignal(0);

  /// 当前目录文件总数（服务端 fileTotal，用于分页）。
  late final _fileTotal = createSignal(0);

  late final _sortKey = createSignal<String>('name');
  late final _ascending = createSignal(true);

  /// 是否还有更多文件可加载。
  late final _hasMore = createSignal(true);

  /// 是否正在加载下一页。
  late final _isLoadingMore = createSignal(false);

  /// 当前播放歌曲 id（用于行尾跳动动画 + 标题高亮）。
  late final _currentId = createSignal<String?>(null);

  /// 是否正在播放。
  late final _playerPlaying = createSignal(false);

  /// 平铺模式：显示当前目录树所有歌曲（不按目录分组）。
  late final _flatten = createSignal(false);

  /// 搜索是否展开。
  bool _searchVisible = false;

  /// 当前搜索关键词（空 = 非搜索态）。
  late final _searchQuery = createSignal('');

  final TextEditingController _searchController = TextEditingController();

  /// 滚动到底部触发加载更多。
  final ScrollController _listController = ScrollController();

  /// 顶部标题：根目录显示功能名，其余显示当前目录名。
  String get _title {
    final segs = _path.value.split('/').where((s) => s.isNotEmpty).toList();
    if (segs.isEmpty) return '文件夹';
    return segs.last;
  }

  @override
  void initState() {
    super.initState();
    _restoreSortPrefs();
    _listController.addListener(_handleScroll);
    // 同步当前播放歌曲，供行尾跳动动画使用
    _currentId.value = _player.currentSong.value?.id;
    _playerPlaying.value = _player.isPlaying.value;
    _player.currentSong.addListener(_handleCurrentSongChanged);
    _player.isPlaying.addListener(_handlePlayingChanged);
    _load();
  }

  @override
  void dispose() {
    _player.currentSong.removeListener(_handleCurrentSongChanged);
    _player.isPlaying.removeListener(_handlePlayingChanged);
    _listController.removeListener(_handleScroll);
    _listController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _handleCurrentSongChanged() {
    if (!mounted) return;
    _currentId.value = _player.currentSong.value?.id;
  }

  void _handlePlayingChanged() {
    if (!mounted) return;
    _playerPlaying.value = _player.isPlaying.value;
  }

  /// 滚动到底部（距底 200px 内）时加载下一页。
  void _handleScroll() {
    if (!_listController.hasClients) return;
    final offset = _listController.offset;
    final maxScroll = _listController.position.maxScrollExtent;
    if (maxScroll > 0 && offset >= maxScroll - 200) {
      _loadMore();
    }
  }

  /// 返回上一级目录（系统返回键）。根目录时返回 true 允许退出。
  bool _handleBack() {
    final current = _path.value;
    if (current == '/') return true;
    final parent = _parentOf(current);
    _goTo(parent);
    return false;
  }

  /// 跳到指定目录（面包屑/进入/返回共用），重新加载。
  void _goTo(String path) {
    if (_path.value == path) return;
    _path.value = path;
    _load();
  }

  static String _parentOf(String path) {
    if (path == '/') return '/';
    final idx = path.lastIndexOf('/');
    return idx <= 0 ? '/' : path.substring(0, idx);
  }

  /// 当前路径的面包屑段：`[{label, path}]`，末位为当前目录。
  List<({String label, String path})> get _crumbs {
    final segs = _path.value.split('/').where((s) => s.isNotEmpty).toList();
    final crumbs = <({String label, String path})>[];
    crumbs.add((label: '/', path: '/'));
    var acc = '';
    for (final seg in segs) {
      acc = '$acc/$seg';
      crumbs.add((label: seg, path: acc));
    }
    return crumbs;
  }

  Future<void> _restoreSortPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(_prefsSortKey);
    if (key != null && key.isNotEmpty) {
      _sortKey.value = key;
    }
    _ascending.value = prefs.getBool(_prefsSortAsc) ?? true;
  }

  Future<void> _persistSortPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsSortKey, _sortKey.value);
    await prefs.setBool(_prefsSortAsc, _ascending.value);
  }

  /// 排序比较器缓存（拼音转写开销只在首次）。
  final Map<String, String> _sortCache = {};

  /// 当前文件列表：服务端已按排序键分页返回，客户端不再本地重排，
  /// 保证分页追加后的顺序与页面显示、播放队列完全一致。
  List<FolderFile> get _sortedFiles => _files.value;

  /// 子目录始终按名称排序（不随文件排序键变化）。
  late final _sortedFolders = createComputed<List<FolderDir>>(() {
    final listing = _listing.value;
    if (listing == null || listing.folders.isEmpty) return const [];
    final list = [...listing.folders];
    list.sort((a, b) => naturalPinyinCompare(a.name, b.name, cache: _sortCache));
    return list;
  });

  void _showSortSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return SortSheet(
          title: '排序',
          options: const [
            SortOption(key: 'name', label: '文件名', icon: Icons.abc_rounded),
            SortOption(key: 'createdAt', label: '创建时间', icon: Icons.access_time_rounded),
            SortOption(key: 'duration', label: '时长', icon: Icons.timer_outlined),
            SortOption(key: 'size', label: '大小', icon: Icons.data_usage_rounded),
          ],
          currentKey: _sortKey.value,
          ascending: _ascending.value,
          onSelectKey: (value) {
            if (_sortKey.value != value) {
              _sortKey.value = value;
              _persistSortPrefs();
              _load();
            }
          },
          onSelectAscending: (value) {
            if (_ascending.value != value) {
              _ascending.value = value;
              _persistSortPrefs();
              _load();
            }
          },
        );
      },
    );
  }

  /// 切换搜索框显隐。
  void _toggleSearch() {
    setState(() {
      _searchVisible = !_searchVisible;
      if (!_searchVisible) {
        _searchController.clear();
        _searchQuery.value = '';
        _load();
      }
    });
  }

  Future<void> _load({bool forceRefresh = false}) async {
    if (forceRefresh) _service.clearCache();
    _loading.value = true;
    _error.value = null;
    _hasMore.value = true;
    _isLoadingMore.value = false;
    try {
      final listing = await _service.list(
        path: _path.value,
        keyword: _searchQuery.value,
        flatten: _flatten.value,
        sort: _sortKey.value,
        asc: _ascending.value,
        page: 1,
        pageSize: _pageSize,
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      _listing.value = listing;
      _files.value = listing.files;
      _total.value = listing.total;
      _fileTotal.value = listing.fileTotal;
      _hasMore.value = listing.files.length < listing.fileTotal;
    } catch (e) {
      if (!mounted) return;
      _error.value = e.toString().replaceFirst('Exception: ', '');
    } finally {
      if (mounted) _loading.value = false;
    }
  }

  /// 加载下一页文件并追加到列表。
  Future<void> _loadMore() async {
    if (_isLoadingMore.value || !_hasMore.value || _loading.value) return;
    _isLoadingMore.value = true;
    try {
      final nextPage = _files.value.length ~/ _pageSize + 1;
      final listing = await _service.list(
        path: _path.value,
        keyword: _searchQuery.value,
        flatten: _flatten.value,
        sort: _sortKey.value,
        asc: _ascending.value,
        page: nextPage,
        pageSize: _pageSize,
      );
      if (!mounted) return;
      _files.value = [..._files.value, ...listing.files];
      _total.value = listing.total;
      _fileTotal.value = listing.fileTotal;
      _hasMore.value = _files.value.length < listing.fileTotal;
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, e.toString().replaceFirst('Exception: ', ''), type: ToastType.error);
    } finally {
      if (mounted) _isLoadingMore.value = false;
    }
  }

  /// 按目标数量加载：循环拉页直到达到 target 或没有更多。
  Future<void> _loadMoreToTarget(int target) async {
    if (_isLoadingMore.value || target <= _files.value.length) return;
    _isLoadingMore.value = true;
    try {
      while (mounted && _files.value.length < target && _hasMore.value) {
        final nextPage = _files.value.length ~/ _pageSize + 1;
        final listing = await _service.list(
          path: _path.value,
          keyword: _searchQuery.value,
          sort: _sortKey.value,
          asc: _ascending.value,
          page: nextPage,
          pageSize: _pageSize,
        );
        if (!mounted) return;
        _files.value = [..._files.value, ...listing.files];
        _total.value = listing.total;
        _fileTotal.value = listing.fileTotal;
        _hasMore.value = _files.value.length < listing.fileTotal;
        if (listing.files.isEmpty) break;
      }
    } finally {
      if (mounted) _isLoadingMore.value = false;
    }
  }

  /// 点击数量显示 → 弹出输入对话框，按用户指定的数量加载。
  Future<void> _showLoadMoreDialog() async {
    final loaded = _files.value.length;
    if (_total.value <= loaded) return;
    final target = await LoadMoreCountDialog.show(
      context,
      currentCount: loaded,
      maxTotal: _total.value,
      title: '歌曲加载更多',
    );
    if (target == null || !mounted || target <= loaded) return;
    await _loadMoreToTarget(target);
  }

  /// 点击文件夹进入子目录（同页内切换）。
  void _openFolder(FolderDir dir) => _goTo(dir.path);

  /// 把单个文件的一首 track 构造成可播放 SongEntity。
  SongEntity _toSongEntity(FolderFile file, FolderTrack t) {
    final spec = file.audioSpec;
    // 音质显示文本（与主 App 各页面风格一致：格式 采样率 位深 码率）
    final specText = [
      if (file.suffix.isNotEmpty) file.suffix.toUpperCase(),
      if (spec?.sampleRate != null && spec!.sampleRate! > 0)
        '${(spec.sampleRate! / 1000).toStringAsFixed(1)}kHz',
      if (spec?.bitDepth != null && spec!.bitDepth! > 0) '${spec.bitDepth}bit',
      if (spec?.bitrate != null && spec!.bitrate! > 0)
        '${(spec.bitrate! / 1000).toStringAsFixed(0)}kbps',
    ].join(' ');
    return SongEntity(
      id: t.guid,
      title: t.title,
      artist: jsonEncode([
        for (final a in t.artists)
          {'guid': a.guid, 'name': a.name},
      ]),
      album: t.album == null
          ? null
          : jsonEncode({'guid': t.albumGuid ?? '', 'name': t.album}),
      uri: _api.streamUrl(t.guid),
      headersJson: jsonEncode(_api.authHeaders()),
      durationMs: t.durationMs ?? file.durationMs,
      bitrate: spec?.bitrate,
      sampleRate: spec?.sampleRate,
      format: file.suffix.isEmpty ? null : file.suffix.toUpperCase(),
      codec: spec?.codec,
      audioSpec: specText.isEmpty ? null : specText,
      coverId: t.coverId,
      trackNumber: t.trackNo,
      isCue: t.isCue,
    );
  }

  /// 当前目录全部歌曲（按显示顺序展平：单文件多轨依次加入）。
  List<SongEntity> get _allSongs {
    return [
      for (final f in _sortedFiles)
        for (final t in f.tracks) _toSongEntity(f, t),
    ];
  }

  /// 确保当前目录全部文件已加载（随机/整目录播放前调用）。
  Future<void> _ensureAllLoaded() async {
    if (!_hasMore.value || _isLoadingMore.value) return;
    _isLoadingMore.value = true;
    try {
      while (mounted && _hasMore.value) {
        final nextPage = _files.value.length ~/ _pageSize + 1;
        final listing = await _service.list(
          path: _path.value,
          keyword: _searchQuery.value,
          sort: _sortKey.value,
          asc: _ascending.value,
          page: nextPage,
          pageSize: _pageSize,
        );
        if (!mounted) return;
        _files.value = [..._files.value, ...listing.files];
        _total.value = listing.total;
        _fileTotal.value = listing.fileTotal;
        _hasMore.value = _files.value.length < listing.fileTotal;
        if (listing.files.isEmpty) break;
      }
    } finally {
      if (mounted) _isLoadingMore.value = false;
    }
  }

  /// 点击文件播放：从该文件的第一个曲目开始，播放当前目录全部歌曲。
  void _playFile(FolderFile file) {
    if (file.tracks.isEmpty) return;
    _playTrack(file, file.tracks.first);
  }

  /// 拉取「已加载页之后」的第 [page] 页文件歌曲（供 playQueueFilledToLimit
  /// 的 fetchMore 使用）。返回一页展平后的 SongEntity。
  Future<List<SongEntity>> _fetchFolderPage(int page) async {
    final nextPage = _files.value.length ~/ _pageSize + page;
    final listing = await _service.list(
      path: _path.value,
      keyword: _searchQuery.value,
      flatten: _flatten.value,
      sort: _sortKey.value,
      asc: _ascending.value,
      page: nextPage,
      pageSize: _pageSize,
    );
    return [
      for (final f in listing.files)
        for (final t in f.tracks) _toSongEntity(f, t),
    ];
  }

  /// 点击单曲（含 CUE 多轨中的一首）播放：从该曲开始播放当前目录全部歌曲。
  ///
  /// 与服务端排序分页一致：已加载的部分立即播放（顺序与页面显示一致），
  /// 后续页由 fetchMore 后台按服务端顺序追加，避免顺序跳动。
  void _playTrack(FolderFile file, FolderTrack track) {
    final songs = _allSongs;
    if (songs.isEmpty) return;
    final start = songs.indexWhere((s) => s.id == track.guid);
    _player.playQueueFilledToLimit(
      songs,
      start < 0 ? 0 : start,
      fetchMore: _searchQuery.value.isNotEmpty ? null : _fetchFolderPage,
    );
  }

  /// 面包屑栏（AppTopBar bottom）：左侧可滚动面包屑 + 右侧平铺按钮。
  PreferredSizeWidget _buildBreadcrumb() {
    final scheme = Theme.of(context).colorScheme;
    final flatten = _flatten.value;
    return PreferredSize(
      preferredSize: const Size.fromHeight(40),
      child: Container(
        // 铺满 AppBar 宽度并强制左对齐，避免窄内容被 bottom 居中。
        width: double.infinity,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(right: 4),
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    for (final (i, crumb) in _crumbs.indexed) ...[
                      if (i > 0)
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: i == _crumbs.length - 1
                            ? null
                            : () => _goTo(crumb.path),
                        child: Padding(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                          child: Text(
                            crumb.label,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: i == _crumbs.length - 1
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: i == _crumbs.length - 1
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // 平铺按钮：把当前文件夹及子文件夹所有歌曲平铺展示
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: flatten ? '退出平铺' : '平铺所有歌曲',
              icon: Icon(
                flatten ? Icons.grid_view_rounded : Icons.dashboard_outlined,
                size: 20,
                color: flatten ? scheme.primary : scheme.onSurfaceVariant,
              ),
              onPressed: () {
                _flatten.value = !_flatten.value;
                _load();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final relayMode = _api.relayMode;
    final enabled = LyricCompanionSettings.enabled.value;

    return PopScope(
      // 根目录可正常返回（退出本页）；子目录时拦截返回键做逐级上退
      canPop: _path.value == '/',
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBack();
      },
      child: AppPageScaffold(
        extendBodyBehindAppBar: true,
        showMiniPlayer: !isMultiSelecting,
        appBar: AppTopBar(
          title: isMultiSelecting ? '已选 $selectedCount 首' : _title,
          leading: isMultiSelecting
              ? IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: exitMultiSelect,
                )
              : null,
          backgroundColor: Colors.transparent,
          elevation: 0,
          bottom: isMultiSelecting ? null : _buildBreadcrumb(),
          actions: isMultiSelecting
              ? [
                  SelectAllButton(
                    isAllSelected: selectedCount == multiSelectSongs.length,
                    selectedCount: selectedCount,
                    totalCount: multiSelectSongs.length,
                    onTap: toggleSelectAll,
                  ),
                  MultiSelectToggleButton(
                    enabled: true,
                    onTap: exitMultiSelect,
                  ),
                  const SizedBox(width: 4),
                ]
              : [
                  IconButton(
                    tooltip: _searchVisible ? '关闭搜索' : '搜索',
                    icon: Icon(_searchVisible ? Icons.search_off : Icons.search),
                    onPressed: _toggleSearch,
                  ),
                  SortActionButton(onTap: _showSortSheet),
                  MultiSelectToggleButton(
                    enabled: false,
                    onTap: toggleMultiSelect,
                  ),
                ],
        ),
        body: Column(
          children: [
            if (_searchVisible)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: TextField(
                  controller: _searchController,
                  autofocus: true,
                  onChanged: (v) {
                    _searchQuery.value = v;
                    _load();
                  },
                  decoration: InputDecoration(
                    hintText: '搜索当前文件夹...',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _searchQuery.value.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              _searchQuery.value = '';
                              _load();
                            },
                          )
                        : null,
                    filled: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    border: const OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(20)),
                      borderSide: BorderSide.none,
                    ),
                    isDense: true,
                  ),
                ),
              ),
            Expanded(
              child: Watch.builder(
          builder: (context) {
            // 未开启服务端增强：提示并引导到设置
            if (!enabled) {
              return _CenterHint(
                icon: Icons.folder_open_rounded,
                text: '请先在设置 → 元数据匹配开启「服务端增强」',
                actionText: '去开启',
                onAction: () =>
                    Navigator.of(context).pushNamed(AppRoutes.metadataMatchSettings),
              );
            }
            // 中继连接不可用
            if (relayMode) {
              return const _CenterHint(
                icon: Icons.wifi_off_rounded,
                text: '服务端增强仅内网直连（非中继）可用，当前为中继连接',
              );
            }

            if (_loading.value) {
              return const Center(child: CircularProgressIndicator());
            }
            final error = _error.value;
            if (error != null) {
              return _CenterHint(
                icon: Icons.error_outline_rounded,
                text: error,
                actionText: '重试',
                onAction: () => _load(forceRefresh: true),
              );
            }
            final listing = _listing.value;
            if (listing == null || (listing.folders.isEmpty && _files.value.isEmpty)) {
              return _CenterHint(
                icon: Icons.folder_open_rounded,
                text: '此文件夹暂无音乐',
                actionText: '刷新',
                onAction: () => _load(forceRefresh: true),
              );
            }
            final files = _sortedFiles;
            // 平铺模式不显示子目录
            final folders = _flatten.value ? const <FolderDir>[] : _sortedFolders.value;

            // 展平文件行：单轨文件 1 行，CUE 多轨文件展开为每轨 1 行。
            final fileRows = <Widget>[
              for (final f in files)
                if (f.tracks.length > 1)
                  for (final t in f.tracks) _buildTrackRow(f, t)
                else
                  _buildFileRow(f),
            ];

            return Column(
              children: [
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: () => _load(forceRefresh: true),
                    child: ListView.builder(
                controller: _listController,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                // 数量行 + 文件夹 + 文件行 + 加载中行（无区块标题）
                itemCount:
                    (_total.value > 0 ? 1 : 0) +
                    folders.length +
                    fileRows.length +
                    (_isLoadingMore.value ? 1 : 0),
                itemBuilder: (context, index) {
                  var i = 0;
                  // 数量行
                  if (_total.value > 0) {
                    if (index == 0) {
                      return _buildCountRow();
                    }
                    i += 1;
                  }
                  // 文件夹行
                  if (index < i + folders.length) {
                    return _buildFolderRow(folders[index - i]);
                  }
                  i += folders.length;
                  // 文件行
                  if (index < i + fileRows.length) {
                    return fileRows[index - i];
                  }
                  i += fileRows.length;
                  // 加载中
                  if (_isLoadingMore.value) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
                    ),
                  ),
                  if (isMultiSelecting) buildMultiSelectBar(),
                ],
              );
          },
        ),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部数量行：随机播放按钮 + `共 N 首`，点击数量弹出加载更多对话框。
  Widget _buildCountRow() {
    final scheme = Theme.of(context).colorScheme;
    final total = _total.value;
    final hasMore = _hasMore.value;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
      child: Row(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: _allSongs.isEmpty ? null : _shufflePlay,
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Icon(
                Icons.shuffle_rounded,
                size: 18,
                color: _allSongs.isEmpty ? scheme.outline : scheme.primary,
              ),
            ),
          ),
          LoadMoreCountText(
            text: '共 $total 首',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            onTap: hasMore ? _showLoadMoreDialog : null,
          ),
        ],
      ),
    );
  }

  /// 随机播放：加载完整目录后打乱全部歌曲加入队列。
  void _shufflePlay() {
    _ensureAllLoaded().then((_) {
      if (!mounted) return;
      final songs = [..._allSongs]..shuffle();
      if (songs.isEmpty) return;
      _player.playQueueFilledToLimit(songs, 0);
    });
  }

  Widget _buildFolderRow(FolderDir dir) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(Icons.folder_rounded, color: scheme.primary, size: 28),
      title: Text(dir.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right_rounded, size: 20),
      onTap: () => _openFolder(dir),
    );
  }

  Widget _buildFileRow(FolderFile file) {
    // 单轨文件：标题为歌曲名，副标题只显示歌手
    final single = file.tracks.isEmpty ? null : file.tracks.first;
    if (single == null) return const SizedBox.shrink();
    return _buildTrackListTile(
      song: _toSongEntity(file, single),
      isCurrent: _currentId.value == single.guid,
      onTap: () => _playFile(file),
    );
  }

  /// CUE 多轨文件的单曲行：每首 track 一行，可独立播放。
  Widget _buildTrackRow(FolderFile file, FolderTrack track) {
    return _buildTrackListTile(
      song: _toSongEntity(file, track),
      isCurrent: _currentId.value == track.guid,
      onTap: () => _playTrack(file, track),
    );
  }

  /// 通用歌曲行：多选勾选圈 + 当前播放高亮 + 行尾跳动动画 + 长按详情。
  Widget _buildTrackListTile({
    required SongEntity song,
    required bool isCurrent,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final isPlaying = isCurrent && _playerPlaying.value;
    final selected = isSongSelected(song.id);
    final title = song.title;
    final artist = song.artistDisplayName;
    final subtitle = artist.isEmpty ? null : artist;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      // 仅多选时显示勾选圈，普通模式直接显示封面
      leading: isMultiSelecting
          ? selectionLeading(context, _buildFileLeadingForSong(song), selected)
          : _buildFileLeadingForSong(song),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: isCurrent ? scheme.primary : null,
        ),
      ),
      subtitle: subtitle == null || subtitle.isEmpty
          ? null
          : Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
      trailing: isPlaying
          ? Padding(
              padding: const EdgeInsets.only(left: 4),
              child: PlayingBars(color: scheme.primary, animating: true),
            )
          : null,
      onTap: isMultiSelecting
          ? () => toggleSongSelection(song.id)
          : onTap,
      onLongPress: isMultiSelecting
          ? null
          : () => _showSongDetail(song),
    );
  }

  /// 文件行首：优先显示封面缩略图，无封面时回退音乐图标。
  Widget _buildFileLeadingForSong(SongEntity song) {
    final scheme = Theme.of(context).colorScheme;
    final coverId = song.coverId;
    if (coverId == null || coverId.isEmpty) {
      return Icon(
        Icons.music_note_rounded,
        color: scheme.onSurfaceVariant,
        size: 26,
      );
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final size = (48 * dpr).round().clamp(120, 800);
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: CachedNetworkImage(
        imageUrl: FeiNiuApiClient.instance.coverUrl(coverId, size: size),
        httpHeaders: FeiNiuApiClient.imageAuthHeaders(),
        width: 40,
        height: 40,
        memCacheWidth: 96,
        fit: BoxFit.cover,
        placeholder: (context, url) => Container(
          width: 40,
          height: 40,
          color: scheme.surfaceContainerHighest,
          child: const Icon(Icons.music_note_rounded, size: 20),
        ),
        errorWidget: (context, url, error) => Icon(
          Icons.music_note_rounded,
          color: scheme.onSurfaceVariant,
          size: 26,
        ),
      ),
    );
  }

  /// 长按歌曲 → 弹出与歌曲页同款的长按面板。
  Future<void> _showSongDetail(SongEntity song) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => SongDetailSheet(
        song: song,
        onUpdated: (_) => _load(forceRefresh: true),
        onOpenArtist: (name) {
          final artistGuid = song.firstArtistGuid;
          if (artistGuid != null) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ArtistDetailPage(
                  artistName: name,
                  artistGuid: artistGuid,
                ),
              ),
            );
          }
        },
        onOpenAlbum: (name) {
          final guid = song.albumGuid;
          if (guid != null) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => AlbumDetailPage(
                  albumName: name,
                  albumGuid: guid,
                ),
              ),
            );
          }
        },
      ),
    );
  }
}

/// 居中提示（未开启 / 中继不可用 / 加载失败 / 空目录）。
class _CenterHint extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? actionText;
  final VoidCallback? onAction;

  const _CenterHint({
    required this.icon,
    required this.text,
    this.actionText,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            if (actionText != null && onAction != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: onAction,
                child: Text(actionText!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
