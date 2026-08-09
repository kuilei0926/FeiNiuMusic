import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/api_models.dart';
import '../../app/services/lyrics/lyric_companion_service.dart';
import '../../app/services/plugin/plugin_result_parser.dart';
import '../../app/services/plugin/plugin_service.dart';
import '../../app/services/song_match/song_match_scorer.dart';
import '../../app/services/song_match/song_match_service.dart';
import '../../app/state/settings_lyric_companion.dart';
import '../../app/state/settings_match.dart';
import '../../app/state/song_state.dart';
import '../../components/index.dart';

/// 批量匹配数据页。
///
/// 两阶段流程：
/// 1. **确认页**：选择要匹配的字段（标题/歌手/专辑/年份/封面/歌词）、
///    写入模式（覆盖/填充）、是否逐首确认候选；
/// 2. **执行页**：按 [MatchSettings.concurrency] 并发执行 Lyrico 数据源插件
///    匹配，自动取候选，上传封面、回传 NAS（updateTrackMetadata）。
class BatchMatchPage extends StatefulWidget {
  final List<SongEntity> songs;

  const BatchMatchPage({super.key, required this.songs});

  @override
  State<BatchMatchPage> createState() => _BatchMatchPageState();
}

class _BatchMatchPageState extends State<BatchMatchPage> {
  final FeiNiuApiClient _api = FeiNiuApiClient.instance;

  /// 阶段：confirm = 确认页；running = 执行中；done = 完成。
  String _phase = 'confirm';

  // 确认页选项（默认全不勾选，由用户选择要应用的字段）
  final Set<MatchField> _fields = {};
  MatchWriteMode _writeMode = MatchWriteMode.fill;
  bool _autoConfirm = true;

  /// 执行状态
  final Map<String, String> _status = {};
  int _completed = 0;
  int _success = 0;
  int _failed = 0;
  bool _running = false;

  /// 单首重匹配中（防止并发重匹配）。
  bool _rematching = false;

  /// 上次批量匹配使用的选项（单首重匹配复用）。
  MatchOptions _lastOptions = const MatchOptions();

  @override
  void initState() {
    super.initState();
    for (final song in widget.songs) {
      _status[song.id] = 'pending';
    }
  }

  Future<void> _start() async {
    if (_running) return;
    if (_fields.isEmpty) {
      AppToast.show(context, '请至少选择一项匹配字段', type: ToastType.error);
      return;
    }
    setState(() {
      _phase = 'running';
      _running = true;
      _completed = 0;
      _success = 0;
      _failed = 0;
    });

    await MatchSettings.ensureLoaded();

    final options = MatchOptions(
      fields: _fields,
      writeMode: _writeMode,
      autoConfirmCandidates: _autoConfirm,
    );
    _lastOptions = options;

    // 逐首确认候选时用串行（并发=1），避免多个候选弹窗同时弹出叠加。
    final concurrency = _autoConfirm
        ? MatchSettings.concurrency.value
        : 1;

    final outcomes = await PluginService.mapConcurrent<SongEntity, bool>(
      widget.songs,
      concurrency,
      (song) async {
        if (!mounted) return false;
        setState(() => _status[song.id] = 'running');
        try {
          await _matchOne(song, options);
          if (!mounted) return false;
          setState(() => _status[song.id] = 'done');
          return true;
        } catch (e) {
          debugPrint('[BatchMatch] ${song.title} 失败: $e');
          if (!mounted) return false;
          setState(() => _status[song.id] = 'error');
          return false;
        } finally {
          if (mounted) setState(() => _completed++);
        }
      },
    );

    if (!mounted) return;
    final success = outcomes.where((ok) => ok).length;
    setState(() {
      _running = false;
      _phase = 'done';
      _success = success;
      _failed = outcomes.length - success;
    });
    AppToast.show(context, '批量匹配完成：成功 $_success，失败 $_failed');
  }

