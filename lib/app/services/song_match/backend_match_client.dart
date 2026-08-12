import 'dart:convert';

import 'package:dio/dio.dart';

import '../companion/companion_error.dart';
import '../feiniu/api_client.dart';
import 'song_match_models.dart';

/// 按数据源分组的搜索结果（对齐后端 /search/songs 返回）。
class GroupedSongResults {
  /// 源 id → 该源结果（保持源排序）。
  final List<SourceGroup> groups;

  const GroupedSongResults({this.groups = const []});

  /// 全部结果（合并拍平，供需要单列表的场景）。
  List<SongMatchResult> get flat => groups.expand((g) => g.results).toList();

  bool get isEmpty => groups.every((g) => g.results.isEmpty);
}

/// 单个数据源的结果分组。
class SourceGroup {
  final String pluginId;
  final String pluginName;
  final List<SongMatchResult> results;

  const SourceGroup({
    required this.pluginId,
    required this.pluginName,
    required this.results,
  });
}

/// 后端可用的搜索平台信息（对应 GET /search/sources）。
class SearchSourceInfo {
  final String id;
  final String name;
  final List<String> capabilities;
  final Map<String, int> searchTypes;
  final int defaultSearchType;
  final Map<String, dynamic> config;

  const SearchSourceInfo({
    required this.id,
    required this.name,
    this.capabilities = const [],
    this.searchTypes = const {},
    this.defaultSearchType = 0,
    this.config = const {},
  });

