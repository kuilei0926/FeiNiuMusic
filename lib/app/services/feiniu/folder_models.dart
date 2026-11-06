/// 文件夹视图模型（来自飞牛音乐官方 folder-view 接口）。
///
/// 官方接口使用 NAS 绝对路径（如 `/vol3/1000/Music`）。页面内仍保留
/// [FolderFile] 作为播放队列的适配层：官方返回的每个 track 对应一个文件项。
library;

int? _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('$value');
}

/// 共享音乐库。
class SharedMusicLibrary {
  final String guid;
  final String name;
  final String path;
  final int itemCount;
  final int? contentLastChangedAt;
  final int? accessStatus;

  const SharedMusicLibrary({
    required this.guid,
    required this.name,
    required this.path,
    this.itemCount = 0,
    this.contentLastChangedAt,
    this.accessStatus,
  });

  factory SharedMusicLibrary.fromJson(Map<String, dynamic> json) {
    return SharedMusicLibrary(
      guid: json['guid'] as String? ?? '',
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '/',
      itemCount: _asInt(json['itemCount']) ?? 0,
      contentLastChangedAt: _asInt(json['contentLastChangedAt']),
      accessStatus: _asInt(json['accessStatus']),
    );
  }

  /// 共享库名称为空时，使用路径最后一段作为展示名。
  String get displayName {
    if (name.trim().isNotEmpty) return name;
    final parts = path.split('/').where((part) => part.isNotEmpty).toList();
    return parts.isEmpty ? '音乐库' : parts.last;
  }
}

/// 单个目录层级的内容：子目录 + 音频曲目。
class FolderListing {
  /// 当前共享音乐库根路径；虚拟根目录时为空。
  final String libraryRoot;

  /// 当前目录绝对路径；虚拟根目录为 `/`。
  final String path;

  /// 上级目录路径；虚拟根目录为 null。
  final String? parent;

  /// 子目录列表。
  final List<FolderDir> folders;

  /// 音频文件列表（每个官方 track 包装为一个文件项）。
  final List<FolderFile> files;

  /// 当前查询结果中的歌曲总数。
  final int total;

  /// 当前查询结果中的文件项总数。
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

  factory FolderListing.root(List<FolderDir> libraries) {
    return FolderListing(libraryRoot: '', path: '/', folders: libraries);
  }

  factory FolderListing.fromFolderView(
    Map<String, dynamic> data, {
    required String libraryRoot,
    required String? parent,
  }) {
    final folder = data['folder'] is Map<String, dynamic>
        ? data['folder'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final folders =
        (folder['folders'] as List<dynamic>?)
            ?.map((item) {
              if (item is! Map<String, dynamic>) return null;
              return FolderDir.fromJson(item);
            })
            .whereType<FolderDir>()
            .where((dir) => !dir.isAdminDeleted)
            .toList() ??
        const <FolderDir>[];
    final files =
        (folder['tracks'] as List<dynamic>?)
            ?.map((item) {
              if (item is! Map<String, dynamic>) return null;
              return FolderFile.fromTrack(FolderTrack.fromJson(item));
            })
            .whereType<FolderFile>()
            .where((file) => !file.tracks.any((track) => track.isAdminDeleted))
            .toList() ??
        const <FolderFile>[];

    return FolderListing(
      libraryRoot: libraryRoot,
      path: folder['path'] as String? ?? '/',
      parent: parent,
      folders: folders,
      files: files,
      total: files.fold(0, (sum, file) => sum + file.tracks.length),
      fileTotal: files.length,
    );
  }
}

/// 子目录项。
class FolderDir {
  final String name;
  final String path;
  final int itemCount;
  final bool isAdminDeleted;

  const FolderDir({
    required this.name,
    required this.path,
    this.itemCount = 0,
    this.isAdminDeleted = false,
  });

