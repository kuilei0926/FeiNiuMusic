import 'package:dio/dio.dart';

import 'api_client.dart';
import 'folder_models.dart';

/// 飞牛音乐官方文件夹视图服务。
///
/// 根目录通过 `GET /shared-library/list` 获取共享音乐库；进入具体目录后
/// 使用 `GET /folder-view/list?parentPath=<绝对路径>` 逐层读取。
class FeiNiuFolderService {
  FeiNiuFolderService._internal();

  static final FeiNiuFolderService instance = FeiNiuFolderService._internal();

  final FeiNiuApiClient _api = FeiNiuApiClient.instance;

  static const Duration _ttl = Duration(minutes: 5);
  final Map<String, _CacheEntry<FolderListing>> _directoryCache = {};
  final Map<String, _CacheEntry<FolderListing>> _flattenCache = {};
  _CacheEntry<List<SharedMusicLibrary>>? _librariesCache;

  bool get available => _api.baseUrl.isNotEmpty && _api.token.isNotEmpty;

  /// 获取某目录的文件夹/曲目列表。
  ///
  /// [path] 为虚拟根目录 `/` 或共享库内绝对路径（如
  /// `/vol3/1000/Music`）。[keyword] 在当前已读取范围内过滤；[flatten]
  /// 会递归读取当前目录树并按歌曲平铺返回。排序与分页在客户端完成，
  /// 因为官方 folder-view 接口一次返回当前目录的完整内容。
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
    if (!available) {
      throw StateError('请先登录飞牛音乐');
    }
    if (forceRefresh) clearCache();

    final source = flatten
        ? await _loadFlattened(path)
        : await _loadDirectory(path);
    final query = keyword.trim().toLowerCase();
    final folders = query.isEmpty
        ? source.folders
        : source.folders
              .where((folder) => folder.name.toLowerCase().contains(query))
              .toList();
    final files = query.isEmpty
        ? [...source.files]
        : source.files.where((file) => _matches(file, query)).toList();
    files.sort((a, b) => _compareFiles(a, b, sort: sort, asc: asc));

    final total = files.fold<int>(0, (sum, file) => sum + file.tracks.length);
    final safePage = page < 1 ? 1 : page;
    final safePageSize = pageSize < 1 ? 100 : pageSize;
    final start = (safePage - 1) * safePageSize;
    final pageFiles = start >= files.length
        ? const <FolderFile>[]
        : files.sublist(start, (start + safePageSize).clamp(0, files.length));

