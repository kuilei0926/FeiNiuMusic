import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_layout_state.dart';
import 'package:feiniu_music/app/tv/tv_layout.dart';
import 'package:feiniu_music/app/theme/app_visual_theme.dart';

/// TV 布局辅助与模式模型的单元测试。
///
/// 验证：
/// - TV 模式永不显示底部导航栏（effectiveTabletMode 生效）；
/// - TV 网格列数按宽度分级；
/// - TV 主题 focusColor 仅在 TV 模式生效（手机端主题逐字节不变）。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLayoutSettings.resetForTest();
  });

  tearDown(() {
    AppLayoutSettings.resetForTest();
  });

  group('AppLayoutSettings.effectiveTabletMode', () {
    test('手机默认：tabletMode=false, tvMode=false → effective=false', () {
      expect(AppLayoutSettings.effectiveTabletMode, isFalse);
    });

    test('用户平板模式开启 → effective=true', () {
      AppLayoutSettings.tabletMode.value = true;
      expect(AppLayoutSettings.effectiveTabletMode, isTrue);
    });

    test('TV 模式开启 → effective=true，即使 tabletMode=false', () {
      AppLayoutSettings.tvMode.value = true;
      expect(AppLayoutSettings.effectiveTabletMode, isTrue);
    });

    test('effectiveTabletModeNotifier 随任一来源变化', () {
      bool? notified;
      AppLayoutSettings.effectiveTabletModeNotifier.addListener(() {
        notified = AppLayoutSettings.effectiveTabletModeNotifier.value;
      });
      AppLayoutSettings.tvMode.value = true;
      expect(notified, isTrue);
      AppLayoutSettings.tvMode.value = false;
      expect(notified, isFalse);
    });

    test('resetForTest 复位所有模式', () {
      AppLayoutSettings.tabletMode.value = true;
      AppLayoutSettings.tvMode.value = true;
      AppLayoutSettings.resetForTest();
      expect(AppLayoutSettings.effectiveTabletMode, isFalse);
    });
  });

  group('AppLayoutSettings.syncTvMode（手动强制开关）', () {
    test('自动检测关闭 + 手动强制开 → tvMode=true', () {
      TvDetectionAutoValue.value = false;
      AppLayoutSettings.syncTvMode();
      expect(AppLayoutSettings.tvMode.value, isFalse);

      AppLayoutSettings.forceTvMode.value = true;
      AppLayoutSettings.syncTvMode();
      expect(AppLayoutSettings.tvMode.value, isTrue);
    });

    test('自动检测开 + 手动强制关 → tvMode=true（或关系）', () {
      TvDetectionAutoValue.value = true;
      AppLayoutSettings.syncTvMode();
      expect(AppLayoutSettings.tvMode.value, isTrue);
    });

    test('手动强制关 + 自动检测关 → tvMode=false', () {
      TvDetectionAutoValue.value = false;
      AppLayoutSettings.forceTvMode.value = false;
      AppLayoutSettings.syncTvMode();
      expect(AppLayoutSettings.tvMode.value, isFalse);
    });

    test('重启后持久化的强制 TV 开关恢复生效（load→sync 顺序与 main 一致）', () async {
      // 模拟上次启动时打开过「TV 模式」开关并已持久化。启动顺序必须与
      // main() 一致：先 ensureLoaded() 读回 forceTvMode，再 syncTvMode()。
      SharedPreferences.setMockInitialValues({'setting_force_tv_mode': true});
      AppLayoutSettings.resetForTest();
      await AppLayoutSettings.ensureLoaded();
      expect(AppLayoutSettings.forceTvMode.value, isTrue);
      expect(AppLayoutSettings.tvMode.value, isFalse); // load 不自动合并
      AppLayoutSettings.syncTvMode();
      expect(AppLayoutSettings.tvMode.value, isTrue);
    });
  });

  group('TvLayout.gridColumns', () {
    test('宽度分级：1080p 电视 6 列，中屏 5 列，小屏 4 列', () {
      expect(TvLayout.gridColumns(1920), 6);
      expect(TvLayout.gridColumns(1600), 6);
      expect(TvLayout.gridColumns(1366), 5);
      expect(TvLayout.gridColumns(1200), 5);
      expect(TvLayout.gridColumns(1024), 4);
      expect(TvLayout.gridColumns(800), 4);
    });

    test('cardAspectRatio 覆盖 4/5/6 列', () {
      expect(TvLayout.cardAspectRatio(4), 0.88);
      expect(TvLayout.cardAspectRatio(5), 0.86);
      expect(TvLayout.cardAspectRatio(6), 0.84);
    });
  });

  group('AppLayoutSettings.consumeTvEdgeHint（首次启动提示）', () {
    test('首次调用返回 true，之后返回 false（只提醒一次）', () async {
      // 空 prefs 加载 → _tvEdgeHintShown=false（未展示过）。
      SharedPreferences.setMockInitialValues({});
      AppLayoutSettings.resetForTest();
      await AppLayoutSettings.ensureLoaded();
      expect(await AppLayoutSettings.consumeTvEdgeHint(), isTrue);
      expect(await AppLayoutSettings.consumeTvEdgeHint(), isFalse);
    });

    test('已展示过（prefs 为 true）→ 不再提醒', () async {
      SharedPreferences.setMockInitialValues({
        'setting_tv_edge_hint_shown': true,
      });
      AppLayoutSettings.resetForTest();
      await AppLayoutSettings.ensureLoaded();
      expect(await AppLayoutSettings.consumeTvEdgeHint(), isFalse);
    });
  });

  group('TV 主题 focusColor', () {
    test('非 TV：focusColor 保持默认（手机端主题逐字节不变）', () {
      final base = ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      );
      final theme = buildMiuixMaterialTheme(base, base.colorScheme);
      // copyWith(focusColor: null) 不会覆盖默认值，应等于 base 的计算结果。
      expect(theme.focusColor, base.focusColor);
      expect(theme.highlightColor, base.highlightColor);
    });

    test('TV：focusColor 为 primary 半透明色（区别于默认）', () {
      final base = ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      );
      final scheme = base.colorScheme;
      final theme = buildMiuixMaterialTheme(base, scheme, isTv: true);
      // ThemeData.focusColor 非空：TV 分支覆盖为主题色半透明，与默认不同。
      expect(theme.focusColor, isNot(base.focusColor));
      expect(theme.focusColor.a, closeTo(0.34, 0.01));
    });
  });
}