import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../state/settings_fn_state.dart';
import 'api_models.dart';

/// FeiNiu API 客户端 — 基于 Dio 的单例 HTTP 客户端
///
/// 所有请求自动携带 `Cookie: music-token=<token>` 认证。
/// 中继模式下额外携带 Cookie: mode=relay，并手动处理 302 重定向以保持中继 Cookie。
class FeiNiuApiClient {
  FeiNiuApiClient._() {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onError: (error, handler) {
          // 通知自动重连监听器
          for (final monitor in _reconnectMonitors) {
            monitor(error);
          }
          // 401 时自动清除 token，交给 AuthService 处理
          if (error.response?.statusCode == 401) {
            _clearToken();
          }
          handler.next(error);
        },
        onResponse: (response, handler) {
          // 收到响应即表示服务器可达，通知连接恢复监听器
          for (final monitor in _recoveryMonitors) {
            monitor();
          }
          // 全局处理 3xx 重定向（手动跟随以保持自定义 Cookie）
          final statusCode = response.statusCode ?? 0;
          if (statusCode >= 300 && statusCode < 400) {
            _handleRedirect(response)
                .then((result) {
                  handler.resolve(result);
                })
                .catchError((e) {
                  handler.next(e);
                });
            return;
          }
          handler.next(response);
        },
      ),
    );
  }

  static final FeiNiuApiClient instance = FeiNiuApiClient._();

  Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 15),
      followRedirects: false,
      maxRedirects: 0,
      validateStatus: (_) => true,
    ),
  );

  String _baseUrl = '';
  String _token = '';
  bool _relayMode = false;

  @visibleForTesting
  void setDioForTest(Dio dio) => _dio = dio;

  /// 网络失败监听回调列表（用于自动重连）
  final List<void Function(DioException)> _reconnectMonitors = [];

  /// 网络恢复监听回调列表（用于重置连接状态）
  final List<VoidCallback> _recoveryMonitors = [];

  // region Token / Auth / Relay 管理

  String get baseUrl => _baseUrl;
  String get token => _token;
  bool get relayMode => _relayMode;

  /// 注册网络失败监听（供 FnAutoReconnectService 使用）
  void addReconnectMonitor(void Function(DioException) callback) {
    _reconnectMonitors.add(callback);
  }

  /// 注册网络恢复监听（供连接状态横幅使用）
  void addRecoveryMonitor(VoidCallback callback) {
    _recoveryMonitors.add(callback);
  }

  /// 设置中继模式（供自动重连时使用）
  void setRelayMode(bool value) {
    _relayMode = value;
  }

  /// 从 SharedPreferences 读取已存储的 token、serverUrl 和 relay 模式
  Future<bool> tryLoadAuth() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('feiniu_music_token') ?? '';
    final serverUrl = prefs.getString('feiniu_server_url') ?? '';
    if (token.isNotEmpty && serverUrl.isNotEmpty) {
      _token = token;
      _baseUrl = serverUrl.endsWith('/')
          ? serverUrl.substring(0, serverUrl.length - 1)
          : serverUrl;
      _relayMode = prefs.getBool('feiniu_relay_mode') ?? false;
      return true;
    }
    return false;
  }

  /// 仅设置 baseUrl（不持久化 token），用于登录前设置
  Future<void> setBaseUrl(String baseUrl) async {
    _baseUrl = baseUrl.replaceAll(RegExp(r'/music/api/v1/*$'), '');
    _baseUrl = _baseUrl.endsWith('/')
        ? _baseUrl.substring(0, _baseUrl.length - 1)
        : _baseUrl;
  }

  /// 在内存中设置认证凭据并持久化
  Future<void> setAuth(
    String baseUrl,
    String token, {
    bool relayMode = false,
  }) async {
    // 去掉用户可能输入的 /music/api/v1 后缀
    _baseUrl = baseUrl.replaceAll(RegExp(r'/music/api/v1/*$'), '');
    _baseUrl = _baseUrl.endsWith('/')
        ? _baseUrl.substring(0, _baseUrl.length - 1)
        : _baseUrl;
    _token = token;
    _relayMode = relayMode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('feiniu_music_token', token);
    await prefs.setString('feiniu_server_url', _baseUrl);
    await prefs.setBool('feiniu_relay_mode', relayMode);
  }

  /// 清除认证凭据
  void _clearToken() {
    _token = '';
    SharedPreferences.getInstance().then((prefs) {
      prefs.remove('feiniu_music_token');
      prefs.remove('feiniu_server_url');
      prefs.remove('feiniu_relay_mode');
    });
  }

  Future<void> clearAuth() async {
    _token = '';
    _baseUrl = '';
    _relayMode = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('feiniu_music_token');
    // 保留 serverUrl 和 username 用于退出登录后自动填充
    // await prefs.remove('feiniu_server_url');
    // await prefs.remove('feiniu_username');
    await prefs.remove('feiniu_relay_mode');
  }

  /// 安全码请求头（未设置安全码时返回空）
  static Map<String, String> accessCodeHeaders() {
    final code = AppFnConnectionSettings.accessCode;
    if (code == null || code.isEmpty) return const {};
    return {
      'x-access-code': base64.encode(utf8.encode(code)),
      'x-access-source': 'app',
    };
  }

  /// 获取认证请求头
  ///
  /// 中继模式时自动追加 Cookie: mode=relay。
  /// 已设置安全码时自动携带 x-access-code / x-access-source。
  Map<String, String> authHeaders() {
    if (_relayMode) {
      return {'Cookie': 'music-token=$_token; mode=relay', ...accessCodeHeaders()};
    }
    return {'Cookie': 'music-token=$_token', ...accessCodeHeaders()};
  }

  /// 获取图片/音频等资源请求认证头（静态方法，用于 CachedNetworkImage 等）
  ///
  /// 中继模式时需携带 mode=relay cookie 验证身份。
  static Map<String, String> imageAuthHeaders() {
    final inst = instance;
    final token = inst._token;
    if (token.isEmpty) return accessCodeHeaders();
    return inst._relayMode
        ? {'Cookie': 'mode=relay; music-token=$token', ...accessCodeHeaders()}
        : {'Cookie': 'music-token=$token', ...accessCodeHeaders()};
  }

  /// 手动处理 3xx 重定向
  ///
  /// 保持请求头（Cookie 等）不丢失。最多跟 5 跳避免死循环。
  Future<Response> _handleRedirect(Response response, {int depth = 0}) async {
    if (depth >= 5) {
      if (kDebugMode) {
        debugPrint(
          '[ApiClient] Redirect depth exceeded, returning last response',
        );
      }
      return response;
    }

    var location = response.headers.value('location');
    if (location == null || location.isEmpty) {
      return response;
    }

    // 相对路径转绝对
    final baseUri = Uri.tryParse(_baseUrl);
    if (baseUri == null) return response;
    final redirectUri = baseUri.resolve(location);

    if (kDebugMode) {
      debugPrint('[ApiClient] 3xx → $redirectUri (depth=$depth)');
    }

    // 获取原始请求中的 Cookie（保持原始请求头不变）
    final originalCookie =
        response.requestOptions.headers['Cookie'] as String? ??
        response.requestOptions.headers['cookie'] as String?;
    // 如果没有原始 Cookie，再根据当前状态构造一个兜底
    final effectiveCookie =
        originalCookie ??
        (_relayMode
            ? 'music-token=$_token; mode=relay'
            : 'music-token=$_token');
    final redirectResponse = await _dio.requestUri(
      redirectUri,
      options: Options(
        method: response.requestOptions.method,
        headers: {'Cookie': effectiveCookie, ...accessCodeHeaders()},
        followRedirects: false,
        validateStatus: (_) => true,
        responseType: ResponseType.json,
      ),
      data: response.requestOptions.data,
    );

    // 如果返回值还是 3xx，继续跟
    final nextStatus = redirectResponse.statusCode ?? 0;
    if (nextStatus >= 300 && nextStatus < 400) {
      return _handleRedirect(redirectResponse, depth: depth + 1);
    }

    return redirectResponse;
  }

  /// API 基础路径前缀
  static const String _apiPrefix = '/music/api/v1';

  /// 拼接完整 API URL（自动添加 /music/api/v1 前缀）
  String _url(String path) {
    final p = path.startsWith('/') ? path : '/$path';
    return '$_baseUrl$_apiPrefix$p';
  }

  // endregion

  // region 通用请求方法

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    final response = await _dio.get(
      _url(path),
      queryParameters: queryParameters,
      options: Options(headers: authHeaders()),
    );
    return response.data is Map<String, dynamic>
        ? response.data as Map<String, dynamic>
        : <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _post(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
  }) async {
    final response = await _dio.post(
      _url(path),
      data: data,
      queryParameters: queryParameters,
      options: Options(headers: authHeaders()),
    );
    return response.data is Map<String, dynamic>
        ? response.data as Map<String, dynamic>
        : <String, dynamic>{};
  }

  /// 解析通用分页响应
  FeiNiuPageData<T> _parsePage<T>(
    Map<String, dynamic> data,
    T Function(Map<String, dynamic>) fromItem,
  ) {
    final list =
        (data['list'] as List<dynamic>?)
            ?.map((e) => fromItem(e as Map<String, dynamic>))
            .toList() ??
        [];
    return FeiNiuPageData(
      list: list,
      total: data['total'] as int? ?? 0,
      sort: data['sort'] as String?,
    );
  }

  // endregion

  // region 1. 用户登录

  /// SHA256 哈希
  static String sha256(String input) {
    final bytes = utf8.encode(input);
    final digest = crypto.sha256.convert(bytes);
    return digest.toString();
  }

  /// 生成设备 ID（32 位 hex）
  static String generateDeviceId() {
    final random = Random();
    return List.generate(
      16,
      (_) => random.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 密码登录
  Future<LoginResponse> login(
    String username,
    String password,
    String deviceId, {
    bool relayMode = false,
  }) async {
    final hashedPassword = sha256(password);
    final response = await _dio.post(
      _url('/user/password-login'),
      data: {
        'username': username,
        'password': hashedPassword,
        'deviceId': deviceId,
      },
      options: Options(
        headers: {
          if (relayMode) 'Cookie': 'mode=relay',
          ...accessCodeHeaders(),
        },
      ),
    );
    final data = response.data is Map<String, dynamic>
        ? response.data as Map<String, dynamic>
        : <String, dynamic>{};
    final parsed = FeiNiuResponse<LoginResponse>.fromJson(
      data,
      (d) => LoginResponse.fromJson(d as Map<String, dynamic>),
    );
    if (!parsed.isSuccess || parsed.data == null) {
      throw Exception(parsed.msg.isNotEmpty ? parsed.msg : '登录失败');
    }
    return parsed.data!;
  }

  // endregion

  // region 2. 获取音乐列表

  Future<FeiNiuPageData<FeiNiuTrack>> getTrackList({
    int page = 1,
    int size = 50,
    String? sort,
  }) async {
    final params = <String, dynamic>{'page': page, 'size': size};
    if (sort != null) params['sort'] = sort;
    final data = await _get('/track/list', queryParameters: params);
    final response = FeiNiuResponse.fromJson(
      data,
      (d) => _parsePage(d as Map<String, dynamic>, FeiNiuTrack.fromJson),
    );
    return response.data ?? const FeiNiuPageData(list: [], total: 0);
  }

  // endregion

  // region 5/18. 风格列表

  Future<FeiNiuPageData<FeiNiuGenre>> getGenreList({
    int page = 1,
    int size = 200,
    String? sort,
  }) async {
    final params = <String, dynamic>{'page': page, 'size': size};
    if (sort != null) params['sort'] = sort;
    final data = await _get('/genre/list', queryParameters: params);
    final response = FeiNiuResponse.fromJson(
      data,
      (d) => _parsePage(d as Map<String, dynamic>, FeiNiuGenre.fromJson),
    );
    return response.data ?? const FeiNiuPageData(list: [], total: 0);
  }

  Future<FeiNiuPageData<FeiNiuTrack>> getGenreTracks({
    required String genreGUID,
    int page = 1,
    int size = 300,
    String? sort,
  }) async {
    final params = <String, dynamic>{
      'genreGUID': genreGUID,
      'page': page,
      'size': size,
    };
    if (sort != null) params['sort'] = sort;
    final data = await _get(
      '/track/genre-detail/list',
      queryParameters: params,
    );
    final response = FeiNiuResponse.fromJson(
      data,
      (d) => _parsePage(d as Map<String, dynamic>, FeiNiuTrack.fromJson),
    );
    return response.data ?? const FeiNiuPageData(list: [], total: 0);
  }

  // endregion

  // region 6. 封面图

  /// 构造封面图 URL
  /// CachedNetworkImage 按 URL 缓存，图片不变 URL 不变即命中磁盘缓存。
  /// [updatedAt] 可选，传入服务端更新时间戳将追加 `&t=` 参数实现缓存失效（cache busting）。
  String coverUrl(String coverId, {int size = 320, int? updatedAt}) {
    var url = '/static/cover?coverId=$coverId&size=$size';
    if (updatedAt != null && updatedAt > 0) {
      url += '&t=$updatedAt';
    }
    return _url(url);
  }

  // endregion

  // region 4. 播放音乐（获取音频流）

  /// 构造音频流 URL
  String streamUrl(String guid) {
    return _url('/track/stream?guid=$guid');
  }

  /// 查询曲目元数据（含 audioSpec.format，用于判断是否需要转码）。
  ///
  /// 返回响应 `data` 段（`{audioSpec, track, ...}`）；异常时抛 DioException。
  Future<Map<String, dynamic>?> trackMetadata(String guid) async {
    final data = await _get('/track/metadata?guid=$guid');
    return data['data'] is Map<String, dynamic>
        ? data['data'] as Map<String, dynamic>
        : null;
  }

  /// 请求服务器转码，返回 HLS 播放地址（`data.url`，通常为相对路径）。
  ///
  /// 默认请求 FLAC（无损）；FLAC 帧超过解码器能力时由上层降级为
  /// `codec: 'mp3'` 重新请求。转码失败 / 服务器未返回地址时返回 null。
  Future<String?> trackTranscode(String guid, {String codec = 'flac'}) async {
    final data = await _post(
      '/track/transcode',
      data: {
        'guid': guid,
        'output': {'codec': codec, 'bitrate': 320, 'channel': 2},
      },
    );
    final body = data['data'];
    if (body is Map<String, dynamic>) {
      final url = body['url'];
      if (url is String && url.isNotEmpty) return url;
    }
    return null;
  }

  /// 拼接 HLS 绝对地址：服务器返回相对路径（以 /music/api/v1 开头）时
  /// 拼上 baseUrl，绝对地址原样返回。
  String resolveHlsUrl(String rel) {
    if (rel.startsWith('http://') || rel.startsWith('https://')) return rel;
    return '$_baseUrl${rel.startsWith('/') ? rel : '/$rel'}';
  }

  /// 抓取 m3u8 播放列表文本（携带资源认证头，与 ExoPlayer 播放请求一致）。
  ///
  /// 用于探测转码 FLAC 流的 fMP4 分片、判断单帧大小是否超出解码器能力。
  /// 返回 null 表示请求失败 / 非 2xx（此时调用方保持 FLAC 并走崩溃兜底）。
  Future<String?> fetchM3u8Text(String url) async {
    final response = await _dio.get(
      url,
      options: Options(
        headers: FeiNiuApiClient.imageAuthHeaders(),
        responseType: ResponseType.plain,
        validateStatus: (code) => code != null && code >= 200 && code < 300,
      ),
    );
    final data = response.data;
    return data is String ? data : null;
  }

  /// 抓取二进制资源（音频分片等）原始字节。
  ///
  /// 返回 null 表示请求失败 / 非 2xx / 响应非字节流。
  Future<Uint8List?> fetchBytes(String url) async {
    final response = await _dio.get(
      url,
      options: Options(
        headers: FeiNiuApiClient.imageAuthHeaders(),
        responseType: ResponseType.bytes,
        validateStatus: (code) => code != null && code >= 200 && code < 300,
      ),
    );
    final data = response.data;
    return data is Uint8List ? data : null;
  }

  // endregion

  // region 5/19. 专辑列表

  Future<FeiNiuPageData<FeiNiuAlbum>> getAlbumList({
    int page = 1,
    int size = 50,
    String? sort,
  }) async {
    final params = <String, dynamic>{'page': page, 'size': size};
    if (sort != null) params['sort'] = sort;
    final data = await _get('/album/list', queryParameters: params);
    final response = FeiNiuResponse.fromJson(
      data,
      (d) => _parsePage(d as Map<String, dynamic>, FeiNiuAlbum.fromJson),
    );
    return response.data ?? const FeiNiuPageData(list: [], total: 0);
  }

  // endregion

  // region 7. 专辑详情

  Future<FeiNiuPageData<FeiNiuTrack>> getAlbumTracks({
    required String albumGUID,
    int page = 1,
    int size = 120,
  }) async {
    final data = await _get(
      '/track/album-detail/list',
      queryParameters: {'albumGUID': albumGUID, 'page': page, 'size': size},
    );
    final response = FeiNiuResponse.fromJson(
      data,
      (d) => _parsePage(d as Map<String, dynamic>, FeiNiuTrack.fromJson),
    );
    return response.data ?? const FeiNiuPageData(list: [], total: 0);
  }

  // endregion

  // region 8. 歌手列表

  Future<FeiNiuPageData<FeiNiuArtist>> getArtistList({
    int page = 1,
    int size = 200,
  }) async {
    final data = await _get(
      '/artist/list',
      queryParameters: {'page': page, 'size': size},
    );
    final response = FeiNiuResponse.fromJson(
      data,
      (d) => _parsePage(d as Map<String, dynamic>, FeiNiuArtist.fromJson),
    );
    return response.data ?? const FeiNiuPageData(list: [], total: 0);
  }

  // endregion

  // region 9. 歌手对应歌曲

  Future<FeiNiuPageData<FeiNiuTrack>> getArtistTracks({
    required String artistGUID,
    int page = 1,
    int size = 120,
    String? sort,
  }) async {
    final params = <String, dynamic>{
      'artistGUID': artistGUID,
      'page': page,
      'size': size,
    };
    if (sort != null && sort.isNotEmpty) params['sort'] = sort;
    debugPrint(
      '[ApiClient] getArtistTracks artistGUID=$artistGUID page=$page size=$size',
    );
    final data = await _get(
      '/track/artist-detail/list',
      queryParameters: params,
    );
    final response = FeiNiuResponse.fromJson(
      data,
      (d) => _parsePage(d as Map<String, dynamic>, FeiNiuTrack.fromJson),
    );
    return response.data ?? const FeiNiuPageData(list: [], total: 0);
  }

  // endregion

  // region 10. 获取歌词

  Future<FeiNiuLyricResponse> getLyrics(String trackGUID) async {
    final data = await _get(
      '/lyric/list',
      queryParameters: {'trackGUID': trackGUID},
    );
    final response = FeiNiuResponse.fromJson(
      data,
      (d) => FeiNiuLyricResponse.fromJson(d as Map<String, dynamic>),
    );
    return response.data ?? const FeiNiuLyricResponse(list: []);
  }

  /// 获取首选歌词文本（LRC 格式）
  Future<String?> getLyricText(String trackGUID) async {
    final lyricResponse = await getLyrics(trackGUID);
    if (lyricResponse.preferred != null) {
      final preferred = lyricResponse.list
          .where((l) => l.guid == lyricResponse.preferred)
          .firstOrNull;
      if (preferred != null) return preferred.content;
    }
    if (lyricResponse.list.isNotEmpty) {
      return lyricResponse.list.first.content;
    }
    return null;
  }

  // endregion

  // region 11. 歌曲元数据

  Future<FeiNiuTrack?> getTrackMetadata(String guid) async {
    final data = await _get('/track/metadata', queryParameters: {'guid': guid});
    final response = FeiNiuResponse.fromJson(data, (d) {
      final d2 = d is Map<String, dynamic> ? d : <String, dynamic>{};
      // metadata 返回的 track 在 track 字段内
      final track = d2['track'] as Map<String, dynamic>?;
      if (track != null) return FeiNiuTrack.fromJson(track);
      return FeiNiuTrack.fromJson(d2);
    });
    return response.data;
  }

  // endregion

  // region 12. 搜索

  Future<FeiNiuPageData<FeiNiuSearchTrack>> searchTrack({
    required String query,
    int page = 1,
    int size = 50,
  }) async {
    final data = await _get(
      '/search/track',
      queryParameters: {'q': query, 'page': page, 'size': size},
    );
    final response = FeiNiuResponse.fromJson(
      data,
      (d) => _parsePage(d as Map<String, dynamic>, FeiNiuSearchTrack.fromJson),
    );
    return response.data ?? const FeiNiuPageData(list: [], total: 0);
  }

  Future<FeiNiuPageData<FeiNiuAlbum>> searchAlbum({
    required String query,
    int page = 1,
    int size = 24,
  }) async {
    final data = await _get(
      '/search/album',
      queryParameters: {'q': query, 'page': page, 'size': size},
    );
    final response = FeiNiuResponse.fromJson(
      data,
      (d) => _parsePage(d as Map<String, dynamic>, FeiNiuAlbum.fromJson),
    );
    return response.data ?? const FeiNiuPageData(list: [], total: 0);
  }

  Future<FeiNiuPageData<FeiNiuArtist>> searchArtist({
    required String query,
    int page = 1,
    int size = 24,
  }) async {
    final data = await _get(
      '/search/artist',
      queryParameters: {'q': query, 'page': page, 'size': size},
    );
    final response = FeiNiuResponse.fromJson(
      data,
      (d) => _parsePage(d as Map<String, dynamic>, FeiNiuArtist.fromJson),
    );
    return response.data ?? const FeiNiuPageData(list: [], total: 0);
  }

  // endregion

  // region 13. 收藏 / 取消收藏

  Future<void> favoriteTrack(String trackGUID) async {
    final data = await _post(
      '/favorite-track/create',
      data: {'trackGUID': trackGUID},
    );
    final response = FeiNiuResponse.fromJson(data, null);
    if (!response.isSuccess) {
      throw Exception(response.msg.isNotEmpty ? response.msg : '收藏失败');
    }
  }

  Future<void> unfavoriteTrack(String trackGUID) async {
    final data = await _post(
      '/favorite-track/delete',
      data: {'trackGUID': trackGUID},
    );
    final response = FeiNiuResponse.fromJson(data, null);
    if (!response.isSuccess) {
      throw Exception(response.msg.isNotEmpty ? response.msg : '取消收藏失败');
    }
  }

  // endregion

  // region 14/17. 收藏列表

  Future<FeiNiuPageData<FeiNiuTrack>> getFavoriteList({
    int page = 1,
    int size = -1,
    String? sort,
  }) async {
    final params = <String, dynamic>{'page': page, 'size': size};
    if (sort != null) params['sort'] = sort;
    final data = await _get('/favorite-track/list', queryParameters: params);
    final response = FeiNiuResponse.fromJson(
      data,
      (d) => _parsePage(d as Map<String, dynamic>, FeiNiuTrack.fromJson),
    );
    return response.data ?? const FeiNiuPageData(list: [], total: 0);
  }

  // endregion

  // region 15. 漫游（随机播放）

  Future<FeiNiuRoamStartResponse> getRoamStart(String deviceId) async {
    final data = await _get(
      '/track/roam-start',
      queryParameters: {'deviceId': deviceId},
    );
    final response = FeiNiuResponse.fromJson(
      data,
      (d) => FeiNiuRoamStartResponse.fromJson(d as Map<String, dynamic>),
    );
    if (!response.isSuccess || response.data == null) {
      throw Exception(response.msg.isNotEmpty ? response.msg : '获取随机歌曲失败');
    }
    return response.data!;
  }

  // endregion

  // region 16. 漫游下一曲

  Future<FeiNiuRoamNextResponse> getRoamNext(
    String deviceId,
    String relativeRoamId,
  ) async {
    final data = await _get(
      '/track/roam-next',
      queryParameters: {'deviceId': deviceId, 'relativeRoamId': relativeRoamId},
    );
    final response = FeiNiuResponse.fromJson(
      data,
      (d) => FeiNiuRoamNextResponse.fromJson(d as Map<String, dynamic>),
    );
    if (!response.isSuccess || response.data == null) {
      throw Exception(response.msg.isNotEmpty ? response.msg : '获取下一曲失败');
    }
    return response.data!;
  }

  // endregion

  // region 18. 播放历史

  Future<FeiNiuPageData<FeiNiuTrack>> getPlayHistory({
    int page = 1,
    int size = 100,
  }) async {
    final data = await _get(
      '/play-history/list',
      queryParameters: {'page': page, 'size': size},
    );
    final response = FeiNiuResponse.fromJson(
      data,
      (d) => _parsePage(d as Map<String, dynamic>, FeiNiuTrack.fromJson),
    );
    return response.data ?? const FeiNiuPageData(list: [], total: 0);
  }

  // endregion

  // region 21. 歌单列表

  Future<FeiNiuPageData<FeiNiuPlaylist>> getPlaylistList() async {
    final data = await _get('/playlist/list');
    final response = FeiNiuResponse.fromJson(
      data,
      (d) => _parsePage(d as Map<String, dynamic>, FeiNiuPlaylist.fromJson),
    );
    return response.data ?? const FeiNiuPageData(list: [], total: 0);
  }

  // endregion

  // region 22. 歌单详情

  Future<FeiNiuPageData<FeiNiuTrack>> getPlaylistTracks({
    required String playlistGUID,
    int page = 1,
    int size = 300,
  }) async {
    final data = await _get(
      '/track/playlist-detail/list',
      queryParameters: {
        'playlistGUID': playlistGUID,
        'page': page,
        'size': size,
      },
    );
    final response = FeiNiuResponse.fromJson(
      data,
      (d) => _parsePage(d as Map<String, dynamic>, FeiNiuTrack.fromJson),
    );
    return response.data ?? const FeiNiuPageData(list: [], total: 0);
  }

  // endregion

  // region 歌单管理（补充接口）

  /// 获取随机歌单封面
  static String _randomPlaylistCoverUrl() {
    final index = DateTime.now().millisecondsSinceEpoch % 4 + 1;
    return '/music/static/assets/img/playlist-covers/$index.png';
  }

  /// 上传封面图片，返回 coverId
  Future<String> uploadCover() async {
    // 使用随机封面图片 URL 下载后上传
    final coverUrl = _randomPlaylistCoverUrl();

    try {
      // 先从封面服务器下载图片再上传
      final imageResponse = await _dio.get(
        '$_baseUrl$coverUrl',
        options: Options(responseType: ResponseType.bytes),
      );
      final imageBytes = imageResponse.data as List<int>;
      // 上传前先设置 content-type
      final formData = FormData.fromMap({
        'file': MultipartFile.fromBytes(
          imageBytes,
          filename: 'cover.png',
          contentType: DioMediaType('image', 'png'),
        ),
      });
      final uploadResponse = await _dio.post(
        _url('/static/cover/playlist'),
        data: formData,
        options: Options(
          headers: {...authHeaders(), 'Content-Type': 'multipart/form-data'},
        ),
      );
      final rawData = uploadResponse.data;
      final data = rawData is Map<String, dynamic>
          ? rawData
          : <String, dynamic>{};
      final parsed = FeiNiuResponse.fromJson(
        data,
        (d) => (d as Map<String, dynamic>)['coverId'] as String?,
      );
      if (!parsed.isSuccess || parsed.data == null) {
        throw Exception(parsed.msg.isNotEmpty ? parsed.msg : '上传封面失败');
      }
      return parsed.data!;
    } catch (e) {
      // 如果上传失败，返回空字符串，创建歌单时不带 coverId
      if (kDebugMode) debugPrint('[ApiClient] uploadCover failed: $e');
      return '';
    }
  }

  Future<FeiNiuPlaylist> createPlaylist(String name, {String? coverId}) async {
    final body = <String, dynamic>{'name': name};
    if (coverId != null && coverId.isNotEmpty) {
      body['coverId'] = coverId;
    }
    final data = await _post('/playlist/create', data: body);
    final response = FeiNiuResponse.fromJson(
      data,
      (d) => FeiNiuPlaylist.fromJson(d as Map<String, dynamic>),
    );
    if (!response.isSuccess || response.data == null) {
      throw Exception(response.msg.isNotEmpty ? response.msg : '创建歌单失败');
    }
    return response.data!;
  }

  Future<void> deletePlaylist(String guid) async {
    final data = await _post('/playlist/delete', data: {'guid': guid});
    final response = FeiNiuResponse.fromJson(data, null);
    if (!response.isSuccess) {
      throw Exception(response.msg.isNotEmpty ? response.msg : '删除歌单失败');
    }
  }

  Future<void> editPlaylist({
    required String guid,
    String? name,
    String? coverId,
  }) async {
    final body = <String, dynamic>{'guid': guid};
    if (name != null) body['name'] = name;
    if (coverId != null) body['coverId'] = coverId;
    final data = await _post('/playlist/edit', data: body);
    final response = FeiNiuResponse.fromJson(data, null);
    if (!response.isSuccess) {
      throw Exception(response.msg.isNotEmpty ? response.msg : '编辑歌单失败');
    }
  }

  Future<void> addTrackToPlaylist(
    String playlistGuid,
    List<String> trackGUIDs,
  ) async {
    final data = await _post(
      '/playlist/add-track',
      data: {'guid': playlistGuid, 'trackGUIDs': trackGUIDs},
    );
    final response = FeiNiuResponse.fromJson(data, null);
    if (!response.isSuccess) {
      throw Exception(response.msg.isNotEmpty ? response.msg : '添加歌曲失败');
    }
  }

  Future<void> removeTrackFromPlaylist(
    String playlistGuid,
    String trackGUID,
  ) async {
    final data = await _post(
      '/playlist/remove-track',
      data: {'guid': playlistGuid, 'trackGUID': trackGUID},
    );
    final response = FeiNiuResponse.fromJson(data, null);
    if (!response.isSuccess) {
      throw Exception(response.msg.isNotEmpty ? response.msg : '移除歌曲失败');
    }
  }

  // endregion

  // region 19. 事件上报

  /// 上报播放事件到服务器
  Future<void> reportTrackPlay(String trackGuid) async {
    try {
      await _post(
        '/event/report',
        data: {
          'events': [
            {
              'eventType': 'track_play',
              'occurredAt': DateTime.now().millisecondsSinceEpoch,
              'payload': {'trackGUID': trackGuid},
            },
          ],
        },
      );
    } catch (e) {
      // 上报失败不影响播放
      if (kDebugMode) {
        debugPrint('reportTrackPlay error: $e');
      }
    }
  }

  // endregion
}
