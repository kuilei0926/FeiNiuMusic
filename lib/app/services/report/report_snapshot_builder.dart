import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../state/song_state.dart';
import '../cover_local_cache.dart';
import '../db/dao/song_dao.dart';
import '../db/db_constants.dart';
import '../db/db_helper.dart';
import '../feiniu/api_client.dart';
import '../feiniu/auth_service.dart';
import '../stats_service.dart';

/// 听歌报告数据生成：把 App 内聚合统计 + 报告埋点事件，组装成与
/// `data.json`（QQ音乐年度报告镜像）同构的 payload。
///
/// 输出结构（外层 req_0.data）：
/// ```
/// { 'page0'..'page19', 'encUin', 'nick', 'avatar', 'invalidList',
///   'isMusician', 'shareStatus', 'deviceList', 'vipType' }
/// ```
/// 其中 `invalidList` 标记哪些页因数据不足而跳过（0=展示，1=跳过）。
///
/// 已知无法提供的数据（作曲/作词/歌词关键词/BPM）对应页面直接置 `invalid:1`；
/// 曲风 genre 尽力通过 `FeiNiuApiClient.getGenreList()` + `getGenreTracks()` 反查，
/// 失败也置 `invalid:1`，不阻塞整个报告。
class ReportSnapshotBuilder {
  ReportSnapshotBuilder({FeiNiuApiClient? apiClient})
      : _apiClient = apiClient;

  final FeiNiuApiClient? _apiClient;

  static const int _pageCount = 20;

  /// 构建完整报告 payload（耗时聚合，建议在 isolate 中调用）。
  Future<Map<String, dynamic>> build() async {
    final events = await _fetchReportEvents();
    final songAgg = await _fetchSongAggregates();
    final totals = await StatsService.instance.fetchTotalStats();
    final monthStats = await _fetchMonthTotals();
    final songsById = await _fetchSongMetaByIds(songAgg.keys.toSet());
    final activeDayCount = await _fetchActiveDayCount();
    // 歌手头像：从服务器拉取歌手列表，建立 歌手名 → coverId 映射
    final artistCovers = await _fetchArtistCovers();

    final builder = _PageBuilder(
      events,
      songAgg,
      monthStats,
      songsById,
      totals,
      activeDayCount,
      _coverUrlBuilder(),
      artistCovers,
    );

    final pages = <String, dynamic>{
      'page0': builder.page0(),
      'page1': builder.page1(),
      'page2': builder.page2(),
      'page3': builder.page3(),
      'page4': builder.page4(),
      'page5': builder.page5(),
      'page6': builder.page6(), // 作曲者：无数据源，用年度歌手替代
      'page7': builder.page7(), // 作词者：无数据源，用年度歌手替代
      'page8': builder.page8(),
      'page9': builder.page9(),
      'page10': builder.page10(),
      'page11': builder.page11(),
      'page12': await _buildPage12(builder), // 歌词关键词：用 top 歌曲歌名替代，尽力拉歌词
      'page13': await _buildPage13(builder), // 曲风：尽力，失败跳过
      'page14': builder.page14(),
      'page15': builder.page15(),
      'page16': builder.page16(),
      'page17': _invalidPage(), // 车载：暂无标记
      'page18': builder.page18(),
      'page19': builder.page19(),
    };

    final invalidList = [
      for (var i = 0; i < _pageCount; i++)
        (pages['page$i'] as Map<String, dynamic>)['invalid'] == 1 ? 1 : 0,
    ];

    final req0Data = <String, dynamic>{
      ...pages,
      'encUin': '',
      'nick': _userNick,
      'avatar': '',
      'isMusician': 0,
      'shareStatus': 0,
      'deviceList': ['本地'],
      'vipType': 0,
      'invalidList': invalidList,
      // 报告年份（App 当前年份），网页端据此把硬编码的 2025 替换成动态值
      'year': DateTime.now().year,
    };

    // 封面图内嵌：把页面用到的 coverId 图片下载成 base64 data URL，
    // 供网页端绕过跨域/CORS/鉴权直接显示。
    req0Data['images'] = await _buildImagesMap(pages);

    return _wrapEnvelope(req0Data);
  }

  /// 收集页面里所有 pic URL 的 coverId，下载并转 base64 data URL。
  ///
  /// 复用 [CoverLocalCache.downloadToLocal]（带鉴权头 + 磁盘缓存），
  /// 返回 `{coverId: 'data:image/jpeg;base64,...'}`。
  ///
  /// payload 经 JS 注入页面（不占 URL hash），因此内嵌 base64 不再受
  /// WebView 2MB URL 上限约束，可全量内嵌保证封面显示。
  Future<Map<String, String>> _buildImagesMap(Map<String, dynamic> pages) async {
    final coverIds = <String>{};

    // 收集所有 pic 字段的 URL 里的 coverId
    void collectCovers(Object? node) {
      if (node is Map) {
        final pic = node['pic'];
        if (pic is String && pic.isNotEmpty) {
          final m = RegExp(r'coverId=([^&]+)').firstMatch(pic);
          if (m != null) coverIds.add(m.group(1)!);
        }
        for (final v in node.values) {
          collectCovers(v);
        }
      } else if (node is List) {
        for (final v in node) {
          collectCovers(v);
        }
      }
    }

    collectCovers(pages);

    final result = <String, String>{};
    final api = _apiClient ?? FeiNiuApiClient.instance;
    debugPrint('[Report] images: 收集到 ${coverIds.length} 个 coverId: ${coverIds.take(8).toList()}');
    for (final cid in coverIds) {
      try {
        final dataUrl = await _downloadCoverDataUrl(api, cid);
        if (dataUrl == null) {
          debugPrint('[Report] images: $cid 下载失败（跳过）');
          continue;
        }
        result[cid] = dataUrl;
        debugPrint('[Report] images: $cid 下载成功 ${dataUrl.length} 字符');
      } catch (_) {
        // 单张下载失败跳过，网页端用占位图
        debugPrint('[Report] images: $cid 下载异常（跳过）');
      }
    }
    debugPrint('[Report] images: 最终 ${result.length} 张内嵌图片');
    return result;
  }

