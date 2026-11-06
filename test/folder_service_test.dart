import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/feiniu/api_client.dart';
import 'package:feiniu_music/app/services/feiniu/folder_service.dart';

void main() {
  const libraryPath = '/vol3/1000/Music';
  late List<RequestOptions> requests;

  Map<String, dynamic> success(Map<String, dynamic> data) => {
    'code': 0,
    'msg': '',
    'data': data,
  };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    requests = [];
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          if (options.uri.path.endsWith('/shared-library/list')) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: success({
                  'list': [
                    {
                      'guid': 'library-1',
                      'name': '',
                      'path': libraryPath,
                      'itemCount': 3394,
                      'autoDownloadLyric': true,
                      'metadataPreference': 'cloud_preferred',
                      'contentLastChangedAt': 1793708376,
                      'accessStatus': 0,
                    },
                  ],
                }),
              ),
            );
            return;
          }
          if (options.uri.path.endsWith('/folder-view/list')) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: success({
                  'folder': {
                    'name': 'Music',
                    'path': libraryPath,
                    'itemCount': 3394,
                    'folders': [
                      {
                        'name': 'IU',
                        'path': '$libraryPath/IU',
                        'itemCount': 196,
                        'isAdminDeleted': false,
                      },
                      {
                        'name': '周杰伦',
                        'path': '$libraryPath/周杰伦',
                        'itemCount': 174,
                        'isAdminDeleted': false,
                      },
                    ],
                    'tracks': [
                      {
                        'guid': 'track-1',
                        'title': '阿刁',
                        'coverId': 'track_cover',
                        'duration': 377897,
                        'isCue': false,
                        'album': {
                          'guid': 'album-1',
                          'name': '无法长大',
                          'coverId': 'album_cover',
                        },
                        'artists': [
                          {'guid': 'artist-1', 'name': '赵雷'},
                        ],
                        'audioSpec': {
                          'format': 'flac',
                          'path': '$libraryPath/赵雷 - 阿刁.flac',
                          'size': 39463713,
                        },
                        'isFavorite': false,
                        'isAdminDeleted': false,
                      },
                    ],
                  },
                  'sort': 'title,asc',
                }),
              ),
            );
            return;
          }
          handler.reject(
            DioException(
              requestOptions: options,
              message: 'unexpected request',
            ),
          );
        },
      ),
    );
    FeiNiuApiClient.instance.setDioForTest(dio);
    await FeiNiuApiClient.instance.setAuth('https://nas.test', 'test-token');
    FeiNiuFolderService.instance.clearCache();
  });

  test('根目录读取共享音乐库，空白库名回退为目录名', () async {
    final listing = await FeiNiuFolderService.instance.list(path: '/');

    expect(listing.folders, hasLength(1));
    expect(listing.folders.single.name, 'Music');
    expect(listing.folders.single.path, libraryPath);
    expect(requests.single.uri.path, '/music/api/v1/shared-library/list');
  });

  test('目录使用官方 parentPath 并解析曲目、专辑、歌手和音质', () async {
    final listing = await FeiNiuFolderService.instance.list(path: libraryPath);

    expect(requests.last.uri.path, '/music/api/v1/folder-view/list');
    expect(requests.last.queryParameters['parentPath'], libraryPath);
    expect(listing.libraryRoot, libraryPath);
    expect(listing.parent, '/');
    expect(listing.folders.map((folder) => folder.name), ['IU', '周杰伦']);
    expect(listing.total, 1);
    expect(listing.fileTotal, 1);

    final track = listing.files.single.tracks.single;
    expect(track.title, '阿刁');
    expect(track.durationMs, 377897);
    expect(track.album, '无法长大');
    expect(track.albumGuid, 'album-1');
    expect(track.coverId, 'track_cover');
    expect(track.artists.single.name, '赵雷');
    expect(track.audioFormat, 'flac');
    expect(track.audioPath, '$libraryPath/赵雷 - 阿刁.flac');
    expect(track.audioSize, 39463713);
  });

  test('搜索在官方响应上本地过滤且不请求增强接口', () async {
    final listing = await FeiNiuFolderService.instance.list(
      path: libraryPath,
      keyword: '赵雷',
    );

    expect(listing.total, 1);
    expect(listing.files, hasLength(1));
    expect(
      requests.every(
        (request) => request.uri.path.startsWith('/music/api/v1/'),
      ),
      isTrue,
    );
    expect(
      requests.any((request) => request.uri.path.contains('music-enhance')),
      isFalse,
    );
  });
}
