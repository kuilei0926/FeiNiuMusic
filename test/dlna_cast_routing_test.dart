import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_cast_dlna/media_cast_dlna.dart';

import 'package:feiniu_music/app/services/cast/dlna_cast_service.dart';
import 'package:feiniu_music/app/services/cast/media_stream_proxy.dart';
import 'package:feiniu_music/app/services/feiniu/api_client.dart';
import 'package:feiniu_music/app/services/feiniu/transcode_service.dart';
import 'package:feiniu_music/app/state/settings_cast_state.dart';
import 'package:feiniu_music/app/state/song_state.dart';

class _Renderer extends MediaCastDlnaApi {
  final urls = <String>[];
  Future<void> Function(String)? onSetMedia;
  Future<void> Function()? onPlay;
  Future<void> Function()? onInitialize;
  TransportState transport = TransportState.playing;
  Object? pollError;

  @override
  Future<void> initializeUpnpService() async => await onInitialize?.call();

  @override
  Future<void> stop(DeviceUdn deviceUdn) async {}

  @override
  Future<void> pause(DeviceUdn deviceUdn) async {}

  @override
  Future<void> play(DeviceUdn deviceUdn) async => await onPlay?.call();

  @override
  Future<void> setMediaUri(
    DeviceUdn deviceUdn,
    Url uri,
    MediaMetadata metadata,
  ) async {
    urls.add(uri.value);
    await onSetMedia?.call(uri.value);
  }

  @override
  Future<PlaybackInfo> getPlaybackInfo(DeviceUdn deviceUdn) async {
    if (pollError != null) throw pollError!;
    return PlaybackInfo(
      state: transport,
      position: TimePosition(seconds: 0),
      duration: TimeDuration(seconds: 200),
    );
  }
}

