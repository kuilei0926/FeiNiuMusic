import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/utils/image_crop_helper.dart';
import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/api_models.dart';
import '../../app/services/lyrics/lyric_companion_service.dart';
import '../../app/services/companion/companion_error.dart';
import '../../app/services/song_match/backend_match_client.dart';
import '../../app/services/song_match/song_match_models.dart';
import '../../app/services/song_match/song_match_scorer.dart';
import '../../app/services/song_match/song_match_service.dart';
import '../../app/state/settings_lyric_companion.dart';
import '../../app/state/song_state.dart';
import '../../app/router/app_router.dart';
import '../../components/index.dart';

/// 歌曲信息编辑页。
///
/// 从歌曲详情页进入，展示歌曲完整信息（封面、音频规格、元数据），支持编辑
/// 封面 / 名称 / 专辑 / 歌手 / 年份 / 歌曲序号 / 光盘序号 / 风格。保存成功后
/// 返回更新后的 [SongEntity]，由调用方刷新列表与播放器。
class SongEditPage extends StatefulWidget {
  final SongEntity song;

  const SongEditPage({super.key, required this.song});

  @override
  State<SongEditPage> createState() => _SongEditPageState();
}

class _SongEditPageState extends State<SongEditPage> {
  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  final _formKey = GlobalKey<FormState>();

  bool _loading = true;
  bool _saving = false;

  /// 匹配歌曲信息进行中（按钮显示 loading）。
  bool _matching = false;

  // 服务端完整元数据（用于展示音频规格等只读信息）
  FeiNiuTrack? _track;
  FeiNiuAudioSpec? _audioSpec;

  // 表单状态
  late final TextEditingController _titleController;
  late final TextEditingController _albumController;
  late final TextEditingController _yearController;
  late final TextEditingController _trackNoController;
  late final TextEditingController _discNoController;

  /// 当前歌手（FeiNiuArtist，含 coverId 用于头像）
  List<FeiNiuArtist> _artists = [];

  /// 当前风格
  List<FeiNiuGenre> _genres = [];

  /// 换图后的本地裁剪文件路径；为 null 表示未换图（保留原封面）
  String? _pendingCoverPath;

  /// 匹配封面下载到本地的预览路径；匹配封面后本地预览，保存时上传。
  String? _matchedCoverPreviewPath;

  /// 缓存的本地封面 ImageProvider：跨 rebuild 复用同一实例（稳定图片缓存 key），
  /// 避免每次 build 重新创建 FileImage 导致重复解码（编辑页卡顿主因之一）。
  ImageProvider? _localCoverProvider;

  /// 重建 [_localCoverProvider]（路径变化时调用）。
  void _refreshLocalCoverProvider(String? path) {
    if (path == null || path.isEmpty) {
      _localCoverProvider = null;
      return;
    }
    _localCoverProvider = ResizeImage.resizeIfNeeded(
      _coverSize.toInt(),
      null,
      FileImage(File(path)),
    );
  }

  /// 歌词编辑状态（歌词修改开关开启时显示）。
  bool _lyricsLoading = false;
  bool _lyricsSaving = false;
  late final TextEditingController _lyricsController;

  /// 检测服务端增强连接中 / 是否已连接（未连接时禁用歌词编辑）。
  bool _companionProbing = false;
  bool _companionConnected = false;

  /// 歌词是否被修改过（只有修改时才随主保存按钮写入服务端增强）。
  bool _lyricsDirty = false;

