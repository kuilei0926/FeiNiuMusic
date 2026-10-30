import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/router/app_router.dart';
import 'package:feiniu_music/app/services/player_service.dart';
import 'package:feiniu_music/app/state/settings_state.dart';
import 'package:feiniu_music/app/state/song_state.dart';
import 'package:feiniu_music/app/utils/route_visibility.dart';
import 'package:feiniu_music/components/layout/bottom_island/bottom_island_host.dart';
import 'package:feiniu_music/pages/player/widgets/player_bottom_panel.dart';
import 'package:feiniu_music/components/player/vinyl_player_gesture_area.dart';

const _song = SongEntity(
  id: 'navigation-song',
  title: '正在播放的歌曲',
  artist: '测试歌手',
);

class _RouteLog extends NavigatorObserver {
  final List<Route<dynamic>> pushes = [];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes.add(route);
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BottomIslandSettings.style.value = BottomIslandStyle.c1;
    AppLayoutSettings.resetForTest();
    AppGlassSettings.liquidGlassEnabled.value = false;
    AppBackgroundSettings.panelBlurEnabled.value = false;
    final player = PlayerService.instance;
    player.currentSong.value = _song;
    player.snapshot.value = PlaybackSnapshot(
      song: _song,
      queue: [_song],
      index: 0,
      isPlaying: false,
      position: const Duration(seconds: 15),
      duration: const Duration(minutes: 3),
      bufferedPosition: Duration.zero,
    );
  });
  tearDown(() {
    PlayerService.instance.currentSong.value = null;
    PlayerService.instance.snapshot.value = PlaybackSnapshot.initial();
    BottomIslandSettings.resetForTest();
  });

  Widget scene(_RouteLog log) => MaterialApp(
    navigatorObservers: [appRouteObserver, log],
    onGenerateRoute: (settings) => settings.name == AppRoutes.player
        ? MaterialPageRoute<void>(
            settings: settings,
            builder: (_) =>
                const Scaffold(body: Text('full-player-destination')),
          )
        : null,
    home: const Scaffold(
      body: Align(alignment: Alignment.bottomCenter, child: BottomIslandHost()),
    ),
  );

  for (final style in [
    BottomIslandStyle.c1,
    BottomIslandStyle.c2,
    BottomIslandStyle.c3,
  ]) {
    testWidgets(
      '${style.name} opens full player directly once and returns in one step',
      (tester) async {
        BottomIslandSettings.style.value = style;
        final log = _RouteLog();
        await tester.pumpWidget(scene(log));
        await tester.pump();
        final c2 = style == BottomIslandStyle.c2;
        final open = find.byKey(
          ValueKey(c2 ? 'island-c2-player' : 'island-open-player'),
        );
        final activate = c2
            ? tester.widget<VinylPlayerGestureArea>(open).onOpen!
            : tester.widget<InkWell>(open).onTap!;
        if (c2) {
          await tester.drag(open, const Offset(0, -70));
        } else {
          await tester.tap(open);
        }
        activate();
        await tester.pumpAndSettle();
        expect(find.text('full-player-destination'), findsOneWidget);
        expect(
          log.pushes.where((route) => route.settings.name == AppRoutes.player),
          hasLength(1),
        );
        expect(log.pushes.whereType<PopupRoute<dynamic>>(), isEmpty);
        expect(find.byType(PlayerPlaylistSheet), findsNothing);
        Navigator.of(
          tester.element(find.text('full-player-destination')),
        ).pop();
        await tester.pumpAndSettle();
        expect(open, findsOneWidget);
        expect(find.byType(BottomSheet), findsNothing);
        if (c2) {
          await tester.drag(open, const Offset(0, -70));
        } else {
          await tester.tap(open);
        }
        await tester.pumpAndSettle();
        expect(
          log.pushes.where((route) => route.settings.name == AppRoutes.player),
          hasLength(2),
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'C3 queue opens directly and closing it leaves no intermediate player',
    (tester) async {
      BottomIslandSettings.style.value = BottomIslandStyle.c3;
      final log = _RouteLog();
      await tester.pumpWidget(scene(log));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('island-queue')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(PlayerPlaylistSheet), findsOneWidget);
      expect(log.pushes.whereType<PopupRoute<dynamic>>(), hasLength(1));
      expect(
        log.pushes.where((route) => route.settings.name == AppRoutes.player),
        isEmpty,
      );
      Navigator.of(tester.element(find.byType(PlayerPlaylistSheet))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byKey(const ValueKey('island-open-player')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('island-open-player')));
      await tester.pumpAndSettle();
      expect(find.text('full-player-destination'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
