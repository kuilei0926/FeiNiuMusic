import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../state/settings_fn_state.dart';
import 'api_models.dart';

/// 音频流 URL 的 302 预解析结果：跟随反向代理链后的最终可播地址 + 该地址
/// 所需的认证头。
///
/// 同源跳转（scheme://host:port 一致，如反向代理内部转发）保留飞牛 Cookie；
/// 跨主机跳转（如跳转网盘 CDN）剥离飞牛 Cookie，第三方地址用自身签名鉴权。
class ResolvedStreamUrl {
  const ResolvedStreamUrl({required this.url, required this.headers});

  /// 跟随 302 链后的最终 URL（失败/超时回退时等于原始 URL）。
  final String url;

  /// 访问 [url] 所需的认证头（跨主机跳转后为空 Map）。
  final Map<String, String> headers;
}

/// 判断 302 跳转是否仍处于同一「源」（scheme + host + port 完全一致）。
///
/// 同源跳转（如 nginx `return 302 /proxy/...` 内部转发）仍需携带飞牛 Cookie
/// 才能通过鉴权；跨源跳转（跳往网盘 CDN 等第三方地址）时飞牛 Cookie 无意义
/// 且会泄漏，应剥离。
@visibleForTesting
bool streamRedirectSameOrigin(Uri from, Uri to) {
  return from.scheme == to.scheme &&
      from.host == to.host &&
      from.port == to.port;
}