    return FolderListing(
      libraryRoot: source.libraryRoot,
      path: source.path,
      parent: source.parent,
      folders: folders,
      files: pageFiles,
      total: total,
      fileTotal: files.length,
    );
  }

  /// 清空文件夹与共享库缓存。
  void clearCache() {
    _directoryCache.clear();
    _flattenCache.clear();
    _librariesCache = null;
  }

  Future<FolderListing> _loadDirectory(String path) async {
    if (path == '/') {
      final libraries = await _loadLibraries();
      return FolderListing.root([
        for (final library in libraries)
          FolderDir(
            name: library.displayName,
            path: library.path,
            itemCount: library.itemCount,
          ),
      ]);
    }

    final cached = _cacheHit(_directoryCache, path);
    if (cached != null) return cached;

    final libraries = await _loadLibraries();
    final libraryRoot = _libraryRootFor(path, libraries);
    final Map<String, dynamic> data;
    try {
      data = await _api.getFolderViewList(path);
    } on DioException catch (error) {
      throw Exception(_folderErrorText(error));
    }
    final listing = FolderListing.fromFolderView(
      data,
      libraryRoot: libraryRoot,
      parent: _parentFor(path, libraryRoot),
    );
    _directoryCache[path] = _CacheEntry(listing, DateTime.now().add(_ttl));
    return listing;
  }

  Future<FolderListing> _loadFlattened(String path) async {
    final cached = _cacheHit(_flattenCache, path);
    if (cached != null) return cached;

    final libraries = await _loadLibraries();
    if (path == '/') {
      final files = <FolderFile>[];
      for (final library in libraries) {
        final listing = await _flattenDirectory(
          library.path,
          libraryRoot: library.path,
          visited: <String>{},
        );
        files.addAll(listing.files);
      }
      final result = FolderListing(
        libraryRoot: '',
        path: '/',
        files: files,
        total: _trackCount(files),
        fileTotal: files.length,
      );
      _flattenCache[path] = _CacheEntry(result, DateTime.now().add(_ttl));
      return result;
    }

    final result = await _flattenDirectory(
      path,
      libraryRoot: _libraryRootFor(path, libraries),
      visited: <String>{},
    );
    _flattenCache[path] = _CacheEntry(result, DateTime.now().add(_ttl));
    return result;
  }

  Future<FolderListing> _flattenDirectory(
    String path, {
    required String libraryRoot,
    required Set<String> visited,
  }) async {
    if (!visited.add(path)) {
      return FolderListing(libraryRoot: libraryRoot, path: path);
    }
    final directory = await _loadDirectory(path);
    final files = <FolderFile>[...directory.files];
    for (final folder in directory.folders) {
      final child = await _flattenDirectory(
        folder.path,
        libraryRoot: libraryRoot,
        visited: visited,
      );
      files.addAll(child.files);
    }
    return FolderListing(
      libraryRoot: libraryRoot,
      path: path,
      parent: directory.parent,
      files: files,
      total: _trackCount(files),
      fileTotal: files.length,
    );
  }

  Future<List<SharedMusicLibrary>> _loadLibraries() async {
    final cached = _librariesCache;
    if (cached != null && DateTime.now().isBefore(cached.expiresAt)) {
      return cached.data;
    }

    try {
      final data = await _api.getSharedLibraryList();
      final libraries =
          (data['list'] as List<dynamic>?)
              ?.map((item) {
                if (item is! Map<String, dynamic>) return null;
                return SharedMusicLibrary.fromJson(item);
              })
              .whereType<SharedMusicLibrary>()
              .toList() ??
          const <SharedMusicLibrary>[];
      _librariesCache = _CacheEntry(libraries, DateTime.now().add(_ttl));
      return libraries;
    } on DioException catch (error) {
      throw Exception(_folderErrorText(error));
    }
  }

  String _libraryRootFor(String path, List<SharedMusicLibrary> libraries) {
    for (final library in libraries) {
      if (path == library.path || path.startsWith('${library.path}/')) {
        return library.path;
      }
    }
    throw StateError('该目录不属于当前账号的共享音乐库');
  }

  static String? _parentFor(String path, String libraryRoot) {
    if (path == libraryRoot || path == '/') return '/';
    final index = path.lastIndexOf('/');
    if (index <= 0) return '/';
    final parent = path.substring(0, index);
    return parent.startsWith(libraryRoot) ? parent : '/';
  }

  static int _trackCount(List<FolderFile> files) {
    return files.fold(0, (sum, file) => sum + file.tracks.length);
  }

  static bool _matches(FolderFile file, String query) {
    if (file.name.toLowerCase().contains(query) ||
        file.path.toLowerCase().contains(query)) {
      return true;
    }
    return file.tracks.any((track) {
      return track.title.toLowerCase().contains(query) ||
          (track.album?.toLowerCase().contains(query) ?? false) ||
          track.artists.any(
            (artist) => artist.name.toLowerCase().contains(query),
          );
    });
  }

  static int _compareFiles(
    FolderFile a,
    FolderFile b, {
    required String sort,
    required bool asc,
  }) {
    int result;
    switch (sort) {
      case 'createdAt':
        result = (a.createdAt ?? 0).compareTo(b.createdAt ?? 0);
      case 'duration':
        result = (a.durationMs ?? 0).compareTo(b.durationMs ?? 0);
      case 'size':
        result = (a.size ?? 0).compareTo(b.size ?? 0);
      default:
        result = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    }
    if (result == 0) {
      result = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    }
    return asc ? result : -result;
  }

  static String _folderErrorText(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
        return '连接超时：无法连接 NAS 音乐服务';
      case DioExceptionType.sendTimeout:
        return '发送超时：无法连接 NAS 音乐服务';
      case DioExceptionType.receiveTimeout:
        return '响应超时：NAS 音乐服务未响应';
      case DioExceptionType.transformTimeout:
        return '响应处理超时：NAS 音乐服务未响应';
      case DioExceptionType.connectionError:
        return '无法连接 NAS 音乐服务';
      case DioExceptionType.badResponse:
        return 'NAS 音乐服务返回异常（HTTP ${error.response?.statusCode}）';
      case DioExceptionType.cancel:
        return '请求已取消';
      case DioExceptionType.badCertificate:
        return 'NAS 音乐服务证书校验失败';
      case DioExceptionType.unknown:
        return error.message ?? '获取文件夹内容失败';
    }
  }
}

class _CacheEntry<T> {
  final T data;
  final DateTime expiresAt;

  const _CacheEntry(this.data, this.expiresAt);
}

T? _cacheHit<T>(Map<String, _CacheEntry<T>> cache, String key) {
  final entry = cache[key];
  if (entry == null || !DateTime.now().isBefore(entry.expiresAt)) return null;
  return entry.data;
}
