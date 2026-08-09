import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../state/settings_match.dart';
import '../companion/metadata_companion_service.dart';
import '../feiniu/api_client.dart';
import '../feiniu/api_models.dart';
import '../plugin/plugin_result_parser.dart';
import '../plugin/plugin_service.dart';

/// 可匹配的字段（用户可在批量匹配确认页选择应用哪些）。
enum MatchField {
  title,
  artist,
  album,
  year,
  trackNumber,
  discNumber,
  cover,
  lyrics,
}

extension MatchFieldLabel on MatchField {
  String get label => switch (this) {
        MatchField.title => '标题',
        MatchField.artist => '歌手',
        MatchField.album => '专辑',
        MatchField.year => '年份',
        MatchField.trackNumber => '歌曲序号',
        MatchField.discNumber => '光盘序号',
        MatchField.cover => '封面',
        MatchField.lyrics => '歌词',
      };
}

/// 匹配写入模式：覆盖（用匹配结果覆盖现有值）或填充（仅当现有值为空时写入）。
enum MatchWriteMode {
  overwrite,
  fill,
}

extension MatchWriteModeLabel on MatchWriteMode {
  String get label =>
      this == MatchWriteMode.overwrite ? '覆盖' : '填充（仅空值）';

  String get description => this == MatchWriteMode.overwrite
      ? '用匹配到的结果覆盖当前歌曲的对应字段'
      : '仅当当前字段为空时才写入匹配结果';
}

/// 批量匹配选项（用户在确认页选择）。
class MatchOptions {
  final Set<MatchField> fields;
  final MatchWriteMode writeMode;
  final bool autoConfirmCandidates; // true=取第一个候选；false=逐首弹候选确认

  const MatchOptions({
    this.fields = const {
      MatchField.title,
      MatchField.artist,
      MatchField.album,
    },
    this.writeMode = MatchWriteMode.fill,
    this.autoConfirmCandidates = true,
  });
}

/// 单曲匹配结果（应用到一个 SongEntity 的字段）。
class SongMatchPatch {
  final String title;
  final String artist; // 匹配到的歌手名（多歌手用分隔符）
  final String album;
  final String year;
  final String trackNumber;
  final String discNumber;
  final String? coverBytes; // base64 或 null；由上层转为上传
  final String? coverUrl;

  /// 匹配到的歌词（LRC 文本）；未获取时为 null。
  final String? lyrics;

  const SongMatchPatch({
    required this.title,
    required this.artist,
    required this.album,
    this.year = '',
    this.trackNumber = '',
    this.discNumber = '',
    this.coverBytes,
    this.coverUrl,
    this.lyrics,
  });
  bool get hasCover => coverBytes != null || (coverUrl?.isNotEmpty ?? false);
}

/// 歌曲匹配服务：把 Lyrico 插件搜索候选转换为可应用到歌曲的补丁。
class SongMatchService {
  SongMatchService._internal();

  static final SongMatchService instance = SongMatchService._internal();

  final PluginService _pluginService = PluginService.instance;
  final FeiNiuApiClient _api = FeiNiuApiClient.instance;

  /// 搜索匹配候选（聚合所有插件的 searchSongs），**按源分组**返回。
  Future<GroupedSongResults> searchCandidates(
    String keyword, {
    int page = 1,
    int pageSize = 20,
  }) {
    return _pluginService.searchSongs(keyword, page: page, pageSize: pageSize);
  }

  /// 搜索封面候选（聚合所有插件的 searchCovers）。
  Future<List<SongMatchResult>> searchCovers(
    String keyword, {
    int page = 1,
    int pageSize = 10,
  }) {
    return _pluginService.searchCovers(keyword, page: page, pageSize: pageSize);
  }