  /// 下载单张封面并转 data URL。
  ///
  /// 用 canonical 尺寸（[FeiNiuApiClient.coverRequestSize]，与 payload 里 pic 一致，
  /// 保证清晰度）经 [FeiNiuApiClient.fetchBytes] 带鉴权头下载。
  Future<String?> _downloadCoverDataUrl(
    FeiNiuApiClient api,
    String coverId,
  ) async {
    try {
      final url = api.coverUrl(coverId, size: FeiNiuApiClient.coverRequestSize);
      final bytes = await api.fetchBytes(url);
      if (bytes == null || bytes.isEmpty) return null;
      return 'data:image/jpeg;base64,${base64Encode(bytes)}';
    } catch (_) {
      // 回退：走 CoverLocalCache（120px，可能模糊但不空白）
      try {
        final localPath = await CoverLocalCache.downloadToLocal(coverId);
        if (localPath == null) return null;
        final bytes = await File(localPath).readAsBytes();
        return 'data:image/jpeg;base64,${base64Encode(bytes)}';
      } catch (_) {
        return null;
      }
    }
  }

  /// 组装与 `data.json` 同构的完整响应信封（含 req_0 / req_1）。
  ///
  /// 网页端 bundle 的响应解析器会取 `res.req_0.data`（页面）与 `res.req_1.data.conf`
  /// （配置），两个请求（GetUserData2025 + GetPanshiConf）都必须成功
  /// （`success:[true,true]`），因此这里同时提供两者。
  Map<String, dynamic> _wrapEnvelope(Map<String, dynamic> req0Data) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    // 中性化的 req_1 配置（后续品牌改造时替换标题/横幅等）。
    // staticControl 保留兼容结构，但 deviceScore 设为 0：en() 里
    // `Number(DeviceScore/x) <= Number(0)` 恒为 false，任何设备都不会触发
    // lowDevice 降级（否则 App WebView 的 UA 带低 DeviceScore 会被强制降到简洁版）。
    final neutralConf = <String, dynamic>{
      'staticControl': {
        'android': {'deviceScore': '0'},
        'ios': {'deviceScore': '0'},
      },
      'isMqqJump': false,
      'title': '音乐年度报告',
      'desc': '听见自己，收集你的音乐碎片',
      'img': '',
      'qrcode': '',
      'link': '',
      'redBookTag': '',
      'bannerList': null,
    };
    return {
      'code': 0,
      'ts': nowMs,
      'start_ts': nowMs,
      'traceid': 'feiniu-local',
      'req_0': {'code': 0, 'data': req0Data},
      'req_1': {
        'code': 0,
        'data': {'code': 0, 'conf': jsonEncode(neutralConf)},
      },
    };
  }

  Map<String, dynamic> _invalidPage() => {
        'invalid': 1,
      };

  /// 用户昵称：优先取登录账号昵称，未登录/为空时回退「音乐人」。
  String get _userNick {
    final nick = AuthService.instance.username.value;
    if (nick != null && nick.trim().isNotEmpty) return nick.trim();
    return '音乐人';
  }

  /// 从主库读取 report_events 全量（整机共享）。
  Future<List<Map<String, dynamic>>> _fetchReportEvents() async {
    final db = await DbHelper.instance.database;
    final rows = await db.query(
      DbConstants.tableReportEvents,
      orderBy: 'sessionEndMs ASC',
    );
    return rows;
  }

  /// 从主库 song_stats 读取每首歌聚合（playCount/listenMs）。
  Future<Map<String, Map<String, int>>> _fetchSongAggregates() async {
    final db = await DbHelper.instance.database;
    final rows = await db.query('song_stats');
    return {
      for (final r in rows)
        (r['songId'] as String? ?? '').toString(): {
          'playCount': r['playCount'] is int
              ? r['playCount'] as int
              : int.tryParse(r['playCount']?.toString() ?? '') ?? 0,
          'listenMs': r['listenMs'] is int
              ? r['listenMs'] as int
              : int.tryParse(r['listenMs']?.toString() ?? '') ?? 0,
        },
    };
  }

  /// 按月聚合 listening_days（用于 page2 月度时长）。
  Future<Map<String, int>> _fetchMonthTotals() async {
    final db = await DbHelper.instance.database;
    final rows = await db.rawQuery(
      'SELECT dayKey, listenMs FROM listening_days',
    );
    final result = <String, int>{};
    for (final r in rows) {
      final day = (r['dayKey'] as String? ?? '');
      final ms = r['listenMs'] is int
          ? r['listenMs'] as int
          : int.tryParse(r['listenMs']?.toString() ?? '') ?? 0;
      if (day.length < 7) continue;
      final month = day.substring(0, 7); // 'yyyy-MM'
      result[month] = (result[month] ?? 0) + ms;
    }
    return result;
  }

  /// 用歌曲 id 批量回表查元数据（title/artists/album/cover）。
  Future<Map<String, SongEntity>> _fetchSongMetaByIds(Set<String> ids) async {
    if (ids.isEmpty) return {};
    final songs = await SongDao.instance.fetchByIds(ids.toList());
    return {for (final s in songs) s.id: s};
  }

  /// 使用天数：主库 listening_days 中 listenMs>0 的去重天数。
  Future<int> _fetchActiveDayCount() async {
    try {
      final db = await DbHelper.instance.database;
      final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM listening_days WHERE listenMs > 0',
      );
      if (rows.isEmpty) return 0;
      final c = rows.first['c'];
      return c is int ? c : int.tryParse(c?.toString() ?? '') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 拉取歌手头像映射：歌手名 → coverId。
  ///
  /// 报告里歌手头像不能用歌曲的 coverId（那是专辑封面），要用歌手自己的
  /// 头像。通过 [FeiNiuApiClient.getArtistList] 拉取歌手列表拿到各歌手的
  /// coverId。失败返回空映射（歌手头像用占位图兜底）。
  Future<Map<String, String>> _fetchArtistCovers() async {
    final result = <String, String>{};
    try {
      final api = _apiClient ?? FeiNiuApiClient.instance;
      // 分页拉取（每页 200，最多 5 页覆盖常规规模）
      for (var page = 1; page <= 5; page++) {
        final resp = await api.getArtistList(page: page, size: 200);
        for (final artist in resp.list) {
          final cid = artist.coverId;
          if (cid != null && cid.isNotEmpty && artist.name.isNotEmpty) {
            result[artist.name] = cid;
          }
        }
        if (resp.list.length < 200 || resp.total <= page * 200) break;
      }
    } catch (_) {
      // 拉取失败不阻塞报告
    }
    return result;
  }

  /// 封面 URL 生成器：把 coverId 拼成 FeiNiu 服务器完整地址。
  ///
  /// 网页端通过 WebView 注入的 cookie（music-token 等）加载这些图片。
  /// coverId 为空或未登录时返回空串（页面用占位图兜底）。
  String Function(String?) _coverUrlBuilder() {
    final api = _apiClient ?? FeiNiuApiClient.instance;
    return (String? coverId) {
      if (coverId == null || coverId.isEmpty) return '';
      try {
        return api.coverUrl(coverId, size: FeiNiuApiClient.coverRequestSize);
      } catch (_) {
        return '';
      }
    };
  }

  /// 歌词关键词页：无真实歌词关键词数据源。
  ///
  /// 替代方案：用播放最多的歌曲名做关键词（无网络、确定性高）。
  /// 不填 lyrics（完整歌词文本会被 bundle 直接渲染出来，用户反馈「逐字
  /// 歌词显示出来了」，故歌词留空，页面只显示关键词词条 + 次数）。
  Future<Map<String, dynamic>> _buildPage12(_PageBuilder builder) async {
    final topSongs = builder.topSongsGlobalForKeywords(3);
    if (topSongs.isEmpty) return _invalidPage();

    final keywords = <Map<String, dynamic>>[];
    for (final entry in topSongs) {
      final songJson = entry['song'] as Map<String, dynamic>;
      final name = (songJson['name'] as String? ?? '').trim();
      if (name.isEmpty) continue;
      keywords.add({
        'word': name,
        'translate': '',
        'times': (entry['times'] as num?)?.toInt() ?? 0,
        'songs': [
          {
            'song': songJson,
            'times': (entry['times'] as num?)?.toInt() ?? 0,
            'lyrics': '',
          },
        ],
      });
    }
    if (keywords.isEmpty) return _invalidPage();
    return {
      'invalid': 0,
      'keywords': keywords,
      'keyword': {'level': 1},
    };
  }

  /// 曲风页：尽力通过 genre 列表反查歌曲→曲风映射。
  ///
  /// 优化：只反查「用户实际听过的歌」所属的曲风——拿 report_events 的
  /// songId 集合，对 top 曲风列表逐个拉 size:300 的 track 列表求交集，
  /// 命中率远高于原实现（原实现每 genre 只取第 1 首）。请求量控制在
  /// genre 数（通常个位数）以内。
  Future<Map<String, dynamic>> _buildPage13(_PageBuilder builder) async {
    try {
      final api = _apiClient ?? FeiNiuApiClient.instance;
      final genres = await api.getGenreList(size: 200);
      if (genres.list.isEmpty) return _invalidPage();

      // 用户实际听过的 songId 集合（去重）
      final listened = <String>{
        for (final e in builder.reportEvents)
          if ((e['songId'] as String? ?? '').isNotEmpty)
            (e['songId'] as String? ?? '').toString(),
      };
      if (listened.isEmpty) return _invalidPage();

      // 按 trackCount 排序取 top 8 曲风，控制请求量
      final topGenres = [...genres.list]
        ..sort((a, b) => b.trackCount.compareTo(a.trackCount));
      final take = topGenres.take(8).toList();

      final map = <String, String>{};
      for (final g in take) {
        try {
          final tracks = await api.getGenreTracks(
            genreGUID: g.guid,
            size: 300,
          );
          for (final t in tracks.list) {
            if (listened.contains(t.guid)) {
              map[t.guid] = g.name;
            }
          }
        } catch (_) {
          // 单曲风拉取失败跳过
        }
      }
      return builder.page13(map);
    } catch (e) {
      return _invalidPage();
    }
  }
}

