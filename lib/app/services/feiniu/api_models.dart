/// 兼容服务端把数字字段返回成字符串的情况
/// （如 `releaseDate: "2024-01-01"` 或 `"1714521600"`）
int? _toInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return int.tryParse(trimmed);
  }
  return null;
}

/// API 响应统一封装
class FeiNiuResponse<T> {
  final int code;
  final String msg;
  final T? data;

  const FeiNiuResponse({required this.code, required this.msg, this.data});

  bool get isSuccess => code == 0;

  factory FeiNiuResponse.fromJson(
    Map<String, dynamic> json,
    T? Function(dynamic data)? fromData,
  ) {
    return FeiNiuResponse(
      code: _toInt(json['code']) ?? -1,
      msg: json['msg'] as String? ?? '',
      data: json['data'] != null && fromData != null
          ? fromData(json['data'])
          : null,
    );
  }
}

/// 登录响应
class LoginResponse {
  final String userToken;
  final String? username;
  final String? guid;
  final String? role;

  const LoginResponse({
    required this.userToken,
    this.username,
    this.guid,
    this.role,
  });

  factory LoginResponse.fromJson(Map<String, dynamic> json) {
    final user = json['user'] as Map<String, dynamic>?;
    return LoginResponse(
      userToken: json['userToken'] as String? ?? '',
      username: user?['name'] as String?,
      guid: user?['guid'] as String?,
      role: user?['role'] as String?,
    );
  }
}

/// 分页数据包装
class FeiNiuPageData<T> {
  final List<T> list;
  final int total;
  final String? sort;

  const FeiNiuPageData({required this.list, required this.total, this.sort});
}

/// 专辑信息
class FeiNiuAlbum {
  final String guid;
  final String name;
  final String? coverId;
  final int? releaseDate;
  final int? trackCount;
  final int? createdAt;

  const FeiNiuAlbum({
    required this.guid,
    required this.name,
    this.coverId,
    this.releaseDate,
    this.trackCount,
    this.createdAt,
  });

  factory FeiNiuAlbum.fromJson(Map<String, dynamic> json) {
    return FeiNiuAlbum(
      guid: json['guid'] as String? ?? '',
      name: json['name'] as String? ?? '未知专辑',
      coverId: json['coverId'] as String?,
      releaseDate: _toInt(json['releaseDate']),
      trackCount: _toInt(json['trackCount']),
      createdAt: _toInt(json['createdAt']),
    );
  }

  Map<String, dynamic> toJson() => {
    'guid': guid,
    'name': name,
    'coverId': coverId,
    'releaseDate': releaseDate,
    'trackCount': trackCount,
    'createdAt': createdAt,
  };
}

/// 歌手信息
class FeiNiuArtist {
  final String guid;
  final String name;
  final String? coverId;
  final int? trackCount;
  final int? albumCount;

  const FeiNiuArtist({
    required this.guid,
    required this.name,
    this.coverId,
    this.trackCount,
    this.albumCount,
  });

  factory FeiNiuArtist.fromJson(Map<String, dynamic> json) {
    return FeiNiuArtist(
      guid: json['guid'] as String? ?? '',
      name: json['name'] as String? ?? '未知歌手',
      coverId: json['coverId'] as String?,
      trackCount: _toInt(json['trackCount']),
      albumCount: _toInt(json['albumCount']),
    );
  }

  Map<String, dynamic> toJson() => {
    'guid': guid,
    'name': name,
    'coverId': coverId,
    'trackCount': trackCount,
    'albumCount': albumCount,
  };
}

/// 音频规格
class FeiNiuAudioSpec {
  final int? bitDepth;
  final int? sampleRate;
  final int? channel;
  final int? bitrate;
  final String? codec;
  final String? format;
  final int? duration;
  final int? size;
  final String? path;

  const FeiNiuAudioSpec({
    this.bitDepth,
    this.sampleRate,
    this.channel,
    this.bitrate,
    this.codec,
    this.format,
    this.duration,
    this.size,
    this.path,
  });

  factory FeiNiuAudioSpec.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const FeiNiuAudioSpec();
    return FeiNiuAudioSpec(
      bitDepth: _toInt(json['bitDepth']),
      sampleRate: _toInt(json['sampleRate']),
      channel: _toInt(json['channel']),
      bitrate: _toInt(json['bitrate']),
      codec: json['codec'] as String?,
      format: json['format'] as String?,
      duration: _toInt(json['duration']),
      size: _toInt(json['size']),
      path: json['path'] as String?,
    );
  }

  String get displayText {
    final parts = <String>[];
    if (format != null && format!.isNotEmpty) parts.add(format!.toUpperCase());
    if (sampleRate != null && sampleRate! > 0) {
      parts.add('${(sampleRate! / 1000).toStringAsFixed(1)}kHz');
    }
    if (bitDepth != null && bitDepth! > 0) parts.add('${bitDepth}bit');
    if (bitrate != null && bitrate! > 0) {
      parts.add('${(bitrate! / 1000).toStringAsFixed(0)}kbps');
    }
    return parts.join(' ');
  }
}

