import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_close_to_tray_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CloseToTraySettings.resetForTest();
  });

  test('默认开启关闭隐藏到托盘', () async {
    await CloseToTraySettings.ensureLoaded();
    expect(CloseToTraySettings.enabled.value, isTrue);
  });

  test('setEnabled 持久化并更新状态', () async {
    await CloseToTraySettings.ensureLoaded();
    await CloseToTraySettings.setEnabled(false);
    expect(CloseToTraySettings.enabled.value, isFalse);

    // 重新加载（模拟重启）应读到持久化的关闭值
    CloseToTraySettings.resetForTest();
    await CloseToTraySettings.ensureLoaded();
    expect(CloseToTraySettings.enabled.value, isFalse);

    await CloseToTraySettings.setEnabled(true);
    expect(CloseToTraySettings.enabled.value, isTrue);
  });
}
