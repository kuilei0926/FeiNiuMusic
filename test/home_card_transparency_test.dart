import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_background_state.dart';
import 'package:feiniu_music/app/state/settings_layout_state.dart';
import 'package:feiniu_music/pages/home/widgets/home_large_layout.dart';
import 'package:feiniu_music/pages/home/widgets/home_panel.dart';
import 'package:feiniu_music/pages/home/widgets/home_section_feedback.dart';
import 'package:feiniu_music/pages/home/widgets/home_shortcut_menu.dart';
import 'package:feiniu_music/pages/settings/app_appearance_settings_page.dart';
import 'package:feiniu_music/components/common/setting_widgets.dart';

const _items = [
  HomeShortcutItem(icon: Icons.music_note, label: '歌曲'),
  HomeShortcutItem(icon: Icons.people, label: '歌手'),
  HomeShortcutItem(icon: Icons.album, label: '专辑'),
  HomeShortcutItem(icon: Icons.style, label: '风格'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppBackgroundSettings.resetForTest();
    AppLayoutSettings.resetForTest();
  });

  tearDown(() {
    AppBackgroundSettings.resetForTest();
    AppLayoutSettings.resetForTest();
  });

  test('default keeps existing solid cards', () async {
    await AppBackgroundSettings.ensureLoaded();
    expect(AppBackgroundSettings.homeCardOpacity.value, 1);
    expect(AppBackgroundSettings.effectiveHomeCardOpacity, 1);
  });

  test('saves opacity and restores it after restart', () async {
    await AppBackgroundSettings.ensureLoaded();
    await AppBackgroundSettings.setBackgroundImagePath('/background.jpg');
    await AppBackgroundSettings.setHomeCardOpacity(0.55);
    AppBackgroundSettings.resetForTest();
    await AppBackgroundSettings.ensureLoaded();
    expect(AppBackgroundSettings.effectiveHomeCardOpacity, 0.55);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('setting_home_card_opacity'), 0.55);
  });

  test(
    'removing image uses solid cards while preserving saved opacity',
    () async {
      await AppBackgroundSettings.ensureLoaded();
      await AppBackgroundSettings.setBackgroundImagePath('/background.jpg');
      await AppBackgroundSettings.setHomeCardOpacity(0.4);
      await AppBackgroundSettings.setBackgroundImagePath(null);
      expect(AppBackgroundSettings.effectiveHomeCardOpacity, 1);
      await AppBackgroundSettings.setBackgroundImagePath('/other.jpg');
      expect(AppBackgroundSettings.effectiveHomeCardOpacity, 0.4);
    },
  );

  test('clamps stored and new opacity to valid bounds', () async {
    SharedPreferences.setMockInitialValues({'setting_home_card_opacity': -1.0});
    await AppBackgroundSettings.ensureLoaded();
    expect(AppBackgroundSettings.homeCardOpacity.value, 0);
    await AppBackgroundSettings.setHomeCardOpacity(2);
    expect(AppBackgroundSettings.homeCardOpacity.value, 1);
    await AppBackgroundSettings.setHomeCardOpacity(-2);
    expect(AppBackgroundSettings.homeCardOpacity.value, 0);
    await AppBackgroundSettings.setHomeCardOpacity(double.nan);
    expect(AppBackgroundSettings.homeCardOpacity.value, 1);
  });

  for (final brightness in Brightness.values) {
    testWidgets('live background-only opacity in ${brightness.name} theme', (
      tester,
    ) async {
      final theme = ThemeData(brightness: brightness);
      await AppBackgroundSettings.ensureLoaded();
      await AppBackgroundSettings.setBackgroundImagePath('/background.jpg');
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(body: HomePanel(child: Text('清晰的文字'))),
        ),
      );
      final surface = find.descendant(
        of: find.byType(HomePanel),
        matching: find.byType(Material),
      );
      Color color() => tester.widget<Material>(surface).color!;
      expect(color(), theme.colorScheme.surfaceContainerLow);
      AppBackgroundSettings.homeCardOpacity.value = 0.4;
      await tester.pump();
      await tester.pumpAndSettle();
      expect(color().a, closeTo(0.4, 0.01));
      expect(find.text('清晰的文字'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(HomePanel),
          matching: find.byType(Opacity),
        ),
        findsNothing,
      );
      AppBackgroundSettings.homeCardOpacity.value = 0;
      await tester.pumpAndSettle();
      expect(color().a, 0);
      AppBackgroundSettings.backgroundImagePath.value = null;
      await tester.pumpAndSettle();
      expect(color().a, 1);
    });
  }

  testWidgets(
    'appearance slider updates card background and hides without image',
    (tester) async {
      await AppBackgroundSettings.ensureLoaded();
      await AppBackgroundSettings.setBackgroundImagePath('/background.jpg');
      await tester.pumpWidget(
        const MaterialApp(home: AppAppearanceSettingsPage()),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.scrollUntilVisible(
        find.text('首页卡片透明度'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      final setting = find.ancestor(
        of: find.text('首页卡片透明度'),
        matching: find.byType(AppSettingSlider),
      );
      final slider = find.descendant(
        of: setting,
        matching: find.byType(Slider),
      );
      tester.widget<Slider>(slider).onChanged!(40);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(AppBackgroundSettings.homeCardOpacity.value, closeTo(0.6, 0.001));
      expect(
        find.descendant(of: setting, matching: find.text('40%')),
        findsOneWidget,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('setting_home_card_opacity'), closeTo(0.6, 0.001));
      await AppBackgroundSettings.setBackgroundImagePath(null);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('首页卡片透明度'), findsNothing);
      expect(AppBackgroundSettings.effectiveHomeCardOpacity, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large layout modules follow opacity without nested solid shortcuts',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await AppBackgroundSettings.ensureLoaded();
      AppBackgroundSettings.backgroundImagePath.value = '/background.jpg';
      AppBackgroundSettings.homeCardOpacity.value = 0.5;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeLargeLayout(
              onPlayRoam: () {},
              onRefreshRoam: () {},
              shortcutItems: _items,
              recentSongs: const [],
              onPlayRecent: () {},
              onOpenRecent: () {},
              onTapRecent: (_) {},
              playlists: const [],
              onOpenPlaylists: () {},
              onTapPlaylist: (_) {},
              recentAlbums: const [],
              onOpenAlbums: () {},
              onTapAlbum: (_) {},
              recentTracks: const [],
              onOpenSongs: () {},
              onTapTrack: (_) {},
              favoriteSongs: const [],
              onOpenFavorite: () {},
              onTapFavorite: (_) {},
              sectionFeedback: const {
                HomeSection.playlists: Text('暂无歌单'),
                HomeSection.albums: Text('暂无专辑'),
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final panels = tester.widgetList<Material>(
        find.descendant(
          of: find.byType(HomePanel),
          matching: find.byType(Material),
        ),
      );
      expect(
        panels.where((p) => p.color!.a > 0).length,
        greaterThanOrEqualTo(4),
      );
      expect(
        panels.every((p) => p.color!.a == 0 || (p.color!.a - 0.5).abs() < 0.01),
        isTrue,
      );
      final shortcuts = find.descendant(
        of: find.byType(HomeShortcutMenu),
        matching: find.byType(Material),
      );
      expect(
        tester.widgetList<Material>(shortcuts).every((m) => m.color!.a == 0),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
