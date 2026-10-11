import 'package:dio/dio.dart';

import '../feiniu/api_client.dart';

/// 删除结果。
class FnmtDeleteResult {
  const FnmtDeleteResult({
    required this.ok,
    this.removed = 0,
    this.error,
    this.backup,
  });

  final bool ok;

  /// 实际删除的曲目数。
  final int removed;

  /// 失败原因（[ok] 为 false 时）。
  final String? error;

  /// 服务端在改库前生成的 SQLite 备份路径（可用于回滚）。
  final String? backup;
}

/// `fnmusic-tools` 曲库管理插件客户端（运行在 NAS 上）。
///
/// 官方音乐 API **没有真正的删除能力**：
/// - 前端界面从未绑定 `POST /music/api/v1/track/delete`（该路由存在但只做
///   「管理员从库中移除」的软隐藏，`is_admin_deleted=1`，**文件不删**）；
/// - 直接删物理文件时官方应用只把 `audio_file.is_physical_file_deleted` 置 1，
///   **库记录仍残留**。
///
/// 本服务对接 NAS 上的 `fnmusic-tools` 插件（nginx 路径 `/music-tools/`），
/// 执行的是**物理删除**：删音频文件（含同名 `.lrc`）+ 级联清库记录 + 清孤儿
/// 专辑/歌手，并在改库前自动做 SQLite online backup。
///
/// 基础 URL：`${FeiNiuApiClient.instance.baseUrl}/music-tools/api`
/// 插件可选校验 `X-API-Key`（转发飞牛音乐登录 token），实体与
/// [MetadataCompanionService] 保持一致。
class FnMusicToolsService {
  FnMusicToolsService._internal();

  static final FnMusicToolsService instance = FnMusicToolsService._internal();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      sendTimeout: const Duration(seconds: 60),
      receiveTimeout: const Duration(seconds: 180),
      responseType: ResponseType.json,
      // 4xx/5xx 由业务层读 body 判断，不抛异常
      validateStatus: (code) => code != null && code < 500,
    ),
  );

  /// 是否已配置服务器地址。
  bool get available => FeiNiuApiClient.instance.baseUrl.isNotEmpty;

  String? get _apiBase {
    final api = FeiNiuApiClient.instance;
    if (api.baseUrl.isEmpty) return null;
    return '${api.baseUrl}/music-tools/api';
  }

  Options get _options => Options(
        headers: {
          'X-API-Key': FeiNiuApiClient.instance.token,
          'Cookie': 'music-token=${FeiNiuApiClient.instance.token}',
        },
      );

  /// 探活：用于判断 NAS 上是否装了插件。
  Future<bool> ping() async {
    final base = _apiBase;
    if (base == null) return false;
    try {
      final resp = await _dio.get('$base/health', options: _options);
      final data = resp.data;
      return resp.statusCode == 200 && data is Map && data['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 按 track guid **彻底删除**（物理删文件 + 级联清库）。
  ///
  /// [guids] 传 `SongEntity.id`（即飞牛 track guid），精确匹配，避免同名误删。
  Future<FnmtDeleteResult> deleteByGuids(List<String> guids) async {
    final base = _apiBase;
    if (base == null) {
      return const FnmtDeleteResult(ok: false, error: '未配置服务器地址');
    }
    final ids = guids.where((g) => g.isNotEmpty).toList();
    if (ids.isEmpty) {
      return const FnmtDeleteResult(ok: false, error: '没有选中歌曲');
    }
    try {
      final resp = await _dio.post(
        '$base/delete',
        data: {'guids': ids, 'mode': 'purge'},
        options: _options,
      );
      final data = resp.data;
      if (data is Map && data['ok'] == true) {
        final removed = data['removed'] is List
            ? (data['removed'] as List).length
            : ids.length;
        final left = data['left'];
        // 服务端会把「匹配到但实际没删掉」的情况也算在 removed 里，这里只信数量
        return FnmtDeleteResult(
          ok: true,
          removed: removed,
          backup: data['backup'] is String ? data['backup'] as String : null,
        );
      }
      final msg = data is Map
          ? '${data['error'] ?? data['msg'] ?? '服务端返回失败'}'
          : '服务端返回异常';
      return FnmtDeleteResult(ok: false, error: msg);
    } on DioException catch (e) {
      final is404 = e.response?.statusCode == 404;
      return FnmtDeleteResult(
        ok: false,
        error: is404
            ? 'NAS 上未安装 fnmusic-tools 插件（/music-tools 不可达）'
            : '请求失败：${e.message ?? e.type.name}',
      );
    } catch (e) {
      return FnmtDeleteResult(ok: false, error: '$e');
    }
  }
}
