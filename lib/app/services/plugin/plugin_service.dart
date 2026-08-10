import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'plugin_manifest.dart';
import 'plugin_result_parser.dart';
import 'plugin_store.dart';

/// 按数据源分组的搜索结果（对齐 Lyrico 多源搜索：结果按源分组展示）。
class GroupedSongResults {
  /// 源 id → 该源结果（保持源排序）。
  final List<SourceGroup> groups;

  const GroupedSongResults({this.groups = const []});

  /// 全部结果（合并拍平，供需要单列表的场景）。
  List<SongMatchResult> get flat =>
      groups.expand((g) => g.results).toList();

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

/// 插件服务：调度中心。
///
/// - 构建插件脚本（include 脚本 + 入口拼接，镜像 Lyrico ScriptSearchSourceFactory）；
/// - 经 MethodChannel `com.feiniu.music/match_plugin` 调原生 QuickJS 执行
///   `searchSongs` / `getLyrics` / `searchCovers`；
/// - 聚合多插件搜索结果；单插件失败隔离（不影响其他插件）。
class PluginService {
  PluginService._internal();

  static final PluginService instance = PluginService._internal();

  static const MethodChannel _channel = MethodChannel(
    'com.feiniu.music/match_plugin',
  );

  /// 单个插件调用超时（秒）。
  int callTimeoutSeconds = 20;

  /// 聚合搜索并发上限（默认 3；用户可在设置中调整）。
  int concurrencyLimit = 3;

  /// 数据源插件走原生 QuickJS（MethodChannel `com.feiniu.music/match_plugin`），
  /// 仅 Android 有实现。桌面端（Windows）显式禁用，返回空结果。
  static bool get _enabledOnPlatform => !kIsWeb && Platform.isAndroid;

  /// 搜索歌曲（聚合所有已启用且含 searchSongs 能力的插件），**按源分组**返回。
  ///
  /// 对齐 Lyrico：各源结果独立分组（不合并），供按源展示。
  Future<GroupedSongResults> searchSongs(
    String keyword, {
    int page = 1,
    int pageSize = 20,
  }) async {
    if (!_enabledOnPlatform) return const GroupedSongResults();
    final plugins = await PluginStore.instance.getPlugins();
    final candidates = plugins
        .where((p) => p.enabled && p.hasCapability(PluginCapability.searchSongs))
        .toList();
    if (candidates.isEmpty) return const GroupedSongResults();

    final results = await mapConcurrent(candidates, concurrencyLimit, (plugin) async {
      try {
        final raw = await _call(plugin, 'searchSongs', {
          'keyword': keyword,
          'page': page,
          'pageSize': pageSize,
          'separator': '/',
          'config': plugin.config,
        });
        return SourceGroup(
          pluginId: plugin.manifest.id,
          pluginName: plugin.manifest.name,
          results: parseSongResults(
            raw,
            plugin.manifest.id,
            plugin.manifest.name,
          ),
        );
      } catch (e) {
        debugPrint('插件 ${plugin.manifest.name} searchSongs 失败: $e');
        return const SourceGroup(pluginId: '', pluginName: '', results: []);
      }
    });
    final groups = results
        .where((g) => g.pluginId.isNotEmpty && g.results.isNotEmpty)
        .toList();
    return GroupedSongResults(groups: groups);
  }

  /// 搜索封面（聚合所有已启用且含 searchCovers 能力的插件）。
  ///
  /// [searchType] 透传给插件（QQ 音乐：0=歌曲 1=歌手 2=专辑，默认 0），
  /// 用于按实体类型搜索封面；不支持的插件忽略该参数。
  Future<List<SongMatchResult>> searchCovers(
    String keyword, {
    int page = 1,
    int pageSize = 5,
    int searchType = 0,
  }) async {
    if (!_enabledOnPlatform) return [];
    final plugins = await PluginStore.instance.getPlugins();
    final candidates = plugins
        .where(
            (p) => p.enabled && p.hasCapability(PluginCapability.searchCovers))
        .toList();
    if (candidates.isEmpty) return [];

    final results = await mapConcurrent(candidates, concurrencyLimit, (plugin) async {
      try {
        final raw = await _call(plugin, 'searchCovers', {
          'keyword': keyword,
          'page': page,
          'pageSize': pageSize,
          'search_type': searchType,
          'config': plugin.config,
        });
        return parseSongResults(
          raw,
          plugin.manifest.id,
          plugin.manifest.name,
          requireId: false,
        );
      } catch (e) {
        debugPrint('插件 ${plugin.manifest.name} searchCovers 失败: $e');
        return <SongMatchResult>[];
      }
    });
    return results.expand((e) => e).toList();
  }