  /// 构造搜索关键词。
  ///
  /// [preferFilename] 开关开启时（[MatchSettings.preferFilename]），优先用
  /// 音频文件名（去扩展名）作为关键词，忽略内置标题/歌手标签；否则用
  /// 标题 + 歌手。
  ///
  /// 文件名模式匹配时自动过滤开头序号（如 `01. 歌名`、`01 - 歌名`、
  /// `01-歌名`、`[01] 歌名`）。
  ///
  /// [filePath] 为音频文件路径（`FeiNiuAudioSpec.path`），用于提取文件名。
  String buildKeyword({
    required String title,
    required String artist,
    String? filePath,
    bool? preferFilename,
  }) {
    final useFilename = preferFilename ?? MatchSettings.preferFilename.value;
    if (useFilename && filePath != null && filePath.isNotEmpty) {
      var name = p.basenameWithoutExtension(filePath).trim();
      // 过滤开头序号：数字 + 分隔符（`.`/`-`/`_`/空格/`]`）前缀
      name = name.replaceFirst(
        RegExp(r'^(?:\d{1,3}|\[?\d{1,3}\]?)[\s.\-_·]*(?=[^\s\d.])'),
        '',
      );
      name = name.trim();
      if (name.isNotEmpty) return name;
    }
    return [
      title,
      artist,
    ].where((s) => s.isNotEmpty).join(' ').trim();
  }

  /// 从文件路径提取文件名（去扩展名）；无效返回空。
  static String filenameFromPath(String? filePath) {
    if (filePath == null || filePath.isEmpty) return '';
    return p.basenameWithoutExtension(filePath).trim();
  }

  /// 把选中的候选应用为补丁（标题/歌手/专辑/年份 + 可选封面下载）。
  ///
  /// [downloadCover] 为 true 时下载候选 picUrl 到内存（失败则补丁不带封面）。
  Future<SongMatchPatch> buildPatch(
    SongMatchResult candidate, {
    bool downloadCover = false,
  }) async {
    String? coverBytes;
    if (downloadCover && candidate.picUrl.isNotEmpty) {
      coverBytes = await _downloadCoverToBase64(candidate.picUrl);
    }
    return SongMatchPatch(
      title: candidate.title,
      artist: candidate.artist,
      album: candidate.album,
      year: candidate.date,
      trackNumber: candidate.trackNumber,
      discNumber: candidate.discNumber,
      coverBytes: coverBytes,
      coverUrl: candidate.picUrl,
    );
  }

