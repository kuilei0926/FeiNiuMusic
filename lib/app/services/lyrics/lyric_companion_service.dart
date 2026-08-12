import 'package:shared_preferences/shared_preferences.dart';

import 'package:dio/dio.dart';

import '../companion/companion_error.dart';
import '../feiniu/api_client.dart';
import 'lyrics_repository.dart';

/// FnMusicEnhance 服务端增强歌词服务。
///
/// 服务端增强运行在飞牛 NAS 上（经 nginx /music-enhance/ 提供），提供 HTTP 写歌词：
/// - **读取歌词**：用飞牛音乐服务原本的接口（`FeiNiuApiClient.getLyricText`），
///   无需第三方；
/// - **写入歌词**：`POST /music/api/v1/lyric/list` body `{guid, content}`
///   （服务端增强，X-API-Key 携带登录 token，必填）。
///
/// 配置了服务地址（`FeiNiuApiClient.instance.baseUrl`）即可用。
/// 基础 URL 取 `FeiNiuApiClient.instance.baseUrl` + `/music-enhance`。
class LyricCompanionService {
  LyricCompanionService._internal();

  static final LyricCompanionService instance = LyricCompanionService._internal();

  static const String _apiPath = '/music/api/v1/lyric/list';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 10),
      responseType: ResponseType.json,
      validateStatus: (code) => code != null && code < 500,
    ),
  );

  /// 当前是否可用（已配置服务地址）。
  bool get available {
    final api = FeiNiuApiClient.instance;
    return api.baseUrl.isNotEmpty;
  }

  /// 构造服务端增强基础 URL：`<FeiNiuApiClient.baseUrl>/music-enhance`。
  ///
  /// NAS 的 nginx 将 `/music-enhance/` 转发到 FnMusicEnhance(unix socket),
  /// scheme/host/port 与主 API 一致。
  String? get baseUrl {
    final api = FeiNiuApiClient.instance;
    if (api.baseUrl.isEmpty) return null;
    return '${api.baseUrl}/music-enhance';
  }

  /// 健康探测：验证服务端增强是否在 NAS 上运行。
  ///
  /// `/health` 无论 token 如何都返回 `code:0`（服务可达），`data.auth`
  /// 区分三态："ok"（token 有效）/ "missing"（未携带）/ "invalid"（无效）。
  /// 因此：
  /// - 服务可达（code==0）→ 默认返回 null（探测成功）；
  /// - [checkKey] 为 true 时校验登录 token：`auth == "ok"` 通过，否则区分
  ///   "missing"（未传 token）与 "invalid"（token 无效/过期）；
  /// - 端口不可达 / 超时 → 返回「未检测到」。
  Future<String?> probe({bool checkKey = false}) async {
    // 确保「曾连接」标记已加载（UI 依赖它区分未安装/已安装不可达）。
    await ensureEverConnectedLoaded();
    final base = baseUrl;
    if (base == null) return '未配置服务器地址';
    final token = FeiNiuApiClient.instance.token;
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '$base/health',
        options: Options(
          headers: {
            if (token.isNotEmpty) 'X-API-Key': token,
          },
        ),
      );
      final code = response.data?['code'];
      if (code == 0) {
        final data = response.data?['data'] as Map<String, dynamic>?;
        // 服务可达：标记「历史上已检测到一次」→ 之后不可达也不提示未安装。
        await _markConnected();
        if (!checkKey) return null;
        final auth = data?['auth'];
        if (auth == 'ok') return null;
        return auth == 'missing'
            ? '未检测到登录 token，请重新登录'
            : '登录 token 无效或已过期';
      }
      if (response.statusCode == 401) return '登录 token 无效（HTTP 401）';
      return '服务异常（${response.statusCode}）';
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.connectionError) {
        return '未检测到 NAS 上运行的 FnMusicEnhance';
      }
      return '连接失败：${e.message}';
    } catch (e) {
      return '连接失败：$e';
    }
  }

  static DateTime? _lastConnectedCheck;
  static bool _lastConnected = false;
  static const Duration _connectedCheckTtl = Duration(seconds: 30);

  /// 「历史上成功检测到过一次服务端增强」的持久化标记。
  ///
  /// 只要成功探测到过一次就永久为 true：之后即使探测失败，也视为「已安装
  /// 但当前不可达」，而不是「未安装」。存 SharedPreferences 跨会话保留。
  static const String _prefsEverConnected = 'lyric_companion_ever_connected';
  static bool _everConnected = false;
  static bool _everConnectedLoaded = false;

  /// 是否历史上成功检测到过一次服务端增强（已安装）。
  bool get everConnected => _everConnected;

  /// 加载「曾连接」标记（probe 成功前先调用，保证 UI 判断有值）。
  static Future<void> ensureEverConnectedLoaded() async {
    if (_everConnectedLoaded) return;
    final prefs = await SharedPreferences.getInstance();
    _everConnected = prefs.getBool(_prefsEverConnected) ?? false;
    _everConnectedLoaded = true;
  }

  static Future<void> _markConnected() async {
    if (_everConnected) return;
    _everConnected = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsEverConnected, true);
  }

  /// 探测服务端增强是否可达（带 30s 缓存）。未连接返回 false。
  ///
  /// 供编辑页等场合在展示/预取歌词前判断「是否真的连上了增强插件」，
  /// 避免把「未连接」误报成「未获取到歌词」。不预设中继模式，统一由
  /// 真实 `/health` 探测判定服务是否可达。
  Future<bool> checkConnected() async {
    final now = DateTime.now();
    if (_lastConnectedCheck != null &&
        now.difference(_lastConnectedCheck!) < _connectedCheckTtl) {
      return _lastConnected;
    }
    _lastConnectedCheck = now;
    _lastConnected = (await probe()) == null;
    return _lastConnected;
  }

  /// 读取歌词（LRC 文本）。
  ///
  /// 用飞牛音乐服务原本的接口（`FeiNiuApiClient.getLyricText`），无需第三方。
  /// 无歌词返回空字符串。
  Future<String> getLyrics(String trackGuid) async {
    final api = FeiNiuApiClient.instance;
    return await api.getLyricText(trackGuid) ?? '';
  }

  /// 写入歌词，成功后重新读取验证。
  Future<void> saveLyrics(String guid, String content) async {
    final base = baseUrl;
    if (base == null) throw StateError('未配置服务器地址');
    final Map<String, dynamic>? data;
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '$base$_apiPath',
        data: {'guid': guid, 'content': content},
        options: Options(
          headers: {
            ..._authHeaders(),
            'Content-Type': 'application/json',
          },
        ),
      );
      data = response.data;
    } on DioException catch (e) {
      throw Exception(companionErrorText(e));
    }
    final code = data?['code'];
    if (code != 0) {
      throw Exception(data?['msg'] ?? '写入歌词失败');
    }
    // 保存后重新读取验证（服务端增强可能规范化歌词内容，仅确认可读回非空）
    final verify = await getLyrics(guid);
    if (verify.isEmpty) {
      throw Exception('写入后读取验证失败');
    }
    // 同步更新本地歌词缓存，避免播放时 loadLrc 读到旧歌词
    await LyricsRepository().saveLrcToCache(guid, verify, overwrite: true);
  }

  Map<String, String> _authHeaders() {
    return {
      'X-API-Key': FeiNiuApiClient.instance.token,
    };
  }
}