/// 跨源 302 跳转后应携带的认证头：剥离飞牛 Cookie（`music-token` /
/// `mode=relay` / 安全码），避免凭据泄漏给第三方；同源跳转原样返回。
@visibleForTesting
Map<String, String> streamRedirectHeaders(
  Uri from,
  Uri to,
  Map<String, String> headers,
) {
  if (streamRedirectSameOrigin(from, to)) return headers;
  return const {};
}

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
          // HTTP 401 → 会话失效，交由高层恢复（静默重登或强制登出）。
          // 仅在已持有 token 时触发：登录请求（无有效 token）返回 401 属正常
          // 登录失败，不应走会话失效恢复。
          if (_token.isNotEmpty && error.response?.statusCode == 401) {
            onSessionExpired?.call();
          }
          handler.next(error);
        },
        onResponse: (response, handler) {
          // 收到响应即表示服务器可达，通知连接恢复监听器
          for (final monitor in _recoveryMonitors) {
            monitor();
          }
          // 会话失效：HTTP 401 或业务码 INVALID TOKEN（validateStatus 全接受，
          // 401 走 onResponse；INVALID TOKEN 是 HTTP 200 + 业务 code≠0）。
          if (_token.isNotEmpty && _isSessionExpired(response)) {
            onSessionExpired?.call();
          }
          // 全局处理 3xx 重定向（手动跟随以保持自定义 Cookie）
          final statusCode = response.statusCode ?? 0;
          if (statusCode >= 300 && statusCode < 400) {
            _handleRedirect(response)
                .then((result) {
                  handler.resolve(result);
                })
                .catchError((Object e, StackTrace st) {
                  // _handleRedirect 重发失败（如重定向目标 TLS 握手失败）时，
                  // 必须把错误通过 handler.reject 传给拦截器链走正常错误流程
                  // （触发自动重连/错误 UI）。不能塞进 handler.next——其参数是
                  // Response，传 DioException 会抛「DioException 不是 Response」
                  // 类型错误 → 未捕获异常崩溃。
                  if (kDebugMode) {
                    debugPrint(
                      '[ApiClient] Redirect follow failed: $e\n$st',
                    );
                  }
                  handler.reject(
                    e is DioException
                        ? e
                        : DioException(
                            requestOptions: response.requestOptions,
                            error: e,
                            stackTrace: st,
                          ),
                  );
                });
            return;
          }
          handler.next(response);
        },
      ),
    );
  }

  /// 判断响应是否表示会话失效（token 过期/被拒）。
  ///
  /// - HTTP 401；
  /// - 业务码 401；
  /// - 业务 msg 含 INVALID TOKEN（服务器对失效 token 的典型返回，HTTP 200 承载）。
  bool _isSessionExpired(Response response) {
    if (response.statusCode == 401) return true;
    final data = response.data;
    if (data is Map<String, dynamic>) {
      final code = data['code'];
      if (code == 401) return true;
      final msg = data['msg'];
      if (msg is String && msg.toLowerCase().contains('invalid token')) {
        return true;
      }
    }
    return false;
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

  /// 音频流 URL 302 预解析结果缓存（按原始 URL，TTL 10 分钟）。
  ///
  /// 网盘 CDN 签名 URL 时效短（分钟级），TTL 过长会播到过期地址；10 分钟内
  /// 重复播放同一首歌直接命中，不再每次探测 302 链。
  static const Duration _streamResolveTtl = Duration(minutes: 10);
  static const int _streamRedirectMaxHops = 5;
  final Map<String, _StreamResolveEntry> _streamResolveCache = {};

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

  /// 会话失效回调（HTTP 401 或业务码 INVALID TOKEN）。
  ///
  /// 由 [AccountStore] 注册，内部实现静默重登或强制登出（见
  /// [AccountStore.handleTokenExpired]）。登录（password-login）请求自身
  /// 不会携带有效 token，应排除在外。
  VoidCallback? onSessionExpired;

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
      debugPrint(
        '[ApiClient] 3xx → $redirectUri (depth=$depth) '
        'from ${response.requestOptions.uri}',
      );
    }

    // 重定向目标与原始请求完全一致 → 重定向循环（典型：nginx「HTTP 强制跳转
    // HTTPS」的规则误命中 HTTPS 端口，把 HTTPS 请求 302 回自己）。直接终止，
    // 由调用方（如登录）给出明确错误，而不是每跳重发直到 depth 上限。
    if (redirectUri == response.requestOptions.uri) {
      if (kDebugMode) {
        debugPrint(
          '[ApiClient] Redirect loop detected: $redirectUri '
          '(HTTP ${response.statusCode})',
        );
      }
      return response;
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
    // _handleRedirect 已尝试跟随（含自循环终止/深度上限），走到这里仍是 3xx
    // 说明重定向没被正常消化：给用户明确提示而不是笼统「登录失败」。
    final status = response.statusCode ?? 0;
    if (status >= 300 && status < 400) {
      throw Exception(
        '服务器返回重定向 (HTTP $status)，请检查服务器'
        '「HTTP 强制跳转 HTTPS」配置是否误拦截了 HTTPS 请求',
      );
    }
    final data = response.data is Map<String, dynamic>
        ? response.data as Map<String, dynamic>
        : <String, dynamic>{};
    final parsed = FeiNiuResponse<LoginResponse>.fromJson(
      data,
      (d) => LoginResponse.fromJson(d as Map<String, dynamic>),
    );
    if (!parsed.isSuccess || parsed.data == null) {
      // 120001：账号或密码错误（服务端 msg 为英文，用户看不懂）
      if (parsed.code == 120001) {
        throw Exception('用户名或密码错误，请重试！');
      }
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

  /// 全 App 统一的封面请求尺寸（像素）。
  ///
  /// 所有封面显示场景（列表缩略图、播放页大图、通知栏、投屏等）共用这一个
  /// 尺寸构造 URL。CachedNetworkImage / flutter_cache_manager 按 URL 缓存，
  /// 同一封面若各处按各自显示尺寸请求（48/120/300/400/800…）会得到互不相同
  /// 的 URL，磁盘缓存与解码缓存互相不命中 → 「列表已显示封面、播放页还在
  /// 转圈」。统一后同一封面只有一份缓存，任一处加载完成其余场景立即可用；
  /// 缩略图用 memCacheWidth 解码小图省内存，URL 不变仍共享磁盘缓存。
  static const int coverRequestSize = 800;

  /// 构造封面图 URL
  /// CachedNetworkImage 按 URL 缓存，图片不变 URL 不变即命中磁盘缓存。
  /// [updatedAt] 可选，传入服务端更新时间戳将追加 `&t=` 参数实现缓存失效（cache busting）。
  String coverUrl(String coverId, {int size = coverRequestSize, int? updatedAt}) {
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

  /// 跟随 302 反向代理链解析音频流最终可播地址。
  ///
  /// 网盘音乐（挂载网盘，如 115）的 `/track/stream` 直连请求可能被服务器
  /// **302 反向代理**到网盘 CDN / 内网代理地址。流请求由播放引擎（mpv /
  /// ExoPlayer）与缓存下载器（dart:io HttpClient）直接发起，**不走本客户端
  /// 的 [_handleRedirect]**，这些层对重定向的认证头保留行为不可控：
  /// - dart:io HttpClient（StreamAudioCacheSource）自动跟随 302 时，SDK
  ///   `shouldCopyHeaderOnRedirect` 仅同 scheme + port 才复制 Cookie → 跨主机
  ///   跳转丢 `music-token` → 401 → 播放转圈；
  /// - media_kit / ExoPlayer 对重定向后的 httpHeaders 保留行为各异。
  ///
  /// 因此在把流 URL 交给引擎/缓存前，先手动跟随 302 链（带飞牛 Cookie），
  /// 拿到最终 URL 与该地址所需认证头（同源保留、跨主机剥离，见
  /// [streamRedirectHeaders]），再用最终 URL 播放，绕开各引擎重定向差异。
  ///
  /// - 最多跟随 [_streamRedirectMaxHops] 跳防死循环；
  /// - 按原始 URL 做 [_streamResolveTtl] 缓存，避免每次播放都探测；
  /// - 任何失败（超时/网络错/超跳数）静默回退原始 URL + 原始认证头，
  ///   不阻塞播放（保持现状兜底）。
  Future<ResolvedStreamUrl> resolveStreamUrl(String url) async {
    final now = DateTime.now();
    final cached = _streamResolveCache[url];
    if (cached != null && cached.expiresAt.isAfter(now)) {
      return cached.value;
    }
    final originalHeaders = imageAuthHeaders();
    try {
      final client = HttpClient()
        // 探测请求必须快速失败：网盘 CDN 无响应时不能挂起播放（resolve
        // 只读响应头，正常场景几十毫秒内完成）。
        ..connectionTimeout = const Duration(seconds: 5)
        ..idleTimeout = const Duration(seconds: 5);
      try {
        var currentUri = Uri.parse(url);
        var currentHeaders = originalHeaders;
        // 是否在跳数内到达了非 3xx 的最终响应；超跳数仍未消化 302 视为
        // 重定向循环/链过长，回退原始 URL（见方法注释）。
        var reachedFinal = false;
        for (var hop = 0; hop < _streamRedirectMaxHops; hop++) {
          // 只探测响应头不拉全量：GET + Range: bytes=0-0（部分服务器不响应
          // HEAD，Range 最通用），读完状态码/Location 即关闭连接。
          final request = await client.openUrl('GET', currentUri);
          // 关闭自动重定向：手动跟随 302 链并控制 Cookie 保留/剥离（SDK 自动
          // 跟随仅同 scheme+port 复制 Cookie，跨主机丢 Cookie 正是要绕开的问题）。
          request.followRedirects = false;
          request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
          for (final entry in currentHeaders.entries) {
            request.headers.set(entry.key, entry.value);
          }
          final response = await request.close();
          final status = response.statusCode;
          if (status >= 300 && status < 400) {
            final location = response.headers.value('location');
            if (location == null || location.isEmpty) break;
            final nextUri = currentUri.resolve(location);
            // 跨主机跳转 → 剥离飞牛 Cookie；同源 → 保留（反向代理内部转发
            // 仍需鉴权）。
            currentHeaders =
                streamRedirectHeaders(currentUri, nextUri, currentHeaders);
            currentUri = nextUri;
            continue;
          }
          reachedFinal = true;
          break;
        }
        if (!reachedFinal) {
          return ResolvedStreamUrl(url: url, headers: originalHeaders);
        }
        final result =
            ResolvedStreamUrl(url: currentUri.toString(), headers: currentHeaders);
        _streamResolveCache[url] =
            _StreamResolveEntry(result, now.add(_streamResolveTtl));
        return result;
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      // 失败静默回退：原 URL + 原始认证头（不缓存，允许下次重试）。
      return ResolvedStreamUrl(url: url, headers: originalHeaders);
    }
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

  /// 保存曲目元数据（编辑歌曲：名称/专辑/歌手/封面/序号/风格/年份）。
  ///
  /// body 约定（服务端格式）：
  /// `{album, artistGUIDs, coverGUID, coverId, discNo, genreGUIDs, guid, title, trackNo, year}`
  ///
  /// 失败（业务 code != 0）时抛异常，携带服务器返回的 msg。
  Future<void> updateTrackMetadata(Map<String, dynamic> body) async {
    final data = await _post('/track/metadata', data: body);
    final parsed = FeiNiuResponse.fromJson(data, null);
    if (!parsed.isSuccess) {
      throw Exception(parsed.msg.isNotEmpty ? parsed.msg : '保存失败');
    }
  }

  /// 上传歌曲封面图片字节，返回 coverId（`track_<guid>` 格式）。
  ///
  /// 与歌单封面上传（_uploadPlaylistCoverBytes）同构：multipart/form-data，
  /// 文件字段名 `file`。失败时抛异常（带服务器 msg）。
  Future<String> uploadTrackCover(List<int> imageBytes) async {
    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        imageBytes,
        filename: 'cover.png',
        contentType: DioMediaType('image', 'png'),
      ),
    });
    final response = await _dio.post(
      _url('/static/cover/track'),
      data: formData,
      options: Options(
        headers: {...authHeaders(), 'Content-Type': 'multipart/form-data'},
      ),
    );
    final rawData = response.data;
    final data = rawData is Map<String, dynamic> ? rawData : <String, dynamic>{};
    final parsed = FeiNiuResponse.fromJson(
      data,
      (d) => (d as Map<String, dynamic>)['coverId'] as String?,
    );
    if (!parsed.isSuccess || parsed.data == null) {
      throw Exception(parsed.msg.isNotEmpty ? parsed.msg : '上传封面失败');
    }
    return parsed.data!;
  }

  /// 从 coverId 派生 coverGUID：剥掉类型前缀（`track_`/`album_`/`artist_`/
  /// `playlist_`），供编辑歌曲提交时使用。
  ///
  /// 例：`track_7de7f67ca7344e158560653721c64dbe` → `7de7f67ca7344e158560653721c64dbe`。
  /// 无已知前缀时原样返回。
  static String deriveCoverGuid(String coverId) {
    for (final prefix in const ['track_', 'album_', 'artist_', 'playlist_']) {
      if (coverId.startsWith(prefix)) {
        return coverId.substring(prefix.length);
      }
    }
    return coverId;
  }

  /// 请求服务器转码，返回 HLS 播放地址（`data.url`，通常为相对路径）。
  ///
  /// 默认请求 FLAC（无损）；FLAC 帧超过解码器能力时由上层降级为
  /// `codec: 'mp3'` 重新请求。转码失败 / 服务器未返回地址时返回 null。
  ///
  /// [bitrate] 只在非空且大于 0 时写入 output——**仅 flac 带 bitrate**（320），
  /// mp3/opus 不带（带 bitrate 会显著劣化音质）。
  Future<String?> trackTranscode(
    String guid, {
    String codec = 'flac',
    int? bitrate,
    int channel = 2,
  }) async {
    final output = <String, dynamic>{'codec': codec, 'channel': channel};
    if (bitrate != null && bitrate > 0) output['bitrate'] = bitrate;
    final data = await _post(
      '/track/transcode',
      data: {'guid': guid, 'output': output},
    );
    final body = data['data'];
    if (body is Map<String, dynamic>) {
      final url = body['url'];
      if (url is String && url.isNotEmpty) return url;
    }
    return null;
  }

  /// 释放服务器端转码会话（切歌/停止/退出时调用）。best-effort，失败忽略。
  Future<void> trackTranscodeQuit(String guid) async {
    await _post('/track/transcode/quit', data: {'guid': guid});
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

  /// 获取专辑全量列表（无分页，供编辑歌曲的专辑解析使用）。
  ///
  /// 响应 `data.list` 直接为专辑数组（与 `/album/list` 的 FeiNiuPageData
  /// 不同，没有 total 分页字段）。
  Future<List<FeiNiuAlbum>> getAlbumListAll() async {
    final data = await _get('/album/list-all');
    final body = data['data'];
    final rawList = (body is Map<String, dynamic>) ? body['list'] : null;
    final list = (rawList as List<dynamic>?)
            ?.map((e) => FeiNiuAlbum.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [];
    return list;
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

  /// 获取歌手全量列表（无分页，供编辑歌曲的歌手选择器使用）。
  ///
  /// 响应 `data.list` 直接为歌手数组（与 `/artist/list` 的 FeiNiuPageData
  /// 不同，没有 total 分页字段）。
  Future<List<FeiNiuArtist>> getArtistListAll() async {
    final data = await _get('/artist/list-all');
    // _get 返回整个响应体 {code,msg,data}，实际列表在 data.data.list
    final body = data['data'];
    final rawList = (body is Map<String, dynamic>) ? body['list'] : null;
    final list = (rawList as List<dynamic>?)
            ?.map((e) => FeiNiuArtist.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [];
    return list;
  }

  /// 创建歌手（不存在时自动新建），返回新歌手对象。
  ///
  /// body: `{"name": "...", "coverId": null}`。服务端返回创建后的歌手
  /// （含 guid）。失败时抛异常（携带服务器 msg）。
  Future<FeiNiuArtist> createArtist(String name, {String? coverId}) async {
    final data = await _post(
      '/artist/create',
      data: {'name': name, 'coverId': coverId},
    );
    final parsed = FeiNiuResponse.fromJson(
      data,
      (d) => FeiNiuArtist.fromJson(d as Map<String, dynamic>),
    );
    if (!parsed.isSuccess) {
      throw Exception(parsed.msg.isNotEmpty ? parsed.msg : '创建歌手失败');
    }
    final artist = parsed.data;
    if (artist == null || artist.guid.isEmpty) {
      throw Exception('创建歌手失败：服务端未返回歌手信息');
    }
    return artist;
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

  /// 移出最近播放（批量删除播放历史）。
  ///
  /// 请求 `POST /play-history/delete`，body `{"trackGUIDs":["..."]}`。
  /// 服务器返回 `{"code":0,...}` 表示成功；非 0 抛异常。
  Future<void> deletePlayHistory(List<String> trackGUIDs) async {
    if (trackGUIDs.isEmpty) return;
    final data = await _post(
      '/play-history/delete',
      data: {'trackGUIDs': trackGUIDs},
    );
    final response = FeiNiuResponse.fromJson(data, null);
    if (!response.isSuccess) {
      throw Exception(response.msg.isNotEmpty ? response.msg : '移出最近播放失败');
    }
  }

  // endregion

  // region 21. 歌单列表

  Future<FeiNiuPageData<FeiNiuPlaylist>> getPlaylistList({
    int page = 1,
    int size = 50,
  }) async {
    final data = await _get(
      '/playlist/list',
      queryParameters: {'page': page, 'size': size},
    );
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

  /// 上传歌单封面图片字节，返回 coverId。上传失败时抛异常。
  Future<String> _uploadPlaylistCoverBytes(List<int> imageBytes) async {
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
  }

  /// 上传本地图片文件作为歌单封面，返回 coverId。失败时抛异常。
  ///
  /// [imagePath] 为本地文件路径，读取其字节后走与随机封面相同的上传流程。
  Future<String> uploadCoverFromFile(String imagePath) async {
    final bytes = await File(imagePath).readAsBytes();
    return _uploadPlaylistCoverBytes(bytes);
  }

  /// 上传随机歌单封面，返回 coverId。
  ///
  /// 随机封面为服务端内置资源，先从封面服务器下载再上传（原逻辑保留）。
  /// 上传失败返回空字符串，创建歌单时不带 coverId（保持原有容错）。
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
      return await _uploadPlaylistCoverBytes(imageBytes);
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

  /// 清除歌单内无效歌曲（曲目已被删除/失效）。
  ///
  /// 先 `GET /playlist/purge-track-count?guid=...` 取待清除数量（用于结果提示），
  /// 再 `POST /playlist/purge-track`（body `{"guid": ...}`）真正执行清除。
  /// 返回清除的无效歌曲数。
  Future<int> purgeInvalidTracks(String playlistGuid) async {
    // 1) 先取待清除数量；数量接口失败不阻塞后续清除。
    int count = 0;
    try {
      final countData = await _get(
        '/playlist/purge-track-count',
        queryParameters: {'guid': playlistGuid},
      );
      final countResp = FeiNiuResponse.fromJson(
        countData,
        (d) => (d as Map<String, dynamic>)['total'] as int? ?? 0,
      );
      if (countResp.isSuccess) count = countResp.data ?? 0;
    } catch (_) {
      count = 0;
    }
    // 2) 真正执行清除（仅调 count 接口不会删除任何歌曲）。
    final data = await _post(
      '/playlist/purge-track',
      data: {'guid': playlistGuid},
    );
    final response = FeiNiuResponse.fromJson(data, null);
    if (!response.isSuccess) {
      throw Exception(response.msg.isNotEmpty ? response.msg : '清除无效歌曲失败');
    }
    return count;
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
      data: {'guid': playlistGuid, 'trackGUIDs': [trackGUID]},
    );
    final response = FeiNiuResponse.fromJson(data, null);
    if (!response.isSuccess) {
      throw Exception(response.msg.isNotEmpty ? response.msg : '移除歌曲失败');
    }
  }

  /// 从歌单批量移除歌曲。
  ///
  /// `POST /playlist/remove-track`，body `{"guid":..., "trackGUIDs":[...]}`。
  Future<void> removeTracksFromPlaylist(
    String playlistGuid,
    List<String> trackGUIDs,
  ) async {
    final data = await _post(
      '/playlist/remove-track',
      data: {'guid': playlistGuid, 'trackGUIDs': trackGUIDs},
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

/// 音频流 URL 302 预解析缓存条目。
class _StreamResolveEntry {
  const _StreamResolveEntry(this.value, this.expiresAt);

  final ResolvedStreamUrl value;
  final DateTime expiresAt;
}
