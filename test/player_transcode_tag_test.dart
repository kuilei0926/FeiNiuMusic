import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/state/song_state.dart';
import 'package:feiniu_music/pages/player/widgets/player_audio_spec.dart';
import 'package:feiniu_music/pages/player/widgets/player_transcode_tag.dart';

void main() {
  testWidgets('播放标签与进度条规格同步更新转码、降级和直连', (tester) async {
    final song = ValueNotifier<SongEntity?>(
      const SongEntity(
        id: 'lossless',
        title: 'Test',
        artist: '',
        format: 'flac',
        bitrate: 1411000,
      ),
    );
    final codec = ValueNotifier<String?>(null);
    addTearDown(song.dispose);
    addTearDown(codec.dispose);
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              PlayerTranscodeTag(
                playbackCodecListenable: codec,
                onTap: () => taps++,
              ),
              PlayerAudioSpec(
                songListenable: song,
                playbackCodecListenable: codec,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('直连'), findsOneWidget);
    expect(find.text('FLAC · 1,411 kbps · 直连'), findsOneWidget);
    for (final output in ['opus', 'mp3']) {
      codec.value = output;
      await tester.pump();
      expect(find.text(output.toUpperCase()), findsOneWidget);
      expect(
        find.text('原始：FLAC · 1,411 kbps\n播放：${output.toUpperCase()} · 转码'),
        findsOneWidget,
      );
      expect(find.text('FLAC · 1,411 kbps · 直连'), findsNothing);
    }
    codec.value = null;
    await tester.pump();
    expect(find.text('直连'), findsOneWidget);
    expect(find.text('FLAC · 1,411 kbps · 直连'), findsOneWidget);
    expect(find.text('MP3'), findsNothing);
    await tester.tap(find.text('直连'));
    expect(taps, 1);
  });
}