  factory FolderDir.fromJson(Map<String, dynamic> json) {
    return FolderDir(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '/',
      itemCount: _asInt(json['itemCount']) ?? 0,
      isAdminDeleted: json['isAdminDeleted'] as bool? ?? false,
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

  /// 音质信息。
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

  /// 将官方 folder-view 曲目适配为页面使用的文件项。
  factory FolderFile.fromTrack(FolderTrack track) {
    return FolderFile(
      name: track.title,
      path: track.audioPath ?? '/',
      suffix: track.audioFormat ?? '',
      size: track.audioSize,
      durationMs: track.durationMs,
      audioSpec: track.audioSpec,
      tracks: [track],
    );
  }

  factory FolderFile.fromJson(Map<String, dynamic> json) {
    return FolderFile(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '/',
      suffix: json['suffix'] as String? ?? '',
      size: _asInt(json['size']),
      durationMs: _asInt(json['durationMs']),
      audioSpec: json['audioSpec'] is Map<String, dynamic>
          ? FolderAudioSpec.fromJson(json['audioSpec'] as Map<String, dynamic>)
          : null,
      createdAt: _asInt(json['createdAt']),
      tracks:
          (json['tracks'] as List<dynamic>?)
              ?.map((item) {
                if (item is! Map<String, dynamic>) return null;
                return FolderTrack.fromJson(item);
              })
              .whereType<FolderTrack>()
              .toList() ??
          const [],
    );
  }

  /// 音质摘要文本（如 `FLAC 44.1kHz 16bit`）。
  String get audioSpecText {
    final spec = audioSpec;
    if (spec == null) return '';
    final parts = <String>[];
    final format = suffix.isNotEmpty ? suffix : spec.format;
    if (format != null && format.isNotEmpty) parts.add(format.toUpperCase());
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

/// 音质信息。
class FolderAudioSpec {
  final int? bitrate;
  final int? sampleRate;
  final int? bitDepth;
  final int? channel;
  final String? codec;
  final String? format;
  final String? path;
  final int? size;

  const FolderAudioSpec({
    this.bitrate,
    this.sampleRate,
    this.bitDepth,
    this.channel,
    this.codec,
    this.format,
    this.path,
    this.size,
  });

  factory FolderAudioSpec.fromJson(Map<String, dynamic> json) {
    return FolderAudioSpec(
      bitrate: _asInt(json['bitrate']),
      sampleRate: _asInt(json['sampleRate']),
      bitDepth: _asInt(json['bitDepth']),
      channel: _asInt(json['channel']),
      codec: json['codec'] as String?,
      format: json['format'] as String?,
      path: json['path'] as String?,
      size: _asInt(json['size']),
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

/// 官方 folder-view 曲目。
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
  final bool isFavorite;
  final bool isAdminDeleted;
  final FolderAudioSpec? audioSpec;
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
    this.isFavorite = false,
    this.isAdminDeleted = false,
    this.audioSpec,
    this.artists = const [],
  });

  factory FolderTrack.fromJson(Map<String, dynamic> json) {
    final albumJson = json['album'] is Map<String, dynamic>
        ? json['album'] as Map<String, dynamic>
        : const <String, dynamic>{};
    return FolderTrack(
      guid: json['guid'] as String? ?? '',
      title: json['title'] as String? ?? '',
      durationMs: _asInt(json['duration']) ?? _asInt(json['durationMs']),
      trackNo: _asInt(json['trackNo']),
      year: _asInt(json['year']),
      album: albumJson['name'] as String?,
      albumGuid: albumJson['guid'] as String?,
      coverId: json['coverId'] as String? ?? albumJson['coverId'] as String?,
      isCue: json['isCue'] as bool? ?? false,
      isFavorite: json['isFavorite'] as bool? ?? false,
      isAdminDeleted: json['isAdminDeleted'] as bool? ?? false,
      audioSpec: json['audioSpec'] is Map<String, dynamic>
          ? FolderAudioSpec.fromJson(json['audioSpec'] as Map<String, dynamic>)
          : null,
      artists:
          (json['artists'] as List<dynamic>?)
              ?.map((item) {
                if (item is! Map<String, dynamic>) return null;
                return FolderArtist.fromJson(item);
              })
              .whereType<FolderArtist>()
              .toList() ??
          const [],
    );
  }

  String? get audioPath => audioSpec?.path;

  String? get audioFormat => audioSpec?.format;

  int? get audioSize => audioSpec?.size;

  /// 歌手显示名（多个用「/」连接）。
  String get artistDisplay => artists
      .map((artist) => artist.name)
      .where((name) => name.isNotEmpty)
      .join(' / ');
}
