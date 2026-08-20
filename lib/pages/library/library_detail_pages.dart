import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lpinyin/lpinyin.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../app/router/app_page_route.dart';
import '../../app/services/companion/metadata_companion_service.dart';
import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/cue_service.dart';
import '../../app/services/feiniu/track_service.dart';
import '../../app/services/player_service.dart';

import '../../app/state/settings_lyric_companion.dart';
import '../../app/state/settings_playback_state.dart';
import '../../app/state/song_state.dart';
import '../../components/index.dart';
import '../songs/song_detail_sheet.dart';
import 'artist_album_edit_page.dart';

List<String> splitArtists(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return const [];
  final normalized = text
      .replaceAll(' feat. ', '&')
      .replaceAll(' ft. ', '&')
      .replaceAll('Feat.', '&')
      .replaceAll('FT.', '&')
      .replaceAll('Feat', '&')
      .replaceAll('Ft', '&');
  final separators = ['&', '/', '、', '，', ',', ';', '；'];
  var parts = <String>[normalized];
  for (final sep in separators) {
    parts = parts.expand((p) => p.split(sep)).toList();
  }
  final out = <String>[];
  for (final p in parts) {
    final v = p.trim();
    if (v.isEmpty) continue;
    out.add(v);
  }
  return out;
}

String primaryArtistLabel(String rawArtist) {
  final list = splitArtists(rawArtist);
  if (list.isEmpty) return '未知歌手';
  if (list.length == 1) return list.first;
  return '${list.first} 等';
}

String albumYearFromSongs(List<SongEntity> songs) {
  if (songs.isEmpty) return '';
  return '';
}

String pinyinKey(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return '';
  final p = PinyinHelper.getPinyin(
    trimmed,
    separator: '',
    format: PinyinFormat.WITHOUT_TONE,
  );
  return (p.isNotEmpty ? p : trimmed).toLowerCase();
}

List<SongEntity> sortAlbumDetailSongs(
  Iterable<SongEntity> songs, {
  required String sortKey,
  required bool ascending,
}) {
  final sorted = songs.toList();

  int albumOrder(SongEntity a, SongEntity b) {
    final discA = (a.discNumber ?? 1) > 0 ? (a.discNumber ?? 1) : 1;
    final discB = (b.discNumber ?? 1) > 0 ? (b.discNumber ?? 1) : 1;
    var result = discA.compareTo(discB);
    if (result != 0) return result;

    final trackA = (a.trackNumber ?? 0) > 0 ? a.trackNumber! : 1 << 30;
    final trackB = (b.trackNumber ?? 0) > 0 ? b.trackNumber! : 1 << 30;
    result = trackA.compareTo(trackB);
    if (result != 0) return result;
    return pinyinKey(a.title).compareTo(pinyinKey(b.title));
  }

  int compare(SongEntity a, SongEntity b) {
    switch (sortKey) {
      case 'title':
        return pinyinKey(a.title).compareTo(pinyinKey(b.title));
      case 'artist':
        return pinyinKey(a.artist).compareTo(pinyinKey(b.artist));
      case 'duration':
        return (a.durationMs ?? 0).compareTo(b.durationMs ?? 0);
      case 'trackNumber':
      default:
        return albumOrder(a, b);
    }
  }

  sorted.sort((a, b) => ascending ? compare(a, b) : compare(b, a));
  return sorted;
}

class ArtistDetailPage extends StatefulWidget {
  final String artistName;
  final String? artistGuid;

  const ArtistDetailPage({
    super.key,
    required this.artistName,
    this.artistGuid,
  });

  @override
  State<ArtistDetailPage> createState() => _ArtistDetailPageState();
}

