import 'package:sqflite/sqflite.dart';

import '../db_constants.dart';
import '../db_helper.dart';
import '../../../state/song_state.dart';
import '../../../utils/cache_version_store.dart';

class SongDao {
  static final SongDao instance = SongDao._();
  SongDao._();

  static const String cacheVersionScope = 'song_library';
  static const int _maxIdsPerQuery = 500;
  static List<SongEntity>? _cachedAll;
  static Future<List<SongEntity>>? _cachedAllFuture;

  Future<int> upsertSongs(List<SongEntity> songs) async {
    if (songs.isEmpty) return 0;
    final db = await DbHelper.instance.database;
    final uniqueIds = songs.map((song) => song.id).toSet().toList();
    final added = await db.transaction<int>((txn) async {
      final existingIds = <String>{};
      for (
        var offset = 0;
        offset < uniqueIds.length;
        offset += _maxIdsPerQuery
      ) {
        final end = (offset + _maxIdsPerQuery).clamp(0, uniqueIds.length);
        final ids = uniqueIds.sublist(offset, end);
        final placeholders = List.filled(ids.length, '?').join(',');
        final rows = await txn.query(
          DbConstants.tableSongs,
          columns: ['id'],
          where: 'id IN ($placeholders)',
          whereArgs: ids,
        );
        existingIds.addAll(rows.map((row) => row['id']).whereType<String>());
      }

      final batch = txn.batch();
      for (final song in songs) {
        batch.insert(
          DbConstants.tableSongs,
          song.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
      return uniqueIds.length - existingIds.length;
    });
    _cachedAll = null;
    CacheVersionStore.instance.bump(cacheVersionScope);
    return added;
  }

  Future<int> countAll() async {
    final db = await DbHelper.instance.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as total FROM ${DbConstants.tableSongs}',
    );
    if (result.isEmpty) return 0;
    final value = result.first['total'];
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<List<SongEntity>> fetchAll() async {
    final db = await DbHelper.instance.database;
    final rows = await db.query(
      DbConstants.tableSongs,
      orderBy: 'title COLLATE NOCASE',
    );
    return rows.map(SongEntity.fromMap).toList();
  }

  Future<List<SongEntity>> fetchAllCached() async {
    final cached = _cachedAll;
    if (cached != null) return cached;
    final inflight = _cachedAllFuture;
    if (inflight != null) return inflight;
    final future = fetchAll();
    _cachedAllFuture = future;
    final list = await future;
    _cachedAll = list;
    _cachedAllFuture = null;
    return list;
  }

  Future<List<SongEntity>> fetchByIds(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final db = await DbHelper.instance.database;
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await db.query(
      DbConstants.tableSongs,
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
    final map = <String, SongEntity>{};
    for (final row in rows) {
      final song = SongEntity.fromMap(row);
      map[song.id] = song;
    }
    return ids.map((id) => map[id]).whereType<SongEntity>().toList();
  }

  Future<int> deleteByIds(List<String> ids) async {
    if (ids.isEmpty) return 0;
    final db = await DbHelper.instance.database;
    final placeholders = List.filled(ids.length, '?').join(',');
    final result = await db.delete(
      DbConstants.tableSongs,
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
    _cachedAll = null;
    CacheVersionStore.instance.bump(cacheVersionScope);
    return result;
  }

  // region API 缓存

  Future<void> cacheApiResponse(
    String key,
    String json, {
    int ttlMs = 300000,
  }) async {
    final db = await DbHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert(DbConstants.tableApiCache, {
      'cache_key': key,
      'json_data': json,
      'cached_at_ms': now,
      'ttl_ms': ttlMs,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getCachedApiResponse(
    String key, {
    bool ignoreTtl = false,
  }) async {
    final db = await DbHelper.instance.database;
    if (ignoreTtl) {
      final rows = await db.query(
        DbConstants.tableApiCache,
        where: 'cache_key = ?',
        whereArgs: [key],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return rows.first['json_data'] as String?;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = await db.query(
      DbConstants.tableApiCache,
      where: 'cache_key = ? AND (cached_at_ms + ttl_ms) > ?',
      whereArgs: [key, now],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['json_data'] as String?;
  }

  Future<void> clearExpiredCache() async {
    final db = await DbHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.delete(
      DbConstants.tableApiCache,
      where: '(cached_at_ms + ttl_ms) < ?',
      whereArgs: [now],
    );
  }

  /// 清空全部 API 响应缓存（设置页「清理缓存」入口）
  Future<void> clearApiCache() async {
    final db = await DbHelper.instance.database;
    await db.delete(DbConstants.tableApiCache);
  }

  /// API 缓存条目数（设置页展示占用）
  Future<int> apiCacheCount() async {
    final db = await DbHelper.instance.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM ${DbConstants.tableApiCache}',
    );
    return rows.isEmpty ? 0 : (rows.first['c'] as int?) ?? 0;
  }

  // endregion
}