  /// 歌词能否编辑写入：需开启服务端增强且连接可达（读取歌词不依赖它）。
  bool get _canEditLyrics =>
      LyricCompanionSettings.enabled.value && _companionConnected;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.song.title);
    _albumController = TextEditingController(
      text: widget.song.albumDisplayName == '未知专辑'
          ? ''
          : widget.song.albumDisplayName,
    );
    _yearController = TextEditingController();
    _trackNoController = TextEditingController(
      text: widget.song.trackNumber?.toString() ?? '',
    );
    _discNoController = TextEditingController(
      text: widget.song.discNumber?.toString() ?? '',
    );
    _lyricsController = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _albumController.dispose();
    _yearController.dispose();
    _trackNoController.dispose();
    _discNoController.dispose();
    _lyricsController.dispose();
    super.dispose();
  }

  /// 拉取歌曲完整元数据填充表单。
  Future<void> _load() async {
    // 歌词修改开关：确保已加载（避免误判「未启用服务端增强」）
    await LyricCompanionSettings.ensureLoaded();
    try {
      final data = await _api.trackMetadata(widget.song.id);
      if (!mounted) return;
      if (data != null) {
        final track = FeiNiuTrack.fromJson(data['track'] as Map<String, dynamic>? ?? {});
        final audioSpec = data['audioSpec'] != null
            ? FeiNiuAudioSpec.fromJson(data['audioSpec'] as Map<String, dynamic>)
            : null;
        _track = track;
        _audioSpec = audioSpec;
        _artists = track.artists;
        _genres = track.genres;
        if (track.year != null) _yearController.text = track.year.toString();
        if (track.title.isNotEmpty) _titleController.text = track.title;
        final albumName = track.album.name;
        if (albumName.isNotEmpty && albumName != '未知专辑') {
          _albumController.text = albumName;
        }
        if (track.trackNo != null) _trackNoController.text = track.trackNo.toString();
        if (track.discNo != null) _discNoController.text = track.discNo.toString();
      }
    } catch (e) {
      debugPrint('[SongEditPage] load metadata error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    // 歌词读取用飞牛原接口（getLyricText），不依赖服务端增强；同时探测
    // 增强连接以决定能否编辑（写入需要增强插件）。
    if (mounted) {
      await _maybeLoadLyrics();
    }
  }

  /// 读取歌词（飞牛原接口）+ 探测服务端增强连接。
  ///
  /// 读取用 `FeiNiuApiClient.getLyricText`（/music/api/v1/lyric/list 原接口），
  /// 不依赖增强插件；[_companionConnected] 仅用于判断能否**编辑写入**
  /// （写入走服务端增强，未开启/未连接时歌词框只读）。
  Future<void> _maybeLoadLyrics() async {
    if (_lyricsLoading) return;
    setState(() => _companionProbing = true);
    final connected = await LyricCompanionService.instance.checkConnected();
    if (!mounted) return;
    setState(() {
      _companionProbing = false;
      _companionConnected = connected;
    });
    await _loadLyrics();
  }

  /// 当前显示的封面 coverId（未换图时用服务端原值）。
  String? get _displayCoverId {
    if (_track?.coverId != null && _track!.coverId!.isNotEmpty) {
      return _track!.coverId;
    }
    if (widget.song.coverId != null && widget.song.coverId!.isNotEmpty) {
      return widget.song.coverId;
    }
    return null;
  }

  // ── 封面选择 / 上传 ──────────────────────────────────────────────

  /// 从相册选择图片 → 1:1 裁剪 → 上传到歌曲封面，得到新 coverId。
  Future<void> _pickCover() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    final file = result?.files.first;
    if (file?.path == null || !mounted) return;

    final cropped = await cropCoverImage(
      sourcePath: file!.path!,
      ratioX: 1,
      ratioY: 1,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: '裁剪封面',
          hideBottomControls: true,
          lockAspectRatio: true,
          toolbarColor: const Color(0xFF212121),
          statusBarLight: false,
          toolbarWidgetColor: Colors.white,
          activeControlsWidgetColor: Colors.white,
          backgroundColor: Colors.black,
        ),
        IOSUiSettings(
          title: '裁剪封面',
          aspectRatioLockEnabled: true,
          resetAspectRatioEnabled: false,
        ),
      ],
    );
    if (cropped == null || !mounted) return;

    setState(() {
      _pendingCoverPath = cropped.path; // 本地预览；保存时才上传
      _refreshLocalCoverProvider(cropped.path);
    });
  }

  /// 封面来源选择：本地相册 / 联网搜索。
  Future<void> _showCoverSourceMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => AppSheetPanel(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickCover();
              },
            ),
            // 「联网搜索封面」依赖数据源插件（原生 QuickJS），非 Android 隐藏。
            if (SongMatchService.instance.available)
              ListTile(
                leading: const Icon(Icons.travel_explore_rounded),
                title: const Text('联网搜索封面'),
                subtitle: const Text('通过数据源插件搜索匹配的封面'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _searchCoverOnline();
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 通过数据源插件联网搜索封面，用户点选后下载并本地预览（保存时上传）。
  Future<void> _searchCoverOnline() async {
    if (_matching) return;
    setState(() => _matching = true);
    try {
      final keyword = SongMatchService.instance.buildKeyword(
        title: _titleController.text.trim(),
        artist: _artists.map((a) => a.name).join(' '),
        filePath: _audioSpec?.path,
      );
      if (keyword.isEmpty) {
        AppToast.show(context, '请输入歌曲名称后再搜索', type: ToastType.error);
        return;
      }

      final covers = await SongMatchService.instance.searchCovers(keyword);
      if (!mounted) return;
      if (covers.isEmpty) {
        AppToast.show(context, '未搜索到封面，请检查数据源插件', type: ToastType.error);
        return;
      }

      final selected = await showModalBottomSheet<SongMatchResult>(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (_) => CoverSearchSheet(
          candidates: covers,
          keyword: keyword,
        ),
      );
      if (selected == null || !mounted) return;

      // 下载封面到本地临时文件预览
      final preview = await _downloadCoverToLocal(selected.picUrl);
      if (!mounted) return;
      if (preview == null) {
        AppToast.show(context, '封面下载失败', type: ToastType.error);
        return;
      }
      setState(() {
        _matchedCoverPreviewPath = preview;
        _pendingCoverPath = null;
        _refreshLocalCoverProvider(preview);
      });
      AppToast.show(context, '已选择封面，保存后生效');
    } catch (e) {
      debugPrint('[SongEditPage] search cover error: $e');
      if (mounted) {
        AppToast.show(context, '搜索封面失败：$e', type: ToastType.error);
      }
    } finally {
      if (mounted) setState(() => _matching = false);
    }
  }

  /// 下载封面 URL 到本地临时文件（供预览与保存时上传）。
  Future<String?> _downloadCoverToLocal(String url) async {
    if (url.isEmpty) return null;
    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
          responseType: ResponseType.bytes,
          validateStatus: (code) => code != null && code >= 200 && code < 300,
        ),
      );
      final response = await dio.get<Uint8List>(url);
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) return null;
      // 平台封面可能是 webp 等格式，转成 JPEG 再保存（上传封面时避免格式被拒）
      var out = bytes;
      try {
        final jpeg = await FlutterImageCompress.compressWithList(
          bytes,
          quality: 92,
          format: CompressFormat.jpeg,
        );
        if (jpeg.isNotEmpty) out = Uint8List.fromList(jpeg);
      } catch (_) {
        // 转码失败用原字节（PNG/JPEG 也能直接用）
      }
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/cover_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await file.writeAsBytes(out);
      return file.path;
    } catch (e) {
      debugPrint('[SongEditPage] download cover error: $e');
      return null;
    }
  }

  // ── 歌手选择 ────────────────────────────────────────────────────

  Future<void> _showArtistPicker() async {
    final selected = await showModalBottomSheet<List<FeiNiuArtist>>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ArtistPickerSheet(initial: _artists),
    );
    if (selected != null && mounted) {
      setState(() => _artists = selected);
    }
  }

  // ── 风格选择 ────────────────────────────────────────────────────

  Future<void> _showGenrePicker() async {
    final selected = await showModalBottomSheet<List<FeiNiuGenre>>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _GenrePickerSheet(initial: _genres),
    );
    if (selected != null && mounted) {
      setState(() => _genres = selected);
    }
  }

  // ── 匹配歌曲信息 ─────────────────────────────────────────────────

  /// 通过 Lyrico 数据源插件搜索当前歌曲的匹配候选，用户点选后回填表单。
  Future<void> _matchSongInfo() async {
    if (_matching) return;
    setState(() => _matching = true);
    try {
      final keyword = SongMatchService.instance.buildKeyword(
        title: _titleController.text.trim(),
        artist: _artists.map((a) => a.name).join(' '),
        filePath: _audioSpec?.path,
      );
      if (keyword.isEmpty) {
        AppToast.show(context, '请输入歌曲名称后再匹配', type: ToastType.error);
        return;
      }

      final grouped = await SongMatchService.instance.searchCandidates(keyword);
      if (!mounted) return;
      if (grouped.isEmpty) {
        AppToast.show(context, '未匹配到歌曲，请检查数据源插件', type: ToastType.error);
        return;
      }

      final selected = await showModalBottomSheet<SongMatchResult>(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (_) => _MatchCandidateSheet(
          grouped: grouped,
          keyword: keyword,
          onSearch: (kw, page) async =>
              (await SongMatchService.instance.searchCandidates(kw, page: page)),
        ),
      );
      if (selected == null || !mounted) return;

      // 歌词修改开启时，候选选中即同步预取歌词（应用时直接使用，不再二次搜索）。
      // 歌词预取走数据源插件（getLyricsCandidates），与 nginx /music-enhance 的服务端增强
      // 无关，故不 gate 于 checkConnected()；连接状态只影响弹层里「未连接到增强
      // 插件」提示与是否可勾选歌词（决定能否写入 NAS）。
      String? prefetchedLyrics;
      bool companionConnected = false;
      if (LyricCompanionSettings.enabled.value) {
        companionConnected =
            await LyricCompanionService.instance.checkConnected();
        final kwTitle = selected.title.isNotEmpty ? selected.title : _titleController.text.trim();
        final kwArtist = selected.artist.isNotEmpty ? selected.artist : _artists.map((a) => a.name).join(' ');
        prefetchedLyrics = await SongMatchService.instance.fetchLyrics(
          title: kwTitle,
          artist: kwArtist,
          album: selected.album,
          sourceId: selected.id,
          sourceInternal: selected.internal,
          sourceFields: selected.normalizedFields,
          pluginId: selected.pluginId,
        );
        if (!mounted) return;
      }

      // 让用户选择要应用哪些信息（而非全部覆盖），并展示变更对比
      final fields = await showModalBottomSheet<Set<MatchField>>(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (_) => _MatchApplySheet(
          candidate: selected,
          currentTitle: _titleController.text.trim(),
          currentArtist: _artists.map((a) => a.name).join(' / '),
          currentAlbum: _albumController.text.trim(),
          currentYear: _yearController.text.trim(),
          currentCoverUrl: _displayCoverId != null && _displayCoverId!.isNotEmpty
              ? _api.coverUrl(_displayCoverId!, size: FeiNiuApiClient.coverRequestSize)
              : null,
          currentLyrics: _lyricsController.text,
          currentTrackNo: _trackNoController.text.trim(),
          currentDiscNo: _discNoController.text.trim(),
          prefetchedLyrics: prefetchedLyrics,
          companionConnected: companionConnected,
        ),
      );
      if (fields == null || !mounted) return;

      final patch = await SongMatchService.instance
          .buildPatch(selected, downloadCover: fields.contains(MatchField.cover));
      if (!mounted) return;

      // 回填表单（仅勾选字段）
      setState(() {
        if (fields.contains(MatchField.title) && patch.title.isNotEmpty) {
          _titleController.text = patch.title;
        }
        if (fields.contains(MatchField.album) && patch.album.isNotEmpty) {
          _albumController.text = patch.album;
        }
        if (fields.contains(MatchField.year) && patch.year.isNotEmpty) {
          _yearController.text = patch.year;
        }
        if (fields.contains(MatchField.trackNumber) &&
            patch.trackNumber.isNotEmpty) {
          _trackNoController.text = patch.trackNumber;
        }
        if (fields.contains(MatchField.discNumber) &&
            patch.discNumber.isNotEmpty) {
          _discNoController.text = patch.discNumber;
        }
      });

      // 解析歌手 → FeiNiuArtist（仅勾选歌手字段且匹配到才应用）
      if (fields.contains(MatchField.artist) && patch.artist.isNotEmpty) {
        final resolved =
            await SongMatchService.instance.resolveArtists(patch.artist);
        if (mounted && resolved.isNotEmpty) {
          setState(() => _artists = resolved);
        }
      }

      // 封面：仅勾选封面字段且有封面时下载预览（保存时上传）。
      if (fields.contains(MatchField.cover) &&
          patch.coverUrl != null &&
          patch.coverUrl!.isNotEmpty) {
        try {
          final preview = await _downloadCoverToLocal(patch.coverUrl!);
          if (!mounted) return;
          if (preview != null) {
            setState(() {
              _matchedCoverPreviewPath = preview;
              _pendingCoverPath = null;
              _refreshLocalCoverProvider(preview);
            });
            AppToast.show(context, '已匹配并更新封面预览');
          }
        } catch (e) {
          debugPrint('[SongEditPage] cover download error: $e');
          if (mounted) {
            AppToast.show(context, '封面预览失败，其余已匹配', type: ToastType.error);
          }
        }
      } else {
        if (mounted) AppToast.show(context, '已匹配歌曲信息');
      }

      // 歌词：勾选歌词字段且歌词修改已开启时，用候选选中时预取的歌词填充
      if (fields.contains(MatchField.lyrics) &&
          LyricCompanionSettings.enabled.value) {
        if (prefetchedLyrics != null && prefetchedLyrics.isNotEmpty) {
          setState(() {
            _lyricsController.text = prefetchedLyrics!;
            _lyricsDirty = true;
          });
          if (mounted) AppToast.show(context, '已匹配歌词（保存时写入）');
        } else {
          if (mounted) {
            AppToast.show(context, '未获取到歌词（检查数据源插件）', type: ToastType.error);
          }
        }
      }
    } catch (e) {
      debugPrint('[SongEditPage] match error: $e');
      if (mounted) {
        AppToast.show(context, '匹配失败：$e', type: ToastType.error);
      }
    } finally {
      if (mounted) setState(() => _matching = false);
    }
  }

  // ── 保存 ────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _saving = true);
    try {
      // 换图了 → 先上传拿新 coverId；未换图 → 保留原 coverId
      String? newCoverId;
      if (_pendingCoverPath != null) {
        final bytes = await File(_pendingCoverPath!).readAsBytes();
        newCoverId = await _api.uploadTrackCover(bytes);
      } else if (_matchedCoverPreviewPath != null) {
        // 匹配/联网搜索选择的封面：本地预览文件，保存时上传
        final bytes = await File(_matchedCoverPreviewPath!).readAsBytes();
        newCoverId = await _api.uploadTrackCover(bytes);
      }

      // 未换图时沿用原曲目 coverId（可能为 null，由服务端决定保留原封面）
      final coverId = newCoverId ?? _displayCoverId;

      // 专辑：解析 album 名 → guid（匹配不到且服务端增强可用时自动新建），
      // 避免服务端按字符串隐式新建出重复专辑。
      String? albumGuid;
      final albumText = _albumController.text.trim();
      if (albumText.isNotEmpty) {
        albumGuid =
            (await SongMatchService.instance.resolveAlbum(albumText))?.guid;
      }

      final body = <String, dynamic>{
        'guid': widget.song.id,
        'title': _titleController.text.trim(),
        'album': albumText,
        if (albumGuid != null && albumGuid.isNotEmpty) 'albumGUID': albumGuid,
        'artistGUIDs': _artists.map((a) => a.guid).toList(),
        'genreGUIDs': _genres.map((g) => g.guid).toList(),
        'year': int.tryParse(_yearController.text.trim()),
        'trackNo': int.tryParse(_trackNoController.text.trim()),
        'discNo': int.tryParse(_discNoController.text.trim()),
        if (coverId != null && coverId.isNotEmpty)
          'coverId': coverId,
        if (coverId != null && coverId.isNotEmpty)
          'coverGUID': FeiNiuApiClient.deriveCoverGuid(coverId),
      };

      await _api.updateTrackMetadata(body);

      // 歌词修改过且可编辑（增强开启 + 连接）则随保存统一写入（未修改跳过）。
      if (_lyricsDirty && _canEditLyrics) {
        await _saveLyrics();
      }

      // 构造更新后的 SongEntity 返回
      final artistJson = jsonEncode(
        _artists
            .map((a) => {
                  'guid': a.guid,
                  'name': a.name,
                  if (a.coverId != null && a.coverId!.isNotEmpty)
                    'coverId': a.coverId,
                })
            .toList(),
      );
      final originalAlbumGuid = widget.song.albumGuid;
      final albumJson = jsonEncode({
        if (originalAlbumGuid != null && originalAlbumGuid.isNotEmpty)
          'guid': originalAlbumGuid,
        'name': _albumController.text.trim(),
      });
      final updated = widget.song.copyWith(
        title: _titleController.text.trim(),
        artist: artistJson,
        album: albumJson,
        coverId: coverId ?? widget.song.coverId,
        trackNumber: int.tryParse(_trackNoController.text.trim()),
        discNumber: int.tryParse(_discNoController.text.trim()),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );

      if (!mounted) return;
      AppToast.show(context, '已保存');
      Navigator.of(context).pop(updated);
    } catch (e) {
      debugPrint('[SongEditPage] save error: $e');
      if (mounted) {
        AppToast.show(context, '保存失败：$e', type: ToastType.error);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── UI ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: AppTopBar(
        title: '编辑歌曲',
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          // 「匹配设置」是数据源插件流程（歌词偏好/元数据处理），
          // 依赖原生 QuickJS，非 Android 隐藏。
          if (SongMatchService.instance.available)
            IconButton(
              tooltip: '匹配设置',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () =>
                  Navigator.pushNamed(context, AppRoutes.matchSettings),
            ),
        ],
      ),
      showMiniPlayer: false,
      // 关掉键盘 inset 缩放：键盘弹出/收起时 Scaffold 不再逐帧重排整页
      // （页面有 4 张圆角卡片 + 6 个输入框，是全 App 唯一开此开关的页，
      //  是展开输入法卡顿的主因）。改用列表末尾的 _KeyboardInsetSpacer
      //  单独占位，只让那一个小组件随键盘逐帧重建。
      resizeToAvoidBottomInset: false,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                Form(
                  key: _formKey,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    children: [
                      // 每张卡片独立 RepaintBoundary：键盘 insets 动画期间
                      // 卡片自身不重排，图层只做合成平移，避免整页重新栅格化。
                      RepaintBoundary(child: _buildHeaderCard(context)),
                      const SizedBox(height: 16),
                      if (_audioSpec != null) ...[
                        RepaintBoundary(child: _buildAudioSpecCard(context)),
                        const SizedBox(height: 16),
                      ],
                      RepaintBoundary(child: _buildEditCard(context)),
                      const SizedBox(height: 16),
                      RepaintBoundary(child: _buildLyricSection(context)),
                      const SizedBox(height: 24),
                      SizedBox(
                        height: 48,
                        child: FilledButton.icon(
                          onPressed: _saving ? null : _save,
                          icon: _saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.check_rounded),
                          label: Text(_saving ? '保存中…' : '保存'),
                          style: FilledButton.styleFrom(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                      // 键盘 insets 占位：resizeToAvoidBottomInset 已关闭，
                      // 这里单独读 viewInsets，让保存按钮仍能滚到键盘上方。
                      // 只让这个小组件随键盘逐帧重建，不波及整页。
                      const _KeyboardInsetSpacer(),
                    ],
                  ),
                ),
                // 搜索匹配进行中的全屏加载遮罩（搜索 + 预取歌词耗时较长时提示）
                if (_matching)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.35),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 20,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(height: 12),
                              Text(
                                '正在搜索匹配…',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  /// 头部：居中的封面大图（点击换图）。歌名/歌手在下方表单已有，这里不重复。
  Widget _buildHeaderCard(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Center(
        child: _buildCover(theme),
      ),
    );
  }

  /// 封面大图：右下角相机角标点击选择来源（本地 / 联网搜索）。换图后本地预览，
  /// 否则网络图。
  static const double _coverSize = 160;

  Widget _buildCover(ThemeData theme) {
    final Widget image;
    if (_pendingCoverPath != null) {
      // 本地相册选择的封面。复用缓存的 provider（稳定缓存 key），避免每次
      // build 重新解码大图。
      if (_localCoverProvider == null) {
        _refreshLocalCoverProvider(_pendingCoverPath);
      }
      image = Image(
        image: _localCoverProvider!,
        width: _coverSize,
        height: _coverSize,
        fit: BoxFit.cover,
      );
    } else if (_matchedCoverPreviewPath != null) {
      // 匹配/联网搜索下载的封面，本地预览
      if (_localCoverProvider == null) {
        _refreshLocalCoverProvider(_matchedCoverPreviewPath);
      }
      image = Image(
        image: _localCoverProvider!,
        width: _coverSize,
        height: _coverSize,
        fit: BoxFit.cover,
      );
    } else if (_displayCoverId != null) {
      image = CachedNetworkImage(
        imageUrl: _api.coverUrl(
          _displayCoverId!,
          size: FeiNiuApiClient.coverRequestSize,
          updatedAt: widget.song.updatedAt,
        ),
        httpHeaders: FeiNiuApiClient.imageAuthHeaders(),
        width: _coverSize,
        height: _coverSize,
        fit: BoxFit.cover,
        placeholder: (_, _) => _coverPlaceholder(theme),
        errorWidget: (_, _, _) => _coverPlaceholder(theme),
      );
    } else {
      image = _coverPlaceholder(theme);
    }

    return InkWell(
      onTap: _showCoverSourceMenu,
      borderRadius: BorderRadius.circular(20),
      child: Stack(
        children: [
          // RepaintBoundary：键盘弹入/表单重建时封面图层独立重绘，
          // 避免每次 rebuild 都触发封面 image 重新 decode（编辑页卡顿主因）。
          RepaintBoundary(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: image,
            ),
          ),
          Positioned(
            right: 5,
            bottom: 5,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.photo_camera_rounded,
                size: 18,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _coverPlaceholder(ThemeData theme) {
    final letter = widget.song.title.trim().isEmpty
        ? '?'
        : widget.song.title.trim().substring(0, 1);
    return Container(
      width: _coverSize,
      height: _coverSize,
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(20),
      ),
      alignment: Alignment.center,
      child: Text(
        letter.toUpperCase(),
        style: TextStyle(
          fontSize: 48,
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// 音频规格只读卡片。
  Widget _buildAudioSpecCard(BuildContext context) {
    final spec = _audioSpec!;
    final theme = Theme.of(context);
    final items = <(String, String)>[
      (
        '码率',
        spec.bitrate != null && spec.bitrate! > 0
            ? '${(spec.bitrate! / 1000).toStringAsFixed(0)}kbps'
            : '-',
      ),
      (
        '采样率',
        spec.sampleRate != null && spec.sampleRate! > 0
            ? '${(spec.sampleRate! / 1000).toStringAsFixed(1)}kHz'
            : '-',
      ),
      ('声道数', spec.channel?.toString() ?? '-'),
      (
        '文件大小',
        spec.size != null && spec.size! > 0
            ? '${(spec.size! / (1024 * 1024)).toStringAsFixed(1)}MB'
            : '-',
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '音频信息',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          // 两行两列：每项用同一 _buildSpecItem（内边距 vertical:6），
          // 行距 4，全部项目的上下边距统一收紧。
          _buildSpecRow(theme, items[0], items[1]),
          const SizedBox(height: 4),
          _buildSpecRow(theme, items[2], items[3]),
          if (_track?.createdAt != null && _track!.createdAt > 0) ...[
            const SizedBox(height: 4),
            _buildSpecItem(theme, '添加时间', _formatDate(_track!.createdAt)),
          ],
          if (spec.path != null && spec.path!.isNotEmpty) ...[
            const SizedBox(height: 4),
            _buildSpecItem(theme, '文件位置', spec.path!),
          ],
        ],
      ),
    );
  }

  Widget _buildSpecItem(ThemeData theme, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  /// 一行两个规格项（左右各一个 Expanded，中间间距 8）。
  Widget _buildSpecRow(
    ThemeData theme,
    (String, String) left,
    (String, String) right,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _buildSpecItem(theme, left.$1, left.$2)),
        const SizedBox(width: 8),
        Expanded(child: _buildSpecItem(theme, right.$1, right.$2)),
      ],
    );
  }

  /// 编辑表单卡片。
  Widget _buildEditCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '编辑信息',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 12),
          // 「匹配歌曲信息」依赖数据源插件（原生 QuickJS），非 Android 隐藏。
          if (SongMatchService.instance.available)
            OutlinedButton.icon(
              onPressed: _matching ? null : _matchSongInfo,
              icon: _matching
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.travel_explore_rounded, size: 18),
              label: Text(_matching ? '匹配中…' : '匹配歌曲信息'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 42),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          const SizedBox(height: 16),
          _buildTextField(
            controller: _titleController,
            label: '名称',
            icon: Icons.music_note_outlined,
            validator: (v) {
              if (v == null || v.trim().isEmpty) return '请输入歌曲名称';
              return null;
            },
          ),
          const SizedBox(height: 14),
          _buildTextField(
            controller: _albumController,
            label: '专辑',
            icon: Icons.album_outlined,
          ),
          const SizedBox(height: 14),
          _buildArtistField(context),
          const SizedBox(height: 14),
          _buildChipField(
            context,
            label: '风格',
            icon: Icons.category_outlined,
            chips: _genres.map((g) => g.name).toList(),
            onAdd: _showGenrePicker,
            onRemove:
                _genres.isEmpty ? null : () => setState(() => _genres = []),
          ),
          const SizedBox(height: 14),
          _buildTextField(
            controller: _yearController,
            label: '年份',
            icon: Icons.calendar_today_outlined,
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 14),
          _buildTextField(
            controller: _trackNoController,
            label: '歌曲序号',
            icon: Icons.format_list_numbered_rounded,
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 14),
          _buildTextField(
            controller: _discNoController,
            label: '光盘序号',
            icon: Icons.album_outlined,
            keyboardType: TextInputType.number,
          ),
        ],
      ),
    );
  }

  /// 歌词编辑卡片（始终显示；未开启歌词修改时给提示入口）。
  Widget _buildLyricSection(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '歌词',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              if (!LyricCompanionSettings.enabled.value)
                Text(
                  '未启用服务端增强',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              else if (_companionProbing)
                Text(
                  '检测服务端增强连接…',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              else if (!_companionConnected)
                Text(
                  '未连接到增强插件',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                )
              else if (_lyricsDirty)
                Text(
                  '已修改',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_companionProbing)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_lyricsLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            TextField(
              controller: _lyricsController,
              enabled: _canEditLyrics,
              maxLines: 10,
              minLines: 6,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              onChanged: (_) {
                if (!_lyricsDirty) setState(() => _lyricsDirty = true);
              },
              decoration: const InputDecoration(
                hintText: 'LRC 歌词（如 [00:25.53]歌词内容）',
                border: OutlineInputBorder(),
              ),
            ),
            if (!_canEditLyrics) ...[
              const SizedBox(height: 8),
              InkWell(
                onTap: _openLyricCompanionSettings,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    LyricCompanionSettings.enabled.value
                        ? '未连接增强插件，仅可查看歌词。点击重试'
                        : '未启用服务端增强，仅可查看歌词。点击开启',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: LyricCompanionSettings.enabled.value
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// 跳转到元数据匹配页开启歌词修改。
  void _openLyricCompanionSettings() {
    Navigator.of(context).pushNamed(AppRoutes.metadataMatchSettings);
  }

  /// 从 FnMusicEnhance 读取当前歌词。
  Future<void> _loadLyrics() async {
    if (_lyricsLoading) return;
    setState(() => _lyricsLoading = true);
    try {
      final content =
          await LyricCompanionService.instance.getLyrics(widget.song.id);
      if (!mounted) return;
      setState(() {
        _lyricsController.text = content;
        _lyricsDirty = false;
      });
      if (content.isEmpty) {
        AppToast.show(context, '该歌曲暂无歌词');
      }
    } catch (e) {
      debugPrint('[SongEditPage] load lyrics error: $e');
      if (mounted) {
        AppToast.show(context, '读取歌词失败：$e', type: ToastType.error);
      }
    } finally {
      if (mounted) setState(() => _lyricsLoading = false);
    }
  }

  /// 保存歌词（写入服务端增强，重新读取验证）。
  ///
  /// 仅在歌词被修改过时调用（随主「保存」按钮统一提交）；未修改则跳过。
  Future<void> _saveLyrics() async {
    if (_lyricsSaving || _lyricsLoading || !_lyricsDirty) return;
    setState(() => _lyricsSaving = true);
    try {
      await LyricCompanionService.instance
          .saveLyrics(widget.song.id, _lyricsController.text);
      if (!mounted) return;
      _lyricsDirty = false;
    } catch (e) {
      debugPrint('[SongEditPage] save lyrics error: $e');
      if (mounted) {
        AppToast.show(
          context,
          '歌词保存失败：${friendlyCompanionError(e)}',
          type: ToastType.error,
        );
        rethrow;
      }
    } finally {
      if (mounted) setState(() => _lyricsSaving = false);
    }
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        isDense: true,
      ),
    );
  }

  /// 歌手字段：大号头像 + 名字（无 chip 背景包裹），横向可换行排列。
  /// 每个歌手显示头像（有 coverId 用图片，否则首字母圆形占位）与名字，
  /// 右上角删除按钮移除。点击「添加」打开歌手选择器。
  Widget _buildArtistField(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.person_outline, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              '歌手',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 14,
          runSpacing: 14,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final artist in _artists)
              _buildArtistItem(theme, artist),
            InkWell(
              onTap: _showArtistPicker,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.3),
                  ),
                ),
                child: Icon(
                  Icons.add_rounded,
                  color: theme.colorScheme.primary,
                  size: 28,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildArtistItem(ThemeData theme, FeiNiuArtist artist) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ArtistAvatarWidget(
              coverId: artist.coverId,
              name: artist.name,
              size: 56,
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: 60,
              child: Text(
                artist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        Positioned(
          top: -3,
          right: -3,
          child: GestureDetector(
            onTap: () {
              setState(() {
                _artists = _artists
                    .where((a) => a.guid != artist.guid)
                    .toList();
              });
            },
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                shape: BoxShape.circle,
                border: Border.all(
                  color: theme.colorScheme.onSurfaceVariant
                      .withValues(alpha: 0.4),
                ),
              ),
              child: Icon(
                Icons.close_rounded,
                size: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 可添加/清空的 chip 字段（风格）。
  Widget _buildChipField(
    BuildContext context, {
    required String label,
    required IconData icon,
    required List<String> chips,
    required VoidCallback onAdd,
    required VoidCallback? onRemove,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (chips.isEmpty)
              const SizedBox.shrink()
            else
              for (final chip in chips)
                InputChip(
                  label: Text(chip),
                  onDeleted: onRemove == null ? null : () => onRemove(),
                  deleteIconColor: theme.colorScheme.onSurfaceVariant,
                  visualDensity: VisualDensity.compact,
                ),
            ActionChip(
              avatar: Icon(
                Icons.add_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              label: const Text('添加'),
              onPressed: onAdd,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ],
    );
  }

  String _formatDate(int timestampMs) {
    // timestamp 单位为秒（服务端 createdAt）
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs * 1000);
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }
}

/// 键盘 insets 占位：编辑页关闭了 resizeToAvoidBottomInset 以避免键盘动画
/// 逐帧重排整页，这里单独读取 viewInsets 撑出底部空间，让保存按钮仍能滚到
/// 键盘上方。独立小部件，随键盘逐帧重建的只有它自己。
class _KeyboardInsetSpacer extends StatelessWidget {
  const _KeyboardInsetSpacer();

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return SizedBox(height: bottomInset + 12);
  }
}

/// 歌手选择弹层：可搜索、显示头像+名字、多选。
class _ArtistPickerSheet extends StatefulWidget {
  final List<FeiNiuArtist> initial;

  const _ArtistPickerSheet({required this.initial});

  @override
  State<_ArtistPickerSheet> createState() => _ArtistPickerSheetState();
}

class _ArtistPickerSheetState extends State<_ArtistPickerSheet> {
  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  List<FeiNiuArtist> _all = [];
  final Set<String> _selected = {};
  bool _loading = true;
  bool _creating = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _selected.addAll(widget.initial.map((a) => a.guid));
    _load();
  }

  Future<void> _load() async {
    try {
      final artists = await _api.getArtistListAll();
      if (!mounted) return;
      setState(() {
        _all = artists;
        _loading = false;
      });
    } catch (e) {
      debugPrint('[ArtistPickerSheet] load error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 手动新增歌手：弹输入框 → 调 `/artist/create` → 追加到列表并选中。
  Future<void> _showCreateDialog() async {
    final controller = TextEditingController();
    final created = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新增歌手'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入歌手名称',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) {
            final name = v.trim();
            if (name.isNotEmpty) Navigator.of(dialogContext).pop(name);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              Navigator.of(dialogContext).pop(name);
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
    final name = created?.trim();
    if (name == null || name.isEmpty || !mounted) return;

    setState(() => _creating = true);
    try {
      final artist = await _api.createArtist(name);
      if (!mounted) return;
      setState(() {
        _creating = false;
        if (!_all.any((a) => a.guid == artist.guid)) _all.add(artist);
        _selected.add(artist.guid);
        _query = ''; // 清空搜索，确保新歌手可见
      });
      if (mounted) {
        AppToast.show(context, '已创建歌手「$name」');
      }
    } catch (e) {
      debugPrint('[ArtistPickerSheet] create artist error: $e');
      if (mounted) {
        setState(() => _creating = false);
        AppToast.show(context, '创建失败：$e', type: ToastType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _query.isEmpty
        ? _all
        : _all
              .where(
                (a) => a.name.toLowerCase().contains(_query.toLowerCase()),
              )
              .toList();

    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Center(
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: theme.brightness == Brightness.dark
                    ? Colors.grey[800]
                    : Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                Text(
                  '选择歌手',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                Text(
                  '已选 ${_selected.length}',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: _creating ? null : _showCreateDialog,
                  icon: _creating
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.person_add_alt_1_rounded, size: 18),
                  label: const Text('新增'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: '搜索歌手',
                prefixIcon: const Icon(Icons.search_rounded),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final artist = filtered[index];
                      final selected = _selected.contains(artist.guid);
                      return ListTile(
                        leading: _ArtistAvatarWidget(
                          coverId: artist.coverId,
                          name: artist.name,
                          size: 40,
                        ),
                        title: Text(artist.name),
                        trailing: selected
                            ? Icon(
                                Icons.check_circle,
                                color: theme.colorScheme.primary,
                              )
                            : Icon(
                                Icons.circle_outlined,
                                color: theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.4),
                              ),
                        onTap: () {
                          setState(() {
                            if (selected) {
                              _selected.remove(artist.guid);
                            } else {
                              _selected.add(artist.guid);
                            }
                          });
                        },
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: SizedBox(
              height: 48,
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  final chosen = _all
                      .where((a) => _selected.contains(a.guid))
                      .toList();
                  Navigator.of(context).pop(chosen);
                },
                child: const Text('确定'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 歌手头像：有 coverId 显示图片，否则首字母圆形占位。
class _ArtistAvatarWidget extends StatelessWidget {
  final String? coverId;
  final String name;
  final double size;

  const _ArtistAvatarWidget({
    required this.coverId,
    required this.name,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final radius = size / 2;
    final initial = name.isNotEmpty ? name.characters.first : '?';
    if (coverId != null && coverId!.isNotEmpty) {
      final coverUrl = FeiNiuApiClient.instance.coverUrl(coverId!, size: FeiNiuApiClient.coverRequestSize);
      // 有封面时不叠加名字首字，仅显示头像图片。
      return CircleAvatar(
        radius: radius,
        backgroundImage: CachedNetworkImageProvider(
          coverUrl,
          headers: FeiNiuApiClient.imageAuthHeaders(),
        ),
        onBackgroundImageError: (_, _) {},
      );
    }
    return CircleAvatar(radius: radius, child: Text(initial));
  }
}

/// 风格选择弹层：搜索 + 多选（风格无封面，仅名字）。
class _GenrePickerSheet extends StatefulWidget {
  final List<FeiNiuGenre> initial;

  const _GenrePickerSheet({required this.initial});

  @override
  State<_GenrePickerSheet> createState() => _GenrePickerSheetState();
}

class _GenrePickerSheetState extends State<_GenrePickerSheet> {
  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  List<FeiNiuGenre> _all = [];
  final Set<String> _selected = {};
  bool _loading = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _selected.addAll(widget.initial.map((g) => g.guid));
    _load();
  }

  Future<void> _load() async {
    try {
      final page = await _api.getGenreList(page: 1, size: 200);
      if (!mounted) return;
      setState(() {
        _all = page.list;
        _loading = false;
      });
    } catch (e) {
      debugPrint('[GenrePickerSheet] load error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _query.isEmpty
        ? _all
        : _all
              .where(
                (g) => g.name.toLowerCase().contains(_query.toLowerCase()),
              )
              .toList();

    return Container(
      height: MediaQuery.of(context).size.height * 0.6,
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Center(
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: theme.brightness == Brightness.dark
                    ? Colors.grey[800]
                    : Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                Text(
                  '选择风格',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                Text(
                  '已选 ${_selected.length}',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: '搜索风格',
                prefixIcon: const Icon(Icons.search_rounded),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final genre = filtered[index];
                      final selected = _selected.contains(genre.guid);
                      return ListTile(
                        leading: Icon(
                          Icons.category_outlined,
                          color: selected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                        title: Text(genre.name),
                        trailing: selected
                            ? Icon(
                                Icons.check_circle,
                                color: theme.colorScheme.primary,
                              )
                            : Icon(
                                Icons.circle_outlined,
                                color: theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.4),
                              ),
                        onTap: () {
                          setState(() {
                            if (selected) {
                              _selected.remove(genre.guid);
                            } else {
                              _selected.add(genre.guid);
                            }
                          });
                        },
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: SizedBox(
              height: 48,
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  final chosen = _all
                      .where((g) => _selected.contains(g.guid))
                      .toList();
                  Navigator.of(context).pop(chosen);
                },
                child: const Text('确定'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 匹配候选弹层：展示 Lyrico 插件搜索到的候选歌曲，**按数据源分组**展示，
/// 用户点选一个返回。
///
/// 顶部搜索框允许手动编辑关键词重新搜索（[onSearch] 回调）。
class _MatchCandidateSheet extends StatefulWidget {
  final GroupedSongResults grouped;
  final String keyword;

  /// 用户修改关键词后触发重新搜索；返回新候选（分组，空表示无结果）。
  /// [page] 从 1 开始，用于下拉加载更多。
  final Future<GroupedSongResults> Function(String keyword, int page) onSearch;

  const _MatchCandidateSheet({
    required this.grouped,
    required this.keyword,
    required this.onSearch,
  });

  @override
  State<_MatchCandidateSheet> createState() => _MatchCandidateSheetState();
}

class _MatchCandidateSheetState extends State<_MatchCandidateSheet> {
  late final TextEditingController _searchController;
  late GroupedSongResults _grouped;
  bool _searching = false;
  bool _loadingMore = false;
  int _page = 1;
  bool _hasMore = true;

  /// 当前激活的 tab：0 = 综合，>0 = 对应 _grouped.groups[index-1] 的源。
  int _activeTab = 0;

  /// 综合 tab 的合并排序结果（匹配度降序，同分按源顺序）。
  late List<SongMatchResult> _merged = [];

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.keyword);
    _grouped = widget.grouped;
    _recomputeMerged();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 重算综合列表（tab 0 用，按歌曲名+歌手相似度降序）。
  void _recomputeMerged() {
    final sourceOrder = _grouped.groups.map((g) => g.pluginId).toList();
    _merged = SongMatchScorer.mergeRanked(
      _grouped.groups.map((g) => g.results).toList(),
      sourceOrder: sourceOrder,
      keyword: _searchController.text.trim(),
    );
  }

  Future<void> _doSearch() async {
    final keyword = _searchController.text.trim();
    if (keyword.isEmpty || _searching) return;
    setState(() => _searching = true);
    try {
      final results = await widget.onSearch(keyword, 1);
      if (!mounted) return;
      setState(() {
        _grouped = results;
        _page = 1;
        _hasMore = !results.isEmpty;
        _activeTab = 0; // 重新搜索后回到综合
        _recomputeMerged();
      });
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// 下拉加载更多（翻页追加候选）。
  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _searching) return;
    setState(() => _loadingMore = true);
    try {
      final next = await widget.onSearch(
        _searchController.text.trim(),
        _page + 1,
      );
      if (!mounted) return;
      setState(() {
        if (!next.isEmpty) {
          // 按源合并：新页结果追加到对应源分组
          final merged = <SourceGroup>[];
          for (final group in _grouped.groups) {
            final added = next.groups
                .where((g) => g.pluginId == group.pluginId)
                .expand((g) => g.results)
                .toList();
            merged.add(SourceGroup(
              pluginId: group.pluginId,
              pluginName: group.pluginName,
              results: [...group.results, ...added],
            ));
          }
          _grouped = GroupedSongResults(groups: merged);
          _page += 1;
          _recomputeMerged();
        }
        _hasMore = !next.isEmpty;
      });
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        return AppSheetPanel(
          title: '匹配歌曲信息',
          expand: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 搜索框：允许手动编辑关键词重新搜索
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: TextField(
                  controller: _searchController,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _doSearch(),
                  decoration: InputDecoration(
                    hintText: '搜索歌曲（可编辑后重新搜索）',
                    prefixIcon: const Icon(Icons.search_rounded),
                    isDense: true,
                    suffixIcon: _searching
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : IconButton(
                            icon: const Icon(Icons.refresh_rounded),
                            tooltip: '重新搜索',
                            onPressed: _doSearch,
                          ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  '共 ${_grouped.flat.length} 个候选 · 点选应用',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // 多源 tag 切换：第一项「综合」，后续每源一个
              _buildSourceTabs(theme),
              const Divider(height: 1),
              Expanded(
                child: _activeList().isEmpty
                    ? Center(
                        child: Text(
                          _searching ? '搜索中…' : '未匹配到歌曲',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : _buildActiveList(scrollController, theme),
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
    for (var i = 0; i < _grouped.groups.length; i++) {
      final group = _grouped.groups[i];
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

  /// 当前激活 tab 的候选列表。
  List<SongMatchResult> _activeList() {
    if (_activeTab == 0) return _merged;
    final group = _grouped.groups[_activeTab - 1];
    return group.results;
  }

  /// 渲染当前激活 tab 的候选列表。
  Widget _buildActiveList(
    ScrollController scrollController,
    ThemeData theme,
  ) {
    final rows = <Widget>[];
    for (final candidate in _activeList()) {
      rows.add(_candidateTile(candidate));
    }
    if (_hasMore) {
      rows.add(Padding(
        key: const ValueKey('load-more'),
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: _loadingMore
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  '上拉加载更多',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
        ),
      ));
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 120 && _hasMore) {
          _loadMore();
        }
        return false;
      },
      child: ListView(
        controller: scrollController,
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: rows,
      ),
    );
  }

  /// 单个候选行。
  Widget _candidateTile(SongMatchResult candidate) {
    return ListTile(
      leading: _candidateCover(candidate),
      title: Text(
        candidate.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          // 综合 tab 显示来源（方便区分同名的不同源结果）
          if (_activeTab == 0 && candidate.pluginName.isNotEmpty)
            candidate.pluginName,
          if (candidate.artist.isNotEmpty) candidate.artist,
          if (candidate.album.isNotEmpty) candidate.album,
          if (candidate.date.isNotEmpty) candidate.date,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: false,
      onTap: () => Navigator.of(context).pop(candidate),
    );
  }

  /// 候选封面缩略图（picUrl 外部 URL，失败显示占位）。
  Widget _candidateCover(SongMatchResult candidate) {
    if (candidate.picUrl.isEmpty) {
      return const CircleAvatar(
        radius: 22,
        child: Icon(Icons.music_note_rounded, size: 22),
      );
    }
    return CircleAvatar(
      radius: 22,
      backgroundImage: NetworkImage(candidate.picUrl),
      onBackgroundImageError: (_, _) {},
      child: const Icon(Icons.music_note_rounded, size: 22),
    );
  }
}

/// 封面搜索结果弹层：展示插件搜索到的封面候选，用户点选一个返回。
class CoverSearchSheet extends StatefulWidget {
  final List<SongMatchResult> candidates;
  final String keyword;

  const CoverSearchSheet({
    super.key,
    required this.candidates,
    required this.keyword,
  });

  @override
  State<CoverSearchSheet> createState() => _CoverSearchSheetState();
}

class _CoverSearchSheetState extends State<CoverSearchSheet> {
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
          title: '搜索封面',
          expand: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  '「${widget.keyword}」 · 选择要使用的封面',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: GridView.builder(
                  controller: scrollController,
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 160,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                  ),
                  itemCount: widget.candidates.length,
                  itemBuilder: (context, index) {
                    final candidate = widget.candidates[index];
                    final url = candidate.picUrl;
                    return InkWell(
                      onTap: url.isEmpty ? null : () => Navigator.of(context).pop(candidate),
                      borderRadius: BorderRadius.circular(12),
                      child: url.isEmpty
                          ? Container(
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Center(
                                child: Icon(Icons.image_not_supported_outlined),
                              ),
                            )
                          : CachedNetworkImage(
                              imageUrl: url,
                              fit: BoxFit.cover,
                              placeholder: (_, _) => Container(
                                color: theme.colorScheme.surfaceContainerHighest,
                              ),
                              errorWidget: (_, _, _) => Container(
                                color: theme.colorScheme.surfaceContainerHighest,
                                child: const Center(
                                  child: Icon(Icons.image_not_supported_outlined),
                                ),
                              ),
                        ),
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
}

/// 匹配应用选择弹层：让用户勾选要覆盖哪些信息（标题/歌手/专辑/年份/封面/歌词）。
class _MatchApplySheet extends StatefulWidget {
  final SongMatchResult candidate;

  /// 当前表单值（用于展示「原值 → 新值」变更对比）。
  final String currentTitle;
  final String currentArtist;
  final String currentAlbum;
  final String currentYear;
  final String? currentCoverUrl;
  final String currentLyrics;
  final String currentTrackNo;
  final String currentDiscNo;

  /// 候选选中时同步预取的歌词（LRC）；未获取时为 null。
  final String? prefetchedLyrics;

  /// 服务端增强是否已连接（未连接时歌词字段显示「未连接到增强插件」并禁用）。
  final bool companionConnected;

  const _MatchApplySheet({
    required this.candidate,
    required this.currentTitle,
    required this.currentArtist,
    required this.currentAlbum,
    required this.currentYear,
    this.currentCoverUrl,
    this.currentLyrics = '',
    this.currentTrackNo = '',
    this.currentDiscNo = '',
    this.prefetchedLyrics,
    this.companionConnected = false,
  });

  @override
  State<_MatchApplySheet> createState() => _MatchApplySheetState();
}

class _MatchApplySheetState extends State<_MatchApplySheet> {
  /// 默认全不勾选，由用户手动选择要应用的字段。
  final Set<MatchField> _selected = {};

  /// 候选有数据的字段（可勾选的）。
  List<MatchField> get _enabledFields {
    final c = widget.candidate;
    final result = <MatchField>[
      if (c.title.isNotEmpty) MatchField.title,
      if (c.artist.isNotEmpty) MatchField.artist,
      if (c.album.isNotEmpty) MatchField.album,
      if (c.date.isNotEmpty) MatchField.year,
      if (c.trackNumber.isNotEmpty) MatchField.trackNumber,
      if (c.discNumber.isNotEmpty) MatchField.discNumber,
      if (c.picUrl.isNotEmpty) MatchField.cover,
      if (LyricCompanionSettings.enabled.value &&
          widget.prefetchedLyrics != null &&
          widget.prefetchedLyrics!.isNotEmpty)
        MatchField.lyrics,
    ];
    return result;
  }

  /// 全选状态：全勾选 / 部分勾选（tristate）。
  bool? get _allEnabledSelected {
    final enabled = _enabledFields;
    if (enabled.isEmpty) return false;
    final selectedCount = enabled.where(_selected.contains).length;
    if (selectedCount == 0) return false;
    if (selectedCount == enabled.length) return true;
    return null;
  }

  void _toggleAll(bool select) {
    setState(() {
      if (select) {
        _selected.addAll(_enabledFields);
      } else {
        _selected.removeWhere(_enabledFields.contains);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = widget.candidate;
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.5,
      maxChildSize: 0.85,
      expand: false,
      builder: (context, scrollController) {
        return AppSheetPanel(
          title: '应用匹配信息',
          expand: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              '「${c.title}」· ${c.artist}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Divider(height: 1),
          // 全选 / 取消全选（仅对候选有数据的字段生效）——按钮放右边
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
            child: Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '全选',
                    style: theme.textTheme.bodyMedium,
                  ),
                  Checkbox(
                    value: _allEnabledSelected,
                    tristate: true,
                    onChanged: (v) => _toggleAll(v ?? false),
                  ),
                ],
              ),
            ),
          ),
          Flexible(
            child: ListView(
              controller: scrollController,
              shrinkWrap: true,
              children: [
                // 封面放最上面：显示候选封面图片 + 勾选
                _coverTile(context),
                _fieldTile(
                  context,
                  MatchField.title,
                  '标题',
                  widget.currentTitle,
                  c.title,
                  enabled: c.title.isNotEmpty,
                ),
                _fieldTile(
                  context,
                  MatchField.artist,
                  '歌手',
                  widget.currentArtist,
                  c.artist,
                  enabled: c.artist.isNotEmpty,
                ),
                _fieldTile(
                  context,
                  MatchField.album,
                  '专辑',
                  widget.currentAlbum,
                  c.album,
                  enabled: c.album.isNotEmpty,
                ),
                _fieldTile(
                  context,
                  MatchField.year,
                  '年份',
                  widget.currentYear,
                  c.date,
                  enabled: c.date.isNotEmpty,
                ),
                _fieldTile(
                  context,
                  MatchField.trackNumber,
                  '歌曲序号',
                  widget.currentTrackNo.isEmpty ? '无' : widget.currentTrackNo,
                  c.trackNumber.isEmpty ? '无序号' : '第 ${c.trackNumber} 首',
                  enabled: c.trackNumber.isNotEmpty,
                ),
                _fieldTile(
                  context,
                  MatchField.discNumber,
                  '光盘序号',
                  widget.currentDiscNo.isEmpty ? '无' : widget.currentDiscNo,
                  c.discNumber.isEmpty ? '无碟号' : '碟号 ${c.discNumber}',
                  enabled: c.discNumber.isNotEmpty,
                ),
                if (LyricCompanionSettings.enabled.value)
                  _fieldTile(
                    context,
                    MatchField.lyrics,
                    '歌词',
                    widget.currentLyrics.isEmpty ? '无' : '有（${widget.currentLyrics.length} 字符）',
                    widget.prefetchedLyrics == null || widget.prefetchedLyrics!.isEmpty
                        ? '未获取到歌词'
                        : '已匹配（${widget.prefetchedLyrics!.length} 字符）',
                    enabled: widget.prefetchedLyrics != null &&
                        widget.prefetchedLyrics!.isNotEmpty,
                    note: widget.companionConnected ? null : '未连接到增强插件（写入 NAS 不可用）',
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: _selected.isEmpty
                    ? null
                    : () => Navigator.of(context).pop(_selected),
                child: Text('应用所选 (${_selected.length})'),
              ),
            ),
          ),
        ],
      ),
    );
      },
    );
  }

  /// 字段行：勾选 + 「原值 → 新值」变更对比。
  ///
  /// [note] 为状态说明（如「未连接到增强插件」）：显示在行尾但不参与
  /// 「变更」对比（不显示箭头、不视为待应用的新值）。
  Widget _fieldTile(
    BuildContext context,
    MatchField field,
    String label,
    String oldValue,
    String newValue, {
    required bool enabled,
    String? note,
  }) {
    final theme = Theme.of(context);
    final changed = note == null &&
        oldValue.trim() != newValue.trim() &&
        newValue.isNotEmpty;
    return CheckboxListTile(
      value: _selected.contains(field),
      enabled: enabled,
      title: Text(label),
      subtitle: Row(
        children: [
          Flexible(
            child: Text(
              oldValue.isEmpty ? '空' : oldValue,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                decoration:
                    changed && _selected.contains(field) ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
          if (changed) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Icon(
                Icons.arrow_forward_rounded,
                size: 14,
                color: theme.colorScheme.primary,
              ),
            ),
            Flexible(
              child: Text(
                newValue,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ] else if (note != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Icon(
                Icons.info_outline_rounded,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Flexible(
              child: Text(
                note,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ),
      onChanged: enabled
          ? (v) {
              setState(() {
                if (v == true) {
                  _selected.add(field);
                } else {
                  _selected.remove(field);
                }
              });
            }
          : null,
    );
  }

  /// 封面勾选行：显示候选封面图片（有 picUrl 时），而非「有/无」文字。
  /// 封面行：勾选 + 「原封面 → 新封面」对比（对齐下方字段行样式）。
  Widget _coverTile(BuildContext context) {
    final theme = Theme.of(context);
    final c = widget.candidate;
    final selected = _selected.contains(MatchField.cover);
    final hasCover = c.picUrl.isNotEmpty;

    final oldCover = widget.currentCoverUrl;
    final newCover = c.picUrl;
    final changed = hasCover &&
        (oldCover == null || oldCover.isEmpty || oldCover != newCover);

    return CheckboxListTile(
      value: selected,
      enabled: hasCover,
      title: Text(
        '封面',
        style: theme.textTheme.titleSmall,
      ),
      // 删除 secondary 小图，改为 subtitle 内「原 → 新」两图对比
      subtitle: Row(
        children: [
          Expanded(
            child: _coverThumb(
              context,
              url: oldCover,
              label: oldCover == null || oldCover.isEmpty ? '原封面：无' : '原封面',
              // 原封面来自 NAS（coverUrl），需带认证头
              headers: FeiNiuApiClient.imageAuthHeaders(),
            ),
          ),
          if (changed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Icon(
                Icons.arrow_forward_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
            ),
          Expanded(
            child: _coverThumb(
              context,
              url: newCover,
              label: hasCover ? '新封面' : '无封面',
            ),
          ),
        ],
      ),
      onChanged: hasCover
          ? (v) {
              setState(() {
                if (v == true) {
                  _selected.add(MatchField.cover);
                } else {
                  _selected.remove(MatchField.cover);
                }
              });
            }
          : null,
    );
  }

  /// 封面缩略图：48×48 圆角图片 + 下方小字标签。
  Widget _coverThumb(
    BuildContext context, {
    String? url,
    required String label,
    Map<String, String>? headers,
  }) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: (url != null && url.isNotEmpty)
              ? CachedNetworkImage(
                  imageUrl: url,
                  httpHeaders: headers,
                  width: 48,
                  height: 48,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => Container(
                    width: 48,
                    height: 48,
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: Icon(
                      Icons.music_note_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : Container(
                  width: 48,
                  height: 48,
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.music_note_rounded,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
