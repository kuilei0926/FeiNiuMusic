import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/audio/cache_source.dart';

void main() {
  test(
    'range response is not truncated when the request hands off its stream',
    () async {
      const total = 4 * 1024 * 1024;
      const rangeStart = 3 * 1024 * 1024;
      final body = List<int>.generate(total, (i) => i & 0xff);

      final rangeHeaders = <String>[];
      final finishInitialDownload = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        try {
          final range = request.headers.value(HttpHeaders.rangeHeader);
          if (range == null) {
            // Slow initial download: expose only one small chunk so the pending
            // request has to take the upstream Range path, then finish normally
            // so the background download does not fail during teardown.
            request.response.headers.contentType = ContentType('audio', 'flac');
            request.response.contentLength = total;
            request.response.add(body.sublist(0, 64 * 1024));
            await request.response.flush();
            await finishInitialDownload.future;
            for (var offset = 64 * 1024; offset < total; offset += 256 * 1024) {
              final chunkEnd = offset + 256 * 1024 < total
                  ? offset + 256 * 1024
                  : total;
              request.response.add(body.sublist(offset, chunkEnd));
            }
            await request.response.close();
            return;
          }
          rangeHeaders.add(range);
          final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
          final start = int.parse(match.group(1)!);
          final end = match.group(2)!.isEmpty
              ? total
              : int.parse(match.group(2)!) + 1;
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.contentType = ContentType('audio', 'flac');
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-${end - 1}/$total',
          );
          request.response.contentLength = end - start;
          for (var offset = start; offset < end; offset += 64 * 1024) {
            final chunkEnd = offset + 64 * 1024 < end
                ? offset + 64 * 1024
                : end;
            request.response.add(body.sublist(offset, chunkEnd));
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          await request.response.close();
        } catch (_) {
          // The test tears the server down while the initial download is open.
        }
      });

      final temp = await Directory.systemTemp.createTemp('cache_source_range');
      addTearDown(() async {
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      final source = StreamAudioCacheSource(
        songId: 'song',
        uri: Uri.parse('http://127.0.0.1:${server.port}/audio'),
        headers: const {},
        cacheFile: File('${temp.path}/song.flac'),
      );
      unawaited(source.downloadDone.then((_) {}, onError: (_) {}));
      addTearDown(() async {
        if (!finishInitialDownload.isCompleted) {
          finishInitialDownload.complete();
        }
        await source.downloadDone.timeout(const Duration(seconds: 3));
      });

      final response = await source.request(rangeStart, null);
      final received = await response.stream.fold<List<int>>(
        <int>[],
        (bytes, data) => bytes..addAll(data),
      );

      expect(rangeHeaders, ['bytes=$rangeStart-${total - 1}']);
      expect(received, orderedEquals(body.sublist(rangeStart)));
    },
  );
}