SongEntity _song(String id, {String format = 'flac'}) => SongEntity(
  id: id,
  title: id,
  artist: '[]',
  album: '{}',
  format: format,
  fileSize: 1000000000,
  bitrate: 9000000,
  durationMs: 200000,
);

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late _Renderer api;
  late DlnaCastService service;
  late DlnaDevice device;
  late HttpServer upstream;
  late HttpClient client;
  late List<RequestOptions> requests;
  late Future<Map<String, dynamic>> Function() transcodeResponse;
  late Future<void> Function(HttpRequest) serve;

  Future<int> fetch(String url, {String method = 'GET'}) async {
    final request = await client.openUrl(method, Uri.parse(url));
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  }

  setUp(() async {
    FeiNiuTranscodeService.instance.resetForTest();
    DlnaCastSettings.resetForTest();
    DlnaCastSettings.enabled.value = true;
    requests = [];
    transcodeResponse = () async => {
      'code': 0,
      'data': {'url': '/fallback.m3u8'},
    };
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          requests.add(options);
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: await transcodeResponse(),
            ),
          );
        },
      ),
    );
    FeiNiuApiClient.instance.setDioForTest(dio);
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    serve = (request) async {
      request.response.headers.contentType = ContentType('audio', 'flac');
      request.response.write('audio bytes');
      await request.response.close();
    };
    upstream.listen((request) => unawaited(serve(request)));
    await FeiNiuApiClient.instance.setBaseUrl(
      'http://127.0.0.1:${upstream.port}',
    );
    client = HttpClient();
    api = _Renderer();
    service = DlnaCastService.forTest(
      api: api,
      positionPollInterval: const Duration(milliseconds: 30),
      playbackStartGrace: const Duration(milliseconds: 240),
    );
    device = DlnaDevice(
      udn: DeviceUdn(value: 'renderer'),
      friendlyName: 'Generic renderer',
      deviceType: 'MediaRenderer',
      manufacturerDetails: ManufacturerDetails(manufacturer: 'Test'),
      modelDetails: ModelDetails(modelName: 'Test'),
      ipAddress: IpAddress(value: '127.0.0.1'),
      port: NetworkPort(value: upstream.port),
    );
    service.currentDevice.value = device;
    await MediaStreamProxy.instance.start(advertisedHost: '127.0.0.1');
  });

  tearDown(() async {
    await service.disconnect(silent: true);
    client.close(force: true);
    await upstream.close(force: true);
    DlnaCastSettings.resetForTest();
  });

  test('all formats and large files start with original stream', () async {
    for (final format in ['mp3', 'flac', 'dsf', 'ape', 'alac']) {
      await service.loadSong(_song(format, format: format));
      expect(api.urls.last, endsWith(format == 'alac' ? '.m4a' : '.$format'));
    }
    expect(requests, isEmpty);
  });

  test('initial connection also starts with original audio', () async {
    service.currentDevice.value = null;
    expect(await service.castTo(device, _song('initial')), isTrue);
    expect(api.urls.single, endsWith('.flac'));
    expect(requests, isEmpty);
  });

  test('format rejection retries once with server MP3 HLS', () async {
    api.onSetMedia = (url) async {
      if (!url.endsWith('.m3u8')) {
        throw PlatformException(code: '714', message: 'Illegal MIME-type');
      }
    };
    await service.loadSong(_song('unsupported'));
    expect(api.urls, [endsWith('.flac'), endsWith('.m3u8')]);
    expect(requests.single.path, endsWith('/track/transcode'));
    expect(requests.single.data['output'], {'codec': 'mp3', 'channel': 2});
    expect(service.isCasting, isTrue);
  });

  test('failed HLS fallback does not loop', () async {
    api.onSetMedia = (_) async => throw PlatformException(code: '714');
    await service.loadSong(_song('unsupported'));
    await _until(() => !service.isCasting);
    expect(requests, hasLength(1));
    expect(api.urls, hasLength(2));
  });

  test('structured UPnP format fault triggers one fallback', () async {
    api.onSetMedia = (url) async {
      if (url.endsWith('.flac')) {
        throw PlatformException(
          code: 'dlna_action_failed',
          details: {
            'action': 'SetAVTransportURI',
            'category': 'upnp_fault',
            'upnpCode': 714,
            'httpStatus': 500,
            'elapsedMs': 50,
          },
        );
      }
    };
    await service.loadSong(_song('structured-format'));
    expect(api.urls, [endsWith('.flac'), endsWith('.m3u8')]);
    expect(requests, hasLength(1));
  });

  for (final category in [
    'invalid_response',
    'timeout',
    'network',
    'http_error',
  ]) {
    test('structured $category is actionable and does not transcode', () async {
      service.currentDevice.value = null;
      api.onSetMedia = (_) async => throw PlatformException(
        code: 'dlna_action_failed',
        details: {
          'action': 'SetAVTransportURI',
          'category': category,
          'httpStatus': 503,
        },
      );
      expect(await service.castTo(device, _song(category)), isFalse);
      expect(requests, isEmpty);
      expect(service.lastCastError, contains('SetAVTransportURI'));
      expect(service.lastCastError, contains('HTTP 503'));
    });
  }

  test(
    'structured polling errors disconnect without startup fallback',
    () async {
      api.pollError = PlatformException(
        code: 'dlna_action_failed',
        details: {
          'action': 'GetTransportInfo',
          'category': 'invalid_response',
          'causeTypes': ['SAXParseException'],
        },
      );
      await service.loadSong(_song('poll-error'));
      await fetch(api.urls.single);
      await _until(() => !service.isCasting);
      expect(requests, isEmpty);
      expect(api.urls, hasLength(1));
    },
  );

  test('initial play format rejection uses the same fallback policy', () async {
    service.currentDevice.value = null;
    api.onPlay = () async {
      if (!api.urls.last.endsWith('.m3u8')) {
        throw PlatformException(
          code: 'RuntimeException',
          message: 'UPnP action failed: Illegal MIME-type',
        );
      }
    };
    expect(await service.castTo(device, _song('initial')), isTrue);
    expect(api.urls, [endsWith('.flac'), endsWith('.m3u8')]);
    expect(requests, hasLength(1));
  });

  test('unavailable fallback does not retry original stream', () async {
    transcodeResponse = () async => {'code': 0, 'data': <String, dynamic>{}};
    api.onSetMedia = (_) async => throw PlatformException(code: '714');
    await service.loadSong(_song('unsupported'));
    await _until(() => !service.isCasting);
    expect(requests, hasLength(1));
    expect(api.urls, hasLength(1));
  });

  test('network and generic command errors do not transcode', () async {
    api.onSetMedia = (_) async =>
        throw TimeoutException('renderer unreachable');
    await service.loadSong(_song('network'));
    await _until(() => !service.isCasting);
    expect(requests, isEmpty);
  });

  test(
    'delivered audio followed by startup failure falls back only once',
    () async {
      api.transport = TransportState.stopped;
      await service.loadSong(_song('silent'));
      expect(await fetch(api.urls.single), 200);
      await _until(() => api.urls.length == 2);
      expect(api.urls.last, endsWith('.m3u8'));
      await _until(() => !service.isCasting);
      expect(requests, hasLength(1));
    },
  );

  for (final scenario in [
    'no request',
    'HTTP failure',
    'paused',
    'buffering',
    'played',
  ]) {
    test('$scenario does not trigger startup transcode', () async {
      api.transport = TransportState.stopped;
      if (scenario == 'HTTP failure') {
        serve = (request) async {
          request.response.statusCode = 503;
          await request.response.close();
        };
      }
      await service.loadSong(_song(scenario));
      if (scenario != 'no request') await fetch(api.urls.single);
      if (scenario == 'paused') await service.pause();
      if (scenario == 'buffering') api.transport = TransportState.transitioning;
      if (scenario == 'played') {
        api.transport = TransportState.playing;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        api.transport = TransportState.stopped;
      }
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(requests, isEmpty);
      expect(api.urls, hasLength(1));
      if (scenario == 'buffering') expect(service.isCasting, isTrue);
    });
  }

  test('pending transcode cannot replace a newer track', () async {
    final result = Completer<Map<String, dynamic>>();
    transcodeResponse = () => result.future;
    api.onSetMedia = (url) async {
      if (api.urls.length == 1) throw PlatformException(code: '714');
    };
    final first = service.loadSong(_song('first'));
    await _until(() => requests.isNotEmpty);
    final next = service.loadSong(_song('next', format: 'mp3'));
    result.complete({
      'code': 0,
      'data': {'url': '/old.m3u8'},
    });
    await Future.wait([first, next]);
    expect(api.urls, [endsWith('.flac'), endsWith('.mp3')]);
    expect(service.isCasting, isTrue);
  });

  test('disconnect cancels a pending fallback without sending HLS', () async {
    final result = Completer<Map<String, dynamic>>();
    transcodeResponse = () => result.future;
    api.onSetMedia = (_) async => throw PlatformException(code: '714');
    final loading = service.loadSong(_song('cancelled'));
    await _until(() => requests.isNotEmpty);
    final disconnecting = service.disconnect(silent: true);
    result.complete({
      'code': 0,
      'data': {'url': '/cancelled.m3u8'},
    });
    await Future.wait([loading, disconnecting]);
    expect(api.urls, hasLength(1));
    expect(MediaStreamProxy.instance.hasMedia, isFalse);
  });

  test(
    'slow upstream without delivered audio does not trigger transcode',
    () async {
      final arrived = Completer<void>();
      final release = Completer<void>();
      serve = (request) async {
        arrived.complete();
        await release.future;
        await request.response.close();
      };
      api.transport = TransportState.transitioning;
      await service.loadSong(_song('slow'));
      final pending = fetch(api.urls.single);
      await arrived.future;
      try {
        await Future<void>.delayed(const Duration(milliseconds: 650));
        expect(requests, isEmpty);
        expect(service.isCasting, isTrue);
      } finally {
        release.complete();
        await pending;
      }
    },
  );

  test('disconnect during initialization cancels initial cast', () async {
    service.currentDevice.value = null;
    final initialized = Completer<void>();
    api.onInitialize = () => initialized.future;
    final pending = service.castTo(device, _song('cancelled'));
    await service.disconnect(silent: true);
    initialized.complete();
    expect(await pending, isFalse);
    expect(api.urls, isEmpty);
    expect(MediaStreamProxy.instance.hasMedia, isFalse);
  });

  test(
    'proxy distinguishes HEAD, successful body and upstream errors',
    () async {
      final proxy = MediaStreamProxy.instance;
      final url = (await proxy.registerMedia(
        'http://127.0.0.1:${upstream.port}/audio',
      ))!;
      await fetch(url, method: 'HEAD');
      expect(proxy.hasMediaData, isFalse);
      expect(proxy.hasMediaFailure, isFalse);
      await fetch(url);
      expect(proxy.hasMediaData, isTrue);
      serve = (request) async {
        request.response.statusCode = 401;
        await request.response.close();
      };
      await fetch(url);
      expect(proxy.hasMediaFailure, isTrue);
      await proxy.registerMedia('http://127.0.0.1:${upstream.port}/next');
      expect(proxy.hasMediaData, isFalse);
      expect(proxy.hasMediaFailure, isFalse);
    },
  );

  test('HLS upstream errors retain HTTP status and error body', () async {
    serve = (request) async {
      request.response.statusCode = 401;
      request.response.headers.contentType = ContentType(
        'application',
        'vnd.apple.mpegurl',
      );
      request.response.write('authentication expired');
      await request.response.close();
    };
    final url = (await MediaStreamProxy.instance.registerMedia(
      'http://127.0.0.1:${upstream.port}/playlist.m3u8',
      fileExtension: 'm3u8',
    ))!;
    final response = await (await client.getUrl(Uri.parse(url))).close();
    expect(response.statusCode, 401);
    expect(
      await response.transform(const SystemEncoding().decoder).join(),
      'authentication expired',
    );
    expect(MediaStreamProxy.instance.hasMediaFailure, isTrue);
  });

  test(
    'late body or error from old resource cannot affect new diagnostics',
    () async {
      for (final status in [200, 503]) {
        final arrived = Completer<void>();
        final release = Completer<void>();
        serve = (request) async {
          arrived.complete();
          await release.future;
          request.response.statusCode = status;
          request.response.write('old body');
          await request.response.close();
        };
        final proxy = MediaStreamProxy.instance;
        final url = (await proxy.registerMedia(
          'http://127.0.0.1:${upstream.port}/old',
        ))!;
        final pending = fetch(url);
        await arrived.future;
        await proxy.registerMedia('http://127.0.0.1:${upstream.port}/new');
        release.complete();
        await pending;
        expect(proxy.hasMediaData, isFalse);
        expect(proxy.hasMediaFailure, isFalse);
      }
    },
  );
}