  /// 获取歌词（聚合所有已启用且含 getLyrics 能力的插件）。
  Future<List<LyricMatchResult>> getLyricsCandidates({
    required String songId,
    required String title,
    required String artist,
    required String album,
    int duration = 0,
    String? pluginId,
    Map<String, String>? internal,
  }) async {
    if (!_enabledOnPlatform) return [];
    final plugins = await PluginStore.instance.getPlugins();
    final candidates = plugins
        .where((p) =>
            p.enabled &&
            p.hasCapability(PluginCapability.getLyrics) &&
            (pluginId == null || p.manifest.id == pluginId))
        .toList();
    if (candidates.isEmpty) return [];

    final fallback = {'title': title, 'artist': artist};
    final results = await mapConcurrent(candidates, concurrencyLimit, (plugin) async {
      try {
        final song = {
          'id': songId,
          'title': title,
          'artist': artist,
          'album': album,
          'duration': duration,
          'sourceId': plugin.manifest.id,
          'pluginId': plugin.manifest.id,
          'fields': <String, String>{},
          'internal': internal ?? <String, String>{},
        };
        final raw = await _call(plugin, 'getLyrics', {
          'song': song,
          'page': 1,
          'pageSize': 20,
          'config': plugin.config,
        });
        return parseLyricsCandidates(
          raw,
          plugin.manifest.id,
          plugin.manifest.name,
          fallbackSong: fallback,
        );
      } catch (e) {
        debugPrint('插件 ${plugin.manifest.name} getLyrics 失败: $e');
        return <LyricMatchResult>[];
      }
    });
    return results.expand((e) => e).toList();
  }

  /// 调用原生 QuickJS 执行插件函数，返回原始 JSON 字符串。
  Future<String> _call(
    InstalledPlugin plugin,
    String method,
    Map<String, dynamic> request,
  ) async {
    final script = await buildScript(plugin);
    final cacheRoot = PluginStore.instance.cacheRootDir;
    final result = await _channel
        .invokeMethod<String>(method, {
          'script': script,
          'pluginId': plugin.manifest.id,
          'cacheRootDir': cacheRoot,
          // MethodChannel 传 Map 到 Kotlin 后按字符串读会得到 null，
          // 必须先把请求 JSON 编码成字符串（Kotlin 侧 call.argument<String>）。
          'requestJson': jsonEncode(request),
        })
        .timeout(Duration(seconds: callTimeoutSeconds));
    if (result == null) throw Exception('插件返回空结果');
    return result;
  }

  /// 构建插件完整脚本（include 脚本 + 入口，镜像 Lyrico）。
  Future<String> buildScript(InstalledPlugin plugin) async {
    final dir = plugin.dirPath;
    final includeSources = <({String path, String content})>[];
    for (final includeDir in plugin.manifest.includeDirs) {
      final dirPath = p.join(dir, includeDir);
      if (!Directory(dirPath).existsSync()) continue;
      final files = Directory(dirPath)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.js'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        final rel = p.relative(file.path, from: p.join(dir, includeDir));
        includeSources.add((
          path: '$includeDir/${rel.replaceAll('\\', '/')}',
          content: file.readAsStringSync(),
        ));
      }
    }

    final includePaths = includeSources.map((s) => s.path).toList();
    final includeBootstrap = '''
(function() {
  var __lyricoDeclaredIncludes = ${_jsonEncodeList(includePaths)};
  var __lyricoDeclaredIncludeMap = Object.create(null);
  __lyricoDeclaredIncludes.forEach(function(path) {
    __lyricoDeclaredIncludeMap[path] = true;
  });
  globalThis.include = function(path) {
    path = String(path || "");
    if (!Object.prototype.hasOwnProperty.call(__lyricoDeclaredIncludeMap, path)) {
      throw new Error("Include path is not declared in includeDirs: " + path);
    }
  };
})();
''';

    final entryFile = File(p.join(dir, plugin.manifest.entry));
    if (!entryFile.existsSync()) {
      throw Exception('插件入口脚本不存在: ${plugin.manifest.entry}');
    }

    final buffer = StringBuffer()
      ..write(includeBootstrap)
      ..writeln();
    for (final source in includeSources) {
      buffer
        ..writeln(';')
        ..writeln('// ===== Platform include: ${source.path} =====')
        ..write(source.content)
        ..writeln()
        ..writeln('//# sourceURL=${source.path}');
    }
    buffer
      ..writeln(';')
      ..writeln('// ===== Platform entry: ${plugin.manifest.entry} =====')
      ..write(entryFile.readAsStringSync())
      ..writeln()
      ..writeln('//# sourceURL=${plugin.manifest.entry}');
    return buffer.toString();
  }

  /// 限流并发 map（[limit] 个并发执行 [action]，收集结果）。
  ///
  /// action 抛出的异常会向上传播（调用方自行捕获）；成功时收集返回结果。
  /// 供插件聚合搜索与批量匹配共用。
  static Future<List<R>> mapConcurrent<T, R>(
    List<T> items,
    int limit,
    Future<R> Function(T item) action,
  ) async {
    final results = <R?>[];
    if (items.isEmpty) return results.whereType<R>().toList();
    final safeLimit = limit.clamp(1, items.length);
    var index = 0;

    Future<void> worker() async {
      while (true) {
        final next = index++;
        if (next >= items.length) break;
        results.add(await action(items[next]));
      }
    }

    await Future.wait(
      List.generate(safeLimit, (_) => worker()),
    );
    return results.whereType<R>().toList();
  }

  /// 限流并发执行（不收集结果，action 内部已隔离异常）。
  static Future<void> mapConcurrentEach<T>(
    List<T> items,
    int limit,
    Future<void> Function(T item) action,
  ) async {
    await mapConcurrent<T, void>(items, limit, action);
  }

  String _jsonEncodeList(List<String> values) {
    return jsonEncode(values);
  }
}