/// 单次构建的页面装配器：缓存中间聚合，避免重复扫描事件。
class _PageBuilder {
  _PageBuilder(
    this.events,
    this.songAgg,
    this.monthTotals,
    this.songsById,
    this.totals,
    this.activeDayCount,
    this.coverUrl,
    this.artistCovers,
  );

  final List<Map<String, dynamic>> events;
  final Map<String, Map<String, int>> songAgg;
  final Map<String, int> monthTotals;
  final Map<String, SongEntity> songsById;
  final StatsTotals totals;
  final int activeDayCount;

  /// 原始 report_events 事件列表（供外层 _buildPage13 反查曲风用）。
  List<Map<String, dynamic>> get reportEvents => events;

  /// 歌手名 → 真实歌手头像 coverId（来自 getArtistList）。
  final Map<String, String> artistCovers;

  /// coverId → 完整封面 URL（FeiNiu 服务器，走 WebView cookie 鉴权）。
  final String Function(String?) coverUrl;

  // ---- 歌曲→歌手 聚合 ----
  late final Map<String, Map<String, int>> _artistAgg = _computeArtistAgg();
  late final List<_ArtistRow> _artistRows =
      _artistAgg.entries.map((e) => _ArtistRow(e.key, e.value)).toList()
        ..sort((a, b) => b.playMs.compareTo(a.playMs));

  late final Map<String, Map<String, int>> _albumAgg = _computeAlbumAgg();
  late final List<_AlbumRow> _albumRows = _albumAgg.entries
      .map((e) => _AlbumRow(e.key, e.value))
      .toList()
    ..sort((a, b) => b.playMs.compareTo(a.playMs));

