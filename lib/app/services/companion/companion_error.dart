import 'package:dio/dio.dart';

/// 配套服务（FnMusicEnhance，经 nginx /music-enhance/ 提供）连接错误的统一中文化。
///
/// 各 companion service（歌词 / 元数据 / 文件夹）在捕获 [DioException] 时调用，
/// 把底层英文错误映射为对用户友好的中文提示，避免把 "Connection refused"
/// 等原始信息直接渲染到界面。
String companionErrorText(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
      return '连接超时：无法连接 NAS 上的服务端增强';
    case DioExceptionType.sendTimeout:
      return '发送超时：无法连接 NAS 上的服务端增强';
    case DioExceptionType.receiveTimeout:
      return '响应超时：服务端增强未响应';
    case DioExceptionType.connectionError:
      return '未检测到 NAS 上运行的服务端增强（连接被拒绝）';
    case DioExceptionType.badCertificate:
      return '证书校验失败';
    case DioExceptionType.badResponse:
      final status = e.response?.statusCode;
      if (status == 401) return '登录 token 无效或已过期，请重新登录';
      if (status != null) return '服务端增强返回异常（HTTP $status）';
      return '服务端增强返回异常';
    case DioExceptionType.cancel:
      return '请求已取消';
    default:
      // 覆盖 DioExceptionType.unknown 及不同 dio 版本新增的枚举
      // （如 5.11.0 的 transformTimeout）
      return '连接失败：${e.message}';
  }
}

/// 把任意异常转为对用户友好的文本（去掉 `Exception: ` 前缀）。
///
/// 配套服务方法统一抛 `Exception(友好中文)`，UI 显示时用此函数取纯文本，
/// 避免 toast 里出现 `Exception: 未检测到 NAS ...` 这种前缀。
String friendlyCompanionError(Object error) {
  final text = error.toString();
  return text.replaceFirst('Exception: ', '').replaceFirst('StateError: ', '');
}

