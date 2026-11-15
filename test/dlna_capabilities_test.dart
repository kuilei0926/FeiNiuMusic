import 'package:flutter_test/flutter_test.dart';
import 'package:feiniu_music/app/services/cast/dlna_capabilities.dart';
import 'package:feiniu_music/app/state/song_state.dart';

void main() {
  const song = SongEntity(id: 'id', title: 'title', artist: '[]');
  test('empty and malformed Sink leave capability unknown', () {
    for (final sink in [null, '', 'broken', 'http-get:audio/mpeg']) {
      expect(
        DlnaCapabilities(sink).supportFor(song, 'mp3'),
        DlnaSupport.unknown,
      );
    }
  });
  test('parses multiple Sink entries and MIME aliases case insensitively', () {
    final caps = DlnaCapabilities(
      'http-get:*:audio/x-flac:*, http-get:*:Audio/MPEG:DLNA.ORG_PN=MP3',
    );
    expect(caps.supportFor(song, 'flac'), DlnaSupport.supported);
    expect(caps.supportFor(song, 'mp3'), DlnaSupport.supported);
    expect(caps.supportFor(song, 'wav'), DlnaSupport.unsupported);
  });
  test('wildcards do not prove decoder support', () {
    expect(
      DlnaCapabilities('http-get:*:*:*').supportFor(song, 'wav'),
      DlnaSupport.unknown,
    );
    expect(
      DlnaCapabilities('http-get:*:audio/*:*').supportFor(song, 'mp3'),
      DlnaSupport.unknown,
    );
  });
  test('WAV declaration does not prove high-resolution PCM support', () {
    const wav = SongEntity(
      id: 'wav',
      title: 't',
      artist: '[]',
      codec: 'pcm_s24le',
      sampleRate: 192000,
      bitrate: 9216000,
    );
    expect(
      DlnaCapabilities('http-get:*:audio/wav:*').supportFor(wav, 'wav'),
      DlnaSupport.unknown,
    );
  });
  test('LPCM support does not imply WAV container support', () {
    expect(
      DlnaCapabilities(
        'http-get:*:audio/L16;rate=44100;channels=2:*',
      ).supportFor(song, 'wav'),
      DlnaSupport.unsupported,
    );
  });
  test('MP4 container alone does not establish ALAC support', () {
    const alac = SongEntity(
      id: 'alac',
      title: 't',
      artist: '[]',
      codec: 'alac',
    );
    expect(
      DlnaCapabilities('http-get:*:audio/mp4:*').supportFor(alac, 'm4a'),
      DlnaSupport.unknown,
    );
  });
  test('MP3 HLS requires both codec and HLS transport support', () {
    expect(
      DlnaCapabilities('http-get:*:audio/mpeg:*').mp3HlsSupport,
      DlnaSupport.unsupported,
    );
    expect(
      DlnaCapabilities(
        'http-get:*:audio/mpeg:*,http-get:*:application/x-mpegurl:*',
      ).mp3HlsSupport,
      DlnaSupport.supported,
    );
    expect(DlnaCapabilities(null).mp3HlsSupport, DlnaSupport.unknown);
  });
}