  Map<String, Map<String, int>> _computeArtistAgg() {
    final result = <String, Map<String, int>>{};
    for (final e in events) {
      final artistsJson = e['artistsJson'] as String?;
      final name = _firstArtistName(artistsJson);
      if (name.isEmpty) continue;
      final bucket = result.putIfAbsent(name, () => {
            'playMs': 0,
            'playCount': 0,
          });
      bucket['playMs'] = (bucket['playMs'] ?? 0) + (_asInt(e['playMs']));
      bucket['playCount'] =
          (bucket['playCount'] ?? 0) + (e['completed'] == 1 ? 1 : 0);
    }
    return result;
  }

  Map<String, Map<String, int>> _computeAlbumAgg() {
    final result = <String, Map<String, int>>{};
    for (final e in events) {
      final albumJson = e['albumJson'] as String?;
      final name = _albumName(albumJson);
      if (name.isEmpty) continue;
      final bucket = result.putIfAbsent(name, () => {
            'playMs': 0,
            'playCount': 0,
          });
      bucket['playMs'] = (bucket['playMs'] ?? 0) + (_asInt(e['playMs']));
      bucket['playCount'] =
          (bucket['playCount'] ?? 0) + (e['completed'] == 1 ? 1 : 0);
    }
    return result;
  }

