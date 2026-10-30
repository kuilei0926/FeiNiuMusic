import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/backup/backup_service.dart';
import 'package:feiniu_music/app/state/settings_bottom_island_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/shared_preferences');
  const key = 'setting_bottom_island_style_v1';
  const platformKey = 'flutter.$key';
  late Map<String, Object> disk;
  late List<Object?> writes;
  bool failReads = false;
  bool rejectWrites = false;
  bool throwWrites = false;
  Completer<void>? writeGate;

  setUp(() {
    disk = {};
    writes = [];
    failReads = false;
    rejectWrites = false;
    throwWrites = false;
    writeGate = null;
    SharedPreferences.resetStatic();
    BottomIslandSettings.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getAll') {
            if (failReads) throw PlatformException(code: 'read_failed');
            return Map<String, Object>.from(disk);
          }
          final args = (call.arguments as Map).cast<String, Object>();
          if (call.method.startsWith('set')) {
            writes.add(args['value']);
            await writeGate?.future;
            if (throwWrites) throw PlatformException(code: 'write_failed');
            if (rejectWrites) return false;
            disk[args['key']! as String] = args['value']!;
            return true;
          }
          throw StateError('Unexpected preferences call: ${call.method}');
        });
  });

  tearDown(() {
    BottomIslandSettings.resetForTest();
    SharedPreferences.resetStatic();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> restart() async {
    BottomIslandSettings.resetForTest();
    SharedPreferences.resetStatic();
    await BottomIslandSettings.ensureLoaded();
  }

  test('empty installation persists C1 before other startup writes', () async {
    final first = BottomIslandSettings.ensureLoaded();
    final second = BottomIslandSettings.ensureLoaded();
    expect(identical(first, second), isTrue);
    await Future.wait([first, second]);
    expect(BottomIslandSettings.style.value, BottomIslandStyle.c1);
    expect(disk[platformKey], 'c1');
    expect(writes, ['c1']);
    disk['flutter.app_onboarding_completed'] = true;
    await restart();
    expect(BottomIslandSettings.style.value, BottomIslandStyle.c1);
    expect(writes, ['c1']);
  });

  for (final oldPrefs in [
    {'flutter.app_onboarding_completed': true},
    {'flutter.app_onboarding_completed': false},
    {'flutter.setting_navigation_style': 'bottomBar'},
    {'flutter.feiniu_current_account_id': 'existing-account'},
  ]) {
    test(
      'existing preferences retain legacy: ${oldPrefs.keys.single}',
      () async {
        disk.addAll(oldPrefs);
        await BottomIslandSettings.ensureLoaded();
        expect(BottomIslandSettings.style.value, BottomIslandStyle.legacy);
        expect(disk[platformKey], 'legacy');
        expect(
          disk,
          containsPair(oldPrefs.keys.single, oldPrefs.values.single),
        );
      },
    );
  }

  for (final style in BottomIslandStyle.values) {
    test('saved ${style.name} takes precedence over migration', () async {
      disk[platformKey] = style.name;
      await BottomIslandSettings.ensureLoaded();
      expect(BottomIslandSettings.style.value, style);
      expect(writes, isEmpty);
    });
  }

  for (final invalid in <Object>['future-style', '', 2, true]) {
    test(
      'invalid stored value $invalid falls back without overwriting',
      () async {
        disk[platformKey] = invalid;
        await BottomIslandSettings.ensureLoaded();
        expect(BottomIslandSettings.style.value, BottomIslandStyle.legacy);
        expect(disk[platformKey], invalid);
        expect(writes, isEmpty);
      },
    );
  }

  test(
    'selection initializes settings even when startup has not loaded',
    () async {
      await BottomIslandSettings.setStyle(BottomIslandStyle.c2);
      expect(disk[platformKey], 'c2');
      expect(BottomIslandSettings.style.value, BottomIslandStyle.c2);
      await restart();
      expect(BottomIslandSettings.style.value, BottomIslandStyle.c2);
    },
  );

  test(
    'rapid selections serialize writes and publish only saved state',
    () async {
      disk[platformKey] = 'c1';
      await BottomIslandSettings.ensureLoaded();
      writeGate = Completer<void>();
      final first = BottomIslandSettings.setStyle(BottomIslandStyle.c2);
      final second = BottomIslandSettings.setStyle(BottomIslandStyle.c3);
      await Future<void>.delayed(Duration.zero);
      expect(writes, ['c2']);
      expect(BottomIslandSettings.style.value, BottomIslandStyle.c1);
      writeGate!.complete();
      await Future.wait([first, second]);
      expect(writes, ['c2', 'c3']);
      expect(disk[platformKey], 'c3');
      expect(BottomIslandSettings.style.value, BottomIslandStyle.c3);
      await restart();
      expect(BottomIslandSettings.style.value, BottomIslandStyle.c3);
    },
  );

  for (final throws in [false, true]) {
    test(
      'failed write (throws=$throws) rolls cache back and allows retry',
      () async {
        disk[platformKey] = 'c1';
        await BottomIslandSettings.ensureLoaded();
        rejectWrites = !throws;
        throwWrites = throws;
        await expectLater(
          BottomIslandSettings.setStyle(BottomIslandStyle.c2),
          throws ? throwsA(isA<PlatformException>()) : throwsStateError,
        );
        expect(BottomIslandSettings.style.value, BottomIslandStyle.c1);
        expect(disk[platformKey], 'c1');
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(key), 'c1');
        rejectWrites = false;
        throwWrites = false;
        await BottomIslandSettings.setStyle(BottomIslandStyle.c3);
        expect(disk[platformKey], 'c3');
        expect(BottomIslandSettings.style.value, BottomIslandStyle.c3);
      },
    );
  }

  test('failed initial migration is safe and retryable', () async {
    rejectWrites = true;
    await BottomIslandSettings.ensureLoaded();
    expect(BottomIslandSettings.style.value, BottomIslandStyle.legacy);
    expect(disk, isEmpty);
    expect((await SharedPreferences.getInstance()).containsKey(key), isFalse);
    rejectWrites = false;
    await BottomIslandSettings.ensureLoaded();
    expect(disk[platformKey], 'c1');
  });

  test('read failure does not overwrite an existing selection', () async {
    disk[platformKey] = 'c2';
    failReads = true;
    await BottomIslandSettings.ensureLoaded();
    expect(BottomIslandSettings.style.value, BottomIslandStyle.legacy);
    expect(writes, isEmpty);
    await expectLater(
      BottomIslandSettings.setStyle(BottomIslandStyle.c3),
      throwsStateError,
    );
    expect(disk[platformKey], 'c2');
    failReads = false;
    await BottomIslandSettings.ensureLoaded();
    expect(BottomIslandSettings.style.value, BottomIslandStyle.c2);
  });

  test(
    'generic settings backup restores island style on next startup',
    () async {
      await BottomIslandSettings.setStyle(BottomIslandStyle.c3);
      final backup = await BackupService.instance.buildBackupJson(
        const BackupSections(accounts: false, stats: false, settings: true),
      );
      final data = jsonDecode(backup) as Map<String, dynamic>;
      expect(data['settings'][key], {'t': 's', 'v': 'c3'});
      disk.clear();
      SharedPreferences.resetStatic();
      await BackupService.instance.restoreFromJson(backup);
      await restart();
      expect(BottomIslandSettings.style.value, BottomIslandStyle.c3);
      expect(disk[platformKey], 'c3');
    },
  );
}
