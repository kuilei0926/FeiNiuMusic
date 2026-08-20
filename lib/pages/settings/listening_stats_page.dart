import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/router/app_page_route.dart';
import '../../app/router/app_router.dart';
import '../../app/services/db/dao/song_dao.dart';
import '../../app/services/feiniu/api_client.dart';
import '../../app/services/player_service.dart';
import '../../app/services/stats_service.dart';
import '../../app/state/song_state.dart';
import '../../components/common/artwork_widget.dart';
import '../../components/common/setting_widgets.dart';
import '../../components/layout/base/app_page_scaffold.dart';
import '../../components/layout/base/app_top_bar.dart';
import '../../components/list/media_list_tile.dart';
import '../library/library_detail_pages.dart';
import '../songs/song_detail_sheet.dart';

enum _TrendMode { week, month }

enum _LeaderTab { songs, artists, albums }

class ListeningStatsPage extends StatefulWidget {
  const ListeningStatsPage({super.key});

  @override
  State<ListeningStatsPage> createState() => _ListeningStatsPageState();
}

class _ListeningStatsPageState extends State<ListeningStatsPage> {
  final StatsService _statsService = StatsService.instance;
  final SongDao _songDao = SongDao.instance;
  final PlayerService _player = PlayerService.instance;

  bool _loading = true;
  _TrendMode _trendMode = _TrendMode.week;
  _LeaderTab _leaderTab = _LeaderTab.songs;

  StatsTotals _totalStats = const StatsTotals(listenMs: 0, playCount: 0);
  final Map<String, DayListeningStat> _dayMap = {};
  int _activeDaysThisMonth = 0;
  List<_SongStatRow> _topSongs = [];
  List<_AggRow> _topArtists = [];
  List<_AggRow> _topAlbums = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final now = DateTime.now();
    final prev = DateTime(now.year, now.month - 1);

    final totals = await _statsService.fetchTotalStats();
    final thisMonth = await _statsService.fetchMonthStats(
      year: now.year,
      month: now.month,
    );
    final lastMonth = await _statsService.fetchMonthStats(
      year: prev.year,
      month: prev.month,
    );

    final dayMap = <String, DayListeningStat>{};
    for (final s in [...lastMonth, ...thisMonth]) {
      dayMap[s.dayKey] = s;
    }
    final activeDays = thisMonth.where((s) => s.listenMs > 0).length;

    // 歌手名 → 真实歌手头像 coverId（来自服务器 /artist/list-all）。
    // 歌手头像不能用歌曲封面（那是专辑图），必须用歌手自己的头像。
    final artistCovers = await _fetchArtistCovers();

    // Pull a wider set of top songs to aggregate artists/albums from.
    final topStats = await _statsService.fetchTopSongs(limit: 60);
    final songs = await _songDao.fetchByIds(
      topStats.map((e) => e.songId).toList(),
    );
    final songMap = {for (final s in songs) s.id: s};
    final topSongs = <_SongStatRow>[];
    final artistAcc = <String, _AggAccum>{};
    final albumAcc = <String, _AggAccum>{};
    for (final stat in topStats) {
      final song = songMap[stat.songId];
      if (song == null) continue;
      topSongs.add(_SongStatRow(song: song, stat: stat));
      final artist = song.artistDisplayName.trim().isEmpty ? '未知歌手' : song.artistDisplayName.trim();
      (artistAcc[artist] ??= _AggAccum(artist, song)).add(stat);
      final albumName = song.albumDisplayName.trim();
      final album = albumName.isEmpty ? '未知专辑' : albumName;
      (albumAcc[album] ??= _AggAccum(album, song)).add(stat);
    }
    List<_AggRow> rank(
      Map<String, _AggAccum> acc, {
      Map<String, String>? covers,
    }) {
      final list = acc.values.map((e) => e.toRow(coverId: covers?[e.name])).toList()
        ..sort((a, b) {
          final c = b.playCount.compareTo(a.playCount);
          return c != 0 ? c : b.listenMs.compareTo(a.listenMs);
        });
      return list.take(10).toList();
    }

