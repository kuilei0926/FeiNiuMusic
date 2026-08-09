import 'dart:convert';

import 'package:dio/dio.dart';

import '../feiniu/api_client.dart';

/// 可编辑的实体类型（歌手 / 专辑）。
enum EntityEditKind {
  artist,
  album;

  /// 服务端增强 /cover、/entity 接口使用的 type 字段值。
  String get apiName => switch (this) {
        EntityEditKind.artist => 'artist',
        EntityEditKind.album => 'album',
      };

  String get label => switch (this) {
        EntityEditKind.artist => '歌手',
        EntityEditKind.album => '专辑',
      };
}

/// FnMusicEnhance 服务端增强元数据服务。
///
/// 服务端增强运行在飞牛 NAS 上（监听 38200 端口），除歌词回写外，还提供
/// 歌手/专辑的**封面写入**与**名称修改 / 实体创建**：
/// - `POST /music/api/v1/cover`：写入歌手/专辑封面（JSON base64），
///   写 `cover/{type}/{guid[:2]}/{guid}` 并更新 DB `cover_guid`；
/// - `POST /music/api/v1/entity`：`action=update` 改名，`action=create` 新建实体。
///
/// 仅非中继（relayMode == false）连接下可用：中继时 NAS 内网端口不暴露。
/// 基础 URL 取 `FeiNiuApiClient.instance.baseUrl` 的主机 + `:38200`。
/// X-API-Key 携带飞牛音乐登录 token（`FeiNiuApiClient.token`）。
class MetadataCompanionService {
  MetadataCompanionService._internal();

  static final MetadataCompanionService instance =
      MetadataCompanionService._internal();

  static const int port = 38200;
  static const String _coverPath = '/music/api/v1/cover';
  static const String _entityPath = '/music/api/v1/entity';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
      responseType: ResponseType.json,
      validateStatus: (code) => code != null && code < 500,
    ),
  );

  /// 当前是否可用（非中继连接 + 已登录）。
  bool get available {
    final api = FeiNiuApiClient.instance;
    return !api.relayMode &&
        api.baseUrl.isNotEmpty &&
        api.token.isNotEmpty;
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

  /// 写入歌手/专辑封面图片。
  ///
  /// 服务端增强负责写文件 + 更新 DB `cover_guid`。失败抛异常（携带服务器 msg）。
  Future<void> uploadCover({
    required EntityEditKind kind,
    required String guid,
    required List<int> bytes,
  }) async {
    final base = baseUrl;
    if (base == null) throw StateError('中继连接下不可用');
    final response = await _dio.post<Map<String, dynamic>>(
      '$base$_coverPath',
      data: {
        'type': kind.apiName,
        'guid': guid,
        'imageBase64': base64Encode(bytes),
      },
      options: Options(
        headers: {
          ..._authHeaders(),
          'Content-Type': 'application/json',
        },
      ),
    );
    _throwIfFailed(response, '封面写入失败');
  }

  /// 修改歌手/专辑名称。
  Future<void> updateName({
    required EntityEditKind kind,
    required String guid,
    required String name,
  }) async {
    final base = baseUrl;
    if (base == null) throw StateError('中继连接下不可用');
    final response = await _dio.post<Map<String, dynamic>>(
      '$base$_entityPath',
      data: {
        'type': kind.apiName,
        'guid': guid,
        'name': name,
        'action': 'update',
      },
      options: Options(
        headers: {
          ..._authHeaders(),
          'Content-Type': 'application/json',
        },
      ),
    );
    _throwIfFailed(response, '名称修改失败');
  }

  /// 创建实体（专辑/歌手），返回新实体的 guid。
  Future<String> createEntity({
    required EntityEditKind kind,
    required String name,
  }) async {
    final base = baseUrl;
    if (base == null) throw StateError('中继连接下不可用');
    final response = await _dio.post<Map<String, dynamic>>(
      '$base$_entityPath',
      data: {
        'type': kind.apiName,
        'name': name,
        'action': 'create',
      },
      options: Options(
        headers: {
          ..._authHeaders(),
          'Content-Type': 'application/json',
        },
      ),
    );
    final data = response.data;
    if (data == null || data['code'] != 0) {
      throw Exception(data?['msg'] as String? ?? '实体创建失败');
    }
    final guid = (data['data'] as Map<String, dynamic>?)?['guid'] as String?;
    if (guid == null || guid.isEmpty) {
      throw Exception('实体创建失败：服务端未返回 guid');
    }
    return guid;
  }

  void _throwIfFailed(
    Response<Map<String, dynamic>> response,
    String fallbackMsg,
  ) {
    final data = response.data;
    if (data == null || data['code'] != 0) {
      throw Exception(data?['msg'] as String? ?? fallbackMsg);
    }
  }

  Map<String, String> _authHeaders() {
    return {
      'X-API-Key': FeiNiuApiClient.instance.token,
    };
  }
}
