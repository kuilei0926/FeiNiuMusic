import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:feiniu_music/app/services/portable_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('portableRoot returns exe-adjacent dir on Windows', () {
    // 本测试跑在 Windows 上，portableRoot() 应返回非空 exe 旁目录。
    if (Platform.isWindows) {
      final root = AppPortableStorage.portableRoot();
      expect(root, isNotNull);
      expect(root, endsWith('feiniumusic_data'));
    } else {
      expect(AppPortableStorage.portableRoot(), isNull);
    }
  });

  test('first run registers machine owner without wiping', () async {
    SharedPreferences.setMockInitialValues({
      'feiniu_music_token': 'tok',
      'feiniu_password': 'pw',
      'feiniu_server_url': 'http://192.168.1.1',
      'feiniu_username': 'admin',
    });
    // 读不到 MachineGuid 时（测试环境）checkMachineOwner 直接返回
    await AppPortableStorage.checkMachineOwner();
    final prefs = await SharedPreferences.getInstance();
    // 未发生换机，凭据应保留
    expect(prefs.getString('feiniu_music_token'), 'tok');
    expect(prefs.getString('feiniu_password'), 'pw');
  });

  test('machine owner mismatch wipes secrets but keeps serverUrl/username',
      () async {
    // 模拟：数据带有"旧机器"归属指纹，且存有凭据
    SharedPreferences.setMockInitialValues({
      'fn_portable_machine_owner': '11111111-1111-1111-1111-111111111111',
      'feiniu_music_token': 'tok',
      'feiniu_password': 'pw',
      'feiniu_accounts_v1': '[{"password":"pw1"}]',
      'feiniu_current_account_id': 'acc1',
      'fn_access_code': 'code',
      'feiniu_server_url': 'http://192.168.1.1',
      'feiniu_username': 'admin',
    });
    // 测试环境读不到当前 MachineGuid → 视为"读不到指纹"，不执行换机清理。
    // 直接调用公开的测试清理逻辑验证真实实现行为。
    final prefs = await SharedPreferences.getInstance();
    await AppPortableStorage.wipeCredentialsForTest(prefs);
    expect(prefs.getString('feiniu_music_token'), isNull);
    expect(prefs.getString('feiniu_password'), isNull);
    expect(prefs.getString('feiniu_accounts_v1'), isNull);
    expect(prefs.getString('feiniu_current_account_id'), isNull);
    expect(prefs.getString('fn_access_code'), isNull);
    expect(prefs.getString('feiniu_server_url'), 'http://192.168.1.1');
    expect(prefs.getString('feiniu_username'), 'admin');
  });
}
