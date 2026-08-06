import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/tv_detection.dart';

/// TV 检测单元测试。
///
/// 用 [TvDetection.setOverride] 短路原生通道，避免测试环境真正调用
/// MethodChannel（无平台通道实现时 invokeMethod 会抛 MissingPluginException）。
void main() {
  tearDown(() {
    TvDetection.setOverride(null);
  });

  test('override=true 直接返回 true，不触发原生查询', () async {
    TvDetection.setOverride(true);
    expect(await TvDetection.detect(), isTrue);
    expect(TvDetection.result.value, isTrue);
  });

  test('override=false 直接返回 false，不触发原生查询', () async {
    TvDetection.setOverride(false);
    expect(await TvDetection.detect(), isFalse);
    expect(TvDetection.result.value, isFalse);
  });

  test('无 override 且非 Android 环境 → 返回 false（不抛异常）', () async {
    // 测试环境 platform 为 Windows/macOS（非 Android），且无通道实现；
    // detect() 必须吞掉 MissingPluginException 返回 false。
    final result = await TvDetection.detect();
    expect(result, isFalse);
  });

  test('setOverride(null) 恢复自动检测', () async {
    TvDetection.setOverride(true);
    expect(await TvDetection.detect(), isTrue);
    TvDetection.setOverride(null);
    // 清除 override 后回到自动路径（非 Android 测试环境 → false）。
    expect(await TvDetection.detect(), isFalse);
  });
}