  Future<void> _matchOne(SongEntity song, MatchOptions options) async {
    // 优先使用文件名匹配：开关开启时需拉取 audioSpec 取文件路径。
    String? filePath;
    if (MatchSettings.preferFilename.value) {
      try {
        final data = await _api.trackMetadata(song.id);
        if (data != null) {
          final audioSpec = data['audioSpec'] != null
              ? FeiNiuAudioSpec.fromJson(data['audioSpec'] as Map<String, dynamic>)
              : null;
          filePath = audioSpec?.path;
        }
      } catch (e) {
        debugPrint('[BatchMatch] ${song.title} 拉取文件路径失败: $e');
      }
    }

    final keyword = SongMatchService.instance.buildKeyword(
      title: song.title,
      artist: song.artistDisplayName,
      filePath: filePath,
    );
    if (keyword.isEmpty) throw Exception('无匹配关键词');

    final grouped =
        await SongMatchService.instance.searchCandidates(keyword, pageSize: 5);
    final candidates = grouped.flat;
    if (candidates.isEmpty) throw Exception('未匹配到');

    // 选择候选：自动取第一个，或逐首确认
    SongMatchResult candidate;
    if (options.autoConfirmCandidates) {
      // 自动选择：取「综合」排序第一项（匹配度最高；同分按源顺序靠前）
      candidate = SongMatchScorer.mergeRanked(
        grouped.groups.map((g) => g.results).toList(),
        keyword,
        sourceOrder: grouped.groups.map((g) => g.pluginId).toList(),
      ).first;
    } else {
      final chosen = await _pickCandidate(song, grouped, keyword);
      if (chosen == null) throw Exception('已跳过');
      candidate = chosen;
    }

    final patch = await SongMatchService.instance
        .buildPatch(candidate, downloadCover: options.fields.contains(MatchField.cover));

    // 歌词：勾选歌词字段且歌词修改已开启时，通过插件获取并写入服务端增强
    if (options.fields.contains(MatchField.lyrics) &&
        LyricCompanionSettings.enabled.value) {
      final lyrics = await SongMatchService.instance.fetchLyrics(
        title: patch.title.isNotEmpty ? patch.title : song.title,
        artist: patch.artist.isNotEmpty ? patch.artist : song.artistDisplayName,
        album: patch.album,
        sourceId: candidate.id,
        sourceInternal: candidate.internal,
        pluginId: candidate.pluginId,
      );
      if (lyrics != null && lyrics.isNotEmpty) {
        try {
          await LyricCompanionService.instance.saveLyrics(song.id, lyrics);
        } catch (e) {
          debugPrint('[BatchMatch] ${song.title} 歌词写入失败: $e');
        }
      }
    }

    final body = await _buildUpdateBody(song, patch, options);
    await _api.updateTrackMetadata(body);
  }

  /// 单首重新匹配：未运行时点击列表项单独重跑一次该歌曲。
  Future<void> _rematchOne(SongEntity song, int index) async {
    if (_running || _rematching) return;
    setState(() {
      _rematching = true;
      _status[song.id] = 'running';
    });
    try {
      await _matchOne(song, _lastOptions);
      if (!mounted) return;
      setState(() {
        _status[song.id] = 'done';
        _success += 1;
      });
      AppToast.show(context, '${song.title} 已重新匹配');
    } catch (e) {
      debugPrint('[BatchMatch] ${song.title} 重匹配失败: $e');
      if (!mounted) return;
      setState(() => _status[song.id] = 'error');
      AppToast.show(context, '${song.title} 重匹配失败', type: ToastType.error);
    } finally {
      if (mounted) setState(() => _rematching = false);
    }
  }

