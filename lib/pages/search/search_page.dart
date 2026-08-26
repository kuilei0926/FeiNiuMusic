import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/api_models.dart';
import '../../app/services/feiniu/track_service.dart';
import '../../app/services/player_service.dart';
import '../../app/state/song_state.dart';
import '../../app/theme/app_styles.dart';
import '../../components/index.dart';
import '../library/library_detail_pages.dart';
import '../songs/song_detail_sheet.dart';

enum SearchCategory { all, song, album, artist }

class SearchPage extends StatefulWidget {
  final SearchCategory initialCategory;

  const SearchPage({super.key, this.initialCategory = SearchCategory.song});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  final FeiNiuTrackService _trackService = FeiNiuTrackService.instance;
  final PlayerService _player = PlayerService.instance;
  SearchCategory _category = SearchCategory.song;

  @override
  void initState() {
    super.initState();
    _category = widget.initialCategory;
  }

  String _query = '';
  bool _searching = false;
  int _searchToken = 0;

  // 搜索结果
  List<SongEntity> _songs = [];
  List<FeiNiuAlbum> _albums = [];
  List<FeiNiuArtist> _artists = [];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    final q = _query.trim();
    if (q.isEmpty) {
      setState(() {
        _songs = [];
        _albums = [];
        _artists = [];
        _searching = false;
      });
      return;
    }

    final token = ++_searchToken;
    setState(() {
      _searching = true;
    });

