import 'package:dio/dio.dart';

import '../feiniu/api_client.dart';
import '../feiniu/folder_models.dart';

/// FnMusicEnhance 服务端增强 —— 文件夹视图服务。
///
/// 服务端增强运行在飞牛 NAS 上（监听 38200 端口），读取 music.db 的
/// `shared_library` / `audio_file` 表提供按目录浏览音乐文件的能力：
/// `GET /music/api/v1/folder/list?path=<相对路径>`。
///
/// 仅非中继（relayMode == false）连接下可用：中继时 NAS 内网端口不暴露。
/// 基础 URL 取 `FeiNiuApiClient.instance.baseUrl` 的主机 + `:38200`。
/// X-API-Key 携带飞牛音乐登录 token（`FeiNiuApiClient.token`）。
class FolderCompanionService {
  FolderCompanionService._internal();

  static final FolderCompanionService instance = FolderCompanionService._internal();

  static const int port = 38200;
  static const String _apiPath = '/music/api/v1/folder/list';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 15),
      responseType: ResponseType.json,
      validateStatus: (code) => code != null && code < 500,
    ),
  );

  /// 内存 TTL 缓存（路径 → 目录内容），返回上级目录时避免重复请求。
  static const Duration _ttl = Duration(minutes: 5);
  final Map<String, _CacheEntry> _cache = {};

  /// 当前是否可用（非中继连接 + 已登录）。
  bool get available {
    final api = FeiNiuApiClient.instance;
    return !api.relayMode && api.baseUrl.isNotEmpty && api.token.isNotEmpty;
  }

  /// 构造服务端增强基础 URL：`http://<NAS-host>:38200`。
  ///
  /// NAS-host 取自 `FeiNiuApiClient.baseUrl` 的主机部分。仅非 relay 时有效。
  String? get baseUrl {
    final api = FeiNiuApiClient.instance;
    if (api.relayMode || api.baseUrl.isEmpty) return null;
    final host = Uri.tryParse(api.baseUrl)?.host;
    if (host == null || host.isEmpty) return null;
    return 'http://$host:$port';
  }

  /// 获取某目录的文件夹/文件列表（分页）。
  ///
  /// [path] 为库内相对路径（`/` 或 `/子目录`）。[keyword] 非空时在当前目录
  /// 范围内（含子文件夹）按文件名/曲目标题过滤。[flatten] 为 true 时平铺
  /// 返回当前目录树所有歌曲（不按目录分组）。[sort] 排序键
  /// （name/createdAt/duration/size），[asc] 升序。[page] 从 1 起，[pageSize]
  /// 默认 100。[forceRefresh] 为 true 时跳过缓存直接拉取。失败抛异常。
  Future<FolderListing> list({
    required String path,
    String keyword = '',
    bool flatten = false,
    String sort = 'name',
    bool asc = true,
    int page = 1,
    int pageSize = 100,
    bool forceRefresh = false,
  }) async {
    final base = baseUrl;
    if (base == null) throw StateError('中继连接下不可用');
    final cacheKey = '$path#$keyword#$flatten#$sort#$asc#$page#$pageSize';
    if (!forceRefresh) {
      final hit = _cache[cacheKey];
      if (hit != null && DateTime.now().isBefore(hit.expiresAt)) {
        return hit.data;
      }
    }
    final response = await _dio.get<Map<String, dynamic>>(
      '$base$_apiPath',
      queryParameters: {
        'path': path,
        if (keyword.isNotEmpty) 'keyword': keyword,
        if (flatten) 'flatten': 'true',
        'sort': sort,
        'asc': asc ? 'true' : 'false',
        'page': page,
        'size': pageSize,
      },
      options: Options(headers: _authHeaders()),
    );
    final data = response.data;
    if (data == null || data['code'] != 0) {
      throw Exception(data?['msg'] as String? ?? '获取文件夹内容失败');
    }
    final payload = data['data'];
    if (payload is! Map<String, dynamic>) {
      throw Exception('获取文件夹内容失败：服务端返回数据异常');
    }
    final listing = FolderListing.fromJson(payload);
    _cache[cacheKey] = _CacheEntry(listing, DateTime.now().add(_ttl));
    return listing;
  }

  /// 清空目录缓存（下拉刷新后调用，保证重新进入目录拿到最新文件）。
  void clearCache() {
    _cache.clear();
  }

  Map<String, String> _authHeaders() {
    return {
      'X-API-Key': FeiNiuApiClient.instance.token,
    };
  }
}

/// 目录列表缓存项：数据 + 过期时间。
class _CacheEntry {
  final FolderListing data;
  final DateTime expiresAt;

  _CacheEntry(this.data, this.expiresAt);
}