  factory SearchSourceInfo.fromJson(Map<String, dynamic> json) {
    return SearchSourceInfo(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      capabilities: (json['capabilities'] as List? ?? const [])
          .map((e) => e.toString())
          .toList(),
      searchTypes: (json['searchTypes'] as Map? ?? const {})
          .map((k, v) => MapEntry(k.toString(), (v as num?)?.toInt() ?? 0)),
      defaultSearchType: (json['defaultSearchType'] as num?)?.toInt() ?? 0,
      config: (json['config'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  bool hasCapability(String capability) => capabilities.contains(capability);
}

/// 后端歌词返回（对应 POST /search/lyrics）。
class BackendLyricResult {
  final String platform;

  /// 行级 LRC 原文文本（structured 不可用时的降级）。
  final String rawPlainLrc;

  /// 结构化歌词行（词级优先；无逐字时为行级整行文本）。
  final List<LyricLine> original;
  final List<LyricLine> translated;
  final List<LyricLine> romanization;
  final Map<String, String> tags;

  const BackendLyricResult({
    required this.platform,
    this.rawPlainLrc = '',
    this.original = const [],
    this.translated = const [],
    this.romanization = const [],
    this.tags = const {},
  });

  bool get hasLyrics => original.isNotEmpty || rawPlainLrc.trim().isNotEmpty;

  /// 是否带逐字时间戳（任一行 ≥2 词）。
  bool get isWordByWord => original.any((l) => l.words.length > 1);
}

/// 批量匹配结果（对应 /match/batch results[]）。
class BatchMatchResult {
  final String guid;
  final bool matched;
  final String? error;
  final String matchedTitle;
  final String matchedArtist;
  final String matchedAlbum;
  final List<String> fieldsUpdated;
  final bool lyricsUpdated;
  final bool coverUpdated;
  final List<String> artistGuids;
  final String albumGuid;

  const BatchMatchResult({
    required this.guid,
    this.matched = false,
    this.error,
    this.matchedTitle = '',
    this.matchedArtist = '',
    this.matchedAlbum = '',
    this.fieldsUpdated = const [],
    this.lyricsUpdated = false,
    this.coverUpdated = false,
    this.artistGuids = const [],
    this.albumGuid = '',
  });

  factory BatchMatchResult.fromJson(Map<String, dynamic> json) {
    return BatchMatchResult(
      guid: json['guid']?.toString() ?? '',
      matched: json['matched'] == true,
      error: json['error']?.toString(),
      matchedTitle: json['matchedTitle']?.toString() ?? '',
      matchedArtist: json['matchedArtist']?.toString() ?? '',
      matchedAlbum: json['matchedAlbum']?.toString() ?? '',
      fieldsUpdated: (json['fieldsUpdated'] as List? ?? const [])
          .map((e) => e.toString())
          .toList(),
      lyricsUpdated: json['lyricsUpdated'] == true,
      coverUpdated: json['coverUpdated'] == true,
      artistGuids: (json['artistGuids'] as List? ?? const [])
          .map((e) => e.toString())
          .toList(),
      albumGuid: json['albumGuid']?.toString() ?? '',
    );
  }
}

/// 批量刷新结果（对应 /match/refresh-* 响应）。
class RefreshBatchResult {
  final int total;
  final int success;
  final int failed;
  final List<Map<String, dynamic>> results;

  const RefreshBatchResult({
    required this.total,
    this.success = 0,
    this.failed = 0,
    this.results = const [],
  });

  factory RefreshBatchResult.fromJson(Map<String, dynamic> json) {
    return RefreshBatchResult(
      total: (json['total'] as num?)?.toInt() ?? 0,
      success: (json['success'] as num?)?.toInt() ?? 0,
      failed: (json['failed'] as num?)?.toInt() ?? 0,
      results: (json['results'] as List? ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList(),
    );
  }
}

/// FnMusicEnhance 数据源搜索客户端。
///
/// 服务端增强运行在飞牛 NAS 上（经 nginx /music-enhance/ 提供），提供多平台搜索 API：
/// - `GET  /music/api/v1/search/sources` 平台列表（客户端决定启用哪些）
/// - `POST /music/api/v1/search/songs`   歌曲搜索（按客户端 sources 顺序分组）
/// - `POST /music/api/v1/search/covers`  封面搜索（扁平列表）
/// - `POST /music/api/v1/search/lyrics`  歌词获取
///
/// 基础 URL 取 `FeiNiuApiClient.instance.baseUrl` + `/music-enhance`。
/// X-API-Key 携带飞牛音乐登录 token（`FeiNiuApiClient.token`）。
class BackendMatchClient {
  BackendMatchClient._internal();

  static final BackendMatchClient instance = BackendMatchClient._internal();

  static const String _sourcesPath = '/music/api/v1/search/sources';
  static const String _songsPath = '/music/api/v1/search/songs';
  static const String _coversPath = '/music/api/v1/search/covers';
  static const String _lyricsPath = '/music/api/v1/search/lyrics';
  static const String _matchBatchPath = '/music/api/v1/match/batch';
  static const String _matchRefreshSongsPath =
      '/music/api/v1/match/refresh-all-songs';
  static const String _matchRefreshArtistCoversPath =
      '/music/api/v1/match/refresh-artist-covers';
  static const String _matchRefreshAlbumCoversPath =
      '/music/api/v1/match/refresh-album-covers';
  static const String _playlistImportPath = '/music/api/v1/playlist/import';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
      responseType: ResponseType.json,
      validateStatus: (code) => code != null && code < 500,
    ),
  );

  /// 当前是否可用（已配置服务地址 + 已登录）。
  bool get available {
    final api = FeiNiuApiClient.instance;
    return api.baseUrl.isNotEmpty && api.token.isNotEmpty;
  }

  /// 构造服务端增强基础 URL：`<FeiNiuApiClient.baseUrl>/music-enhance`。
  String? get baseUrl {
    final api = FeiNiuApiClient.instance;
    if (api.baseUrl.isEmpty) return null;
    return '${api.baseUrl}/music-enhance';
  }

  /// 获取后端可用平台列表。失败抛异常（携带服务器 msg）。
  Future<List<SearchSourceInfo>> fetchSources() async {
    final base = baseUrl;
    if (base == null) throw StateError('未配置服务器地址');
    final Map<String, dynamic> data;
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '$base$_sourcesPath',
        options: Options(headers: _authHeaders()),
      );
      data = response.data ?? const {};
    } on DioException catch (e) {
      throw Exception(companionErrorText(e));
    }
    if (data['code'] != 0) {
      throw Exception(data['msg'] as String? ?? '获取平台列表失败');
    }
    final payload = data['data'];
    if (payload is! Map<String, dynamic>) return const [];
    final list = payload['sources'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => SearchSourceInfo.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  /// 多平台歌曲搜索，**按 [sources] 顺序分组**返回。
  Future<GroupedSongResults> searchSongs({
    required String keyword,
    List<String>? sources,
    String sort = 'default',
    int page = 1,
    int pageSize = 20,
  }) async {
    final base = baseUrl;
    if (base == null) throw StateError('未配置服务器地址');
    final Map<String, dynamic> data;
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '$base$_songsPath',
        data: {
          'keyword': keyword,
          if (sources != null) 'sources': sources,
          'sort': sort,
          'page': page,
          'pageSize': pageSize,
        },
        options: Options(
          headers: {..._authHeaders(), 'Content-Type': 'application/json'},
        ),
      );
      data = response.data ?? const {};
    } on DioException catch (e) {
      throw Exception(companionErrorText(e));
    }
    if (data['code'] != 0) {
      throw Exception(data['msg'] as String? ?? '搜索歌曲失败');
    }
    final payload = data['data'];
    if (payload is! Map<String, dynamic>) return const GroupedSongResults();
    final groupsJson = payload['groups'];
    if (groupsJson is! List) return const GroupedSongResults();
    final groups = <SourceGroup>[];
    for (final g in groupsJson) {
      if (g is! Map) continue;
      final pluginId = g['pluginId']?.toString() ?? '';
      final pluginName = g['pluginName']?.toString() ?? '';
      final items = g['items'];
      if (pluginId.isEmpty || items is! List) continue;
      final results = parseSongResults(
        jsonEncode(items),
        pluginId,
        pluginName,
      );
      if (results.isEmpty) continue;
      groups.add(SourceGroup(
        pluginId: pluginId,
        pluginName: pluginName,
        results: results,
      ));
    }
    return GroupedSongResults(groups: groups);
  }

  /// 封面搜索（扁平列表）。[searchType]：0=歌曲 1=歌手 2=专辑。
  Future<List<SongMatchResult>> searchCovers({
    required String keyword,
    List<String>? sources,
    int searchType = 0,
    int page = 1,
    int pageSize = 10,
  }) async {
    final base = baseUrl;
    if (base == null) throw StateError('未配置服务器地址');
    final Map<String, dynamic> data;
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '$base$_coversPath',
        data: {
          'keyword': keyword,
          if (sources != null) 'sources': sources,
          'searchType': searchType,
          'page': page,
          'pageSize': pageSize,
        },
        options: Options(
          headers: {..._authHeaders(), 'Content-Type': 'application/json'},
        ),
      );
      data = response.data ?? const {};
    } on DioException catch (e) {
      throw Exception(companionErrorText(e));
    }
    if (data['code'] != 0) {
      throw Exception(data['msg'] as String? ?? '搜索封面失败');
    }
    final payload = data['data'];
    if (payload is! Map<String, dynamic>) return const [];
    final items = payload['items'];
    if (items is! List) return const [];
    final results = <SongMatchResult>[];
    for (final item in items) {
      if (item is! Map) continue;
      final pluginId = item['pluginId']?.toString() ?? '';
      final pluginName = item['pluginName']?.toString() ?? '';
      final parsed = parseSongResults(
        jsonEncode([item]),
        pluginId,
        pluginName,
        requireId: false,
      );
      results.addAll(parsed);
    }
    return results;
  }

  /// 获取某平台歌词。无歌词（rawPlainLrc 为空）返回 null。
  ///
  /// [convert] 简繁转换：none / simplifiedToTraditional / traditionalToSimplified；
  /// [removeBlankLines] 移除空行；[filterRules] 非歌词内容过滤规则。
  Future<BackendLyricResult?> fetchLyrics({
    required String platform,
    required String songId,
    String title = '',
    String artist = '',
    String album = '',
    int duration = 0,
    String convert = 'none',
    bool removeBlankLines = false,
    List<String>? filterRules,
  }) async {
    final base = baseUrl;
    if (base == null) throw StateError('未配置服务器地址');
    final Map<String, dynamic> data;
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '$base$_lyricsPath',
        data: {
          'platform': platform,
          'songId': songId,
          'title': title,
          'artist': artist,
          'album': album,
          'duration': duration,
          'convert': convert,
          'removeBlankLines': removeBlankLines,
          if (filterRules != null && filterRules.isNotEmpty)
            'filterRules': filterRules,
        },
        options: Options(
          headers: {..._authHeaders(), 'Content-Type': 'application/json'},
        ),
      );
      data = response.data ?? const {};
    } on DioException catch (e) {
      throw Exception(companionErrorText(e));
    }
    if (data['code'] != 0) {
      // 该平台不支持歌词（400）等：视为无歌词，不抛错
      return null;
    }
    final payload = data['data'];
    if (payload is! Map<String, dynamic>) return null;
    final result = BackendLyricResult(
      platform: payload['platform']?.toString() ?? platform,
      rawPlainLrc: payload['rawPlainLrc']?.toString() ?? '',
      original: parseStructuredLines(payload['original']),
      translated: parseStructuredLines(payload['translated']),
      romanization: parseStructuredLines(payload['romanization']),
      tags: (payload['tags'] as Map? ?? const {})
          .map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')),
    );
    return result.hasLyrics ? result : null;
  }

  /// 批量匹配（服务端全自动处理：搜索取首个候选并写入歌手/歌词/专辑/封面）。
  ///
  /// [songs]：`{guid, title, artist, album, duration}` 列表；
  /// [wants]：要匹配的字段名（title/artist/album/year/trackNumber/discNumber/cover/lyrics）；
  /// [writeMode]：fill / overwrite；
  /// [lyricOptions]：`{convert, removeBlankLines, filterRules}`。
  Future<List<BatchMatchResult>> batchMatch({
    required List<Map<String, dynamic>> songs,
    List<String>? sources,
    List<String>? wants,
    String writeMode = 'fill',
    bool preferFilename = false,
    Map<String, dynamic>? lyricOptions,
  }) async {
    final base = baseUrl;
    if (base == null) throw StateError('未配置服务器地址');
    final Map<String, dynamic> data;
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '$base$_matchBatchPath',
        data: {
          'songs': songs,
          if (sources != null) 'sources': sources,
          if (wants != null) 'wants': wants,
          'writeMode': writeMode,
          'preferFilename': preferFilename,
          if (lyricOptions != null) 'lyricOptions': lyricOptions,
        },
        options: Options(
          headers: {..._authHeaders(), 'Content-Type': 'application/json'},
        ),
      );
      data = response.data ?? const {};
    } on DioException catch (e) {
      throw Exception(companionErrorText(e));
    }
    if (data['code'] != 0) {
      throw Exception(data['msg'] as String? ?? '批量匹配失败');
    }
    final payload = data['data'];
    if (payload is! Map<String, dynamic>) return const [];
    final results = payload['results'];
    if (results is! List) return const [];
    return results
        .whereType<Map>()
        .map((e) => BatchMatchResult.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  /// 批量刷新通用请求。
  Future<RefreshBatchResult> _refresh(
    String path,
    Map<String, dynamic> body,
  ) async {
    final base = baseUrl;
    if (base == null) throw StateError('未配置服务器地址');
    final Map<String, dynamic> data;
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '$base$path',
        data: body,
        options: Options(
          headers: {..._authHeaders(), 'Content-Type': 'application/json'},
          // 批量刷新遍历全部歌曲/歌手，非常慢，需长超时（默认 30s 会超时）
          sendTimeout: const Duration(minutes: 1),
          receiveTimeout: const Duration(minutes: 10),
        ),
      );
      data = response.data ?? const {};
    } on DioException catch (e) {
      throw Exception(companionErrorText(e));
    }
    if (data['code'] != 0) {
      throw Exception(data['msg'] as String? ?? '批量刷新失败');
    }
    final payload = data['data'];
    if (payload is! Map<String, dynamic>) {
      return const RefreshBatchResult(total: 0);
    }
    return RefreshBatchResult.fromJson(payload);
  }

  /// 批量刷新所有歌曲信息（高危：遍历全部歌曲搜索+写入）。
  Future<RefreshBatchResult> refreshAllSongs({
    List<String>? sources,
    List<String>? wants,
    String writeMode = 'fill',
    Map<String, dynamic>? lyricOptions,
  }) {
    return _refresh(_matchRefreshSongsPath, {
      if (sources != null) 'sources': sources,
      if (wants != null) 'wants': wants,
      'writeMode': writeMode,
      if (lyricOptions != null) 'lyricOptions': lyricOptions,
    });
  }

  /// 批量刷新所有歌手图片（高危：遍历歌手搜索封面+新 guid 删旧）。
  Future<RefreshBatchResult> refreshArtistCovers({
    List<String>? sources,
  }) {
    return _refresh(_matchRefreshArtistCoversPath, {
      if (sources != null) 'sources': sources,
    });
  }

  /// 批量刷新所有专辑图片（高危：遍历专辑搜索封面+新 guid 删旧）。
  Future<RefreshBatchResult> refreshAlbumCovers({
    List<String>? sources,
  }) {
    return _refresh(_matchRefreshAlbumCoversPath, {
      if (sources != null) 'sources': sources,
    });
  }

  /// 导入歌单（网易云/QQ/酷狗/酷我）。返回 {playlistId, name, total, matched, inserted, failed}。
  Future<Map<String, dynamic>> importPlaylist(String url) async {
    final base = baseUrl;
    if (base == null) throw StateError('未配置服务器地址');
    final Map<String, dynamic> data;
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '$base$_playlistImportPath',
        data: {'url': url},
        options: Options(
          headers: {..._authHeaders(), 'Content-Type': 'application/json'},
          sendTimeout: const Duration(minutes: 1),
          receiveTimeout: const Duration(minutes: 5),
        ),
      );
      data = response.data ?? const {};
    } on DioException catch (e) {
      throw Exception(companionErrorText(e));
    }
    if (data['code'] != 0) {
      throw Exception(data['msg'] as String? ?? '导入歌单失败');
    }
    final payload = data['data'];
    return payload is Map<String, dynamic> ? payload : const {};
  }

  Map<String, String> _authHeaders() {
    return {
      'X-API-Key': FeiNiuApiClient.instance.token,
    };
  }
}
