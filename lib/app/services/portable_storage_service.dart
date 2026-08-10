import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 便携模式：应用数据（prefs / 数据库 / 缓存）跟随可执行文件所在的文件夹。
///
/// 绿色版分发时用户直接把整个文件夹拷到别的电脑运行，若数据仍留在系统
/// `%APPDATA%` 反而会"拆散"；这里把数据根目录重定向到 exe 旁的
/// `feiniumusic_data/`，让账号/收藏/播放记录跟着文件夹走。
///
/// 安全：数据里保存着 NAS 密码、token 等敏感凭据。复制到其他电脑使用前，
/// 由 [AppPortableStorage.checkMachineOwner] 用 Windows `MachineGuid`
/// 校验当前机器与数据产生时是否同一台；不同则视为"换机使用"，
/// 自动清空密码/token/安全码/登录态（保留服务器地址与用户名供重新输入密码），
/// 避免把本机 NAS 凭据带到另一台电脑。
class AppPortableStorage {
  AppPortableStorage._();

  /// prefs 中记录"数据归属机器指纹"的键。
  static const String _prefsMachineOwner = 'fn_portable_machine_owner';

  /// Windows 机器唯一标识：注册表 `HKLM\SOFTWARE\Microsoft\Cryptography`
  /// 下的 `MachineGuid`，每台 Windows 唯一、重装系统才变。桌面端用它做
  /// 换机检测的指纹。
  static const String _machineGuidRegPath =
      r'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography';

  static String? _overrideRoot;

  /// 便携数据根目录（Windows）：exe 同级的 `feiniumusic_data/`。
  /// 其他平台返回 null（沿用系统目录）。
  static String? portableRoot() {
    if (_overrideRoot != null) return _overrideRoot;
    if (Platform.isWindows) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      _overrideRoot = '$exeDir${Platform.pathSeparator}feiniumusic_data';
      return _overrideRoot;
    }
    return null;
  }

  /// 让所有 path_provider 数据路径指向便携根目录。
  ///
  /// 全局替换 [PathProviderPlatform.instance]，使 SharedPreferences、数据库、
  /// 歌词/封面/音频缓存全部落到 exe 旁的 `feiniumusic_data/`。
  /// 仅在 Windows 桌面端生效；其余平台保持系统默认路径。
  static void overridePathProviderForPortable() {
    if (!Platform.isWindows) return;
    final root = portableRoot();
    if (root == null) return;
    PathProviderPlatform.instance = PortablePathProvider(root);
  }

  /// 换机检测：读取数据归属机器指纹，与当前机器比对。
  ///
  /// - 无指纹记录（本机首次运行）→ 记录当前指纹，视为"本机"。
  /// - 指纹与当前机器一致 → 本机，无需处理。
  /// - 指纹不同（文件夹从别的电脑拷来）→ 换机，清空凭据，并把指纹更新为
  ///   当前机器（后续在本机运行不再反复提示）。
  ///
  /// 只在桌面端（Windows）执行；其余平台无便携数据，跳过。
  static Future<void> checkMachineOwner() async {
    if (!Platform.isWindows) return;
    final current = _readMachineGuid();
    if (current == null) return; // 读不到指纹时不做换机判断（宁缺毋滥）

    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefsMachineOwner);
    if (stored == current) return; // 同一台机器，正常

    if (stored == null) {
      // 首次运行：登记归属
      await prefs.setString(_prefsMachineOwner, current);
      return;
    }
    // 换机：清空敏感凭据，保留服务器地址/用户名供重新输入密码
    await _wipeCredentials(prefs);
    await prefs.setString(_prefsMachineOwner, current);
  }

  /// 读取 Windows `MachineGuid`（每台机器唯一）。失败返回 null。
  static String? _readMachineGuid() {
    try {
      final lines = Process.runSync('reg', [
        'query',
        _machineGuidRegPath,
        '/v',
        'MachineGuid',
      ]).stdout.toString();
      final m = RegExp(r'\{?([0-9A-Fa-f-]{36})\}?').firstMatch(lines);
      return m?.group(1);
    } catch (_) {
      return null;
    }
  }

  /// 清空所有 NAS 凭据与登录态，但保留服务器地址、用户名、FNID 等非敏感项，
  /// 让用户在换机后只需重新输入密码即可登录。
  ///
  /// [prefs] 可注入便于测试；公开仅供测试换机清理逻辑。
  @visibleForTesting
  static Future<void> wipeCredentialsForTest(SharedPreferences prefs) =>
      _wipeCredentials(prefs);

  static Future<void> _wipeCredentials(SharedPreferences prefs) async {
    const secretKeys = [
      'feiniu_music_token', // 当前激活 token
      'feiniu_password', // 保存的密码
      'fn_access_code', // 安全码（与服务器绑定，换机不应携带）
      'feiniu_accounts_v1', // 账号列表（含各账号密码/token）
      'feiniu_current_account_id', // 当前账号（连同列表一并清掉）
    ];
    for (final k in secretKeys) {
      await prefs.remove(k);
    }
    // 登出：清 token 但保留 server_url / username（clearAuth 约定）
    final serverUrl = prefs.getString('feiniu_server_url') ?? '';
    final username = prefs.getString('feiniu_username') ?? '';
    if (serverUrl.isNotEmpty) {
      await prefs.setString('feiniu_server_url', serverUrl);
    }
    if (username.isNotEmpty) {
      await prefs.setString('feiniu_username', username);
    }
  }
}

/// 便携 PathProvider 实现：把 Windows 数据路径覆盖到 exe 旁 `feiniumusic_data/`。
///
/// 各数据子目录分离，避免"清临时缓存"误删 prefs/数据库：
/// - `data/`  ← getApplicationSupportPath（prefs、歌词、插件等）
/// - `documents/` ← getApplicationDocumentsDirectory（feiniu_music.db）
/// - `cache/` ← getApplicationCachePath
/// - `temp/` ← getTemporaryDirectory（封面/音频缓存）
class PortablePathProvider extends PathProviderPlatform {
  PortablePathProvider(this._root);

  final String _root;

  static String? _documentsDir;
  static String? _cacheDir;
  static String? _tempDir;

  /// 在 [_root] 下创建子目录（不存在则创建），返回其路径。
  static Future<String?> _subdir(String root, String name) async {
    final dir = Directory('$root${Platform.pathSeparator}$name');
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
    } catch (_) {}
    return dir.path;
  }

  @override
  Future<String?> getApplicationSupportPath() => _subdir(_root, 'data');

  @override
  Future<String?> getApplicationDocumentsPath() async {
    if (_documentsDir != null) return _documentsDir;
    final d = await _subdir(_root, 'documents');
    _documentsDir = d;
    return d;
  }

  @override
  Future<String?> getApplicationCachePath() async {
    if (_cacheDir != null) return _cacheDir;
    final d = await _subdir(_root, 'cache');
    _cacheDir = d;
    return d;
  }

  @override
  Future<String?> getTemporaryPath() async {
    if (_tempDir != null) return _tempDir;
    final d = await _subdir(_root, 'temp');
    _tempDir = d;
    return d;
  }

  @override
  Future<String?> getDownloadsPath() => _subdir(_root, 'downloads');

  @override
  Future<String?> getLibraryPath() => getApplicationSupportPath();
}
