import 'package:audio_service/audio_service.dart';

import '../state/song_state.dart';
import 'media_notification_car_lyrics.dart';

({MediaItem item, bool suppressQueueIndex}) buildMediaNotificationMetadata(
  SongEntity song, {
  required bool current,
  required bool isAndroid,
  required bool isPlaying,
  required bool showLyrics,
  required bool lyricOnTop,
  required bool carLyricsEnabled,
  required String? lyricLine,
  required String? carLyricLine,
  Uri? artUri,
  Map<String, String>? artHeaders,
}) {
  final notificationLine = current && showLyrics ? lyricLine : null;
  final artistText = song.artistDisplayName.trim();
  final songAndArtist = artistText.isEmpty
      ? song.title.trim()
      : '${song.title.trim()} · $artistText';
  final carLyricsActive = carLyricsEnabled && current && isPlaying;
  final carTitle = carLyricsTitleOverride(
    carLyricsEnabled: carLyricsActive,
    isCurrentSong: current,
    isPlaying: isPlaying,
    currentCarLyricLine: carLyricLine,
  );
  final lyricsOnTop = lyricOnTop && notificationLine != null;
  // SystemUI reads ARTIST for its second line, ignoring DISPLAY_SUBTITLE.
  final androidSubtitle = isAndroid && !lyricOnTop ? notificationLine : null;
  final item = MediaItem(
    id: song.id,
    title:
        carTitle ??
        (lyricsOnTop && !carLyricsEnabled ? notificationLine : song.title),
    artist:
        androidSubtitle ??
        (lyricsOnTop || carTitle != null
            ? songAndArtist
            : song.artistDisplayName),
    album: song.albumDisplayName,
    artUri: artUri,
    duration: song.durationMs != null
        ? Duration(milliseconds: song.durationMs!)
        : null,
    displayTitle: lyricsOnTop ? notificationLine : song.title,
    displaySubtitle: lyricsOnTop
        ? songAndArtist
        : current
        ? notificationLine
        : song.artistDisplayName,
    displayDescription: notificationLine != null
        ? (lyricsOnTop
              ? (artistText.isEmpty ? null : artistText)
              : song.artistDisplayName)
        : null,
    artHeaders: artHeaders,
    extras: carLyricsActive
        ? <String, dynamic>{'android.media.metadata.LYRICS': carLyricLine ?? ''}
        : null,
  );
  // AVRCP compares the active queue item's title/artist with session metadata.
  // Lyrics differ from the static queue, including when playback is paused.
  return (
    item: item,
    suppressQueueIndex:
        carLyricsActive || (isAndroid && notificationLine != null),
  );
}