class _ArtistDetailPageState extends State<ArtistDetailPage>
    with SignalsMixin, SongMultiSelectMixin {
  final FeiNiuApiClient _apiClient = FeiNiuApiClient.instance;
  final FeiNiuTrackService _trackService = FeiNiuTrackService.instance;

  @override
  List<SongEntity> get multiSelectSongs => _songs.value;

  late String _artistName = widget.artistName;
  late final _loading = createSignal(true);
  late final _songs = createSignal<List<SongEntity>>([]);
  late final _albumsExpanded = createSignal(true);
  late final _albumNames = createSignal<Set<String>>(<String>{});
  late final _albumGroups = createSignal<List<_AlbumGroup>>([]);
  late final _representative = createSignal<SongEntity?>(null);
  late final _isRefreshing = createSignal(false);

  /// 已加载页数：首拉 page:1 size:200 一次拿完，后续填充从已加载页之后起。
  final int _loadedPages = 1;

  /// 歌手自身 coverId：优先按 artistGuid 精确匹配（多歌手时不取错人），
  /// 找不到则回退到第一个含 coverId 的歌手（服务端歌曲常只回填主要歌手）。
  String? _artistCoverIdFor(List<SongEntity> songs, String? artistGuid) {
    for (final s in songs) {
      final byGuid = s.artistCoverIdForGuid(artistGuid);
      if (byGuid != null && byGuid.isNotEmpty) return byGuid;
    }
    for (final s in songs) {
      final byFirst = s.firstArtistCoverId;
      if (byFirst != null && byFirst.isNotEmpty) return byFirst;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 拉取「已加载页之后」的第 [page] 页歌曲（供填充播放使用）。
  Future<List<SongEntity>> _fetchDetailPage(int page) async {
    final pageData = await _apiClient.getArtistTracks(
      artistGUID: widget.artistGuid!,
      page: _loadedPages + page,
      size: 200,
    );
    return pageData.list
        .map((t) => _trackService.trackToSongEntity(t))
        .toList();
  }

  /// 按队列上限循环拉满该歌手的歌曲（供播放/随机按钮使用）。
  Future<List<SongEntity>> _fetchFilledSongs() async {
    final full = List<SongEntity>.from(_songs.value);
    final cap = AppPlaybackQueueSettings.maxQueueLength.value.clamp(10, 1000);
    var page = 1;
    while (full.length < cap) {
      final songs = await _fetchDetailPage(page++);
      if (songs.isEmpty) break;
      full.addAll(songs);
    }
    if (full.length > cap) full.removeRange(cap, full.length);
    return full;
  }

  /// 打开歌手编辑页；保存后刷新名称与歌曲列表（新 coverId 内嵌于重拉的歌曲）。
  Future<void> _openEdit() async {
    final guid = widget.artistGuid;
    if (guid == null) return;
    final result = await Navigator.of(context).push<String>(
      buildAppPageRoute(
        (_) => ArtistAlbumEditPage(
          kind: EntityEditKind.artist,
          guid: guid,
          name: _artistName,
          coverId: _artistCoverIdFor(_songs.value, guid),
        ),
      ),
    );
    if (!mounted || result == null) return;
    setState(() => _artistName = result);
    _load();
  }

  Future<void> _load() async {
    _isRefreshing.value = true;
    _loading.value = true;

    // API path: when artistGuid is provided
    if (widget.artistGuid != null) {
      try {
        final pageData = await _apiClient.getArtistTracks(
          artistGUID: widget.artistGuid!,
          page: 1,
          size: 200,
        );
        if (!mounted) return;
        final songs = pageData.list
            .map((t) => _trackService.trackToSongEntity(t))
            .toList();

        // Group by album for the album section
        final albumMap = <String, List<SongEntity>>{};
        for (final s in songs) {
          final albumName = s.albumDisplayName;
          albumMap.putIfAbsent(albumName, () => []).add(s);
        }
        final albumGroups = albumMap.entries
            .map((e) => _AlbumGroup(name: e.key, songs: e.value))
            .toList()
          ..sort(
            (a, b) => pinyinKey(a.name).compareTo(pinyinKey(b.name)),
          );

        _songs.value = songs;
        _albumNames.value = albumMap.keys.toSet();
        _albumGroups.value = albumGroups;
        _representative.value = songs.isNotEmpty ? songs.first : null;
        _loading.value = false;
        _isRefreshing.value = false;
        return;
      } catch (e) {
        debugPrint('[ArtistDetailPage] API error: $e');
        // Fall through to fallback
      }
    }

    // Fallback: nothing
    if (!mounted) return;
    _loading.value = false;
    _isRefreshing.value = false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppNavigationModeBuilder(
      builder: (context, useBottomNavigation) => AppPageScaffold(
        extendBodyBehindAppBar: false,
        useSafeArea: false,
        showMiniPlayer: !isMultiSelecting,
        appBar: AppTopBar(
          title: isMultiSelecting ? '已选 $selectedCount 首' : _artistName,
          leading: isMultiSelecting
              ? IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: exitMultiSelect,
                )
              : null,
          backgroundColor: Colors.transparent,
          elevation: 0,
          actions: isMultiSelecting
              ? [
                  SelectAllButton(
                    isAllSelected: selectedCount == multiSelectSongs.length,
                    selectedCount: selectedCount,
                    totalCount: multiSelectSongs.length,
                    onTap: toggleSelectAll,
                  ),
                  MultiSelectToggleButton(enabled: true, onTap: exitMultiSelect),
                ]
              : [
                  if (widget.artistGuid != null)
                    ValueListenableBuilder<bool>(
                      valueListenable: LyricCompanionSettings.enabled,
                      builder: (context, enabled, _) {
                        final available = enabled;
                        return IconButton(
                          tooltip: available ? '编辑' : '需先启用服务端增强（设置 → 元数据管理）',
                          icon: Icon(
                            Icons.edit_outlined,
                            color: available
                                ? null
                                : theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.4),
                          ),
                          onPressed: available ? _openEdit : null,
                        );
                      },
                    ),
                  MultiSelectToggleButton(
                    enabled: false,
                    onTap: toggleMultiSelect,
                  ),
                ],
        ),
        body: Watch.builder(
          builder: (context) {
            final theme = Theme.of(context);
            final isDark = theme.brightness == Brightness.dark;
            final player = PlayerService.instance;
            final songs = _songs.value;
            final albumNames = _albumNames.value;
            final albums = _albumGroups.value;
            final representative = _representative.value;

            return Column(
              children: [
                Expanded(
                  child: ListView(
              padding: const EdgeInsets.only(top: 0, bottom: 160),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (representative != null)
                        _ArtistHeaderAvatar(
                          coverId: _artistCoverIdFor(songs, widget.artistGuid),
                          name: _artistName,
                          size: 110,
                          fallback: representative,
                        )
                      else
                        CircleAvatar(
                          radius: 55,
                          child: Text(
                            _artistName.isEmpty
                                ? '?'
                                : _artistName.substring(0, 1),
                            style: const TextStyle(fontSize: 36),
                          ),
                        ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _artistName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '专辑：${albumNames.length}  歌曲：${songs.length}',
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.textTheme.bodySmall?.color
                                    ?.withValues(alpha: 0.7),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  thickness: 0.5,
                  indent: 16,
                  endIndent: 16,
                  color: Colors.grey.withValues(alpha: 0.2),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                  child: Row(
                    children: [
                      Text(
                        '歌曲',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.shuffle),
                        tooltip: '随机播放',
                        visualDensity: VisualDensity.compact,
                        onPressed: songs.isEmpty
                            ? null
                            : () async {
                                // 按队列上限拉满再随机
                                final full = await _fetchFilledSongs();
                                final shuffled = List<SongEntity>.from(full)
                                  ..shuffle();
                                await player.playQueue(shuffled, 0);
                              },
                      ),
                      IconButton(
                        icon: const Icon(Icons.play_arrow),
                        tooltip: '顺序播放',
                        visualDensity: VisualDensity.compact,
                        onPressed: songs.isEmpty
                            ? null
                            : () async {
                                final full = await _fetchFilledSongs();
                                await player.playQueue(full, 0);
                              },
                      ),
                    ],
                  ),
                ),
                ...songs.asMap().entries.map((entry) {
                  final index = entry.key;
                  final song = entry.value;
                  return ValueListenableBuilder<SongEntity?>(
                    valueListenable: player.currentSong,
                    builder: (context, current, _) {
                      final isPlaying = current?.id == song.id;
                      final titleColor = isPlaying
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface;
                      final subtitleColor = isPlaying
                          ? theme.colorScheme.primary
                          : (isDark
                                ? Colors.white70
                                : const Color.fromARGB(255, 100, 100, 100));
                      final selected = isSongSelected(song.id);
                      return AppListTile(
                        leading: isMultiSelecting
                            ? Icon(
                                selected
                                    ? Icons.check_circle
                                    : Icons.circle_outlined,
                                size: 20,
                                color: selected
                                    ? theme.colorScheme.primary
                                    : theme.disabledColor,
                              )
                            : ArtworkWidget(
                                song: song,
                                size: 44,
                                borderRadius: 8,
                                placeholder: Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: theme.cardColor,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    song.title.isEmpty
                                        ? '?'
                                        : song.title.substring(0, 1).toUpperCase(),
                                    style: TextStyle(
                                      color: theme.colorScheme.primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                        title: song.title,
                        subtitle: song.albumDisplayName,
                        titleColor: titleColor,
                        subtitleColor: subtitleColor,
                        contentPadding: const EdgeInsets.only(
                          left: 16,
                          right: 16,
                        ),
                        onTap: () async {
                          if (isMultiSelecting) {
                            toggleSongSelection(song.id);
                            return;
                          }
                          await player.playQueueFilledToLimit(
                            songs,
                            index,
                            fetchMore: _fetchDetailPage,
                          );
                        },
                        onLongPress: isMultiSelecting
                            ? null
                            : () {
                                showModalBottomSheet(
                            context: context,
                            backgroundColor: Colors.transparent,
                            isScrollControlled: true,
                            builder: (_) => SongDetailSheet(
                              song: song,
                              onOpenArtist: (artistName) {
                                Navigator.of(context).push(
                                  buildAppPageRoute(
                                    (_) => ArtistDetailPage(
                                      artistName: artistName,
                                      artistGuid: song.firstArtistGuid,
                                    ),
                                  ),
                                );
                              },
                              onOpenAlbum: (albumName) {
                                Navigator.of(context).push(
                                  buildAppPageRoute(
                                    (_) =>
                                        AlbumDetailPage(albumName: albumName, albumGuid: song.albumGuid),
                                  ),
                                );
                              },
                            ),
                          );
                        },
                      );
                    },
                  );
                }),
                if (albums.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Divider(
                    height: 1,
                    thickness: 0.5,
                    indent: 16,
                    endIndent: 16,
                    color: Colors.grey.withValues(alpha: 0.2),
                  ),
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: Text(
                      '专辑',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    trailing: Icon(
                      _albumsExpanded.value
                          ? Icons.expand_less
                          : Icons.expand_more,
                    ),
                    onTap: () {
                      _albumsExpanded.value = !_albumsExpanded.value;
                    },
                  ),
                  if (_albumsExpanded.value)
                    ...albums.map((album) {
                      final rep = album.songs.isNotEmpty
                          ? album.songs.first
                          : representative;
                      return ListTile(
                        leading: rep == null
                            ? const SizedBox(width: 44, height: 44)
                            : ArtworkWidget(
                                song: rep,
                                size: 44,
                                borderRadius: 10,
                                placeholder: Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: theme.cardColor,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                              ),
                        title: Text(
                          album.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text('${album.songs.length} 首'),
                        onTap: () {
                          Navigator.of(context).push(
                            buildAppPageRoute(
                              (_) => AlbumDetailPage(
                                albumName: album.name,
                                albumGuid: rep?.albumGuid,
                              ),
                            ),
                          );
                        },
                      );
                    }),
                ],
                const SizedBox(height: 24),
              ],
                  ),
                ),
                if (isMultiSelecting) buildMultiSelectBar(),
              ],
            );
          },
        ),
        bottomNavIndex: useBottomNavigation ? 0 : null,
        onBottomNavTap: useBottomNavigation
            ? (index) => navigateToPrimaryDestination(context, index)
            : null,
      ),
    );
  }
}

class AlbumDetailPage extends StatefulWidget {
  final String albumName;
  final String? albumGuid;

  const AlbumDetailPage({
    super.key,
    required this.albumName,
    this.albumGuid,
  });

  @override
  State<AlbumDetailPage> createState() => _AlbumDetailPageState();
}

class _AlbumDetailPageState extends State<AlbumDetailPage>
    with SignalsMixin, SongMultiSelectMixin {
  final FeiNiuApiClient _apiClient = FeiNiuApiClient.instance;
  final FeiNiuTrackService _trackService = FeiNiuTrackService.instance;

  @override
  List<SongEntity> get multiSelectSongs => _songs.value;

  late String _albumName = widget.albumName;
  late final _loading = createSignal(true);
  late final _songs = createSignal<List<SongEntity>>([]);
  late final _showCovers = createSignal(true);
  late final _sortKey = createSignal('trackNumber');
  late final _sortAscending = createSignal(true);

  /// 已加载页数：首拉 page:1 size:200 一次拿完，后续填充从已加载页之后起。
  final int _loadedPages = 1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 拉取「已加载页之后」的第 [page] 页专辑歌曲（供填充播放使用）。
  Future<List<SongEntity>> _fetchDetailPage(int page) async {
    final pageData = await _apiClient.getAlbumTracks(
      albumGUID: widget.albumGuid!,
      page: _loadedPages + page,
      size: 200,
    );
    final tracks = pageData.list;
    return FeiNiuCueService.instance.withCueOffsets(
      tracks.map((t) => _trackService.trackToSongEntity(t)).toList(),
      tracks,
    );
  }

  /// 按队列上限循环拉满该专辑的歌曲（供播放/随机按钮使用）。
  Future<List<SongEntity>> _fetchFilledSongs() async {
    final full = List<SongEntity>.from(_songs.value);
    final cap = AppPlaybackQueueSettings.maxQueueLength.value.clamp(10, 1000);
    var page = 1;
    while (full.length < cap) {
      final songs = await _fetchDetailPage(page++);
      if (songs.isEmpty) break;
      full.addAll(songs);
    }
    if (full.length > cap) full.removeRange(cap, full.length);
    return full;
  }

  /// 打开专辑编辑页；保存后刷新名称与歌曲列表（新 album.coverId 内嵌于重拉的歌曲）。
  Future<void> _openEdit() async {
    final guid = widget.albumGuid;
    if (guid == null) return;
    final result = await Navigator.of(context).push<String>(
      buildAppPageRoute(
        (_) => ArtistAlbumEditPage(
          kind: EntityEditKind.album,
          guid: guid,
          name: _albumName,
          coverId: _songs.value.firstOrNull?.albumCoverId,
        ),
      ),
    );
    if (!mounted || result == null) return;
    setState(() => _albumName = result);
    _load();
  }

  Future<void> _load() async {
    _loading.value = true;

    // API path: when albumGuid is provided
    if (widget.albumGuid != null) {
      try {
        final pageData = await _apiClient.getAlbumTracks(
          albumGUID: widget.albumGuid!,
          page: 1,
          size: 200,
        );
        if (!mounted) return;
        final tracks = pageData.list;
        final songs = FeiNiuCueService.instance.withCueOffsets(
          tracks.map((t) => _trackService.trackToSongEntity(t)).toList(),
          tracks,
        );
        _songs.value = sortAlbumDetailSongs(
          songs,
          sortKey: _sortKey.value,
          ascending: _sortAscending.value,
        );
        _loading.value = false;
        return;
      } catch (e) {
        debugPrint('[AlbumDetailPage] API error: $e');
        // Fall through to fallback
      }
    }

    // Fallback: empty
    if (!mounted) return;
    _songs.value = [];
    _loading.value = false;
  }

  void _sortSongs() {
    _songs.value = sortAlbumDetailSongs(
      _songs.value,
      sortKey: _sortKey.value,
      ascending: _sortAscending.value,
    );
  }

  void _showMoreSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return SortSheet(
          title: '更多',
          options: const [
            SortOption(
              key: 'trackNumber',
              label: '轨道号',
              icon: Icons.format_list_numbered_rounded,
            ),
            SortOption(key: 'title', label: '歌曲名称', icon: Icons.sort_by_alpha),
            SortOption(
              key: 'artist',
              label: '歌手名称',
              icon: Icons.person_outline,
            ),
            SortOption(key: 'duration', label: '歌曲时长', icon: Icons.schedule),
          ],
          currentKey: _sortKey.value,
          ascending: _sortAscending.value,
          onSelectKey: (value) {
            _sortKey.value = value;
            _sortSongs();
          },
          onSelectAscending: (value) {
            _sortAscending.value = value;
            _sortSongs();
          },
          extra: Watch.builder(
            builder: (context) {
              return SwitchListTile(
                title: const Text('显示专辑封面'),
                subtitle: const Text('关闭时显示歌曲序号'),
                secondary: const Icon(Icons.image_outlined),
                value: _showCovers.value,
                onChanged: (value) => _showCovers.value = value,
              );
            },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppNavigationModeBuilder(
      builder: (context, useBottomNavigation) => AppPageScaffold(
        extendBodyBehindAppBar: false,
        useSafeArea: false,
        showMiniPlayer: !isMultiSelecting,
        appBar: AppTopBar(
          title: isMultiSelecting ? '已选 $selectedCount 首' : _albumName,
          leading: isMultiSelecting
              ? IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: exitMultiSelect,
                )
              : null,
          backgroundColor: Colors.transparent,
          elevation: 0,
          actions: isMultiSelecting
              ? [
                  SelectAllButton(
                    isAllSelected: selectedCount == multiSelectSongs.length,
                    selectedCount: selectedCount,
                    totalCount: multiSelectSongs.length,
                    onTap: toggleSelectAll,
                  ),
                  MultiSelectToggleButton(enabled: true, onTap: exitMultiSelect),
                ]
              : [
                  if (widget.albumGuid != null)
                    ValueListenableBuilder<bool>(
                      valueListenable: LyricCompanionSettings.enabled,
                      builder: (context, enabled, _) {
                        final available = enabled;
                        return IconButton(
                          tooltip: available ? '编辑' : '需先启用服务端增强（设置 → 元数据管理）',
                          icon: Icon(
                            Icons.edit_outlined,
                            color: available
                                ? null
                                : theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.4),
                          ),
                          onPressed: available ? _openEdit : null,
                        );
                      },
                    ),
                  IconButton(
                    tooltip: '更多',
                    icon: const Icon(Icons.more_vert_rounded),
                    onPressed: _showMoreSheet,
                  ),
                  MultiSelectToggleButton(
                    enabled: false,
                    onTap: toggleMultiSelect,
                  ),
                  const SizedBox(width: 8),
                ],
        ),
        body: Watch.builder(
          builder: (context) {
            final theme = Theme.of(context);
            final isDark = theme.brightness == Brightness.dark;
            final player = PlayerService.instance;
            final songs = _songs.value;
            final representative = songs.isNotEmpty ? songs.first : null;
            final artistLabel = representative != null
                ? primaryArtistLabel(representative.artistDisplayName)
                : '未知歌手';
            final year = albumYearFromSongs(songs);
            final songCountText = '${songs.length}首';
            final infoText = year.isEmpty
                ? songCountText
                : '$songCountText · $year';

            final Set<String> participatingArtists = {};
            for (final song in songs) {
              participatingArtists.addAll(splitArtists(song.artistDisplayName));
            }
            final sortedArtists = participatingArtists.toList()
              ..sort((a, b) => pinyinKey(a).compareTo(pinyinKey(b)));

            return Column(
              children: [
                Expanded(
                  child: ListView(
              padding: const EdgeInsets.only(top: 12, bottom: 160),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (representative != null)
                        _AlbumHeaderCover(
                          coverId: representative.albumCoverId,
                          size: 110,
                          fallback: representative,
                        )
                      else
                        Container(
                          width: 110,
                          height: 110,
                          decoration: BoxDecoration(
                            color: theme.cardColor,
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _albumName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              artistLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                color: theme.textTheme.bodyMedium?.color
                                    ?.withValues(alpha: 0.85),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              infoText,
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.textTheme.bodySmall?.color
                                    ?.withValues(alpha: 0.7),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  thickness: 0.5,
                  indent: 16,
                  endIndent: 16,
                  color: Colors.grey.withValues(alpha: 0.2),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                  child: Row(
                    children: [
                      Text(
                        '歌曲',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.shuffle),
                        tooltip: '随机播放',
                        visualDensity: VisualDensity.compact,
                        onPressed: songs.isEmpty
                            ? null
                            : () async {
                                // 按队列上限拉满再随机
                                final full = await _fetchFilledSongs();
                                final shuffled = List<SongEntity>.from(full)
                                  ..shuffle();
                                await player.playQueue(shuffled, 0);
                              },
                      ),
                      IconButton(
                        icon: const Icon(Icons.play_arrow),
                        tooltip: '顺序播放',
                        visualDensity: VisualDensity.compact,
                        onPressed: songs.isEmpty
                            ? null
                            : () async {
                                final full = await _fetchFilledSongs();
                                await player.playQueue(full, 0);
                              },
                      ),
                    ],
                  ),
                ),
                ...songs.asMap().entries.map((entry) {
                  final index = entry.key;
                  final song = entry.value;
                  return ValueListenableBuilder<SongEntity?>(
                    valueListenable: player.currentSong,
                    builder: (context, current, _) {
                      final isPlaying = current?.id == song.id;
                      final titleColor = isPlaying
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface;
                      final subtitleColor = isPlaying
                          ? theme.colorScheme.primary
                          : (isDark
                                ? Colors.white70
                                : const Color.fromARGB(255, 100, 100, 100));
                      final selected = isSongSelected(song.id);
                      return AppListTile(
                        leading: isMultiSelecting
                            ? Icon(
                                selected
                                    ? Icons.check_circle
                                    : Icons.circle_outlined,
                                size: 20,
                                color: selected
                                    ? theme.colorScheme.primary
                                    : theme.disabledColor,
                              )
                            : (_showCovers.value
                                ? ArtworkWidget(
                                    song: song,
                                    size: 48,
                                    borderRadius: 6,
                                    placeholder: Container(
                                      width: 48,
                                      height: 48,
                                      decoration: BoxDecoration(
                                        color: theme.cardColor,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                    ),
                                  )
                                : SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: Center(
                                      child: Text(
                                        '${index + 1}',
                                        style: TextStyle(
                                          fontSize: 16,
                                          color: subtitleColor,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  )),
                        title: song.title,
                        subtitle: song.artistDisplayName,
                        titleColor: titleColor,
                        subtitleColor: subtitleColor,
                        contentPadding: const EdgeInsets.only(
                          left: 16,
                          right: 16,
                        ),
                        onTap: () async {
                          if (isMultiSelecting) {
                            toggleSongSelection(song.id);
                            return;
                          }
                          await player.playQueueFilledToLimit(
                            songs,
                            index,
                            fetchMore: _fetchDetailPage,
                          );
                        },
                        onLongPress: isMultiSelecting
                            ? null
                            : () {
                                showModalBottomSheet(
                            context: context,
                            backgroundColor: Colors.transparent,
                            isScrollControlled: true,
                            builder: (_) => SongDetailSheet(
                              song: song,
                              onOpenArtist: (artistName) {
                                Navigator.of(context).push(
                                  buildAppPageRoute(
                                    (_) => ArtistDetailPage(
                                      artistName: artistName,
                                      artistGuid: song.firstArtistGuid,
                                    ),
                                  ),
                                );
                              },
                              onOpenAlbum: (albumName) {
                                Navigator.of(context).push(
                                  buildAppPageRoute(
                                    (_) =>
                                        AlbumDetailPage(albumName: albumName, albumGuid: song.albumGuid),
                                  ),
                                );
                              },
                            ),
                          );
                        },
                      );
                    },
                  );
                }),
                if (sortedArtists.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Divider(
                    height: 1,
                    thickness: 0.5,
                    indent: 16,
                    endIndent: 16,
                    color: Colors.grey.withValues(alpha: 0.2),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      '参与创作的歌手',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  ...sortedArtists.map((artist) {
                    final artistSong = songs.firstWhere(
                      (s) => splitArtists(s.artistDisplayName).contains(artist),
                      orElse: () => songs.first,
                    );
                    // 歌手自身图片：按歌手名精确匹配 coverId（多歌手时不取错人）；
                    // 找不到则回退到该歌手参与的第一首歌封面。
                    final artistCoverId = artistSong.artistCoverIdForName(artist) ??
                        artistSong.firstArtistCoverId;
                    // 歌手 guid：按名从歌曲中精确匹配，供打开歌手详情页拉取歌曲
                    final artistGuid = artistSong.artistGuidForName(artist);
                    final initial = artist.isNotEmpty ? artist[0] : '?';
                    return ListTile(
                      leading: _ArtistCoverTile(
                        coverId: artistCoverId,
                        size: 44,
                        fallback: artistSong,
                        placeholder: CircleAvatar(
                          radius: 22,
                          child: Text(initial),
                        ),
                      ),
                      title: Text(artist),
                      onTap: () {
                        Navigator.of(context).push(
                          buildAppPageRoute(
                            (_) => ArtistDetailPage(
                              artistName: artist,
                              artistGuid: artistGuid,
                            ),
                          ),
                        );
                      },
                    );
                  }),
                ],
                const SizedBox(height: 24),
              ],
                  ),
                ),
                if (isMultiSelecting) buildMultiSelectBar(),
              ],
            );
          },
        ),
        bottomNavIndex: useBottomNavigation ? 0 : null,
        onBottomNavTap: useBottomNavigation
            ? (index) => navigateToPrimaryDestination(context, index)
            : null,
      ),
    );
  }
}

class _AlbumGroup {
  final String name;
  final List<SongEntity> songs;

  const _AlbumGroup({required this.name, required this.songs});
}

/// 歌手头像：有歌手自身 coverId 时显示歌手图片，否则回退到代表性歌曲封面，
/// 再不行显示首字母占位。头像为圆形（对齐歌手列表的 _ArtistAvatar）。
/// 专辑封面头部：有专辑自身 coverId 时显示专辑图片，否则回退到代表性歌曲封面。
/// 圆角矩形（对齐专辑列表封面样式）。
class _AlbumHeaderCover extends StatelessWidget {
  final String? coverId;
  final double size;
  final SongEntity fallback;

  const _AlbumHeaderCover({
    required this.coverId,
    required this.size,
    required this.fallback,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderRadius = BorderRadius.circular(12);

    // 专辑自身图片
    if (coverId != null && coverId!.isNotEmpty) {
      final coverUrl = FeiNiuApiClient.instance.coverUrl(
        coverId!,
        size: FeiNiuApiClient.coverRequestSize,
      );
      return ClipRRect(
        borderRadius: borderRadius,
        child: CachedNetworkImage(
          imageUrl: coverUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          httpHeaders: FeiNiuApiClient.imageAuthHeaders(),
          errorWidget: (_, _, _) => Container(
            width: size,
            height: size,
            color: theme.cardColor,
          ),
          placeholder: (_, _) => Container(
            width: size,
            height: size,
            color: theme.cardColor,
          ),
        ),
      );
    }

    // 无专辑图片：用代表性歌曲封面（原 ArtworkWidget 行为）
    return ArtworkWidget(
      song: fallback,
      size: size,
      borderRadius: 12,
      placeholder: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: borderRadius,
        ),
      ),
    );
  }
}

class _ArtistHeaderAvatar extends StatelessWidget {
  final String? coverId;
  final String name;
  final double size;
  final SongEntity fallback;

  const _ArtistHeaderAvatar({
    required this.coverId,
    required this.name,
    required this.size,
    required this.fallback,
  });

  @override
  Widget build(BuildContext context) {
    final radius = size / 2;
    final initial = name.isNotEmpty ? name.characters.first : '?';

    // 歌手自身图片
    if (coverId != null && coverId!.isNotEmpty) {
      final coverUrl = FeiNiuApiClient.instance.coverUrl(
        coverId!,
        size: FeiNiuApiClient.coverRequestSize,
      );
      return CircleAvatar(
        radius: radius,
        backgroundImage: CachedNetworkImageProvider(
          coverUrl,
          headers: FeiNiuApiClient.imageAuthHeaders(),
        ),
      );
    }

    // 无歌手图片：用代表性歌曲封面（原 ArtworkWidget 行为），圆角处理
    return ClipOval(
      child: ArtworkWidget(
        song: fallback,
        size: size,
        borderRadius: radius,
        placeholder: CircleAvatar(
          radius: radius,
          child: Text(initial),
        ),
      ),
    );
  }
}

/// 歌手头像条目：有歌手自身 coverId 时显示歌手图片，否则回退到歌曲封面，
/// 再不行显示占位图。圆形裁剪（对齐歌手列表的 _ArtistAvatar）。
class _ArtistCoverTile extends StatelessWidget {
  final String? coverId;
  final double size;
  final SongEntity fallback;
  final Widget placeholder;

  const _ArtistCoverTile({
    required this.coverId,
    required this.size,
    required this.fallback,
    required this.placeholder,
  });

  @override
  Widget build(BuildContext context) {
    final radius = size / 2;

    // 歌手自身图片（按 DPR 请求清晰图，含 auth 头）
    if (coverId != null && coverId!.isNotEmpty) {
      final coverUrl = FeiNiuApiClient.instance.coverUrl(
        coverId!,
        size: FeiNiuApiClient.coverRequestSize,
      );
      return ClipOval(
        child: SizedBox(
          width: size,
          height: size,
          child: CachedNetworkImage(
            imageUrl: coverUrl,
            httpHeaders: FeiNiuApiClient.imageAuthHeaders(),
            fit: BoxFit.cover,
            placeholder: (context, url) => placeholder,
            errorWidget: (context, url, error) => placeholder,
          ),
        ),
      );
    }

    // 无歌手图片：回退到该歌手参与的第一首歌封面
    return ClipOval(
      child: ArtworkWidget(
        song: fallback,
        size: size,
        borderRadius: radius,
        placeholder: placeholder,
      ),
    );
  }
}
