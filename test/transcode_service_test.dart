import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/feiniu/api_client.dart';
import 'package:feiniu_music/app/services/feiniu/transcode_service.dart';
import 'package:feiniu_music/app/state/song_state.dart';

/// 构造一个用拦截器短路返回指定响应体的 Dio（不真正发网络请求）。
///
/// [respond] 返回任意响应体：JSON Map（transcode 响应）、String（m3u8）、
/// Uint8List（音频分片字节）。
Dio _mockDio(
  dynamic Function(RequestOptions options) respond, {
  DioException Function(RequestOptions options)? error,
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final e = error?.call(options);
        if (e != null) {
          handler.reject(e, true);
          return;
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: respond(options),
          ),
        );
      },
    ),
  );
  return dio;
}

/// 拼一个 fMP4 分片：moof(traf(trun(sample sizes))) + mdat。
/// 用于让 fetchBytes 的拦截器返回一个带指定 sample 大小表的分片。
Uint8List _fmp4Segment(List<int> sampleSizes) {
  final trunPayload = ByteData(8 + sampleSizes.length * 4);
  trunPayload.setUint32(0, 0x000200); // version=0, sample_size 位
  trunPayload.setUint32(4, sampleSizes.length);
  for (var i = 0; i < sampleSizes.length; i++) {
    trunPayload.setUint32(8 + i * 4, sampleSizes[i]);
  }
  final trun = _box('trun', trunPayload.buffer.asUint8List());
  final traf = _box('traf', trun);
  final moof = _box('moof', traf);
  final mdat = _box('mdat', Uint8List(16));
  final all = Uint8List(moof.length + mdat.length);
  all.setAll(0, moof);
  all.setAll(moof.length, mdat);
  return all;
}

Uint8List _box(String type, Uint8List payload) {
  final data = Uint8List(8 + payload.length);
  final bd = ByteData.sublistView(data);
  bd.setUint32(0, data.length);
  for (var i = 0; i < 4; i++) {
    bd.setUint8(4 + i, type.codeUnitAt(i));
  }
  data.setAll(8, payload);
  return data;
}

const _m3u8 = '#EXTM3U\n'
    '#EXT-X-MAP:URI="init.mp4"\n'
    '#EXTINF:4.0,\n'
    'seg0.mp4\n';