    try {
      // 并行请求三个搜索接口
      final results = await Future.wait([
        _api.searchTrack(query: q, page: 1, size: 50),
        _api.searchAlbum(query: q, page: 1, size: 24),
        _api.searchArtist(query: q, page: 1, size: 24),
      ]);

      if (!mounted || token != _searchToken) return;

      final trackPage = results[0] as FeiNiuPageData<FeiNiuSearchTrack>;
      final albumPage = results[1] as FeiNiuPageData<FeiNiuAlbum>;
      final artistPage = results[2] as FeiNiuPageData<FeiNiuArtist>;

      final songs = trackPage.list.map((t) {
        final entity = _trackService.trackToSongEntity(t);
        final streamUrl =
            '${_api.baseUrl}/music/api/v1/track/stream?guid=${entity.id}';
        return entity.copyWith(uri: streamUrl);
      }).toList();

      setState(() {
        _songs = songs;
        _albums = albumPage.list;
        _artists = artistPage.list;
        _searching = false;
      });
    } catch (e) {
      if (!mounted || token != _searchToken) return;
      setState(() {
        _songs = [];
        _albums = [];
        _artists = [];
        _searching = false;
      });
    }
  }

  bool _hasResults() =>
      _songs.isNotEmpty || _albums.isNotEmpty || _artists.isNotEmpty;

  /// 拉取「已加载页之后」的第 [page] 页搜索结果（供填充播放使用）。
  /// 当前 _songs 已是第 1 页，填充从第 2 页起。
  Future<List<SongEntity>> _fetchSearchPage(int page) async {
    final pageData = await _api.searchTrack(
      query: _query,
      page: page + 1,
      size: 50,
    );
    return pageData.list.map((t) {
      final entity = _trackService.trackToSongEntity(t);
      final streamUrl =
          '${_api.baseUrl}/music/api/v1/track/stream?guid=${entity.id}';
      return entity.copyWith(uri: streamUrl);
    }).toList();
  }

  /// 播放搜索结果：首屏 50 首不足队列上限时，自动分页拉取更多搜索结果填充。
  void _playSong(int index) {
    if (_songs.isEmpty) return;
    _player.playQueueFilledToLimit(_songs, index, fetchMore: _fetchSearchPage);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    const topBarHeight = 48.0;

    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      resizeToAvoidBottomInset: false,
      keepBottomOverlayFixed: true,
      ignoreKeyboardInsets: true,
      // 搜索页为沉浸式搜索体验，屏蔽底部迷你播放器（含平板/TV/Windows 外壳）。
      showMiniPlayer: false,
      appBar: AppTopBar(
        title: '搜索',
        backgroundColor: Colors.transparent,
        elevation: 0,
        showBackButton: true,
      ),
      body: Padding(
        padding: const EdgeInsets.only(top: topBarHeight),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: TextField(
                controller: _controller,
                // 进入搜索页自动聚焦，可直接输入。
                autofocus: true,
                onChanged: (value) {
                  setState(() {
                    _query = value;
                  });
                  _runSearch();
                },
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: '搜索',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            setState(() {
                              _query = '';
                              _controller.clear();
                            });
                            _runSearch();
                          },
                        ),
                  filled: true,
                  fillColor: theme.appPanelColor,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  border: const OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(20)),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: const BorderRadius.all(Radius.circular(20)),
                    borderSide: BorderSide(
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.6,
                      ),
                      width: 1,
                    ),
                  ),
                ),
                onSubmitted: (_) => _runSearch(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildCategoryChip(SearchCategory.all, '综合'),
                    _buildCategoryChip(SearchCategory.song, '歌曲'),
                    _buildCategoryChip(SearchCategory.album, '专辑'),
                    _buildCategoryChip(SearchCategory.artist, '歌手'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Expanded(child: _buildResults(theme, isDark)),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryChip(SearchCategory category, String label) {
    final selected = _category == category;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: selected
                ? theme.colorScheme.onPrimary
                : (isDark
                      ? Colors.white70
                      : const Color.fromARGB(255, 80, 80, 80)),
          ),
        ),
        selected: selected,
        onSelected: (_) => setState(() => _category = category),
        showCheckmark: false,
        selectedColor: theme.colorScheme.primary,
        backgroundColor: theme.appPanelColor,
        pressElevation: 0,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  Widget _buildResults(ThemeData theme, bool isDark) {
    final listCoverCacheSize = coverMemoryCacheDimensionOf(context, 48);
    final q = _query.trim();

    if (q.isEmpty) {
      return Center(
        child: Text(
          '请输入关键字进行搜索',
          style: TextStyle(
            color: isDark
                ? Colors.white70
                : const Color.fromARGB(255, 110, 110, 110),
          ),
        ),
      );
    }

    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!_hasResults()) {
      return Center(
        child: Text(
          '没有匹配的结果',
          style: TextStyle(
            color: isDark
                ? Colors.white70
                : const Color.fromARGB(255, 110, 110, 110),
          ),
        ),
      );
    }

    return ListView(
      padding: EdgeInsets.only(
        top: 4,
        bottom: AppPageScaffold.scrollableBottomPadding(
          context,
          showMiniPlayer: false,
        ),
      ),
      children: [
        // 歌曲结果
        if (_songs.isNotEmpty &&
            (_category == SearchCategory.all ||
                _category == SearchCategory.song))
          _SectionCard(
            title: '歌曲',
            child: Column(
              children: _songs.take(5).toList().asMap().entries.map((entry) {
                final i = entry.key;
                final song = entry.value;
                return ListTile(
                  leading: ArtworkWidget(song: song, size: 48, borderRadius: 6),
                  title: Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    _artistNames(song.artist),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => _playSong(i),
                  onLongPress: () {
                    showModalBottomSheet<void>(
                      context: context,
                      backgroundColor: Colors.transparent,
                      isScrollControlled: true,
                      builder: (_) => SongDetailSheet(song: song),
                    );
                  },
                );
              }).toList(),
            ),
          ),

        // 专辑结果
        if (_albums.isNotEmpty &&
            (_category == SearchCategory.all ||
                _category == SearchCategory.album))
          _SectionCard(
            title: '专辑',
            child: Column(
              children: _albums.map((album) {
                final coverUrl =
                    album.coverId != null && album.coverId!.isNotEmpty
                    ? _api.coverUrl(album.coverId!, size: FeiNiuApiClient.coverRequestSize)
                    : null;
                return ListTile(
                  leading: coverUrl != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: CachedNetworkImage(
                            imageUrl: coverUrl,
                            httpHeaders: FeiNiuApiClient.imageAuthHeaders(),
                            width: 48,
                            height: 48,
                            memCacheWidth: listCoverCacheSize,
                            memCacheHeight: listCoverCacheSize,
                            fit: BoxFit.cover,
                            errorWidget: (_, _, _) => _albumPlaceholder(theme),
                          ),
                        )
                      : _albumPlaceholder(theme),
                  title: Text(
                    album.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: album.trackCount != null
                      ? Text('${album.trackCount} 首')
                      : null,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => AlbumDetailPage(
                        albumName: album.name,
                        albumGuid: album.guid.isNotEmpty ? album.guid : null,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),

        // 歌手结果
        if (_artists.isNotEmpty &&
            (_category == SearchCategory.all ||
                _category == SearchCategory.artist))
          _SectionCard(
            title: '歌手',
            child: Column(
              children: _artists.map((artist) {
                final coverUrl =
                    artist.coverId != null && artist.coverId!.isNotEmpty
                    ? _api.coverUrl(artist.coverId!, size: FeiNiuApiClient.coverRequestSize)
                    : null;
                return ListTile(
                  leading: CircleAvatar(
                    radius: 24,
                    backgroundImage: coverUrl != null
                        ? ResizeImage.resizeIfNeeded(
                            listCoverCacheSize,
                            listCoverCacheSize,
                            CachedNetworkImageProvider(
                              coverUrl,
                              headers: FeiNiuApiClient.imageAuthHeaders(),
                            ),
                          )
                        : null,
                    child: coverUrl == null
                        ? Text(
                            artist.name.isNotEmpty
                                ? artist.name.characters.first
                                : '?',
                          )
                        : null,
                  ),
                  title: Text(
                    artist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: artist.trackCount != null
                      ? Text('${artist.trackCount} 首')
                      : null,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ArtistDetailPage(
                        artistName: artist.name,
                        artistGuid: artist.guid,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
      ],
    );
  }

  String _artistNames(String artistJson) {
    try {
      final list = jsonDecode(artistJson) as List<dynamic>;
      return list
          .map((e) => (e as Map<String, dynamic>)['name'] as String? ?? '')
          .where((n) => n.isNotEmpty)
          .join(' / ');
    } catch (_) {
      return artistJson;
    }
  }

  Widget _albumPlaceholder(ThemeData theme) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(
        Icons.album_rounded,
        color: theme.colorScheme.primary.withValues(alpha: 0.4),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  const _SectionCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}
