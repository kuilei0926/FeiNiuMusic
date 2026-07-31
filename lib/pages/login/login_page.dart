import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/services/feiniu/auth_service.dart';
import '../../app/services/feiniu/fn_connection_probe_service.dart';
import '../../app/state/settings_fn_state.dart';
import '../../app/router/app_router.dart';
import '../../components/feedback/probe_overlay.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _serverUrlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _obscurePassword = true;
  String? _errorMessage;

  OverlayEntry? _probeOverlay;

  static const String _prefsServerUrl = 'feiniu_server_url';
  static const String _prefsUsername = 'feiniu_username';
  static const String _prefsPassword = 'feiniu_password';

  @override
  void initState() {
    super.initState();
    // 加载上次保存的凭据
    SharedPreferences.getInstance().then((prefs) {
      final savedUrl = prefs.getString(_prefsServerUrl) ?? '';
      final savedUsername = prefs.getString(_prefsUsername) ?? '';
      final savedPassword = prefs.getString(_prefsPassword) ?? '';
      if (mounted) {
        setState(() {
          // FNID 优先：上次通过 FNID 登录过则保留 FNID，否则用保存的完整 URL
          _serverUrlController.text =
              AppFnConnectionSettings.lastFnId ?? savedUrl;
          _usernameController.text = savedUsername;
          _passwordController.text = savedPassword;
        });

        // 自动探测：如果当前输入是 FNID 且未登录，自动开始探测
        _tryAutoProbe();
      }
    });
  }

  void _tryAutoProbe() {
    final input = _serverUrlController.text.trim();
    if (input.isEmpty || !_isFnId(input)) return;
    // 等一帧让 UI 渲染完，再开始自动探测
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _autoProbeStarted) return;
      _autoProbeStarted = true;
      // 只探测，不登录（没必要让用户重新输密码）
      _silentProbe(input);
    });
  }

  bool _autoProbeStarted = false;

  /// 静默探测（只探测不登录，更新连接信息显示）
  Future<void> _silentProbe(String fnId) async {
    try {
      final preference = AppFnConnectionSettings.connectionPreference.value;
      final cache = AppFnConnectionSettings.cachedConnection;

      final result = cache != null
          ? await FnConnectionProbeService.instance.probeWithCache(
              cachedUrl: cache.url,
              cachedIsRelay: cache.isRelay,
              fnId: fnId,
              preference: preference,
            )
          : await FnConnectionProbeService.instance.probe(
              fnId: fnId,
              preference: preference,
            );

      if (!mounted) return;
      // 保存连接信息，显示在设置页
      AppFnConnectionSettings.saveProbeResult(
        fnId: fnId,
        url: result.serverUrl,
        method: result.probeMethod,
        isRelay: result.isRelay,
      );
    } catch (_) {
      // 静默探测失败不显示错误，等用户手动操作
    }
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// 判断输入是否为 FNID
  bool _isFnId(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return false;
    // 以 http/https 开头的是普通地址
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return false;
    }
    // FNID 至少 6 个字符
    if (trimmed.length < 6) return false;
    return true;
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _errorMessage = null);

    final serverUrlInput = _serverUrlController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    // 检测是否为 FNID
    if (_isFnId(serverUrlInput)) {
      await _fnLogin(serverUrlInput, username, password);
    } else {
      await _performLogin(serverUrlInput, username, password);
    }
  }

  /// FNID 登录流程：探测 → 连接 → 认证
  Future<void> _fnLogin(String fnId, String username, String password) async {
    // 展示探测浮层
    _probeOverlay = ProbeOverlay.show(context);

    try {
      final preference = AppFnConnectionSettings.connectionPreference.value;
      final cache = AppFnConnectionSettings.cachedConnection;

      final result = cache != null
          ? await FnConnectionProbeService.instance.probeWithCache(
              cachedUrl: cache.url,
              cachedIsRelay: cache.isRelay,
              fnId: fnId,
              preference: preference,
            )
          : await FnConnectionProbeService.instance.probe(
              fnId: fnId,
              preference: preference,
            );

      // 探测成功，用成功 URL 继续登录（中继模式的 relayMode 标记一并传递）
      // 同时保存连接信息供设置页显示
      AppFnConnectionSettings.saveProbeResult(
        fnId: fnId,
        url: result.serverUrl,
        method: result.probeMethod,
        isRelay: result.isRelay,
      );
      await _performLogin(
        result.serverUrl,
        username,
        password,
        relayMode: result.isRelay,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      ProbeOverlay.hide(_probeOverlay);
      _probeOverlay = null;
    }
  }

  /// 执行实际登录（共享逻辑）
  Future<void> _performLogin(
    String serverUrl,
    String username,
    String password, {
    bool relayMode = false,
  }) async {
    try {
      await AuthService.instance.login(
        serverUrl,
        username,
        password,
        relayMode: relayMode,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
      return;
    }

    if (!mounted) return;

    // 登录成功，保存凭据
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsServerUrl, serverUrl);
    await prefs.setString(_prefsUsername, username);

    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed(AppRoutes.home);
  }

  /// 当前是否可以点击登录按钮
  bool _canLogin() {
    return !AuthService.instance.isLoggingIn.value &&
        !FnConnectionProbeService.instance.isProbing.value;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Logo
                  ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: Image.asset(
                      'assets/icon/app_icon.png',
                      width: 80,
                      height: 80,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '飞牛音乐',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'FeiNiu Music',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isDark ? Colors.grey[400] : Colors.grey[600],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '支持输入服务器地址或 FNID 快速连接',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(height: 48),

                  // 服务器地址 / FNID
                  TextFormField(
                    controller: _serverUrlController,
                    decoration: InputDecoration(
                      labelText: '服务器地址或 FNID',
                      hintText: 'https://ip:port 或输入 FNID',
                      prefixIcon: const Icon(Icons.dns_outlined),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    keyboardType: TextInputType.text,
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return '请输入服务器地址或 FNID';
                      }
                      final trimmed = value.trim();
                      // 以 http/https 开头的是普通地址
                      if (trimmed.startsWith('http://') ||
                          trimmed.startsWith('https://')) {
                        return null;
                      }
                      // 否则当作 FNID，必须 >= 6 字符
                      if (trimmed.length >= 6) {
                        return null;
                      }
                      return 'FNID 至少需要 6 个字符';
                    },
                    onChanged: (_) {
                      // 输入变化时清除错误信息
                      if (_errorMessage != null) {
                        setState(() => _errorMessage = null);
                      }
                    },
                  ),
                  const SizedBox(height: 16),

                  // 用户名
                  TextFormField(
                    controller: _usernameController,
                    decoration: InputDecoration(
                      labelText: '用户名',
                      prefixIcon: const Icon(Icons.person_outline),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return '请输入用户名';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  // 密码
                  TextFormField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    decoration: InputDecoration(
                      labelText: '密码',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),
                        onPressed: () {
                          setState(() => _obscurePassword = !_obscurePassword);
                        },
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return '请输入密码';
                      }
                      return null;
                    },
                    onFieldSubmitted: (_) => _canLogin() ? _login() : null,
                  ),
                  const SizedBox(height: 8),

                  // 错误信息
                  if (_errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(
                          color: theme.colorScheme.error,
                          fontSize: 13,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),

                  const SizedBox(height: 16),

                  // 登录按钮（仅登录进行中时禁用，静默探测不影响）
                  ValueListenableBuilder<bool>(
                    valueListenable: AuthService.instance.isLoggingIn,
                    builder: (context, isLoggingIn, _) {
                      return SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: FilledButton(
                          onPressed: isLoggingIn ? null : _login,
                          style: FilledButton.styleFrom(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text(
                            '登录',
                            style: TextStyle(fontSize: 16),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
