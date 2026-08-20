import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/services/companion/companion_error.dart';
import '../../app/services/companion/metadata_companion_service.dart';
import '../../app/services/feiniu/api_client.dart';
import '../../app/services/song_match/song_match_models.dart';
import '../../app/services/song_match/song_match_service.dart';
import '../../app/state/settings_lyric_companion.dart';
import '../../app/utils/image_crop_helper.dart';
import '../../components/index.dart';
import '../songs/song_edit_page.dart';

/// 歌手/专辑编辑页：修改名称 + 封面图（本地上传或联网搜索）。
///
/// 写入走 FnMusicEnhance 服务端增强（`/cover` 写封面、`/entity` 改名），
/// 已启用服务端增强（[LyricCompanionSettings.enabled]）时可用。
/// 保存成功返回新名称（null = 未修改名称）。
class ArtistAlbumEditPage extends StatefulWidget {
  final EntityEditKind kind;
  final String guid;
  final String name;
  final String? coverId;

  const ArtistAlbumEditPage({
    super.key,
    required this.kind,
    required this.guid,
    required this.name,
    this.coverId,
  });

  @override
  State<ArtistAlbumEditPage> createState() => _ArtistAlbumEditPageState();
}

class _ArtistAlbumEditPageState extends State<ArtistAlbumEditPage> {
  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  final MetadataCompanionService _companion = MetadataCompanionService.instance;
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameController =
      TextEditingController(text: widget.name);

  /// 换图后的本地预览文件路径（保存时读字节上传）。
  String? _pendingCoverPath;

  /// 封面加载状态。
  bool _saving = false;
  bool _searching = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
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
            // 「联网搜索封面」依赖服务端增强数据源，后端可达即可用（含 Windows）。
            if (SongMatchService.instance.available)
              ListTile(
                leading: const Icon(Icons.travel_explore_rounded),
                title: const Text('联网搜索封面'),
                subtitle: const Text('通过数据源搜索匹配的封面'),
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

  /// 本地上传：文件选择 → 1:1 裁剪 → 本地预览（保存时上传）。
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
    setState(() => _pendingCoverPath = cropped.path);
  }

  /// 联网搜索：按名称搜封面 → 候选网格 → 下载本地预览（保存时上传）。
  Future<void> _searchCoverOnline() async {
    if (_searching) return;
    final keyword = _nameController.text.trim();
    if (keyword.isEmpty) {
      AppToast.show(context, '请输入名称后再搜索', type: ToastType.error);
      return;
    }

    setState(() => _searching = true);
    try {
      // 歌手 → search_type=1，专辑 → search_type=2（QQ 音乐数据源支持）
      final searchType = switch (widget.kind) {
        EntityEditKind.artist => 1,
        EntityEditKind.album => 2,
      };
      final covers = await SongMatchService.instance
          .searchCovers(keyword, searchType: searchType);
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

      final preview = await _downloadCoverToLocal(selected.picUrl);
      if (!mounted) return;
      if (preview == null) {
        AppToast.show(context, '封面下载失败', type: ToastType.error);
        return;
      }
      setState(() => _pendingCoverPath = preview);
    } catch (e) {
      debugPrint('[ArtistAlbumEditPage] search cover error: $e');
      if (mounted) {
        AppToast.show(context, '搜索封面失败：$e', type: ToastType.error);
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// 下载封面 URL 到本地临时文件（转成 JPEG，供预览与保存时上传）。
  ///
  /// 平台封面可能是 webp 等格式，服务端增强仅接受 PNG/JPEG（magic-byte 校验），
  /// 故下载后统一转成 JPEG，避免上传被拒。
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
      // webp 等格式 → JPEG（PNG/JPEG 转码后仍是 JPEG，统一通过服务端校验）
      var out = bytes;
      try {
        final jpeg = await FlutterImageCompress.compressWithList(
          bytes,
          quality: 92,
          format: CompressFormat.jpeg,
        );
        if (jpeg.isNotEmpty) out = Uint8List.fromList(jpeg);
      } catch (_) {
        // 转码失败用原字节（PNG/JPEG 也能直接通过）
      }
      final dir = await getTemporaryDirectory();
      final file =
          File('${dir.path}/cover_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await file.writeAsBytes(out);
      return file.path;
    } catch (e) {
      debugPrint('[ArtistAlbumEditPage] download cover error: $e');
      return null;
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    // 服务端增强可用性门槛：未启用时禁用
    if (!LyricCompanionSettings.enabled.value) {
      AppToast.show(context, '请先在设置 → 元数据管理启用服务端增强', type: ToastType.error);
      return;
    }

    setState(() => _saving = true);
    try {
      final newName = _nameController.text.trim();

      // 换图 → 上传封面
      if (_pendingCoverPath != null) {
        final bytes = await File(_pendingCoverPath!).readAsBytes();
        await _companion.uploadCover(
          kind: widget.kind,
          guid: widget.guid,
          bytes: bytes,
        );
      }

      // 名称变化 → 改名
      if (newName.isNotEmpty && newName != widget.name) {
        await _companion.updateName(
          kind: widget.kind,
          guid: widget.guid,
          name: newName,
        );
      }

      if (!mounted) return;
      AppToast.show(context, '已保存');
      Navigator.of(context).pop(newName);
    } catch (e) {
      debugPrint('[ArtistAlbumEditPage] save error: $e');
      if (mounted) {
        AppToast.show(
          context,
          '保存失败：${friendlyCompanionError(e)}',
          type: ToastType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── UI ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: AppTopBar(
        title: '编辑${widget.kind.label}',
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            // 封面头部
            Center(child: _buildCover()),
            const SizedBox(height: 24),
            // 名称
            TextFormField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: '${widget.kind.label}名称',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? '请输入名称'
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCover() {
    final theme = Theme.of(context);
    const size = 160.0;
    final isAlbum = widget.kind == EntityEditKind.album;
    final shape = BorderRadius.circular(isAlbum ? 16 : size / 2);

    Widget child;
    if (_pendingCoverPath != null) {
      // 本地预览（裁剪/下载后）
      child = Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: shape,
          color: theme.colorScheme.surfaceContainerHighest,
          image: DecorationImage(
            image: FileImage(File(_pendingCoverPath!)),
            fit: BoxFit.cover,
          ),
        ),
      );
    } else if (widget.coverId != null && widget.coverId!.isNotEmpty) {
      final coverUrl = _api.coverUrl(widget.coverId!, size: FeiNiuApiClient.coverRequestSize);
      child = ClipRRect(
        borderRadius: shape,
        child: CachedNetworkImage(
          imageUrl: coverUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          httpHeaders: FeiNiuApiClient.imageAuthHeaders(),
          errorWidget: (_, _, _) => _coverPlaceholder(theme, size, shape),
          placeholder: (_, _) => Container(
            width: size,
            height: size,
            color: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
      );
    } else {
      child = _coverPlaceholder(theme, size, shape);
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          right: 4,
          bottom: 4,
          child: InkWell(
            onTap: _searching ? null : _showCoverSourceMenu,
            customBorder: const CircleBorder(),
            child: CircleAvatar(
              radius: 20,
              backgroundColor: theme.colorScheme.primary,
              child: _searching
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.edit_outlined, size: 18, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  Widget _coverPlaceholder(ThemeData theme, double size, BorderRadius shape) {
    final initial = widget.name.isNotEmpty ? widget.name.characters.first : '?';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: shape,
        color: theme.colorScheme.surfaceContainerHighest,
      ),
      child: Center(
        child: Text(
          initial,
          style: const TextStyle(fontSize: 48),
        ),
      ),
    );
  }
}
