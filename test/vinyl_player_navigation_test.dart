import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/router/app_router.dart';
import 'package:feiniu_music/app/services/player_service.dart';
import 'package:feiniu_music/app/state/settings_state.dart';
import 'package:feiniu_music/app/state/song_state.dart';
import 'package:feiniu_music/app/utils/route_visibility.dart';
import 'package:feiniu_music/components/layout/bottom_island/bottom_island_host.dart';
import 'package:feiniu_music/components/player/vinyl_player_sheet.dart';
import 'package:feiniu_music/pages/player/widgets/player_bottom_panel.dart';

const _song = SongEntity(
  id: 'navigation-song',
  title: '正在播放的歌曲',
  artist: '测试歌手',
);

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

  for (final queue in [false, true]) {
    testWidgets(
      'sheet closes completely before ${queue ? 'queue' : 'full player'} opens once',
      (tester) async {
        var fullPages = 0;
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [appRouteObserver],
            onGenerateRoute: (settings) {
              if (settings.name == AppRoutes.player) {
                fullPages++;
                return MaterialPageRoute<void>(
                  settings: settings,
                  builder: (_) =>
                      const Scaffold(body: Text('full-player-destination')),
                );
              }
              return null;
            },
            home: const Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: BottomIslandHost(),
              ),
            ),
          ),
        );
        await tester.pump();
        final open = find.byKey(const ValueKey('island-open-player'));
        await tester.tap(open);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.byType(VinylPlayerSheet), findsOneWidget);
        final action = find.byKey(
          ValueKey(queue ? 'vinyl-sheet-queue' : 'vinyl-sheet-full-player'),
        );
        await tester.scrollUntilVisible(
          action,
          100,
          scrollable: find
              .descendant(
                of: find.byType(VinylPlayerSheet),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        final activate = queue
            ? tester.widget<IconButton>(action).onPressed!
            : tester.widget<TextButton>(action).onPressed!;
        await tester.tap(action);
        activate();
        await tester.pump();
        expect(fullPages, 0);
        expect(find.byType(PlayerPlaylistSheet), findsNothing);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.byType(VinylPlayerSheet), findsNothing);
        if (queue) {
          expect(find.byType(PlayerPlaylistSheet), findsOneWidget);
          expect(fullPages, 0);
        } else {
          expect(find.text('full-player-destination'), findsOneWidget);
          expect(fullPages, 1);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      },
    );
  }
}