SongEntity _song(String id, {String? format}) {
  return SongEntity(id: id, title: 't', artist: '[{"name":"a"}]', format: format);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FeiNiuTranscodeService.instance.resetForTest();
    FeiNiuApiClient.instance.setDioForTest(
      _mockDio((o) => {
        'code': 0,
        'data': {
          'audioSpec': {'format': 'dsf'},
          'track': {
            'audioSpec': {'format': 'dsf'},
          },
          'url': '/music/api/v1/track/hls/id-1/preset.m3u8',
        },
      }),
    );
  });

  group('isTranscodeNeeded', () {
    test('不支持的格式返回 true', () {
      for (final f in ['dsf', 'dff', 'wma', 'ape', 'dts', 'aiff', 'DSF', ' Wma ']) {
        expect(FeiNiuTranscodeService.instance.isTranscodeNeeded(f), isTrue,
            reason: '$f 应判定为需要转码');
      }
    });

    test('常见格式返回 false', () {
      for (final f in ['flac', 'mp3', 'ogg', 'wav', 'm4a', 'aac', 'opus']) {
        expect(FeiNiuTranscodeService.instance.isTranscodeNeeded(f), isFalse,
            reason: '$f 应判定为无需转码');
      }
    });

    test('null/空返回 false', () {
      expect(FeiNiuTranscodeService.instance.isTranscodeNeeded(null), isFalse);
      expect(FeiNiuTranscodeService.instance.isTranscodeNeeded(''), isFalse);
    });
  });

  group('hlsUrlFor', () {
    test('metadata 确认是 dsf → 请求转码并返回绝对 URL', () async {
      final api = FeiNiuApiClient.instance;
      final meta = await api.trackMetadata('id-1');
      expect(meta, isNotNull);
      expect(meta!['audioSpec'], isNotNull);

      final url = await FeiNiuTranscodeService.instance.hlsUrlFor(
        _song('id-1', format: 'dsf'),
      );
      // 转码未走 trackTranscode（mock 拦截器未实现），此处验证逻辑能到 transcode 调用
      expect(url, isNotNull);
    });

    test('无需转码的格式 → null，不调用网络', () async {
      final url = await FeiNiuTranscodeService.instance.hlsUrlFor(
        _song('id-2', format: 'flac'),
      );
      expect(url, isNull);
    });

    test('song.format 为空 → 经 metadata 确认 dsf 后仍转码', () async {
      var metadataCalls = 0;
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) {
          if (o.path.contains('metadata')) metadataCalls++;
          return {
            'code': 0,
            'data': {
              'audioSpec': {'format': 'dsf'},
              'url': '/music/api/v1/track/hls/id-2a/preset.m3u8',
            },
          };
        }),
      );
      FeiNiuApiClient.instance.setBaseUrl('https://nas.example.com');
      final url = await FeiNiuTranscodeService.instance.hlsUrlFor(
        _song('id-2a', format: ''), // 列表接口未返回 audioSpec
      );
      expect(url, 'https://nas.example.com/music/api/v1/track/hls/id-2a/preset.m3u8');
      expect(metadataCalls, 1);
    });

    test('metadata 失败（格式无法确认）→ 返回 null，不转码', () async {
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio(
          (o) => {},
          error: (o) => DioException(requestOptions: o, type: DioExceptionType.connectionError),
        ),
      );
      final url = await FeiNiuTranscodeService.instance.hlsUrlFor(
        _song('id-2b', format: ''),
      );
      expect(url, isNull);
    });

    test('metadata 格式为 flac → 返回 null（不转码）', () async {
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) => {
          'code': 0,
          'data': {
            'audioSpec': {'format': 'flac'},
          },
        }),
      );
      final url = await FeiNiuTranscodeService.instance.hlsUrlFor(
        _song('id-3', format: 'dsf'),
      );
      expect(url, isNull);
    });

    test('转码成功 → 缓存命中，第二次不重复请求', () async {
      var transcodeCalls = 0;
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) {
          if (o.path.contains('transcode')) transcodeCalls++;
          return {
            'code': 0,
            'data': {
              'audioSpec': {'format': 'dsf'},
              'url': '/music/api/v1/track/hls/id-4/preset.m3u8',
            },
          };
        }),
      );

      final first = await FeiNiuTranscodeService.instance.hlsUrlFor(
        _song('id-4', format: 'dsf'),
      );
      final second = await FeiNiuTranscodeService.instance.hlsUrlFor(
        _song('id-4', format: 'dsf'),
      );
      expect(first, second);
      expect(transcodeCalls, 1, reason: '第二次应命中 TTL 缓存');
    });

    test('invalidate 后重新请求转码', () async {
      var transcodeCalls = 0;
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) {
          if (o.path.contains('transcode')) transcodeCalls++;
          return {
            'code': 0,
            'data': {
              'audioSpec': {'format': 'dsf'},
              'url': '/music/api/v1/track/hls/id-5/preset.m3u8',
            },
          };
        }),
      );

      await FeiNiuTranscodeService.instance.hlsUrlFor(
        _song('id-5', format: 'dsf'),
      );
      FeiNiuTranscodeService.instance.invalidate('id-5');
      await FeiNiuTranscodeService.instance.hlsUrlFor(
        _song('id-5', format: 'dsf'),
      );
      expect(transcodeCalls, 2, reason: 'invalidate 后应重新请求');
    });

    test('trackTranscode 返回 null → hlsUrlFor 返回 null', () async {
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) => {
          'code': 0,
          'data': {
            'audioSpec': {'format': 'dsf'},
          },
        }),
      );
      final url = await FeiNiuTranscodeService.instance.hlsUrlFor(
        _song('id-6', format: 'dsf'),
      );
      expect(url, isNull);
    });

    test('默认请求 FLAC 转码（无损优先）', () async {
      String? requestedCodec;
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) {
          if (o.path.contains('transcode')) {
            final data = o.data as Map<String, dynamic>;
            final output = data['output'] as Map<String, dynamic>;
            requestedCodec = output['codec'] as String?;
          }
          return {
            'code': 0,
            'data': {
              'audioSpec': {'format': 'dsf'},
              'url': '/music/api/v1/track/hls/id-8/preset.m3u8',
            },
          };
        }),
      );
      await FeiNiuTranscodeService.instance.hlsUrlFor(
        _song('id-8', format: 'dsf'),
      );
      expect(requestedCodec, 'flac', reason: '默认应请求无损 FLAC');
    });

    test('degradeToMp3 后请求 MP3，且 invalidate 不恢复 FLAC', () async {
      final codecs = <String>[];
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) {
          if (o.path.contains('transcode')) {
            final data = o.data as Map<String, dynamic>;
            final output = data['output'] as Map<String, dynamic>;
            codecs.add(output['codec'] as String);
          }
          return {
            'code': 0,
            'data': {
              'audioSpec': {'format': 'dsf'},
              'url': '/music/api/v1/track/hls/id-9/preset.m3u8',
            },
          };
        }),
      );
      FeiNiuApiClient.instance.setBaseUrl('https://nas.example.com');

      final svc = FeiNiuTranscodeService.instance;
      await svc.hlsUrlFor(_song('id-9', format: 'dsf'));
      expect(svc.isDegradedToMp3('id-9'), isFalse);

      svc.degradeToMp3('id-9');
      expect(svc.isDegradedToMp3('id-9'), isTrue, reason: '应标记为已降级');

      // 降级应清掉已缓存的 FLAC 地址，并重新请求 MP3
      svc.invalidate('id-9');
      await svc.hlsUrlFor(_song('id-9', format: 'dsf'));
      expect(codecs, ['flac', 'mp3'], reason: '降级后应请求 MP3');

      // 重复降级不重复重建：MP3 地址已缓存，缓存命中的是 mp3 请求的地址
      expect(svc.isDegradedToMp3('id-9'), isTrue);
      svc.degradeToMp3('id-9'); // 重复标记是 no-op
      await svc.hlsUrlFor(_song('id-9', format: 'dsf'));
      expect(codecs, ['flac', 'mp3'], reason: 'MP3 结果命中缓存，不再重复请求');
    });

    test('FLAC 单帧远离上限 → 保持 FLAC，不降级', () async {
      final codecs = <String>[];
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) {
          if (o.path.contains('transcode')) {
            final output = (o.data as Map<String, dynamic>)['output']
                as Map<String, dynamic>;
            codecs.add(output['codec'] as String);
          }
          if (o.path.endsWith('preset.m3u8')) return _m3u8;
          if (o.path.endsWith('seg0.mp4')) return _fmp4Segment([4096, 8192]);
          return {
            'code': 0,
            'data': {
              'audioSpec': {'format': 'dsf'},
              'url': '/music/api/v1/track/hls/id-10/preset.m3u8',
            },
          };
        }),
      );
      FeiNiuApiClient.instance.setBaseUrl('https://nas.example.com');

      final svc = FeiNiuTranscodeService.instance;
      final url = await svc.hlsUrlFor(_song('id-10', format: 'dsf'));
      expect(url, 'https://nas.example.com/music/api/v1/track/hls/id-10/preset.m3u8');
      expect(codecs, ['flac'], reason: '单帧远离上限应保持无损 FLAC');
      expect(svc.isDegradedToMp3('id-10'), isFalse);
    });

    test('FLAC 单帧超硬上限 → 当场降级 MP3，不缓存 FLAC', () async {
      final codecs = <String>[];
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) {
          if (o.path.contains('transcode')) {
            final output = (o.data as Map<String, dynamic>)['output']
                as Map<String, dynamic>;
            codecs.add(output['codec'] as String);
          }
          if (o.path.endsWith('preset.m3u8')) return _m3u8;
          if (o.path.endsWith('seg0.mp4')) return _fmp4Segment([94376]);
          return {
            'code': 0,
            'data': {
              'audioSpec': {'format': 'dsf'},
              'url': '/music/api/v1/track/hls/id-11/preset.m3u8',
            },
          };
        }),
      );
      FeiNiuApiClient.instance.setBaseUrl('https://nas.example.com');

      final svc = FeiNiuTranscodeService.instance;
      await svc.hlsUrlFor(_song('id-11', format: 'dsf'));
      expect(codecs, ['flac', 'mp3'], reason: '探测到超限应降级请求 MP3');
      expect(svc.isDegradedToMp3('id-11'), isTrue);
      // 降级后第二次直接请求 MP3（不再探测 FLAC）
      await svc.hlsUrlFor(_song('id-11', format: 'dsf'));
      expect(codecs, ['flac', 'mp3'], reason: '已降级直接走 MP3，命中缓存');
    });

    test('FLAC 单帧接近上限（<32KB 但 ≥阈值）→ 提前降级，防后续分片超限', () async {
      final codecs = <String>[];
      // 阈值 = 32KB * 0.80 = 26214；用 30000（硬上限内，但已接近）验证提前降级
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) {
          if (o.path.contains('transcode')) {
            final output = (o.data as Map<String, dynamic>)['output']
                as Map<String, dynamic>;
            codecs.add(output['codec'] as String);
          }
          if (o.path.endsWith('preset.m3u8')) return _m3u8;
          if (o.path.endsWith('seg0.mp4')) return _fmp4Segment([30000]);
          return {
            'code': 0,
            'data': {
              'audioSpec': {'format': 'dsf'},
              'url': '/music/api/v1/track/hls/id-13/preset.m3u8',
            },
          };
        }),
      );
      FeiNiuApiClient.instance.setBaseUrl('https://nas.example.com');

      final svc = FeiNiuTranscodeService.instance;
      await svc.hlsUrlFor(_song('id-13', format: 'dsf'));
      expect(codecs, ['flac', 'mp3'], reason: '接近上限也应提前降级');
      expect(svc.isDegradedToMp3('id-13'), isTrue);
    });

    test('探测失败（分片抓取失败）→ 保持 FLAC 交给解码兜底', () async {
      final codecs = <String>[];
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio((o) {
          if (o.path.contains('transcode')) {
            final output = (o.data as Map<String, dynamic>)['output']
                as Map<String, dynamic>;
            codecs.add(output['codec'] as String);
          }
          if (o.path.endsWith('preset.m3u8')) return _m3u8;
          if (o.path.endsWith('seg0.mp4')) return 'not-bytes'; // 探测失败
          return {
            'code': 0,
            'data': {
              'audioSpec': {'format': 'dsf'},
              'url': '/music/api/v1/track/hls/id-12/preset.m3u8',
            },
          };
        }),
      );
      FeiNiuApiClient.instance.setBaseUrl('https://nas.example.com');

      final svc = FeiNiuTranscodeService.instance;
      final url = await svc.hlsUrlFor(_song('id-12', format: 'dsf'));
      expect(url, 'https://nas.example.com/music/api/v1/track/hls/id-12/preset.m3u8');
      expect(codecs, ['flac'], reason: '探测失败不降级，保持 FLAC');
      expect(svc.isDegradedToMp3('id-12'), isFalse);
    });

    test('网络异常 → 抛 DioException（调用方回退直连）', () async {
      FeiNiuApiClient.instance.setDioForTest(
        _mockDio(
          (o) => {},
          error: (o) => DioException(requestOptions: o, type: DioExceptionType.connectionError),
        ),
      );
      expect(
        () => FeiNiuTranscodeService.instance.hlsUrlFor(
          _song('id-7', format: 'dsf'),
        ),
        throwsA(isA<DioException>()),
      );
    });

    test('resolveHlsUrl：相对路径拼接 baseUrl，绝对路径原样', () async {
      FeiNiuApiClient.instance.setBaseUrl('https://nas.example.com');
      final api = FeiNiuApiClient.instance;
      expect(
        api.resolveHlsUrl('/music/api/v1/track/hls/x/preset.m3u8'),
        'https://nas.example.com/music/api/v1/track/hls/x/preset.m3u8',
      );
      expect(
        api.resolveHlsUrl('https://cdn.example.com/a.m3u8'),
        'https://cdn.example.com/a.m3u8',
      );
    });
  });
}
