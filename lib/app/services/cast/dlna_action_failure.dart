import 'package:flutter/services.dart';

class DlnaActionFailure {
  const DlnaActionFailure({
    required this.action,
    required this.category,
    this.upnpCode,
    this.httpStatus,
    this.elapsedMs,
    this.causeTypes = const [],
  });

  final String action;
  final String category;
  final int? upnpCode;
  final int? httpStatus;
  final int? elapsedMs;
  final List<String> causeTypes;

  static DlnaActionFailure? from(Object error) {
    if (error is! PlatformException || error.code != 'dlna_action_failed') {
      return null;
    }
    final details = error.details;
    if (details is! Map) return null;
    String safeToken(Object? value, String fallback) {
      if (value is String &&
          RegExp(r'^[A-Za-z_][A-Za-z0-9_.$]{0,79}$').hasMatch(value)) {
        return value;
      }
      return fallback;
    }

    int? integer(Object? value) => value is int && value >= 0 ? value : null;
    final causes = details['causeTypes'];
    return DlnaActionFailure(
      action: safeToken(details['action'], 'UnknownAction'),
      category: safeToken(details['category'], 'action_failed'),
      upnpCode: integer(details['upnpCode']),
      httpStatus: integer(details['httpStatus']),
      elapsedMs: integer(details['elapsedMs']),
      causeTypes: causes is List
          ? causes.take(8).map((value) => safeToken(value, 'Unknown')).toList()
          : const [],
    );
  }

  bool get isFormatError =>
      category == 'upnp_fault' && const {704, 714}.contains(upnpCode);

  String get diagnostic =>
      'action=$action category=$category '
      'upnp=${upnpCode ?? 'unknown'} http=${httpStatus ?? 'unknown'} '
      'elapsedMs=${elapsedMs ?? 'unknown'} causes=${causeTypes.join(',')}';

  String get userMessage {
    final reason = switch (category) {
      'timeout' => '设备响应超时，请检查设备和网络',
      'network' => '无法与设备通信，请检查网络',
      'invalid_response' => '设备响应无法解析，请导出诊断日志',
      'upnp_fault' when isFormatError => '设备拒绝当前音频格式',
      'upnp_fault' => '设备拒绝操作',
      'http_error' => '设备返回 HTTP 错误',
      _ => '设备操作失败，请导出诊断日志',
    };
    final codes = [
      if (upnpCode != null) 'UPnP $upnpCode',
      if (httpStatus != null) 'HTTP $httpStatus',
    ];
    return '$reason（$action${codes.isEmpty ? '' : '，${codes.join('，')}'}）';
  }
}
