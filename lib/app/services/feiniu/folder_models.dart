/// 文件夹视图模型（来自 FnMusicEnhance 服务端增强接口）。
///
/// 响应信封为增强服务自有的 `{code, msg, data}`，不走主 API 的
/// [FeiNiuResponse] 封装；页面直接解析 `data` 段为这些模型。
///
/// 所有路径均为**库内相对路径**（如 `/`、`/IU/A Flower Bookmark 2`），
/// 不含 `/vol3/1000/...` 等 NAS 内部前缀，仅用于展示。
library;

/// 单个目录层级的内容：子目录 + 音频文件。
class FolderListing {
  /// 库根目录名（如 `Music`），用于顶部标题。
  final String libraryRoot;

  /// 当前相对路径（如 `/` 或 `/IU`）。
  final String path;

  /// 上级相对路径；根目录为 null。
  final String? parent;

  /// 子目录列表。
  final List<FolderDir> folders;

  /// 音频文件列表（当前分页的一页）。
  final List<FolderFile> files;

  /// 当前目录文件总数（分页用）。
  final int total;

  /// 当前目录文件总数（分页依据；CUE 整轨文件算 1 个文件）。
  final int fileTotal;

  const FolderListing({
    required this.libraryRoot,
    required this.path,
    this.parent,
    this.folders = const [],
    this.files = const [],
    this.total = 0,
    this.fileTotal = 0,
  });

  factory FolderListing.fromJson(Map<String, dynamic> json) {
    return FolderListing(
      libraryRoot: json['libraryRoot'] as String? ?? '',
      path: json['path'] as String? ?? '/',
      parent: json['parent'] as String?,
      folders: (json['folders'] as List<dynamic>?)
              ?.map((e) => FolderDir.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      files: (json['files'] as List<dynamic>?)
              ?.map((e) => FolderFile.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      total: json['total'] as int? ?? 0,
      fileTotal: json['fileTotal'] as int? ?? 0,
    );
  }
}

/// 子目录项。
class FolderDir {
  final String name;
  final String path;

  const FolderDir({required this.name, required this.path});

  factory FolderDir.fromJson(Map<String, dynamic> json) {
    return FolderDir(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '/',
    );
  }
}

/// 音频文件项。
class FolderFile {
  final String name;
  final String path;
  final String suffix;
  final int? size;
  final int? durationMs;

  /// 音质信息（来自 audio_file 技术参数）。
  final FolderAudioSpec? audioSpec;

  /// 创建时间（epoch 毫秒）。
  final int? createdAt;

  /// 该文件对应的曲目（通常 1 个；CUE 整轨文件可有多个）。
  final List<FolderTrack> tracks;

  const FolderFile({
    required this.name,
    required this.path,
    this.suffix = '',
    this.size,
    this.durationMs,
    this.audioSpec,
    this.createdAt,
    this.tracks = const [],
  });

  factory FolderFile.fromJson(Map<String, dynamic> json) {
    return FolderFile(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '/',
      suffix: json['suffix'] as String? ?? '',
      size: json['size'] as int?,
      durationMs: json['durationMs'] as int?,
      audioSpec: json['audioSpec'] is Map<String, dynamic>
          ? FolderAudioSpec.fromJson(json['audioSpec'] as Map<String, dynamic>)
          : null,
      createdAt: json['createdAt'] as int?,
      tracks: (json['tracks'] as List<dynamic>?)
              ?.map((e) => FolderTrack.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }

  /// 音质摘要文本（如 `FLAC 44.1kHz 16bit`）。
  String get audioSpecText {
    final spec = audioSpec;
    if (spec == null) return '';
    final parts = <String>[];
    if (suffix.isNotEmpty) parts.add(suffix.toUpperCase());
    if (spec.sampleRate != null && spec.sampleRate! > 0) {
      parts.add('${(spec.sampleRate! / 1000).toStringAsFixed(1)}kHz');
    }
    if (spec.bitDepth != null && spec.bitDepth! > 0) {
      parts.add('${spec.bitDepth}bit');
    }
    if (spec.bitrate != null && spec.bitrate! > 0) {
      parts.add('${(spec.bitrate! / 1000).toStringAsFixed(0)}kbps');
    }
    return parts.join(' ');
  }
}

/// 音质信息（audio_file 技术参数）。
class FolderAudioSpec {
  final int? bitrate;
  final int? sampleRate;
  final int? bitDepth;
  final int? channel;
  final String? codec;

  const FolderAudioSpec({
    this.bitrate,
    this.sampleRate,
    this.bitDepth,
    this.channel,
    this.codec,
  });

  factory FolderAudioSpec.fromJson(Map<String, dynamic> json) {
    return FolderAudioSpec(
      bitrate: json['bitrate'] as int?,
      sampleRate: json['sampleRate'] as int?,
      bitDepth: json['bitDepth'] as int?,
      channel: json['channel'] as int?,
      codec: json['codec'] as String?,
    );
  }
}

/// 曲目歌手（含 guid，供歌手详情跳转）。
class FolderArtist {
  final String guid;
  final String name;

  const FolderArtist({required this.guid, required this.name});

  factory FolderArtist.fromJson(Map<String, dynamic> json) {
    return FolderArtist(
      guid: json['guid'] as String? ?? '',
      name: json['name'] as String? ?? '',
    );
  }
}

/// 文件对应的曲目（可播放，含增强的专辑/歌手信息）。
class FolderTrack {
  final String guid;
  final String title;
  final int? durationMs;
  final int? trackNo;
  final int? year;
  final String? album;
  final String? albumGuid;
  final String? coverId;
  final bool isCue;
  final List<FolderArtist> artists;

  const FolderTrack({
    required this.guid,
    required this.title,
    this.durationMs,
    this.trackNo,
    this.year,
    this.album,
    this.albumGuid,
    this.coverId,
    this.isCue = false,
    this.artists = const [],
  });

  factory FolderTrack.fromJson(Map<String, dynamic> json) {
    return FolderTrack(
      guid: json['guid'] as String? ?? '',
      title: json['title'] as String? ?? '',
      durationMs: json['durationMs'] as int?,
      trackNo: json['trackNo'] as int?,
      year: json['year'] as int?,
      album: json['album'] as String?,
      albumGuid: json['albumGuid'] as String?,
      coverId: json['coverId'] as String?,
      isCue: json['isCue'] as bool? ?? false,
      artists: (json['artists'] as List<dynamic>?)
              ?.map((e) => FolderArtist.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }

  /// 歌手显示名（多个用「/」连接）。
  String get artistDisplay =>
      artists.map((a) => a.name).where((n) => n.isNotEmpty).join(' / ');
}