    if (!mounted) return;
    setState(() {
      _totalStats = totals;
      _dayMap
        ..clear()
        ..addAll(dayMap);
      _activeDaysThisMonth = activeDays;
      _topSongs = topSongs.take(20).toList();
      _topArtists = rank(artistAcc, covers: artistCovers);
      _topAlbums = rank(albumAcc);
      _loading = false;
    });
  }

  /// 拉取歌手头像映射：歌手名 → coverId。
  ///
  /// 通过 [FeiNiuApiClient.getArtistListAll] 拉取服务器歌手列表拿到各歌手
  /// 真实 coverId。失败返回空映射（歌手头像用歌曲封面兜底）。
  Future<Map<String, String>> _fetchArtistCovers() async {
    final result = <String, String>{};
    try {
      final artists = await FeiNiuApiClient.instance.getArtistListAll();
      for (final a in artists) {
        final cid = a.coverId;
        if (cid != null && cid.isNotEmpty && a.name.isNotEmpty) {
          result[a.name] = cid;
        }
      }
    } catch (_) {
      // 拉取失败不阻塞统计页
    }
    return result;
  }

  // ---- formatting helpers ----
  String _formatDuration(int ms) {
    if (ms <= 0) return '0 分钟';
    final totalMinutes = (ms / 60000).floor();
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    if (hours <= 0) return '$minutes 分钟';
    return '$hours 小时 $minutes 分';
  }

  String _formatShortDuration(int ms) {
    if (ms <= 0) return '0:00';
    final totalSeconds = (ms / 1000).round();
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) return '$hours:${minutes.toString().padLeft(2, '0')}';
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  String _durationText(int? durationMs) {
    if (durationMs == null || durationMs <= 0) return '--:--';
    final totalSeconds = (durationMs / 1000).floor();
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  String _dayKey(DateTime t) {
    final y = t.year.toString().padLeft(4, '0');
    final m = t.month.toString().padLeft(2, '0');
    final d = t.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  List<_TrendBar> _buildTrendBars() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    const weekdayLabels = ['一', '二', '三', '四', '五', '六', '日'];
    if (_trendMode == _TrendMode.week) {
      return List.generate(7, (i) {
        final date = today.subtract(Duration(days: 6 - i));
        final ms = _dayMap[_dayKey(date)]?.listenMs ?? 0;
        return _TrendBar(
          value: ms,
          label: weekdayLabels[date.weekday - 1],
          fullLabel: '${date.month}月${date.day}日 周${weekdayLabels[date.weekday - 1]}',
          highlight: date == today,
          showLabel: true,
        );
      });
    }
    final days = DateUtils.getDaysInMonth(now.year, now.month);
    return List.generate(days, (i) {
      final day = i + 1;
      final date = DateTime(now.year, now.month, day);
      final ms = _dayMap[_dayKey(date)]?.listenMs ?? 0;
      final showLabel = day == 1 || day % 5 == 0 || day == today.day;
      return _TrendBar(
        value: ms,
        label: showLabel ? '$day' : '',
        fullLabel: '${now.month}月$day日',
        highlight: date == today,
        showLabel: showLabel,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding =
        AppPageScaffold.scrollableBottomPadding(context, showMiniPlayer: false);
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const AppTopBar(
        title: '听歌统计',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      showMiniPlayer: false,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
          children: [
            // 年度报告入口：仅开发版（debug）显示，正式版隐藏（先发布埋点收集数据）。
            // Windows 桌面端无 WebView 实现，报告页不可用，一律隐藏。
            if (kDebugMode && !kIsWeb && defaultTargetPlatform != TargetPlatform.windows) ...[
              _buildReportEntry(context),
              const SizedBox(height: 16),
            ],
            _buildOverview(context),
            const SizedBox(height: 16),
            _buildTrend(context),
            const SizedBox(height: 16),
            _buildLeaderboard(context),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildReportEntry(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: () =>
            Navigator.pushNamed(context, AppRoutes.listeningReport),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Theme.of(context).colorScheme.primary,
                      Theme.of(context).colorScheme.tertiary,
                    ],
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.auto_awesome_rounded,
                  color: Theme.of(context).colorScheme.onPrimary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '听歌报告',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '生成你的年度音乐报告',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOverview(BuildContext context) {
    return AppSettingSection(
      title: '概览',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
          child: Row(
            children: [
              _OverviewMetric(
                icon: Icons.schedule_rounded,
                value: _formatDuration(_totalStats.listenMs),
                label: '累计收听',
              ),
              _OverviewDivider(),
              _OverviewMetric(
                icon: Icons.play_circle_outline_rounded,
                value: '${_totalStats.playCount}',
                label: '播放次数',
              ),
              _OverviewDivider(),
              _OverviewMetric(
                icon: Icons.calendar_month_rounded,
                value: '$_activeDaysThisMonth',
                label: '本月活跃(天)',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTrend(BuildContext context) {
    final bars = _buildTrendBars();
    return AppSettingSection(
      title: '听歌趋势',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: _SegmentedToggle(
            options: const ['最近7天', '本月'],
            selectedIndex: _trendMode == _TrendMode.week ? 0 : 1,
            onChanged: (i) => setState(
              () => _trendMode = i == 0 ? _TrendMode.week : _TrendMode.month,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 14),
          child: _TrendBarChart(
            bars: bars,
            tooltip: (ms) => _formatDuration(ms),
          ),
        ),
      ],
    );
  }

  Widget _buildLeaderboard(BuildContext context) {
    return AppSettingSection(
      title: '排行榜',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: _SegmentedToggle(
            options: const ['歌曲', '歌手', '专辑'],
            selectedIndex: _leaderTab.index,
            onChanged: (i) =>
                setState(() => _leaderTab = _LeaderTab.values[i]),
          ),
        ),
        switch (_leaderTab) {
          _LeaderTab.songs => _buildTopSongs(context),
          _LeaderTab.artists => _buildAggList(context, _topArtists, isAlbum: false),
          _LeaderTab.albums => _buildAggList(context, _topAlbums, isAlbum: true),
        },
      ],
    );
  }

  Widget _buildTopSongs(BuildContext context) {
    if (_topSongs.isEmpty) return const _EmptyHint(text: '暂无播放数据');
    final queue = _topSongs.map((e) => e.song).toList();
    return ValueListenableBuilder<SongEntity?>(
      valueListenable: _player.currentSong,
      builder: (context, current, _) {
        return Column(
          children: _topSongs.asMap().entries.map((entry) {
            final i = entry.key;
            final row = entry.value;
            final song = row.song;
            return MediaListTile(
              leading: _RankedArtwork(
                rank: i + 1,
                child: ArtworkWidget(
                  song: song,
                  size: 44,
                  borderRadius: 8,
                  placeholder: _SquarePlaceholder(label: song.title),
                ),
              ),
              title: song.title,
              subtitle:
                  '${song.artistDisplayName} · ${_durationText(song.durationMs)}',
              selected: false,
              multiSelect: false,
              isHighlighted: current?.id == song.id,
              trailing: _CountTrailing(
                count: row.stat.playCount,
                time: _formatShortDuration(row.stat.listenMs),
              ),
              onTap: () {
                if (queue.isEmpty) return;
                _player.playQueue(queue, i);
              },
              onLongPress: () {
                showModalBottomSheet<void>(
                  context: context,
                  backgroundColor: Colors.transparent,
                  isScrollControlled: true,
                  builder: (_) => SongDetailSheet(song: song),
                );
              },
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildAggList(
    BuildContext context,
    List<_AggRow> rows, {
    required bool isAlbum,
  }) {
    if (rows.isEmpty) return const _EmptyHint(text: '暂无播放数据');
    return Column(
      children: rows.asMap().entries.map((entry) {
        final i = entry.key;
        final row = entry.value;
        return MediaListTile(
          leading: _RankedArtwork(
            rank: i + 1,
            child: isAlbum
                ? ArtworkWidget(
                    song: row.sample,
                    size: 44,
                    borderRadius: 8,
                    placeholder: _SquarePlaceholder(label: row.name),
                  )
                // 歌手行：优先用服务器返回的真实歌手头像（coverId），
                // 找不到才回退到歌曲封面（与歌手详情页一致）。
                : _ArtistCoverTile(
                    coverId: row.coverId,
                    size: 44,
                    fallback: row.sample,
                    placeholder: _SquarePlaceholder(label: row.name),
                  ),
          ),
          title: row.name,
          subtitle: '${row.playCount} 次播放',
          selected: false,
          multiSelect: false,
          isHighlighted: false,
          trailing: _CountTrailing(
            count: row.playCount,
            time: _formatShortDuration(row.listenMs),
          ),
          onTap: () {
            Navigator.of(context).push(
              buildAppPageRoute<void>(
                (_) => isAlbum
                    ? AlbumDetailPage(
                        albumName: row.name,
                        albumGuid: row.sample.albumGuid,
                      )
                    : ArtistDetailPage(
                        artistName: row.name,
                        artistGuid: row.sample.firstArtistGuid,
                      ),
              ),
            );
          },
        );
      }).toList(),
    );
  }
}

// ---- small presentational widgets ----

class _OverviewMetric extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  const _OverviewMetric({
    required this.icon,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        children: [
          Icon(icon, color: scheme.primary, size: 22),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: scheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }
}

class _OverviewDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 40,
      color: Theme.of(context).dividerColor.withValues(alpha: 0.25),
    );
  }
}

class _SegmentedToggle extends StatelessWidget {
  final List<String> options;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  const _SegmentedToggle({
    required this.options,
    required this.selectedIndex,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: List.generate(options.length, (i) {
          final selected = i == selectedIndex;
          return Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onChanged(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(vertical: 7),
                decoration: BoxDecoration(
                  color: selected ? scheme.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  options[i],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: selected
                        ? scheme.onPrimary
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _TrendBar {
  final int value;
  final String label;
  final String fullLabel;
  final bool highlight;
  final bool showLabel;

  const _TrendBar({
    required this.value,
    required this.label,
    required this.fullLabel,
    required this.highlight,
    required this.showLabel,
  });
}

class _TrendBarChart extends StatefulWidget {
  final List<_TrendBar> bars;
  final String Function(int ms) tooltip;

  const _TrendBarChart({required this.bars, required this.tooltip});

  @override
  State<_TrendBarChart> createState() => _TrendBarChartState();
}

class _TrendBarChartState extends State<_TrendBarChart> {
  int? _selected;

  @override
  void didUpdateWidget(_TrendBarChart old) {
    super.didUpdateWidget(old);
    if (old.bars.length != widget.bars.length) {
      _selected = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bars = widget.bars;
    final maxVal = bars.fold<int>(0, (m, b) => b.value > m ? b.value : m);
    final hasData = maxVal > 0;
    const chartHeight = 120.0;

    final todayIndex = bars.indexWhere((b) => b.highlight);
    final focusIndex = _selected ?? (todayIndex >= 0 ? todayIndex : null);
    final focus = focusIndex != null ? bars[focusIndex] : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: focus != null
              ? Row(
                  children: [
                    Text(
                      focus.fullLabel,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurface),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      widget.tooltip(focus.value),
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: scheme.primary),
                    ),
                  ],
                )
              : Text(
                  hasData ? '点击柱状查看当天时长' : '还没有这段时间的收听记录',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant.withValues(alpha: 0.7)),
                ),
        ),
        SizedBox(
          height: chartHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(bars.length, (i) {
              final b = bars[i];
              final frac = hasData ? b.value / maxVal : 0.0;
              final barHeight = 4 + frac * (chartHeight - 8);
              final isFocused = i == focusIndex;
              return Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _selected = i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Container(
                          height: barHeight,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            border: isFocused ? Border.all(color: scheme.primary, width: 1.5) : null,
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: (b.highlight || isFocused)
                                  ? [scheme.primary, scheme.primary.withValues(alpha: 0.7)]
                                  : [scheme.primary.withValues(alpha: 0.5), scheme.primary.withValues(alpha: 0.25)],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: bars.map((b) {
            return Expanded(
              child: Text(
                b.showLabel ? b.label : '',
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  fontSize: 10,
                  color: b.highlight ? scheme.primary : scheme.onSurfaceVariant.withValues(alpha: 0.7),
                  fontWeight: b.highlight ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

class _RankedArtwork extends StatelessWidget {
  final int rank;
  final Widget child;

  const _RankedArtwork({required this.rank, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final topThree = rank <= 3;
    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          child,
          Positioned(
            left: -6,
            top: -6,
            child: Container(
              width: 18,
              height: 18,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: topThree ? scheme.primary : scheme.surfaceContainerHighest,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.surface, width: 1.5),
              ),
              child: Text(
                '$rank',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: topThree ? scheme.onPrimary : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CountTrailing extends StatelessWidget {
  final int count;
  final String time;

  const _CountTrailing({required this.count, required this.time});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text('$count 次', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: scheme.primary)),
        const SizedBox(height: 2),
        Text(time, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant.withValues(alpha: 0.7))),
      ],
    );
  }
}

class _SquarePlaceholder extends StatelessWidget {
  final String label;

  const _SquarePlaceholder({required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Text(
        label.trim().isEmpty ? '?' : label.trim().substring(0, 1).toUpperCase(),
        style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// 歌手行头像：优先用歌手自身图片（artist JSON 里的 coverId），
/// 找不到才回退到该歌手参与的第一首歌封面（与歌手详情页同款逻辑）。
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

class _EmptyHint extends StatelessWidget {
  final String text;

  const _EmptyHint({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7))),
      ),
    );
  }
}

class _SongStatRow {
  final SongEntity song;
  final SongListeningStat stat;

  const _SongStatRow({required this.song, required this.stat});
}

class _AggRow {
  final String name;
  final int playCount;
  final int listenMs;
  final SongEntity sample;

  /// 真实歌手头像 coverId（来自服务器 /artist/list-all）。
  final String? coverId;

  const _AggRow({
    required this.name,
    required this.playCount,
    required this.listenMs,
    required this.sample,
    this.coverId,
  });
}

class _AggAccum {
  final String name;
  final SongEntity sample;
  int playCount = 0;
  int listenMs = 0;

  _AggAccum(this.name, this.sample);

  void add(SongListeningStat stat) {
    playCount += stat.playCount;
    listenMs += stat.listenMs;
  }

  _AggRow toRow({String? coverId}) => _AggRow(
    name: name,
    playCount: playCount,
    listenMs: listenMs,
    sample: sample,
    coverId: coverId,
  );
}
