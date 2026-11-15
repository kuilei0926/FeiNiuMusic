import '../../state/song_state.dart';

enum DlnaSupport { supported, unsupported, unknown }

/// Sink protocolInfo describes transport/container support, not a full decoder
/// specification. Wildcards and missing codec information remain unknown.
class DlnaCapabilities {
  DlnaCapabilities(String? sink)
    : _entries = (sink ?? '')
          .split(',')
          .map((entry) => entry.trim().split(':'))
          .where(
            (parts) =>
                parts.length >= 4 &&
                (parts[2].contains('/') || parts[2] == '*'),
          )
          .toList();

  final List<List<String>> _entries;

  DlnaSupport mimeSupport(Set<String> mimeTypes) {
    if (_entries.isEmpty) return DlnaSupport.unknown;
    var wildcard = false;
    for (final parts in _entries) {
      if (parts[0] == '*') {
        wildcard = true;
        continue;
      }
      if (parts[0] != 'http-get') continue;
      final mime = parts[2].split(';').first.trim().toLowerCase();
      if (mimeTypes.contains(mime)) return DlnaSupport.supported;
      if (mime == '*' ||
          mime == 'audio/*' && mimeTypes.any((m) => m.startsWith('audio/'))) {
        wildcard = true;
      }
    }
    return wildcard ? DlnaSupport.unknown : DlnaSupport.unsupported;
  }

  DlnaSupport supportFor(SongEntity song, String? format) {
    final mimeTypes = switch ((format ?? '').trim().toLowerCase()) {
      'mp3' || 'mpeg' => {'audio/mpeg', 'audio/mp3'},
      'wav' || 'wave' => {'audio/wav', 'audio/x-wav', 'audio/wave'},
      'flac' => {'audio/flac', 'audio/x-flac'},
      'aac' => {'audio/aac', 'audio/aacp'},
      'm4a' || 'mp4' => {'audio/mp4', 'audio/x-m4a'},
      'ogg' || 'opus' => {'audio/ogg', 'application/ogg'},
      'wma' => {'audio/x-ms-wma'},
      'aiff' || 'aif' => {'audio/aiff', 'audio/x-aiff'},
      _ => <String>{},
    };
    if (mimeTypes.isEmpty) return DlnaSupport.unknown;
    final support = mimeSupport(mimeTypes);
    if (support != DlnaSupport.supported) return support;
    // A container declaration cannot establish support for its embedded codec
    // or high-resolution PCM. Playback monitoring must handle that uncertainty.
    final codec = (song.codec ?? '').trim().toLowerCase();
    if (mimeTypes.contains('audio/wav') ||
        mimeTypes.contains('audio/mp4') ||
        codec == 'alac' ||
        codec == 'eac3' ||
        codec == 'dts') {
      return DlnaSupport.unknown;
    }
    return DlnaSupport.supported;
  }

  DlnaSupport get mp3HlsSupport {
    final mp3 = mimeSupport({'audio/mpeg', 'audio/mp3'});
    final hls = mimeSupport({
      'application/vnd.apple.mpegurl',
      'application/x-mpegurl',
      'audio/mpegurl',
      'audio/x-mpegurl',
    });
    if (mp3 == DlnaSupport.unsupported || hls == DlnaSupport.unsupported) {
      return DlnaSupport.unsupported;
    }
    return mp3 == DlnaSupport.supported && hls == DlnaSupport.supported
        ? DlnaSupport.supported
        : DlnaSupport.unknown;
  }
}