  /// 从数据源插件获取候选歌词（LRC），取第一个有内容的候选。
  ///
  /// 返回 null 表示未获取到歌词。
  Future<String?> fetchLyrics({
    required String title,
    required String artist,
    String album = '',
    int duration = 0,
    String? sourceId, // 源平台歌曲 id（来自 searchSongs 候选），供 getLyrics 定位
    Map<String, String>? sourceInternal,
    String? pluginId, // 候选来自哪个插件（getLyrics 需同插件）
  }) async {
    final candidates = await _pluginService.getLyricsCandidates(
      songId: sourceId ?? title, // 优先用源平台 id，无则标题占位
      title: title,
      artist: artist,
      album: album,
      duration: duration,
      pluginId: pluginId,
      internal: sourceInternal,
    );
    if (candidates.isEmpty) return null;
    // 按歌词模式（逐字/增强逐字/逐行/TTML）+ 翻译/罗马音偏好选择歌词。
    final mode = MatchSettings.lyricMode.value;
    final includeTranslation = MatchSettings.translation.value;
    final includeRomanization = MatchSettings.romanization.value;
    final onlyTranslation = MatchSettings.onlyTranslation.value;

    // TTML 模式：优先找 rawTtml 类型候选（Apple 等插件），否则退回普通处理。
    if (mode == LyricMode.ttml) {
      for (final candidate in candidates) {
        if (candidate.type == 'rawTtml' && candidate.rawTtml.isNotEmpty) {
          return candidate.rawTtml;
        }
      }
      // 无 rawTtml 候选时退回 structured → 生成 TTML
      for (final candidate in candidates) {
        final text = candidate.lyricsFor(
          mode,
          includeTranslation: includeTranslation,
          includeRomanization: includeRomanization,
          onlyTranslation: onlyTranslation,
        );
        if (text.isNotEmpty) return text;
      }
      return null;
    }

    for (final candidate in candidates) {
      final text = candidate.lyricsFor(
        mode,
        includeTranslation: includeTranslation,
        includeRomanization: includeRomanization,
        onlyTranslation: onlyTranslation,
      );
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  /// 把匹配到的歌手名解析为飞牛 FeiNiuArtist（用于 artistGUIDs）。
  ///
  /// 按名字精确匹配；**匹配不到时自动调用 `/artist/create` 新建歌手**
  /// （避免匹配结果因歌手不存在而丢失）。新建失败时跳过该名字。
  /// [separator] 支持多歌手分隔符拆分。
  Future<List<FeiNiuArtist>> resolveArtists(
    String artistNames, {
    String separator = '/',
  }) async {
    if (artistNames.trim().isEmpty) return [];
    final artists = await _api.getArtistListAll();
    if (artists.isEmpty) return [];

    final names = artistNames
        .split(RegExp(RegExp.escape(separator)))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    final byName = <String, FeiNiuArtist>{};
    for (final artist in artists) {
      byName[artist.name] = artist;
    }

    final resolved = <FeiNiuArtist>[];
    for (final name in names) {
      final match = byName[name];
      if (match != null && !resolved.contains(match)) {
        resolved.add(match);
        continue;
      }
      if (match == null) {
        // 库中不存在 → 自动创建，保证匹配的歌手名能正确关联
        try {
          final created = await _api.createArtist(name);
          byName[created.name] = created;
          if (!resolved.contains(created)) resolved.add(created);
        } catch (e) {
          debugPrint('创建歌手 "$name" 失败: $e');
        }
      }
    }
    return resolved;
  }

  /// 把匹配到的专辑名解析为飞牛 FeiNiuAlbum（用于回填专辑 guid）。
  ///
  /// 按名字精确匹配；**匹配不到且服务端增强可用时自动创建专辑**（主 API 无
  /// `album/create`，走服务端增强 `createEntity`），避免服务端按字符串隐式新建出
  /// 重复专辑。服务端增强不可用（中继 / 未登录）或创建失败返回 null
  /// （调用方回退原专辑字符串）。
  Future<FeiNiuAlbum?> resolveAlbum(String albumName) async {
    final name = albumName.trim();
    if (name.isEmpty) return null;

    // 先在库中精确匹配
    final albums = await _api.getAlbumListAll();
    for (final album in albums) {
      if (album.name == name) return album;
    }

    // 库中不存在 → 服务端增强创建（仅非中继直连 + 已登录时可用）
    if (!MetadataCompanionService.instance.available) return null;
    try {
      final guid = await MetadataCompanionService.instance
          .createEntity(kind: EntityEditKind.album, name: name);
      return FeiNiuAlbum(guid: guid, name: name);
    } catch (e) {
      debugPrint('创建专辑 "$name" 失败: $e');
      return null;
    }
  }

  /// 下载候选封面为 base64（供 [FeiNiuApiClient.uploadTrackCover] 上传 NAS）。
  ///
  /// 超时 15s；失败返回 null。
  Future<String?> _downloadCoverToBase64(String url) async {
    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
          responseType: ResponseType.bytes,
          validateStatus: (code) => code != null && code >= 200 && code < 300,
        ),
      );
      final response = await dio.get<Uint8List>(url);
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) return null;
      return _base64Encode(bytes);
    } catch (e) {
      return null;
    }
  }

  String _base64Encode(List<int> bytes) {
    // 手动 base64 编码（避免额外依赖 base64 包）
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    final buffer = StringBuffer();
    var i = 0;
    while (i + 2 < bytes.length) {
      final n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
      buffer
        ..write(chars[(n >> 18) & 63])
        ..write(chars[(n >> 12) & 63])
        ..write(chars[(n >> 6) & 63])
        ..write(chars[n & 63]);
      i += 3;
    }
    if (i + 1 == bytes.length) {
      final n = bytes[i] << 16;
      buffer
        ..write(chars[(n >> 18) & 63])
        ..write(chars[(n >> 12) & 63])
        ..write('==');
    } else if (i + 2 == bytes.length) {
      final n = (bytes[i] << 16) | (bytes[i + 1] << 8);
      buffer
        ..write(chars[(n >> 18) & 63])
        ..write(chars[(n >> 12) & 63])
        ..write(chars[(n >> 6) & 63])
        ..write('=');
    }
    return buffer.toString();
  }
}