  Future<SongMatchResult?> _pickCandidate(
    SongEntity song,
    GroupedSongResults grouped,
    String keyword,
  ) async {
    if (!mounted) return null;
    return showModalBottomSheet<SongMatchResult>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _CandidatePickerSheet(
        song: song,
        grouped: grouped,
        keyword: keyword,
      ),
    );
  }

  /// 按字段选择 + 写入模式构造更新 body。
  ///
  /// 关键：只提交**被勾选且解析成功**的字段；未被勾选或解析失败的字段
  /// **不传**（服务端保留原值），绝不传空数组覆盖已有数据。
  Future<Map<String, dynamic>> _buildUpdateBody(
    SongEntity song,
    SongMatchPatch patch,
    MatchOptions options,
  ) async {
    final overwrite = options.writeMode == MatchWriteMode.overwrite;
    final wants = options.fields;

    final body = <String, dynamic>{
      'guid': song.id,
    };

    // 标题：仅勾选且有匹配结果时应用（否则不传，服务端保留原值）
    if (wants.contains(MatchField.title) && patch.title.isNotEmpty) {
      body['title'] = patch.title;
    }

    // 专辑：仅勾选且有匹配结果时应用；解析 album 名 → guid（匹配不到且服务端
    // 增强可用时自动新建）。成功则带 albumGUID 关联实体；解析失败（如中继
    // 不可用）则仅带 album 字符串，回退服务端原有行为。
    if (wants.contains(MatchField.album) && patch.album.isNotEmpty) {
      body['album'] = patch.album;
      final album = await SongMatchService.instance.resolveAlbum(patch.album);
      if (album != null && album.guid.isNotEmpty) {
        body['albumGUID'] = album.guid;
      }
    }

    // 歌手：仅勾选时处理；匹配解析成功用匹配歌手，失败回退原歌手 GUIDs。
    if (wants.contains(MatchField.artist)) {
      List<FeiNiuArtist> artists = [];
      if (patch.artist.isNotEmpty) {
        artists = await SongMatchService.instance.resolveArtists(patch.artist);
      }
      if (artists.isNotEmpty) {
        body['artistGUIDs'] = artists.map((a) => a.guid).toList();
      } else if (!overwrite && song.artistGuids.isNotEmpty) {
        // 填充模式且没解析到新歌手：保留原歌手
        body['artistGUIDs'] = song.artistGuids;
      } else if (overwrite) {
        // 覆盖模式但没解析到：保留原歌手，避免清空
        body['artistGUIDs'] = song.artistGuids;
      }
    }

    // 年份：仅勾选且有匹配结果时应用
    if (wants.contains(MatchField.year)) {
      final year = int.tryParse(patch.year);
      if (year != null) body['year'] = year;
    }

    // 歌曲序号：仅勾选且有匹配结果时应用
    if (wants.contains(MatchField.trackNumber)) {
      final trackNo = int.tryParse(patch.trackNumber);
      if (trackNo != null) body['trackNo'] = trackNo;
    }

    // 光盘序号：插件通常不提供 discNumber，保留原值（不提交）

    // 封面：仅勾选且有下载字节时上传
    String? coverId = song.coverId;
    if (wants.contains(MatchField.cover) && patch.coverBytes != null) {
      try {
        coverId =
            await _api.uploadTrackCover(base64Decode(patch.coverBytes!));
      } catch (e) {
        debugPrint('[BatchMatch] ${song.title} 封面上传失败: $e');
      }
    }
    if (coverId != null && coverId.isNotEmpty) {
      body['coverId'] = coverId;
      body['coverGUID'] = FeiNiuApiClient.deriveCoverGuid(coverId);
    }

    return body;
  }

  @override
  Widget build(BuildContext context) {
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: AppTopBar(
        title: '批量匹配数据',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      showMiniPlayer: false,
      body: _phase == 'confirm'
          ? _buildConfirmPage(context)
          : _buildProgressPage(context),
    );
  }

  // ── 确认页 ─────────────────────────────────────────────────────

  Widget _buildConfirmPage(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        AppSettingSection(
          title: '匹配范围',
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '共 ${widget.songs.length} 首歌曲',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            // 选中歌曲封面横排缩略图
            if (widget.songs.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: SizedBox(
                  height: 44,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: widget.songs.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final song = widget.songs[index];
                      return ArtworkWidget(
                        song: song,
                        size: 44,
                        borderRadius: 8,
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        AppSettingSection(
          title: '匹配字段',
          children: [
            // 全选 / 取消全选
            Row(
              children: [
                const SizedBox(width: 12),
                Text(
                  '全选',
                  style: theme.textTheme.bodyMedium,
                ),
                const Spacer(),
                Checkbox(
                  value: _fields.length == MatchField.values.length,
                  tristate:
                      _fields.isNotEmpty &&
                      _fields.length != MatchField.values.length,
                  onChanged: (v) {
                    setState(() {
                      if (v == true) {
                        _fields.addAll(MatchField.values);
                      } else {
                        _fields.clear();
                      }
                    });
                  },
                ),
              ],
            ),
            const Divider(height: 1),
            for (final field in MatchField.values)
              AppSettingCheckboxTile(
                title: field.label,
                subtitle: _fieldDescription(field),
                value: _fields.contains(field),
                onChanged: (v) {
                  setState(() {
                    if (v) {
                      _fields.add(field);
                    } else {
                      _fields.remove(field);
                    }
                  });
                },
              ),
          ],
        ),
        const SizedBox(height: 16),
        AppSettingSection(
          title: '写入模式',
          children: [
            RadioGroup<MatchWriteMode>(
              groupValue: _writeMode,
              onChanged: (v) {
                if (v != null) setState(() => _writeMode = v);
              },
              child: Column(
                children: [
                  for (final mode in MatchWriteMode.values)
                    RadioListTile<MatchWriteMode>(
                      title: Text(mode.label),
                      subtitle: Text(mode.description),
                      value: mode,
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        AppSettingSection(
          title: '候选确认',
          children: [
            AppSettingSwitchTile(
              title: '自动取第一个候选',
              subtitle: '关闭后逐首弹出候选供选择',
              value: _autoConfirm,
              onChanged: (v) => setState(() => _autoConfirm = v),
            ),
          ],
        ),
        const SizedBox(height: 24),
        SizedBox(
          height: 48,
          child: FilledButton.icon(
            onPressed: _start,
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text('开始匹配 ${widget.songs.length} 首'),
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _fieldDescription(MatchField field) {
    switch (field) {
      case MatchField.title:
        return '匹配歌曲标题';
      case MatchField.artist:
        return '匹配歌手并关联到飞牛歌手';
      case MatchField.album:
        return '匹配所属专辑';
      case MatchField.year:
        return '匹配发行年份';
      case MatchField.trackNumber:
        return '匹配歌曲序号';
      case MatchField.discNumber:
        return '匹配光盘序号';
      case MatchField.cover:
        return '匹配封面并上传到 NAS';
      case MatchField.lyrics:
        return '匹配歌词（写入服务端增强）';
    }
  }

  // ── 执行页 ─────────────────────────────────────────────────────

  Widget _buildProgressPage(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Card(
            margin: EdgeInsets.zero,
            color: theme.cardColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _running
                        ? '正在匹配 $_completed/${widget.songs.length}'
                        : '批量匹配完成',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: widget.songs.isEmpty
                        ? 1
                        : _completed / widget.songs.length,
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _statChip(theme, '总数', widget.songs.length),
                      _statChip(theme, '成功', _success),
                      _statChip(theme, '失败', _failed),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            itemCount: widget.songs.length,
            itemBuilder: (context, index) {
              final song = widget.songs[index];
              final status = _status[song.id] ?? 'pending';
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: ArtworkWidget(song: song, size: 44, borderRadius: 8),
                title: Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  song.artistDisplayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: switch (status) {
                  'running' => const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  'done' => Icon(
                      Icons.check_circle_rounded,
                      color: theme.colorScheme.primary,
                    ),
                  'error' => Icon(
                      Icons.error_rounded,
                      color: theme.colorScheme.error,
                    ),
                  _ => Icon(
                      Icons.schedule_rounded,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                },
                // 未运行时点击单首可单独重新匹配
                onTap: _running
                    ? null
                    : () => _rematchOne(song, index),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _statChip(ThemeData theme, String label, int value) {
    return Padding(
      padding: const EdgeInsets.only(right: 20),
      child: Column(
        children: [
          Text(
            '$value',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: label == '失败' && value > 0
                  ? theme.colorScheme.error
                  : null,
            ),
          ),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 逐首候选选择弹层。
class _CandidatePickerSheet extends StatefulWidget {
  final SongEntity song;
  final GroupedSongResults grouped;
  final String keyword;

  const _CandidatePickerSheet({
    required this.song,
    required this.grouped,
    required this.keyword,
  });

  @override
  State<_CandidatePickerSheet> createState() => _CandidatePickerSheetState();
}

class _CandidatePickerSheetState extends State<_CandidatePickerSheet> {
  /// 当前激活的 tab：0 = 综合，>0 = 对应 grouped.groups[index-1] 的源。
  int _activeTab = 0;

  /// 综合 tab 的合并排序结果（匹配度降序，同分按源顺序）。
  late final List<SongMatchResult> _merged = _computeMerged();

  List<SongMatchResult> _computeMerged() {
    return SongMatchScorer.mergeRanked(
      widget.grouped.groups.map((g) => g.results).toList(),
      widget.keyword,
      sourceOrder: widget.grouped.groups.map((g) => g.pluginId).toList(),
    );
  }

  List<SongMatchResult> get _activeList {
    if (_activeTab == 0) return _merged;
    return widget.grouped.groups[_activeTab - 1].results;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.85,
      expand: false,
      builder: (context, scrollController) {
        return AppSheetPanel(
          title: '选择匹配候选',
          expand: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  '「${widget.song.title}」· ${widget.song.artistDisplayName}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _buildSourceTabs(theme),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _activeList.length,
                  itemBuilder: (context, index) {
                    final candidate = _activeList[index];
                    return ListTile(
                      leading: _candidateCover(theme, candidate),
                      title: Text(
                        candidate.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          // 综合 tab 显示来源（方便区分同名不同源）
                          if (_activeTab == 0 && candidate.pluginName.isNotEmpty)
                            candidate.pluginName,
                          if (candidate.artist.isNotEmpty) candidate.artist,
                          if (candidate.album.isNotEmpty) candidate.album,
                          if (candidate.date.isNotEmpty) candidate.date,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.of(context).pop(candidate),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 顶部源切换 tag 栏：综合 + 各数据源。
  Widget _buildSourceTabs(ThemeData theme) {
    final tabs = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 4, 8),
        child: _sourceChip(theme, 0, '综合'),
      ),
    ];
    for (var i = 0; i < widget.grouped.groups.length; i++) {
      final group = widget.grouped.groups[i];
      if (group.results.isEmpty) continue;
      tabs.add(Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: _sourceChip(theme, i + 1, group.pluginName),
      ));
    }
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(right: 16),
        children: tabs,
      ),
    );
  }

  Widget _sourceChip(ThemeData theme, int index, String label) {
    final selected = _activeTab == index;
    return ChoiceChip(
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      selected: selected,
      onSelected: (_) => setState(() => _activeTab = index),
      labelStyle: theme.textTheme.bodySmall?.copyWith(
        fontSize: 12,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
      ),
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 8),
    );
  }

  /// 候选封面缩略图（picUrl 外部 URL，失败显示占位）。
  Widget _candidateCover(ThemeData theme, SongMatchResult candidate) {
    if (candidate.picUrl.isEmpty) {
      return Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          Icons.music_note_rounded,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CachedNetworkImage(
        imageUrl: candidate.picUrl,
        width: 44,
        height: 44,
        fit: BoxFit.cover,
        errorWidget: (_, _, _) => Container(
          color: theme.colorScheme.surfaceContainerHighest,
          child: Icon(
            Icons.music_note_rounded,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
