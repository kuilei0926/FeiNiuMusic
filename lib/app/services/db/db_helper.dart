import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
// sqflite_common_ffi 已 re-export sqflite 的 openDatabase/Database 等符号。
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'db_constants.dart';

class DbHelper {
  DbHelper._internal();

  static final DbHelper instance = DbHelper._internal();

  Database? _db;

  /// 是否已为 Windows 一次性接入 sqflite ffi factory（系统 winsqlite3.dll）。
  static bool _ffiFactoryReady = false;

  /// 桌面端（Windows）sqflite 无原生实现，需切到 ffi factory。
  ///
  /// 幂等：只初始化一次。Android/iOS 走原 platform channel，不触碰这里。
  static void _ensureFfiFactoryForWindows() {
    if (defaultTargetPlatform != TargetPlatform.windows || kIsWeb) return;
    if (_ffiFactoryReady) return;
    _ffiFactoryReady = true;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  Future<Database> get database async {
    final current = _db;
    if (current != null) return current;
    _db = await _openDb();
    return _db!;
  }

  /// 测试专用：注入数据库文件路径（覆盖 getApplicationDocumentsDirectory），
  /// 并重置已缓存的连接。用于在内存/临时目录中验证真实迁移逻辑。
  @visibleForTesting
  void resetForTest({String? overridePath}) {
    _db?.close();
    _db = null;
    _pathOverride = overridePath;
  }

  String? _pathOverride;

  /// 幂等加列：songs 表缺少 [column] 时才执行 `ALTER TABLE ... ADD COLUMN`。
  ///
  /// 迁移历史上多次出现「列状态与 user_version 不同步」：v12 缺 updatedAt
  /// 写入回滚、v13 漏加 isCue、v14 重复加 isCue 导致 open 失败。最后一种
  /// （列已存在但版本号偏旧）常见于高版本打开后降级——sqflite 会把
  /// user_version 复位到低版本但**列保留**（onDowngrade 未定义时只 setVersion），
  /// 再开新版代码时裸 `ALTER TABLE ADD COLUMN` 抛 duplicate column name，
  /// 整个 openDatabase 在事务内回滚失败。用 `PRAGMA table_info` 先查列名，
  /// 保证任意状态下迁移都能安全幂等执行。
  Future<void> _addSongColumnIfMissing(
    Database db,
    String column,
    String typeSql,
  ) async {
    final rows = await db.rawQuery(
      'PRAGMA table_info(${DbConstants.tableSongs})',
    );
    final names = rows.map((r) => r['name']).toSet();
    if (names.contains(column)) return;
    await db.execute(
      'ALTER TABLE ${DbConstants.tableSongs} ADD COLUMN $column $typeSql',
    );
  }

  Future<Database> _openDb() async {
    _ensureFfiFactoryForWindows();
    final override = _pathOverride;
    final String path;
    if (override != null) {
      path = override;
    } else {
      final directory = await getApplicationDocumentsDirectory();
      path = p.join(directory.path, DbConstants.dbName);
    }
    return openDatabase(
      path,
      version: DbConstants.dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
CREATE TABLE ${DbConstants.tableSongs} (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  artist TEXT NOT NULL,
  album TEXT,
  uri TEXT,
  isLocal INTEGER NOT NULL DEFAULT 0,
  headersJson TEXT,
  durationMs INTEGER,
  bitrate INTEGER,
  sampleRate INTEGER,
  fileSize INTEGER,
  format TEXT,
  codec TEXT,
  isFavorite INTEGER NOT NULL DEFAULT 0,
  coverId TEXT,
  audioSpec TEXT,
  trackNumber INTEGER,
  discNumber INTEGER,
  updatedAt INTEGER,
  isCue INTEGER NOT NULL DEFAULT 0,
  cueOffsetMs INTEGER
)
''');
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_songs_title ON ${DbConstants.tableSongs}(title COLLATE NOCASE)',
        );
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_songs_artist ON ${DbConstants.tableSongs}(artist COLLATE NOCASE)',
        );
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_songs_album ON ${DbConstants.tableSongs}(album COLLATE NOCASE)',
        );
        await db.execute('''
CREATE TABLE ${DbConstants.tablePlaylists} (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  createdAtMs INTEGER NOT NULL,
  isFavorite INTEGER NOT NULL,
  sortOrder INTEGER NOT NULL
)
''');
        await db.execute('''
CREATE TABLE ${DbConstants.tablePlaylistSongs} (
  playlistId TEXT NOT NULL,
  songId TEXT NOT NULL,
  sortOrder INTEGER NOT NULL,
  PRIMARY KEY (playlistId, songId)
)
''');
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_playlist_songs_playlist ON ${DbConstants.tablePlaylistSongs}(playlistId, sortOrder)',
        );
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_playlist_songs_song ON ${DbConstants.tablePlaylistSongs}(songId)',
        );
        await db.execute('''
CREATE TABLE ${DbConstants.tableListeningDays} (
  dayKey TEXT PRIMARY KEY,
  listenMs INTEGER NOT NULL,
  playCount INTEGER NOT NULL
)
''');
        await db.execute('''
CREATE TABLE ${DbConstants.tableSongStats} (
  songId TEXT PRIMARY KEY,
  listenMs INTEGER NOT NULL,
  playCount INTEGER NOT NULL,
  lastPlayedMs INTEGER NOT NULL
)
''');
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_song_stats_playcount ON ${DbConstants.tableSongStats}(playCount)',
        );
        await db.execute('''
CREATE TABLE ${DbConstants.tableAlbumStats} (
  albumName TEXT PRIMARY KEY,
  playCount INTEGER NOT NULL,
  lastPlayedMs INTEGER NOT NULL
)
''');
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_album_stats_playcount ON ${DbConstants.tableAlbumStats}(playCount)',
        );
        await db.execute('''
CREATE TABLE ${DbConstants.tablePlaylistStats} (
  playlistId TEXT PRIMARY KEY,
  playCount INTEGER NOT NULL,
  lastPlayedMs INTEGER NOT NULL
)
''');
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_playlist_stats_playcount ON ${DbConstants.tablePlaylistStats}(playCount)',
        );
        // 版本 11：API 响应缓存表
        await db.execute('''
CREATE TABLE IF NOT EXISTS ${DbConstants.tableApiCache} (
  cache_key TEXT PRIMARY KEY,
  json_data TEXT NOT NULL,
  cached_at_ms INTEGER NOT NULL,
  ttl_ms INTEGER NOT NULL
)
''');
        // 版本 16：听歌报告原始事件（从独立库 feiniu_report.db 迁回主库，
        // 让听歌统计数据统一在一个库里，便于备份/还原）。
        await db.execute('''
CREATE TABLE IF NOT EXISTS ${DbConstants.tableReportEvents} (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  dayKey TEXT NOT NULL,
  hour INTEGER NOT NULL,
  songId TEXT NOT NULL,
  songTitle TEXT NOT NULL,
  artistsJson TEXT,
  albumJson TEXT,
  coverId TEXT,
  durationMs INTEGER,
  playMs INTEGER NOT NULL,
  completed INTEGER NOT NULL,
  sessionStartMs INTEGER NOT NULL,
  sessionEndMs INTEGER NOT NULL
)
''');
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_report_events_day ON ${DbConstants.tableReportEvents}(dayKey)',
        );
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_report_events_song ON ${DbConstants.tableReportEvents}(songId)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _addSongColumnIfMissing(db, 'localCoverPath', 'TEXT');
          await _addSongColumnIfMissing(db, 'tagsParsed', 'INTEGER');
        }
        if (oldVersion < 3) {
          await _addSongColumnIfMissing(db, 'bitrate', 'INTEGER');
          await _addSongColumnIfMissing(db, 'sampleRate', 'INTEGER');
          await _addSongColumnIfMissing(db, 'fileSize', 'INTEGER');
          await _addSongColumnIfMissing(db, 'format', 'TEXT');
        }
        if (oldVersion < 4) {
          await _addSongColumnIfMissing(db, 'headersJson', 'TEXT');
        }
        if (oldVersion < 5) {
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_songs_title ON ${DbConstants.tableSongs}(title COLLATE NOCASE)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_songs_artist ON ${DbConstants.tableSongs}(artist COLLATE NOCASE)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_songs_album ON ${DbConstants.tableSongs}(album COLLATE NOCASE)',
          );
        }
        if (oldVersion < 6) {
          await db.execute('''
CREATE TABLE IF NOT EXISTS ${DbConstants.tablePlaylists} (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  createdAtMs INTEGER NOT NULL,
  isFavorite INTEGER NOT NULL,
  sortOrder INTEGER NOT NULL
)
''');
          await db.execute('''
CREATE TABLE IF NOT EXISTS ${DbConstants.tablePlaylistSongs} (
  playlistId TEXT NOT NULL,
  songId TEXT NOT NULL,
  sortOrder INTEGER NOT NULL,
  PRIMARY KEY (playlistId, songId)
)
''');
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_playlist_songs_playlist ON ${DbConstants.tablePlaylistSongs}(playlistId, sortOrder)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_playlist_songs_song ON ${DbConstants.tablePlaylistSongs}(songId)',
          );
        }
        if (oldVersion < 7) {
          await db.execute('''
CREATE TABLE IF NOT EXISTS ${DbConstants.tableListeningDays} (
  dayKey TEXT PRIMARY KEY,
  listenMs INTEGER NOT NULL,
  playCount INTEGER NOT NULL
)
''');
          await db.execute('''
CREATE TABLE IF NOT EXISTS ${DbConstants.tableSongStats} (
  songId TEXT PRIMARY KEY,
  listenMs INTEGER NOT NULL,
  playCount INTEGER NOT NULL,
  lastPlayedMs INTEGER NOT NULL
)
''');
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_song_stats_playcount ON ${DbConstants.tableSongStats}(playCount)',
          );
        }
        if (oldVersion < 8) {
          await _addSongColumnIfMissing(db, 'localAssetId', 'TEXT');
        }
        if (oldVersion < 9) {
          await db.execute('''
CREATE TABLE IF NOT EXISTS ${DbConstants.tableAlbumStats} (
  albumName TEXT PRIMARY KEY,
  playCount INTEGER NOT NULL,
  lastPlayedMs INTEGER NOT NULL
)
''');
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_album_stats_playcount ON ${DbConstants.tableAlbumStats}(playCount)',
          );
          await db.execute('''
CREATE TABLE IF NOT EXISTS ${DbConstants.tablePlaylistStats} (
  playlistId TEXT PRIMARY KEY,
  playCount INTEGER NOT NULL,
  lastPlayedMs INTEGER NOT NULL
)
''');
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_playlist_stats_playcount ON ${DbConstants.tablePlaylistStats}(playCount)',
          );
        }
        if (oldVersion < 10) {
          // Track/disc numbers so we can offer a proper "album order" sort.
          // Existing rows get NULL — a rescan is needed to populate them from
          // the tag reader. Sort falls back to song title for those in the
          // meantime.
          await _addSongColumnIfMissing(db, 'trackNumber', 'INTEGER');
          await _addSongColumnIfMissing(db, 'discNumber', 'INTEGER');
        }
        if (oldVersion < 11) {
          // FeiNiu 迁移：添加云端专属字段，移除本地字段
          // 添加新列（SQLite ALTER TABLE 只能加列不能删）
          await _addSongColumnIfMissing(
            db,
            'isFavorite',
            'INTEGER NOT NULL DEFAULT 0',
          );
          await _addSongColumnIfMissing(db, 'coverId', 'TEXT');
          await _addSongColumnIfMissing(db, 'audioSpec', 'TEXT');
          // 创建 API 缓存表
          await db.execute('''
CREATE TABLE IF NOT EXISTS ${DbConstants.tableApiCache} (
  cache_key TEXT PRIMARY KEY,
  json_data TEXT NOT NULL,
  cached_at_ms INTEGER NOT NULL,
  ttl_ms INTEGER NOT NULL
)
''');
        }
        if (oldVersion < 12) {
          // 确保 api_cache 表存在（v11 全新安装漏建）
          await db.execute('''
CREATE TABLE IF NOT EXISTS ${DbConstants.tableApiCache} (
  cache_key TEXT PRIMARY KEY,
  json_data TEXT NOT NULL,
  cached_at_ms INTEGER NOT NULL,
  ttl_ms INTEGER NOT NULL
)
''');
        }
        if (oldVersion < 13) {
          // v12 遗漏了 updatedAt 列，导致 StatsService._flushPending 写入
          // SongEntity.toMap() 时因缺失列使事务回滚，统计数据和歌曲元数据全丢失。
          await _addSongColumnIfMissing(db, 'updatedAt', 'INTEGER');
        }
        if (oldVersion < 14) {
          // 8c28b36 新增 CUE 整轨曲目支持时漏改了 schema：SongEntity.toMap()
          // 会写入 isCue/cueOffsetMs，但旧库没有这两列导致 INSERT 报错。
          // 已有行 isCue 默认 0（非 CUE），cueOffsetMs 为空，下次扫描时回填。
          await _addSongColumnIfMissing(
            db,
            'isCue',
            'INTEGER NOT NULL DEFAULT 0',
          );
          await _addSongColumnIfMissing(db, 'cueOffsetMs', 'INTEGER');
        }
        if (oldVersion < 15) {
          // 引入 audioSpec.codec 路由（EAC3/ALAC 无声兜底）时，SongEntity.toMap()
          // 新增 codec 列写入；旧库缺列会使 upsertSongs / stats 事务回滚。
          await _addSongColumnIfMissing(db, 'codec', 'TEXT');
        }
        if (oldVersion < 16) {
          // 听歌报告原始事件迁回主库（此前独立在 feiniu_report.db，见
          // report_db_helper.dart，此版本起删除该独立库）。老安装的独立库
          // 数据不自动搬运——报告功能尚未发布，无历史数据包袱。
          await db.execute('''
CREATE TABLE IF NOT EXISTS ${DbConstants.tableReportEvents} (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  dayKey TEXT NOT NULL,
  hour INTEGER NOT NULL,
  songId TEXT NOT NULL,
  songTitle TEXT NOT NULL,
  artistsJson TEXT,
  albumJson TEXT,
  coverId TEXT,
  durationMs INTEGER,
  playMs INTEGER NOT NULL,
  completed INTEGER NOT NULL,
  sessionStartMs INTEGER NOT NULL,
  sessionEndMs INTEGER NOT NULL
)
''');
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_report_events_day ON ${DbConstants.tableReportEvents}(dayKey)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_report_events_song ON ${DbConstants.tableReportEvents}(songId)',
          );
        }
      },
    );
  }
}