  String _firstArtistName(String? artistsJson) {
    if (artistsJson == null || artistsJson.isEmpty) return '';
    try {
      final list = jsonDecode(artistsJson) as List<dynamic>;
      if (list.isEmpty) return '';
      final first = list.first as Map<String, dynamic>;
      return (first['name'] as String? ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  Map<String, dynamic> _invalidPage() => {'invalid': 1};

  String _albumName(String? albumJson) {
    if (albumJson == null || albumJson.isEmpty) return '';
    try {
      final map = jsonDecode(albumJson) as Map<String, dynamic>;
      return (map['name'] as String? ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  /// 歌手头像 coverId。
  ///
  /// 优先用服务器返回的真实歌手头像（artistCovers，来自 getArtistList）；
  /// 查不到时回退到该歌手歌曲的封面（可能显示专辑图，但至少不空白）。
  String? _artistCoverId(String artistName) {
    final real = artistCovers[artistName];
    if (real != null && real.isNotEmpty) return real;
    for (final song in songsById.values) {
      final names = _artistNamesOf(song);
      if (names.any((n) => n == artistName)) {
        final cid = song.coverId;
        if (cid != null && cid.isNotEmpty) return cid;
      }
    }
    // 回退：从事件里找（coverId 存在 report_events）
    for (final e in events) {
      if ((e['artistsJson'] as String?)?.contains(artistName) == true) {
        final cid = e['coverId'] as String?;
        if (cid != null && cid.isNotEmpty) return cid;
      }
    }
    return null;
  }

  /// 从已缓存的歌曲元数据里，找该专辑的一张封面 coverId。
  String? _albumCoverId(String albumName) {
    for (final song in songsById.values) {
      if (song.albumDisplayName == albumName) {
        final cid = song.coverId;
        if (cid != null && cid.isNotEmpty) return cid;
      }
    }
    return null;
  }

  // ---- 页面装配 ----

  Map<String, dynamic> page0() {
    // 首次使用日期：暂无持久化 → 用最早事件日期兜底
    final firstDay = _firstEventDay();
    if (firstDay == null) return _invalidPage();
    return {'invalid': 0, 'type': 2, 'date': firstDay};
  }

  Map<String, dynamic> page1() {
    final totalMs = totals.listenMs;
    final totalSeconds = totalMs ~/ 1000;
    final hour = totalSeconds ~/ 3600;
    final minute = (totalSeconds % 3600) ~/ 60;
    final second = totalSeconds % 60;
    return {
      'invalid': 0,
      'songNum': songAgg.length,
      'listenTime': {
        'time': totalSeconds.toString(),
        'hour': hour,
        'minute': minute,
        'second': second,
        'unixSec': totalSeconds,
      },
      'percent': '',
      // num = 使用天数（有听歌记录的去重天数，来自 listening_days / report_events）
      'num': activeDayCount,
    };
  }

  Map<String, dynamic> page2() {
    final months = <Map<String, dynamic>>[];
    for (var m = 1; m <= 12; m++) {
      final key = '${DateTime.now().year}-${m.toString().padLeft(2, '0')}';
      final ms = monthTotals[key] ?? 0;
      // 只输出有听歌数据的月份（原版如此：无数据月份直接跳过）
      if (ms <= 0) continue;
      final secs = ms ~/ 1000;
      final topSinger = _monthlyTopSinger(key);
      months.add({
        'type': 0,
        'title': '$m月',
        // 原版页面组件直接访问 singer.pic / singer.name（无判空），
        // singer 必须是对象，不能是 null，否则 TypeError: null.name 崩溃黑屏。
        'singer': topSinger == null
            ? _singerJson('')
            : _singerJson(topSinger.$1, coverId: topSinger.$2),
        'songs': null,
        'otherMap': {
          'timeInfo': jsonEncode({
            'time': secs.toString(),
            'hour': secs ~/ 3600,
            'minute': (secs % 3600) ~/ 60,
            'second': secs % 60,
            'unixSec': 0,
          }),
        },
      });
    }
    return {'invalid': 0, 'singers': months};
  }

  /// 该月播放最多的歌手（name, coverId）。从 report_events 按 dayKey 月份分组统计。
  (String, String?)? _monthlyTopSinger(String monthKey) {
    final agg = <String, int>{};
    final covers = <String, String?>{};
    for (final e in events) {
      final day = (e['dayKey'] as String? ?? '');
      if (!day.startsWith(monthKey)) continue;
      final name = _firstArtistName(e['artistsJson'] as String?);
      if (name.isEmpty) continue;
      agg[name] = (agg[name] ?? 0) + _asInt(e['playMs']);
      final cid = e['coverId'] as String?;
      if (cid != null && cid.isNotEmpty && covers[name] == null) {
        covers[name] = cid;
      }
    }
    if (agg.isEmpty) return null;
    String? best;
    var bestMs = -1;
    for (final entry in agg.entries) {
      if (entry.value > bestMs) {
        bestMs = entry.value;
        best = entry.key;
      }
    }
    final bestName = best;
    if (bestName == null) return null;
    return (bestName, covers[bestName]);
  }

  Map<String, dynamic> page3() {
    final singers = _artistRows.take(10).map((r) {
      return {
        'type': 0,
        'title': '',
        'singer': _singerJson(r.name, coverId: _artistCoverId(r.name)),
        'songs': null,
        'otherMap': null,
      };
    }).toList();
    return {'invalid': singers.isEmpty ? 1 : 0, 'singers': singers};
  }

  Map<String, dynamic> page4() {
    final top = _artistRows.isEmpty ? null : _artistRows.first;
    if (top == null) return _invalidPage();
    final topSongs = _topSongsFor(top.name, 9);
    return {
      'invalid': 0,
      'singer': _singerJson(top.name, coverId: _artistCoverId(top.name)),
      'listenTime': _listenTimeJson(top.playMs),
      'rank': '',
      'voiceUrl': '',
      'otherMap': null,
      'songs': topSongs,
    };
  }

  Map<String, dynamic> page5() {
    // 「走过你的2025」页：bundle 读 changeList（非 singers），每个元素
    // { singer:{pic,name}, type:1-4 }，type 映射文案（1一直都爱/2邂逅新欢/
    // 3淡出耳畔/4夜晚歌手）。取歌手榜前 4 位，按排名分配 type。
    final others = _artistRows.take(4).toList();
    if (others.isEmpty) return _invalidPage();
    final changeList = <Map<String, dynamic>>[];
    for (var i = 0; i < others.length; i++) {
      changeList.add({
        'singer': _singerJson(others[i].name,
            coverId: _artistCoverId(others[i].name)),
        'type': i + 1,
      });
    }
    return {'invalid': 0, 'changeList': changeList};
  }

  Map<String, dynamic> page6() {
    // 年度作曲者页：无作曲者数据源。bundle 读 singer + songs[].song.name，
    // 与 page4 歌手页结构一致 → 用年度歌手替代（保证页面不空白、不 invalid）。
    // 用第 2 位歌手（第 1 位已用于 page4 忠实歌迷）。
    return _substituteArtistPage(index: 1);
  }

  Map<String, dynamic> page7() {
    // 年度作词者页：同上，用第 3 位歌手（避免与 page6 重复）。
    return _substituteArtistPage(index: 2);
  }

  /// 无数据源页面的替代：用年度歌手（默认第 2 位）填充 singer+songs，
  /// 结构与 bundle 的 page6/page7 组件（singer.pic/name + songs[].song.name）完全兼容。
  /// [index] 指定用歌手榜第几位（0 起），避免多个替代页展示同一位歌手。
  Map<String, dynamic> _substituteArtistPage({int index = 1}) {
    if (_artistRows.isEmpty) return _invalidPage();
    final pick = index < _artistRows.length ? _artistRows[index] : _artistRows.last;
    final songs = _topSongsFor(pick.name, 3);
    return {
      'invalid': 0,
      'singer': _singerJson(pick.name, coverId: _artistCoverId(pick.name)),
      'songs': songs.isEmpty ? null : songs,
    };
  }

  Map<String, dynamic> page8() {
    final albums = _albumRows.take(9).map((r) {
      return {
        'id': 0,
        'name': r.name,
        'mid': '',
        'pMid': '',
        'pic': coverUrl(_albumCoverId(r.name)),
        'singers': const [],
        'otherMap': null,
      };
    }).toList();
    return {'invalid': albums.isEmpty ? 1 : 0, 'albums': albums};
  }

  Map<String, dynamic> page9() {
    final top = _albumRows.isEmpty ? null : _albumRows.first;
    if (top == null) return _invalidPage();
    return {
      'invalid': 0,
      'album': {
        'id': 0,
        'name': top.name,
        'mid': '',
        'pMid': '',
        'pic': coverUrl(_albumCoverId(top.name)),
        'singers': const [],
        'otherMap': null,
      },
      'peopleNum': 0,
      'listenTime': _listenTimeJson(top.playMs),
    };
  }

  Map<String, dynamic> page10() {
    final topSongs = _topSongsGlobal(10);
    if (topSongs.isEmpty) return _invalidPage();
    return {
      'invalid': 0,
      'songs': topSongs,
      // songList 用原始 track guid（网页收藏歌单时按 guid 加歌到 FeiNiu）
      'songList': _topSongsGlobal(50)
          .map((s) => ((s['song'] as Map<String, dynamic>)['guid'] ?? '').toString())
          .where((g) => g.isNotEmpty)
          .toList(),
      'saved': 0,
      'picList': null,
    };
  }

  Map<String, dynamic> page11() {
    final top = _topSongsGlobal(1);
    if (top.isEmpty) return _invalidPage();
    final entry = top.first;
    return {
      'invalid': 0,
      'song': entry, // {song:{...}, times, lyrics, type, listenTime, otherMap}
      'times': _asInt(entry['times']),
      'lyrics': '',
    };
  }

  Map<String, dynamic> page14() {
    final loop = _topLoopDay();
    if (loop == null) return _invalidPage();
    final dt = loop.date;
    return {
      'invalid': 0,
      'song': loop.songJson,
      'date': dt == null
          ? null
          : {
              'date': '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}',
              'year': dt.year,
              'month': dt.month,
              'day': dt.day,
              'hour': 0,
              'minute': 0,
              'second': 0,
            },
      'des': '',
    };
  }

  Map<String, dynamic> page15() {
    final late = _topLateNight();
    if (late == null) return _invalidPage();
    final dt = late.dateTime;
    return {
      'invalid': 0,
      // 深夜页 bundle 直接读 song.name / song.singers / song.album.pic，
      // song 必须是裸 song 对象（不能用 _songJson 的 {song:{...}} 包装）
      'song': _songInnerJson(late.songId),
      'date': {
        'date': '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:00',
        'year': 0,
        'month': dt.month,
        'day': dt.day,
        'hour': dt.hour,
        'minute': dt.minute,
        'second': 0,
      },
      'dayNum': 0,
    };
  }

  Map<String, dynamic> page16() {
    final seasons = _seasonInfos();
    if (seasons.isEmpty) return _invalidPage();
    return {
      'invalid': 0,
      'seasonInfos': seasons,
      'temp': _seasonTemp(),
    };
  }

  Map<String, dynamic> page18() {
    final p0 = page0();
    final p1 = page1();
    final p4 = page4();
    final p9 = page9();
    final p11 = page11();
    final p13 = _invalidPage(); // 曲风单独构建，这里用空
    final top = _artistRows.isEmpty ? null : _artistRows.first;
    return {
      'invalid': 0,
      'title': '',
      'registerDate': p0,
      'listenTime': p1,
      'singer': p4,
      'song': p11,
      'album': p9,
      'genre': p13,
      'grade': 0,
      'desc': jsonEncode({
        'persona_titles': _personaTitle(top?.name),
        'emotional_journey': '',
        'future_wishes': '',
        'persona_description': '',
      }),
      'cardType': 6,
      'nick': AuthService.instance.username.value?.trim().isNotEmpty == true
          ? AuthService.instance.username.value!.trim()
          : '音乐人',
      'avatar': '',
    };
  }

  Map<String, dynamic> page19() {
    final top = _artistRows.isEmpty ? null : _artistRows.first;
    if (top == null) return _invalidPage();
    final day = _topArtistDay(top.name);
    if (day == null) return _invalidPage();
    final date = day.date ?? DateTime.now();
    final minute = day.playMs ~/ 60000;
    // 原版文案：desc 列当天听的歌（最多 3 首）→ 「一共听了 N 分钟」
    final songsText = day.songNames.take(3).map((n) => '《$n》').join('、');
    final desc = songsText.isEmpty
        ? '这一天，你与 ${top.name} 的音乐相伴，一共听了 $minute 分钟'
        : '收听$songsText等，一共听了 $minute 分钟';
    return {
      'invalid': 0,
      'type': 1,
      'date': '${date.year}年${date.month}月${date.day}日',
      'title': '你的「${top.name}日」',
      'desc': desc,
      'minute': minute,
      'songNum': day.songNum,
      'genreNum': 0,
      'singerNum': 0,
      'bpm': 0,
      'content': '当耳机里的旋律响起，节拍便系住了你们。相隔万里，却心跳同频，在声波的潮汐里，成为彼此最近的岛屿。',
    };
  }

  // ---- 曲风页（由外层传入反查映射） ----
  Map<String, dynamic> page13(Map<String, String> songGenreMap) {
    if (songGenreMap.isEmpty) return _invalidPage();
    final counts = <String, int>{};
    for (final e in events) {
      final songId = (e['songId'] as String? ?? '').toString();
      final g = songGenreMap[songId];
      if (g == null) continue;
      counts[g] = (counts[g] ?? 0) + 1;
    }
    if (counts.isEmpty) return _invalidPage();
    final total = counts.values.fold<int>(0, (a, b) => a + b);
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return {
      'invalid': 0,
      'tagPicList': null,
      // genre/topGenre 必须用 bundle Ja 表的数字 id（不是曲风名），
      // 否则第二页「你的年度曲风」的标签按 id 匹配不到、风格名不显示。
      'genreInfos': [
        for (final e in sorted.take(5))
          {
            'genre': _genreIdOf(e.key),
            'percent': '${(e.value / total * 100).toStringAsFixed(0)}%',
            'secGenres': null,
          }
      ],
      'lang': '',
      'genreNum': counts.length,
      'topGenre': _genreIdOf(sorted.first.key),
    };
  }

  /// 曲风名 → bundle Ja 表数字 id（与网页端曲风勋章/标签映射对齐）。
  ///
  /// 反查到的曲风是名字（如「摇滚」），bundle 用数字 id 查标签与样式。
  /// 未命中映射的曲风名返回空串（该曲风不点亮，避免错误 id 匹配到别的样式）。
  static const Map<String, int> _genreIdMap = {
    '摇滚': 4, '说唱': 3, '电子': 2, '流行': 7, '节奏布鲁斯': 11,
    '硬摇滚': 253, '后摇': 264, '另类摇滚': 260, '世界音乐': 57, 'ACG': 65,
    '乡村': 13, '先锋音乐': 16, '爵士': 14, '灵魂乐': 290, '古典': 33,
    '蓝调': 10, '拉丁': 62, '国风': 19, '民谣': 8, '影视原声': 68,
    '轻音乐': 93, '雷鬼': 12, '朋克': 261, '金属': 6, '新世纪': 15,
    'K-pop': 94, '独立流行': 247, 'J-pop': 95, 'House': 299, 'Techno': 304,
    'Funk': 291, 'EDM': 1, '中国戏曲': 43,
  };

  String _genreIdOf(String genreName) {
    final id = _genreIdMap[genreName.trim()];
    return id == null ? '' : id.toString();
  }

  // ---- 工具 ----

  /// 构造 data.json 同构的 singer 对象。可传入 [coverId] 生成真实封面 URL。
  Map<String, dynamic> _singerJson(String name, {String? coverId}) {
    return {
      'id': 0,
      'mid': '',
      'name': name,
      'pMid': '',
      'pic': coverUrl(coverId),
      'type': 1,
      'genre': 0,
      'forceShow': 0,
      'identity': 0,
      'otherMap': null,
    };
  }

  Map<String, dynamic> _listenTimeJson(int playMs) {
    final secs = playMs ~/ 1000;
    return {
      'time': secs.toString(),
      'hour': secs ~/ 3600,
      'minute': (secs % 3600) ~/ 60,
      'second': secs % 60,
      'unixSec': 0,
    };
  }

  /// 构造 data.json 同构的 song 对象（page4/page10/page11 的 {song:{...}}）。
  Map<String, dynamic> _songJson(String songId, int times) {
    final meta = songsById[songId];
    final name = meta?.title ?? _eventTitle(songId) ?? '未知歌曲';
    final albumName = meta?.albumDisplayName ?? '';
    final albumCover = _songCoverId(songId);
    return {
      'song': {
        'id': songId.hashCode & 0x7fffffff,
        'guid': songId, // 原始 FeiNiu track guid（网页收藏歌单时发给 App）
        'mid': '',
        'name': name,
        'singers': [
          for (final n in _artistNamesOf(meta)) _singerJson(n),
        ],
        'album': {
          'id': 0,
          'name': albumName,
          'mid': '',
          'pMid': '',
          'pic': coverUrl(albumCover),
          'singers': null,
        },
        'publishTime': '',
        'otherMap': null,
      },
      'times': times,
      'lyrics': '',
      'type': 0,
      'listenTime': _listenTimeJson(_songListenMs(songId)),
      'otherMap': null,
    };
  }

  /// 裸 song 对象（不含外层 {song:...} 包装）。
  ///
  /// page15 深夜听歌、page16 四季歌单的 bundle 组件直接读 `song.name` /
  /// `song.singers` / `song.album.pic`，song 必须是 song 对象本身，
  /// 不能用 [_songJson] 的 `{song:{...}}` 包装（否则页面读不到歌名/封面）。
  Map<String, dynamic> _songInnerJson(String songId) {
    final meta = songsById[songId];
    final name = meta?.title ?? _eventTitle(songId) ?? '未知歌曲';
    final albumName = meta?.albumDisplayName ?? '';
    final albumCover = _songCoverId(songId);
    return {
      'id': songId.hashCode & 0x7fffffff,
      'mid': '',
      'name': name,
      'singers': [
        for (final n in _artistNamesOf(meta)) _singerJson(n),
      ],
      'album': {
        'id': 0,
        'name': albumName,
        'mid': '',
        'pMid': '',
        'pic': coverUrl(albumCover),
        'singers': null,
      },
      'publishTime': '',
      'otherMap': null,
    };
  }

  String? _eventTitle(String songId) {
    for (final e in events) {
      if ((e['songId'] as String? ?? '').toString() == songId) {
        return (e['songTitle'] as String? ?? '未知歌曲').trim();
      }
    }
    return null;
  }

  /// 歌曲封面 coverId：优先主库缓存的歌曲元数据，回退 report_events 里
  /// 的 coverId（深夜晚/四季等页的歌曲可能不在主库缓存，此时需从事件回退，
  /// 否则 album.pic 为空 → 网页封面黑屏）。
  String? _songCoverId(String songId) {
    final cached = songsById[songId]?.coverId;
    if (cached != null && cached.isNotEmpty) return cached;
    for (final e in events) {
      if ((e['songId'] as String? ?? '').toString() == songId) {
        final cid = e['coverId'] as String?;
        if (cid != null && cid.isNotEmpty) return cid;
      }
    }
    return null;
  }

  List<String> _artistNamesOf(SongEntity? meta) {
    if (meta == null) return const [];
    final names = <String>[];
    try {
      final list = jsonDecode(meta.artist) as List<dynamic>;
      for (final e in list) {
        final n = (e as Map<String, dynamic>)['name'] as String?;
        if (n != null && n.trim().isNotEmpty) names.add(n.trim());
      }
    } catch (_) {}
    return names;
  }

  int _songListenMs(String songId) {
    final agg = songAgg[songId];
    if (agg != null) return agg['listenMs'] ?? 0;
    var sum = 0;
    for (final e in events) {
      if ((e['songId'] as String? ?? '').toString() == songId) {
        sum += _asInt(e['playMs']);
      }
    }
    return sum;
  }

  List<Map<String, dynamic>> _topSongsGlobal(int n) {
    final list = songAgg.entries.toList()
      ..sort((a, b) =>
          (b.value['playCount'] ?? 0).compareTo(a.value['playCount'] ?? 0));
    return list.take(n).map((e) => _songJson(e.key, e.value['playCount'] ?? 0)).toList();
  }

  /// top 歌曲（带原始 songId 供拉歌词用）。
  ///
  /// 与 [_topSongsGlobal] 相同排序，但每条额外带 `songId`（原始 id）。
  /// 供 page12 关键字页拉歌词使用。
  List<Map<String, dynamic>> topSongsGlobalForKeywords(int n) {
    final list = songAgg.entries.toList()
      ..sort((a, b) =>
          (b.value['playCount'] ?? 0).compareTo(a.value['playCount'] ?? 0));
    return list.take(n).map((e) => {
          ..._songJson(e.key, e.value['playCount'] ?? 0),
          'songId': e.key,
        }).toList();
  }

  /// 某歌手旗下播放最多的歌曲（page4）。
  List<Map<String, dynamic>> _topSongsFor(String artistName, int n) {
    final matching = <MapEntry<String, Map<String, int>>>[];
    for (final e in events) {
      final songId = (e['songId'] as String? ?? '').toString();
      final name = _firstArtistName(e['artistsJson'] as String?);
      if (name == artistName) {
        matching.add(MapEntry(songId, songAgg[songId] ?? {
              'playCount': 0,
              'listenMs': 0,
            }));
      }
    }
    final seen = <String>{};
    final unique = <MapEntry<String, Map<String, int>>>[];
    for (final m in matching) {
      if (seen.add(m.key)) unique.add(m);
    }
    unique.sort((a, b) =>
        (b.value['playCount'] ?? 0).compareTo(a.value['playCount'] ?? 0));
    return unique
        .take(n)
        .map((e) => _songJson(e.key, e.value['playCount'] ?? 0))
        .toList();
  }

  String? _firstEventDay() {
    if (events.isEmpty) return null;
    final first = events.first;
    final dayKey = (first['dayKey'] as String? ?? '').trim();
    if (dayKey.isEmpty) return null;
    final parts = dayKey.split('-');
    if (parts.length != 3) return null;
    return '${parts[0]}年${int.parse(parts[1])}月${int.parse(parts[2])}日';
  }

  _LoopDay? _topLoopDay() {
    final byDay = <String, Map<String, int>>{};
    for (final e in events) {
      final day = e['dayKey'] as String? ?? '';
      if (day.isEmpty) continue;
      final songId = (e['songId'] as String? ?? '').toString();
      final bucket = byDay.putIfAbsent(day, () => <String, int>{});
      bucket[songId] = (bucket[songId] ?? 0) + _asInt(e['playMs']);
    }
    String? bestDay;
    String? bestSongId;
    var bestMs = 0;
    for (final entry in byDay.entries) {
      for (final songEntry in entry.value.entries) {
        if (songEntry.value > bestMs) {
          bestMs = songEntry.value;
          bestDay = entry.key;
          bestSongId = songEntry.key;
        }
      }
    }
    if (bestDay == null || bestSongId == null) return null;
    final parts = bestDay.split('-');
    if (parts.length != 3) return null;
    final dt =
        DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
    return _LoopDay(bestDay, bestSongId, bestMs,
        date: dt, songJson: _songJson(bestSongId, 1));
  }

  _LateNight? _topLateNight() {
    DateTime? bestDate;
    String? bestSongId;
    var bestMs = 0;
    for (final e in events) {
      final hour = _asInt(e['hour']);
      if (hour >= 0 && hour <= 4 || hour >= 22) {
        final ms = _asInt(e['playMs']);
        if (ms > bestMs) {
          bestMs = ms;
          bestDate = DateTime.fromMillisecondsSinceEpoch(
              _asInt(e['sessionEndMs'] ?? 0));
          bestSongId = (e['songId'] as String? ?? '').toString();
        }
      }
    }
    if (bestDate == null || bestSongId == null) return null;
    return _LateNight(bestDate, bestSongId, bestMs);
  }

  List<Map<String, dynamic>> _seasonInfos() {
    const seasons = ['春天', '夏天', '秋天', '冬天'];
    final bySeason = <int, Map<String, int>>{};
    for (final e in events) {
      final month = DateTime.fromMillisecondsSinceEpoch(
              _asInt(e['sessionEndMs'] ?? 0))
          .month;
      final s = _seasonOf(month);
      final songId = (e['songId'] as String? ?? '').toString();
      final bucket = bySeason.putIfAbsent(s, () => <String, int>{});
      bucket[songId] = (bucket[songId] ?? 0) + _asInt(e['playMs']);
    }
    final result = <Map<String, dynamic>>[];
    for (var s = 0; s < 4; s++) {
      final songs = bySeason[s];
      if (songs == null || songs.isEmpty) continue;
      final top = songs.entries.reduce((a, b) => a.value > b.value ? a : b);
      result.add({
        // 四季页 bundle 直接读 song.name / song.singers，
        // song 必须是裸 song 对象
        'song': _songInnerJson(top.key),
        'season': seasons[s],
        'otherMap': {'mbti': _mbtiFor(s)},
      });
    }
    return result;
  }

  int _seasonOf(int month) {
    if (month >= 3 && month <= 5) return 0;
    if (month >= 6 && month <= 8) return 1;
    if (month >= 9 && month <= 11) return 2;
    return 3;
  }

  String _mbtiFor(int season) {
    const list = ['INFP', 'ESFP', 'INTP', 'ISTJ'];
    return list[season];
  }

  int _seasonTemp() {
    // 仅用于挑选季节插画，给个中性值
    return 22;
  }

  _ArtistDay? _topArtistDay(String artistName) {
    final byDay = <String, _ArtistDayAcc>{};
    for (final e in events) {
      final name = _firstArtistName(e['artistsJson'] as String?);
      if (name != artistName) continue;
      final day = e['dayKey'] as String? ?? '';
      if (day.isEmpty) continue;
      final acc = byDay.putIfAbsent(
          day, () => _ArtistDayAcc(day, DateTime.tryParse(day)));
      acc.playMs += _asInt(e['playMs']);
      acc.songIds.add((e['songId'] as String? ?? '').toString());
    }
    _ArtistDayAcc? best;
    for (final acc in byDay.values) {
      if (best == null || acc.playMs > best.playMs) best = acc;
    }
    if (best == null) return null;
    // 当天听的歌名（去重，最多取 6 首用于 desc 展示）
    final songNames = <String>[];
    for (final sid in best.songIds) {
      final name = _eventTitle(sid) ?? songsById[sid]?.title;
      if (name != null && name.isNotEmpty && !songNames.contains(name)) {
        songNames.add(name);
      }
      if (songNames.length >= 6) break;
    }
    return _ArtistDay(
      best.day,
      best.date,
      best.playMs,
      best.songIds.length,
      songNames,
    );
  }

  /// 总结页顶部的人设标题。
  ///
  /// 返回空串：避免「与 XXX 同行的人」置顶盖住「XXX的2025年度总结」标题
  /// （bundle 仅对 undefined 走默认文案，空串渲染为空白）。
  String _personaTitle(String? artistName) => '';

  int _asInt(dynamic v) {
    if (v is int) return v;
    if (v == null) return 0;
    return int.tryParse(v.toString()) ?? 0;
  }
}

class _ArtistRow {
  final String name;
  final Map<String, int> agg;
  _ArtistRow(this.name, this.agg);

  int get playMs => agg['playMs'] ?? 0;
  int get playCount => agg['playCount'] ?? 0;
}

class _AlbumRow {
  final String name;
  final Map<String, int> agg;
  _AlbumRow(this.name, this.agg);

  int get playMs => agg['playMs'] ?? 0;
  int get playCount => agg['playCount'] ?? 0;
}

class _LoopDay {
  final String day;
  final String songId;
  final int playMs;
  final DateTime? date;
  final Map<String, dynamic>? songJson;

  _LoopDay(this.day, this.songId, this.playMs,
      {this.date, this.songJson});
}

class _LateNight {
  final DateTime dateTime;
  final String songId;
  final int playMs;

  _LateNight(this.dateTime, this.songId, this.playMs);
}

class _ArtistDay {
  final String day;
  final DateTime? date;
  final int playMs;
  final int songNum;
  final List<String> songNames;

  _ArtistDay(this.day, this.date, this.playMs, this.songNum, [this.songNames = const []]);
}

class _ArtistDayAcc {
  final String day;
  final DateTime? date;
  int playMs = 0;
  final Set<String> songIds = {};

  _ArtistDayAcc(this.day, this.date);
}