/// 曲目信息
class FeiNiuTrack {
  final String guid;
  final String title;
  final String? coverId;
  final int? year;
  final int? discNo;
  final int? trackNo;
  final int? duration;
  final bool isCue;
  final int createdAt;
  final int updatedAt;
  final FeiNiuAlbum album;
  final List<FeiNiuArtist> artists;
  final bool isFavorite;
  final bool? hasLyric;
  final FeiNiuAudioSpec? audioSpec;

  const FeiNiuTrack({
    required this.guid,
    required this.title,
    this.coverId,
    this.year,
    this.discNo,
    this.trackNo,
    this.duration,
    this.isCue = false,
    required this.createdAt,
    required this.updatedAt,
    required this.album,
    required this.artists,
    this.isFavorite = false,
    this.hasLyric,
    this.audioSpec,
  });

  factory FeiNiuTrack.fromJson(Map<String, dynamic> json) {
    return FeiNiuTrack(
      guid: json['guid'] as String? ?? '',
      title: json['title'] as String? ?? '未知标题',
      coverId: json['coverId'] as String?,
      year: _toInt(json['year']),
      discNo: _toInt(json['discNo']),
      trackNo: _toInt(json['trackNo']),
      duration: _toInt(json['duration']),
      isCue: json['isCue'] as bool? ?? false,
      createdAt: _toInt(json['createdAt']) ?? 0,
      updatedAt: _toInt(json['updatedAt']) ?? 0,
      album: FeiNiuAlbum.fromJson(json['album'] as Map<String, dynamic>? ?? {}),
      artists:
          (json['artists'] as List<dynamic>?)
              ?.map((e) => FeiNiuArtist.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      isFavorite: json['isFavorite'] as bool? ?? false,
      hasLyric: json['hasLyric'] as bool?,
      audioSpec: json['audioSpec'] != null
          ? FeiNiuAudioSpec.fromJson(json['audioSpec'] as Map<String, dynamic>)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'guid': guid,
    'title': title,
    'coverId': coverId,
    'year': year,
    'discNo': discNo,
    'trackNo': trackNo,
    'duration': duration,
    'isCue': isCue,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'album': album.toJson(),
    'artists': artists.map((a) => a.toJson()).toList(),
    'isFavorite': isFavorite,
    'hasLyric': hasLyric,
    'audioSpec': audioSpec != null
        ? {
            'format': audioSpec!.format,
            'sampleRate': audioSpec!.sampleRate,
            'bitDepth': audioSpec!.bitDepth,
            'bitrate': audioSpec!.bitrate,
            'duration': audioSpec!.duration,
            'size': audioSpec!.size,
          }
        : null,
  };
}

/// 搜索结果的额外字段
class FeiNiuSearchTrack extends FeiNiuTrack {
  final double? score;

  const FeiNiuSearchTrack({
    required super.guid,
    required super.title,
    super.coverId,
    super.year,
    super.discNo,
    super.trackNo,
    super.duration,
    super.isCue,
    required super.createdAt,
    required super.updatedAt,
    required super.album,
    required super.artists,
    super.isFavorite,
    super.hasLyric,
    super.audioSpec,
    this.score,
  });

  factory FeiNiuSearchTrack.fromJson(Map<String, dynamic> json) {
    final base = FeiNiuTrack.fromJson(json);
    return FeiNiuSearchTrack(
      guid: base.guid,
      title: base.title,
      coverId: base.coverId,
      year: base.year,
      discNo: base.discNo,
      trackNo: base.trackNo,
      duration: base.duration,
      isCue: base.isCue,
      createdAt: base.createdAt,
      updatedAt: base.updatedAt,
      album: base.album,
      artists: base.artists,
      isFavorite: base.isFavorite,
      hasLyric: base.hasLyric,
      audioSpec: base.audioSpec,
      score: (json['score'] as num?)?.toDouble(),
    );
  }
}

/// 歌单信息
class FeiNiuPlaylist {
  final String guid;
  final String name;
  final String? coverId;
  final int trackCount;
  final int createdAt;
  final int updatedAt;

  const FeiNiuPlaylist({
    required this.guid,
    required this.name,
    this.coverId,
    this.trackCount = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  factory FeiNiuPlaylist.fromJson(Map<String, dynamic> json) {
    return FeiNiuPlaylist(
      guid: json['guid'] as String? ?? '',
      name: json['name'] as String? ?? '未知歌单',
      coverId: json['coverId'] as String?,
      trackCount: _toInt(json['trackCount']) ?? 0,
      createdAt: _toInt(json['createdAt']) ?? 0,
      updatedAt: _toInt(json['updatedAt']) ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'guid': guid,
    'name': name,
    'coverId': coverId,
    'trackCount': trackCount,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };
}

/// 风格信息
class FeiNiuGenre {
  final String guid;
  final String name;
  final String? coverId;
  final int trackCount;
  final int createdAt;
  final int updatedAt;

  const FeiNiuGenre({
    required this.guid,
    required this.name,
    this.coverId,
    this.trackCount = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  factory FeiNiuGenre.fromJson(Map<String, dynamic> json) {
    return FeiNiuGenre(
      guid: json['guid'] as String? ?? '',
      name: json['name'] as String? ?? '未知风格',
      coverId: json['coverId'] as String?,
      trackCount: _toInt(json['trackCount']) ?? 0,
      createdAt: _toInt(json['createdAt']) ?? 0,
      updatedAt: _toInt(json['updatedAt']) ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'guid': guid,
    'name': name,
    'coverId': coverId,
    'trackCount': trackCount,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };
}

/// 漫游响应
class FeiNiuRoamTrack {
  final String roamId;
  final FeiNiuTrack track;

  const FeiNiuRoamTrack({required this.roamId, required this.track});

  factory FeiNiuRoamTrack.fromJson(Map<String, dynamic> json) {
    return FeiNiuRoamTrack(
      roamId: json['roamId'] as String? ?? '',
      track: FeiNiuTrack.fromJson(json['track'] as Map<String, dynamic>? ?? {}),
    );
  }
}

class FeiNiuRoamStartResponse {
  final FeiNiuRoamTrack current;
  final FeiNiuRoamTrack? next;

  const FeiNiuRoamStartResponse({required this.current, this.next});

  factory FeiNiuRoamStartResponse.fromJson(Map<String, dynamic> json) {
    return FeiNiuRoamStartResponse(
      current: FeiNiuRoamTrack.fromJson(
        json['current'] as Map<String, dynamic>? ?? {},
      ),
      next: json['next'] != null
          ? FeiNiuRoamTrack.fromJson(json['next'] as Map<String, dynamic>)
          : null,
    );
  }
}

class FeiNiuRoamNextResponse {
  final FeiNiuRoamTrack? previous;
  final FeiNiuRoamTrack? current;
  final FeiNiuRoamTrack? next;

  const FeiNiuRoamNextResponse({this.previous, this.current, this.next});

  factory FeiNiuRoamNextResponse.fromJson(Map<String, dynamic> json) {
    return FeiNiuRoamNextResponse(
      previous: json['previous'] != null
          ? FeiNiuRoamTrack.fromJson(json['previous'] as Map<String, dynamic>)
          : null,
      current: json['current'] != null
          ? FeiNiuRoamTrack.fromJson(json['current'] as Map<String, dynamic>)
          : null,
      next: json['next'] != null
          ? FeiNiuRoamTrack.fromJson(json['next'] as Map<String, dynamic>)
          : null,
    );
  }
}

/// 歌词响应
class FeiNiuLyric {
  final String guid;
  final String content;
  final bool isLRC;
  final int? offset;

  const FeiNiuLyric({
    required this.guid,
    required this.content,
    this.isLRC = true,
    this.offset,
  });

  factory FeiNiuLyric.fromJson(Map<String, dynamic> json) {
    return FeiNiuLyric(
      guid: json['guid'] as String? ?? '',
      content: json['content'] as String? ?? '',
      isLRC: json['isLRC'] as bool? ?? true,
      offset: _toInt(json['offset']),
    );
  }
}

class FeiNiuLyricResponse {
  final List<FeiNiuLyric> list;
  final String? preferred;

  const FeiNiuLyricResponse({required this.list, this.preferred});

  factory FeiNiuLyricResponse.fromJson(Map<String, dynamic> json) {
    return FeiNiuLyricResponse(
      list:
          (json['list'] as List<dynamic>?)
              ?.map((e) => FeiNiuLyric.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      preferred: json['preferred'] as String?,
    );
  }
}
