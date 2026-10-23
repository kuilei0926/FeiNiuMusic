import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/cast/dlna_action_failure.dart';

void main() {
  test(
    'structured native fault retains actionable codes without raw message',
    () {
      final failure = DlnaActionFailure.from(
        PlatformException(
          code: 'dlna_action_failed',
          message: 'http://server/stream?token=secret',
          details: {
            'action': 'SetAVTransportURI',
            'category': 'upnp_fault',
            'upnpCode': 714,
            'httpStatus': 500,
            'elapsedMs': 123,
            'causeTypes': ['ActionException'],
          },
        ),
      )!;
      expect(failure.isFormatError, isTrue);
      expect(failure.diagnostic, contains('upnp=714 http=500 elapsedMs=123'));
      expect(failure.userMessage, contains('SetAVTransportURI'));
      expect(failure.userMessage, contains('设备拒绝当前音频格式'));
      expect(failure.diagnostic, isNot(contains('secret')));
    },
  );

  for (final category in [
    'timeout',
    'network',
    'invalid_response',
    'http_error',
    'action_failed',
  ]) {
    test('$category is never a format rejection', () {
      final failure = DlnaActionFailure.from(
        PlatformException(
          code: 'dlna_action_failed',
          details: {'action': 'Play', 'category': category, 'upnpCode': 714},
        ),
      )!;
      expect(failure.isFormatError, isFalse);
      expect(failure.userMessage, isNot(contains('XML')));
      expect(failure.userMessage, isNot(contains('SOAP')));
    });
  }

  test(
    'untrusted or malformed detail fields cannot inject credentials into logs',
    () {
      final failure = DlnaActionFailure.from(
        PlatformException(
          code: 'dlna_action_failed',
          details: {
            'action': 'http://speaker/?token=secret',
            'category': 'error\nCookie: secret',
            'elapsedMs': -1,
            'upnpCode': '714',
            'causeTypes': ['Cookie: secret'],
          },
        ),
      )!;
      expect(failure.action, 'UnknownAction');
      expect(failure.elapsedMs, isNull);
      expect(failure.upnpCode, isNull);
      expect(failure.isFormatError, isFalse);
      expect(failure.diagnostic, isNot(contains('secret')));
    },
  );

  test('legacy and absent details remain unsupported by structured parser', () {
    expect(DlnaActionFailure.from(StateError('failed')), isNull);
    expect(DlnaActionFailure.from(PlatformException(code: '714')), isNull);
    expect(
      DlnaActionFailure.from(
        PlatformException(code: 'dlna_action_failed', details: 'invalid'),
      ),
      isNull,
    );
  });
}
