import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../state/settings_fn_state.dart';
import 'fn_models.dart';

/// FN 连接探测服务（单例）
///
/// 核心职责：
/// 1. 调用 FN 接口获取连接参数
/// 2. 按优先级分层探测可用链路（1 秒超时）
/// 3. 返回首个可用的连接地址
///
/// 探测规则：
/// - 内网 IPv4 永久最高优先级
/// - HTTPS 端口优先于 HTTP
/// - 公网优先模式探测公网 IPv6 → IPv4 → 中继
/// - 中继优先模式跳过公网直连
/// - 所有单链路探测 1 秒超时
class FnConnectionProbeService {
  FnConnectionProbeService._();

  static final FnConnectionProbeService instance = FnConnectionProbeService._();

  /// FN 接口签名常量
  static const String _authxPrefix = 'NDzZTVxnRKP8Z0jXg1VAMonaG8akvh';
  static const String _apiKey = 'zIGtkc3dqZnJpd29qZXJqa2w7c';

  /// 是否正在探测中
  final ValueNotifier<bool> isProbing = ValueNotifier(false);

  /// 独立 Dio 实例，不与主 API 客户端共享配置
  final Dio _probeDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 2),
      receiveTimeout: const Duration(seconds: 2),
      sendTimeout: const Duration(seconds: 2),
      followRedirects: false,
    ),
  );

  CancelToken? _cancelToken;

  /// 在途连接探测（probe / probeSmart 单飞行共用）
  ///
  /// 相同 FNID 的并发调用复用同一探测请求，避免重复探测——例如登录页自动
  /// 静默探测与用户点击登录同时发起时，只探测一次、共享同一结果。
  Future<ConnectionProbeResult>? _inflightProbe;
  String? _inflightProbeFnId;

  /// 执行分层探测
  ///
  /// [fnId] - FNID（如 "kuilei0926"）
  /// [order] - 连接优先级顺序，默认读 [AppFnConnectionSettings.connectionOrder]
  ///
  /// 传输协议按地址类型自动选择（IP 先 HTTP、域名/中继仅 HTTPS），
  /// 见 [buildProbeCandidateSpecs]。
  ///
  /// 返回 [ConnectionProbeResult]，包含最终成功的 URL。
  /// 所有链路失败时抛出 [Exception]。
  Future<ConnectionProbeResult> probe({
    required String fnId,
    List<ProbeCandidateGroup>? order,
  }) {
    return _joinOrStartProbe(
      fnId: fnId,
      start: () => _probeCore(
        fnId: fnId,
        order: order,
      ),
    );
  }

  /// 分层探测核心实现（被 [probe] 调用，受单飞行守卫）
  Future<ConnectionProbeResult> _probeCore({
    required String fnId,
    List<ProbeCandidateGroup>? order,
  }) async {
    isProbing.value = true;
    _cancelToken = CancelToken();

    try {
      // Step 1: 调用 FN API 获取连接参数
      if (kDebugMode) {
        debugPrint('[FnProbe] Fetching connection params for fnId=$fnId');
      }
      final params = await _callFnConnectionApi(fnId, _cancelToken!);

      // Step 2: 分层探测
      if (kDebugMode) {
        debugPrint('[FnProbe] Starting hierarchical probe');
      }
      final result = await _hierarchicalProbe(
        fnId,
        params,
        cancelToken: _cancelToken!,
        order: order ?? AppFnConnectionSettings.connectionOrder.value,
      );

      if (kDebugMode) {
        debugPrint(
          '[FnProbe] Probe succeeded: ${result.serverUrl} (${result.probeMethod})',
        );
      }
      return result;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        throw Exception('探测已取消');
      }
      throw Exception('连接探测失败：${_dioErrorMessage(e)}');
    } finally {
      isProbing.value = false;
      _cancelToken = null;
      _clearInflightProbe();
    }
  }

  /// 单飞行入口：相同 FNID 的并发探测复用同一在途请求，结果共享，不重复探测。
  ///
  /// 不同 FNID 并发（理论场景：用户在登录页改了 FNID 立即再点）仍走旧的
  /// 「探测进行中」守卫，避免拿到错误 FNID 的探测结果。全量探测
  /// （[probeAllCandidates]）在途时同样拒绝新探测，避免 cancel token 被覆盖。
  Future<ConnectionProbeResult> _joinOrStartProbe({
    required String fnId,
    required Future<ConnectionProbeResult> Function() start,
  }) {
    final inflight = _inflightProbe;
    if (inflight != null) {
      if (_inflightProbeFnId == fnId) {
        return inflight; // 复用同一探测，结果共享
      }
      throw Exception('探测正在进行中，请等待完成');
    }
    if (isProbing.value) {
      throw Exception('探测正在进行中，请等待完成');
    }
    final future = start();
    // 探测完成（成功或失败）后自动清空在途标记，下一次可正常发起
    final tracked = future.whenComplete(_clearInflightProbe);
    _inflightProbe = tracked;
    _inflightProbeFnId = fnId;
    return tracked;
  }

  void _clearInflightProbe() {
    _inflightProbe = null;
    _inflightProbeFnId = null;
  }

  @visibleForTesting
  void resetForTest() {
    _inflightProbe = null;
    _inflightProbeFnId = null;
    _cancelToken = null;
    isProbing.value = false;
  }

  @visibleForTesting
  Future<ConnectionProbeResult> joinOrStartProbeForTest({
    required String fnId,
    required Future<ConnectionProbeResult> Function() start,
  }) {
    return _joinOrStartProbe(fnId: fnId, start: start);
  }

  /// 取消当前探测
  void cancel() {
    _cancelToken?.cancel();
  }

  /// 缓存优先探测（仅升级，不降级）
  ///
  /// 下次打开优先验证上次成功连接的 URL 是否仍可用（200ms 快探）：
  /// - 缓存可达：仅探测优先级高于缓存的候选，若更高优先级链路可达则自动切换（升级）；
  ///   否则保持缓存连接（不降级）。
  /// - 缓存不可达或已不在当前候选列表（陈旧地址）：回退到完整分层探测。
  ///
  /// [cachedUrl] - 上次成功连接的 URL（来自 AppFnConnectionSettings）
  /// [cachedIsRelay] - 上次连接是否为中继模式
  /// [fnId] - FNID
  /// [order] - 连接优先级顺序，默认读 [AppFnConnectionSettings.connectionOrder]
  ///
  /// 返回 [ConnectionProbeResult]，包含最终成功的 URL。
  /// 所有链路失败时抛出 [Exception]。
  Future<ConnectionProbeResult> probeSmart({
    required String fnId,
    String? cachedUrl,
    bool cachedIsRelay = false,
    List<ProbeCandidateGroup>? order,
  }) {
    return _joinOrStartProbe(
      fnId: fnId,
      start: () => _probeSmartCore(
        fnId: fnId,
        cachedUrl: cachedUrl,
        cachedIsRelay: cachedIsRelay,
        order: order,
      ),
    );
  }

  /// 缓存优先探测核心实现（被 [probeSmart] 调用，受单飞行守卫）
  Future<ConnectionProbeResult> _probeSmartCore({
    required String fnId,
    String? cachedUrl,
    bool cachedIsRelay = false,
    List<ProbeCandidateGroup>? order,
  }) async {
    final effOrder = order ?? AppFnConnectionSettings.connectionOrder.value;

    isProbing.value = true;
    _cancelToken = CancelToken();

    try {
      if (kDebugMode) {
        debugPrint('[FnProbe] Trying cached connection: $cachedUrl');
      }

      // Step 1: 获取参数并构建按优先级排序的候选列表
      final params = await _callFnConnectionApi(fnId, _cancelToken!);
      final candidates = buildProbeCandidateSpecs(
        fnId: fnId,
        params: params,
        order: effOrder,
      );

      // Step 2: 缓存优先快探
      if (cachedUrl != null && cachedUrl.isNotEmpty) {
        final cachedIndex = candidates.indexWhere(
          (c) => c.address == cachedUrl,
        );
        if (cachedIndex >= 0) {
          final cacheOk = await _tryCachedAddress(
            cachedUrl,
            cachedIsRelay,
            _cancelToken!,
          );
          if (cacheOk) {
            if (_cancelToken!.isCancelled) throw Exception('探测已取消');

            // 探测优先级更高的候选（索引 < cachedIndex），首个可达者即升级
            final better = candidates.sublist(0, cachedIndex);
            if (better.isNotEmpty) {
              final results = await Future.wait(
                better.map((c) => _tryAddressWithDetail(c, _cancelToken!)),
              );
              for (var i = 0; i < results.length; i++) {
                if (_cancelToken!.isCancelled) throw Exception('探测已取消');
                if (results[i].isReachable) {
                  if (kDebugMode) {
                    debugPrint(
                      '[FnProbe] ✓ Upgraded (priority ${i + 1}): ${results[i].description}',
                    );
                  }
                  return ConnectionProbeResult(
                    serverUrl: results[i].address,
                    probeMethod: results[i].description,
                    isRelay: results[i].isRelay,
                  );
                }
              }
            }

            // 无更高优先级可达，保持缓存连接
            if (kDebugMode) {
              debugPrint('[FnProbe] Cached connection still valid: $cachedUrl');
            }
            return ConnectionProbeResult(
              serverUrl: cachedUrl,
              probeMethod: '缓存连接',
              isRelay: cachedIsRelay,
            );
          }
          // 缓存不可达 → 回退完整探测
        }
        // 缓存不在当前候选列表（陈旧地址）→ 忽略缓存，完整探测
      }

      // Step 3: 完整分层探测
      final result = await _hierarchicalProbe(
        fnId,
        params,
        cancelToken: _cancelToken!,
        order: effOrder,
      );

      if (kDebugMode) {
        debugPrint(
          '[FnProbe] Full probe succeeded: ${result.serverUrl} (${result.probeMethod})',
        );
      }
      return result;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        throw Exception('探测已取消');
      }
      throw Exception('连接探测失败：${_dioErrorMessage(e)}');
    } finally {
      isProbing.value = false;
      _cancelToken = null;
      _clearInflightProbe();
    }
  }

  /// 快速验证某个地址是否可达（200ms 快探）。
  ///
  /// 供自动重连的健康检查 / App 恢复检查使用：不触发完整探测，不发
  /// FN API，只探测当前连接 URL 的连通性。复用 [probeAllCandidates] 的
  /// 探测锁（isProbing）与 cancel token，避免与正在进行的全量探测并发
  /// 相互干扰。探测进行中返回 null（调用方按"可达"处理，跳过本次检查）。
  Future<bool?> isAddressReachable(String url, {bool isRelay = false}) async {
    if (isProbing.value) return null;
    isProbing.value = true;
    _cancelToken = CancelToken();
    try {
      return await _tryCachedAddress(url, isRelay, _cancelToken!);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        return null;
      }
      return false;
    } finally {
      isProbing.value = false;
      _cancelToken = null;
    }
  }

  /// 快速验证缓存连接是否可达（200ms 快探）
  Future<bool> _tryCachedAddress(
    String url,
    bool isRelay,
    CancelToken cancelToken,
  ) async {
    try {
      await _probeDio.getUri(
        Uri.parse(url),
        cancelToken: cancelToken,
        options: Options(
          connectTimeout: const Duration(milliseconds: 200),
          receiveTimeout: const Duration(seconds: 1),
          sendTimeout: const Duration(seconds: 1),
          followRedirects: false,
          validateStatus: (_) => true,
          headers: isRelay ? {'Cookie': 'mode=relay'} : null,
        ),
      );
      return true;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        rethrow;
      }
      return false;
    }
  }

  /// 调用 FN 接口获取连接参数
  Future<FnConnectionParams> _callFnConnectionApi(
    String fnId,
    CancelToken cancelToken,
  ) async {
    const apiPath = '/api/v1/fn/con';
    final url = 'https://5ddd.com$apiPath';
    final data = {'fnId': fnId};

    final response = await _probeDio.post(
      url,
      data: data,
      cancelToken: cancelToken,
      options: Options(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        headers: {'authx': _computeAuthx('post', apiPath, data)},
      ),
    );

    final parsed = FnConnectionResponse.fromJson(
      response.data as Map<String, dynamic>,
    );

    if (!parsed.isSuccess || parsed.data == null) {
      throw Exception(parsed.msg.isNotEmpty ? parsed.msg : 'FNID 查询失败，请检查输入');
    }

    return parsed.data!;
  }

  /// 计算 authx 签名请求头
  ///
  /// 注意：url 参数必须传相对路径（如 /api/v1/fn/con），
  /// 服务端签名校验用的是路径部分，不是完整 URL。
  ///
  /// 算法：
  ///   raw = PREFIX + url + nonce + timestamp + md5(参数) + apiKey
  ///   sign = md5(raw)
  ///   authx = nonce=xxx&timestamp=xxx&sign=xxx
  static String _computeAuthx(String method, String url, dynamic data) {
    final c = method == 'get'
        ? _sortAndSerializeQuery(data as Map<String, dynamic>?)
        : jsonEncode(data);
    final nonce = (Random().nextInt(900000) + 100000).toString().padLeft(
      6,
      '0',
    );
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final raw = [
      _authxPrefix,
      url,
      nonce,
      timestamp,
      _md5(c),
      _apiKey,
    ].join('_');
    final sign = _md5(raw);
    return 'nonce=$nonce&timestamp=$timestamp&sign=$sign';
  }

  static String _md5(String input) {
    return crypto.md5.convert(utf8.encode(input)).toString();
  }

  static String _sortAndSerializeQuery(Map<String, dynamic>? params) {
    if (params == null || params.isEmpty) return '';
    final keys = params.keys.toList()..sort();
    return keys
        .map((k) => '$k=${Uri.encodeComponent(params[k].toString())}')
        .join('&');
  }

  /// 探测所有候选链路（用于「FN Connect」设置页完整展示）
  ///
  /// 与 [probe] 不同，此方法会探测*所有*候选地址并返回完整结果列表，
  /// 同时返回首个可用连接。
  ///
  /// 返回一个元组：(所有候选结果列表, 首个成功的 [ConnectionProbeResult] 或 null)
  Future<
    ({
      List<ProbeCandidateResult> candidates,
      ConnectionProbeResult? firstSuccess,
    })
  >
  probeAllCandidates({
    required String fnId,
    List<ProbeCandidateGroup>? order,
  }) async {
    if (isProbing.value) {
      throw Exception('探测正在进行中，请等待完成');
    }

    isProbing.value = true;
    _cancelToken = CancelToken();

    try {
      final params = await _callFnConnectionApi(fnId, _cancelToken!);
      final candidates = buildProbeCandidateSpecs(
        fnId: fnId,
        params: params,
        order: order ?? AppFnConnectionSettings.connectionOrder.value,
      );

      // 并行探测所有候选（默认所有候选中继模式共 4 条以上，并行可加速）
      final results = await Future.wait(
        candidates.map((c) => _tryAddressWithDetail(c, _cancelToken!)),
      );

      final firstSuccess = results
          .where((r) => r.isReachable)
          .map(
            (r) => ConnectionProbeResult(
              serverUrl: r.address,
              probeMethod: r.description,
              isRelay: r.isRelay,
            ),
          )
          .firstOrNull;

      return (candidates: results, firstSuccess: firstSuccess);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        throw Exception('探测已取消');
      }
      throw Exception('连接探测失败：${_dioErrorMessage(e)}');
    } finally {
      isProbing.value = false;
      _cancelToken = null;
    }
  }

  /// 并发探测所有候选地址，按优先级取首个可用
  Future<ConnectionProbeResult> _hierarchicalProbe(
    String fnId,
    FnConnectionParams params, {
    required CancelToken cancelToken,
    required List<ProbeCandidateGroup> order,
  }) async {
    final candidates = buildProbeCandidateSpecs(
      fnId: fnId,
      params: params,
      order: order,
    );

    // 并发探测所有候选
    final results = await Future.wait(
      candidates.map((c) => _tryAddressWithDetail(c, cancelToken)),
    );

    // 按原始优先级顺序取第一个可达的
    for (var i = 0; i < results.length; i++) {
      if (cancelToken.isCancelled) {
        throw Exception('探测已取消');
      }
      final r = results[i];
      if (r.isReachable) {
        if (kDebugMode) {
          debugPrint(
            '[FnProbe] ✓ Success (priority ${i + 1}): ${r.description}',
          );
        }
        return ConnectionProbeResult(
          serverUrl: r.address,
          probeMethod: r.description,
          isRelay: r.isRelay,
        );
      }
    }

    // 全部失败
    throw Exception('所有链路均无法连接，请检查网络或稍后重试。');
  }

  /// 探测单条链路并返回探测结果详情
  Future<ProbeCandidateResult> _tryAddressWithDetail(
    ProbeCandidateSpec candidate,
    CancelToken cancelToken,
  ) async {
    try {
      final options = Options(
        connectTimeout: const Duration(seconds: 1),
        receiveTimeout: const Duration(seconds: 1),
        sendTimeout: const Duration(seconds: 1),
        followRedirects: false,
        validateStatus: (_) => true,
        headers: candidate.relayMode ? {'Cookie': 'mode=relay'} : null,
      );

      await _probeDio.getUri(
        Uri.parse(candidate.address),
        options: options,
        cancelToken: cancelToken,
      );

      return ProbeCandidateResult(
        address: candidate.address,
        description: candidate.description,
        group: candidate.group,
        ipLabel: candidate.ipLabel,
        isRelay: candidate.relayMode,
        isReachable: true,
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        rethrow;
      }
      return ProbeCandidateResult(
        address: candidate.address,
        description: candidate.description,
        group: candidate.group,
        ipLabel: candidate.ipLabel,
        isRelay: candidate.relayMode,
        isReachable: false,
        error: _dioErrorMessage(e),
      );
    }
  }

  String _dioErrorMessage(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
        return '连接超时';
      case DioExceptionType.receiveTimeout:
        return '响应超时';
      case DioExceptionType.sendTimeout:
        return '发送超时';
      case DioExceptionType.connectionError:
        return '网络连接错误';
      case DioExceptionType.badResponse:
        return '服务器返回错误 (${e.response?.statusCode})';
      case DioExceptionType.cancel:
        return '请求已取消';
      default:
        return e.message ?? '未知网络错误';
    }
  }
}
