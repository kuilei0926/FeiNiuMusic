import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/services/feiniu/access_code_service.dart';
import '../../app/services/feiniu/account_entry.dart';
import '../../app/services/feiniu/account_store.dart';
import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/auth_service.dart';
import '../../app/services/feiniu/fn_connection_probe_service.dart';
import '../../app/services/feiniu/fn_models.dart';
import '../../app/services/login_pair_server.dart';
import '../../app/state/settings_state.dart';
import '../../app/router/app_router.dart';
import '../../components/feedback/probe_overlay.dart';
import '../../components/dialog/access_code_dialog.dart';
import '../../components/focus/tv_text_field_focus_node.dart';
import '../../components/feedback/app_toast.dart';
import 'widgets/login_qr_card.dart';

class LoginPage extends StatefulWidget {
  /// 是否为「添加新账号」模式：从账号切换页进入，登录成功后返回上一页
  /// （外壳由 currentAccountId 变化自动重建），并跳过账号凭据自动填充。
  final bool isAddMode;

  /// 是否为「编辑账号」模式：传入待编辑的账号，登录成功后写回该账号
  /// （保留原 id 与备注），而非新增/去重。
  final AccountEntry? editAccount;

  const LoginPage({super.key, this.isAddMode = false, this.editAccount});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _serverUrlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _obscurePassword = true;
  String? _errorMessage;

  /// TV 模式输入框焦点节点：空输入框时方向键用于移出输入框。
  /// 非 TV 模式不拦截任何按键，行为与普通 TextField 完全一致。
  final TvTextFieldFocusNode _serverUrlFocus =
      TvTextFieldFocusNode(debugLabel: 'serverUrl');
  final TvTextFieldFocusNode _usernameFocus =
      TvTextFieldFocusNode(debugLabel: 'username');
  final TvTextFieldFocusNode _passwordFocus =
      TvTextFieldFocusNode(debugLabel: 'password');
  final TvTextFieldFocusNode _nameFocus =
      TvTextFieldFocusNode(debugLabel: 'name');

  /// 已保存账号下拉当前选中值（填充表单后复位，避免误以为仍是选中状态）
  String? _selectedAccountId;

  /// TV 模式：首次返回显示「再按一次退出」提示并武装，2 秒内再按才退出。
  /// 登录页是门控根页面（不经 _RootBackHandler），需自己拦截返回，
  /// 否则 TV 遥控器按返回会直接退掉整个 App。
  bool _armedToExit = false;
  Timer? _exitResetTimer;

  OverlayEntry? _probeOverlay;

  static const String _prefsServerUrl = 'feiniu_server_url';
  static const String _prefsUsername = 'feiniu_username';
  static const String _prefsPassword = 'feiniu_password';

  @override
  void initState() {
    super.initState();
    // TV 焦点节点绑定 controller：空输入框时方向键可移出。
    _serverUrlFocus.bindTo(_serverUrlController);
    _usernameFocus.bindTo(_usernameController);
    _passwordFocus.bindTo(_passwordController);
    _nameFocus.bindTo(_nameController);
    // 编辑账号模式：预填该账号的字段
    if (widget.editAccount != null) {
      final acc = widget.editAccount!;
      _serverUrlController.text = acc.fnId?.isNotEmpty == true
          ? acc.fnId!
          : acc.serverUrl;
      _usernameController.text = acc.username;
      _passwordController.text = acc.password ?? '';
      _nameController.text = acc.name;
      return;
    }
    // 添加新账号模式：不自动填充上一个账号的凭据
    if (widget.isAddMode) return;
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

  /// 最近一次静默探测的结果（FNID → 结果），供登录时复用
  ConnectionProbeResult? _silentProbeResult;
  String? _silentProbeFnId;
  DateTime _silentProbeAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 静默探测（只探测不登录，更新连接信息显示）
  Future<void> _silentProbe(String fnId) async {
    // 已有同 FNID 探测在途（如 main() 启动预热）时直接复用，
    // 探测结果由发起方写入，避免重复探测与重复保存。
    if (FnConnectionProbeService.instance.isProbing.value) return;
    try {
      final cache = AppFnConnectionSettings.cachedConnection;

      final result = await FnConnectionProbeService.instance.probeSmart(
        cachedUrl: cache?.url,
        cachedIsRelay: cache?.isRelay ?? false,
        fnId: fnId,
      );

      // 无论页面是否仍在显示，都缓存结果供登录复用
      _silentProbeResult = result;
      _silentProbeFnId = fnId;
      _silentProbeAt = DateTime.now();
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
    _exitResetTimer?.cancel();
    _serverUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _serverUrlFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _nameFocus.dispose();
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
    final name = _nameController.text.trim();

    // 检测是否为 FNID
    if (_isFnId(serverUrlInput)) {
      await _fnLogin(serverUrlInput, username, password, name: name);
    } else {
      await _performLogin(serverUrlInput, username, password, name: name);
    }
  }

  /// FNID 登录流程：探测 → 连接 → 安全码 → 认证
  Future<void> _fnLogin(
    String fnId,
    String username,
    String password, {
    String name = '',
  }) async {
    try {
      final cache = AppFnConnectionSettings.cachedConnection;

      // 复用自动静默探测的「新鲜」结果（同一 FNID 且 30 秒内），
      // 避免点登录后又探测一遍。
      final silent = _silentProbeResult;
      final useSilent = silent != null &&
          _silentProbeFnId == fnId &&
          DateTime.now().difference(_silentProbeAt) <= const Duration(
            seconds: 30,
          );

      // 复用静默结果时无需再展示探测浮层（探测已完成，仅走认证）
      if (!useSilent) {
        _probeOverlay = ProbeOverlay.show(context);
      }

      final result = useSilent
          ? silent
          : await FnConnectionProbeService.instance.probeSmart(
              cachedUrl: cache?.url,
              cachedIsRelay: cache?.isRelay ?? false,
              fnId: fnId,
            );

      // 探测成功，用成功 URL 继续登录（中继模式的 relayMode 标记一并传递）
      // 同时保存连接信息供设置页显示
      AppFnConnectionSettings.saveProbeResult(
        fnId: fnId,
        url: result.serverUrl,
        method: result.probeMethod,
        isRelay: result.isRelay,
      );

      // 收起探测浮层再弹安全码框（浮层期间无法交互输入框）
      ProbeOverlay.hide(_probeOverlay);
      _probeOverlay = null;

      // 安全码检查在 _performLogin 内统一处理（域名/IP 直连共用同一逻辑）
      await _performLogin(
        result.serverUrl,
        username,
        password,
        relayMode: result.isRelay,
        fnId: fnId,
        name: name,
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
    String? fnId,
    String name = '',
  }) async {
    try {
      // 安全码检查（仅未存过才询问）：域名/IP 直连与 FNID 登录共用
      final proceed = await _ensureAccessCodeIfNeeded(
        serverUrl,
        isRelay: relayMode,
      );
      if (!proceed) return; // 用户取消 → 中止登录
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

    // 登录成功：捕获账号入列表（含 token/服务器地址/中继/安全码/FNID/备注）
    if (widget.editAccount != null) {
      // 编辑账号：写回原账号（保留 id 与自定义备注），而非新增
      await AccountStore.instance.persistLoginForEdit(
        id: widget.editAccount!.id,
        serverUrl: FeiNiuApiClient.instance.baseUrl,
        username: AuthService.instance.username.value ?? username,
        password: password,
        relayMode: relayMode,
        fnId: fnId,
        name: name,
      );
    } else {
      await AccountStore.instance.persistLogin(
        serverUrl: FeiNiuApiClient.instance.baseUrl,
        username: AuthService.instance.username.value ?? username,
        password: password,
        relayMode: relayMode,
        fnId: fnId,
        name: name,
      );
    }

    if (!mounted) return;

    // 添加新账号 / 编辑账号模式：返回上一页（账号切换页），外壳由
    // currentAccountId 变化自动重建，无需手动跳转。登录后 currentAccountId
    // 已改变，外壳可能已重建——但账号切换页若挂在嵌套导航器上则随外壳一并
    // 重建（新栈里它仍是顶部路由），此时直接关掉登录页即可露出账号切换页。
    if (widget.isAddMode || widget.editAccount != null) {
      Navigator.of(context).pop();
      return;
    }

    // 保存凭据，供下次登录页自动填充
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsServerUrl, serverUrl);
    await prefs.setString(_prefsUsername, username);

    if (!mounted) return;
    // 用 root 导航器回退到登录门控（_AppStartupGate）：门控监听 isLoggedIn /
    // currentAccountId，会自动切换到主外壳。不要用 pushReplacementNamed(home)
    // 替换门控 —— 那会让切换账号时的外壳重建失效。
    Navigator.of(
      context,
      rootNavigator: true,
    ).popUntil((r) => r.isFirst);
  }

  /// 若本地尚未存过安全码，探测服务器是否需要并（需要时）弹窗询问。
  ///
  /// 返回 false 表示用户取消输入安全码（中止登录）；true 表示无需安全码
  /// 或安全码已确认。验证端点网络异常按「不需要」处理（与 FNID 登录一致）。
  Future<bool> _ensureAccessCodeIfNeeded(
    String serverUrl, {
    bool isRelay = false,
  }) async {
    if (AppFnConnectionSettings.accessCode != null) return true;
    try {
      final requires = await AccessCodeService.instance.requiresAccessCode(
        serverUrl,
        isRelay: isRelay,
      );
      if (requires && mounted) {
        final code = await AccessCodeDialog.show(
          context,
          baseUrl: serverUrl,
          isRelay: isRelay,
        );
        return code != null; // 取消 → false
      }
      return true;
    } on DioException {
      // 验证端点不可达（服务器未开启该端点 / 网络异常）→ 按不需要处理
      return true;
    }
  }

  /// 当前是否可以点击登录按钮
  bool _canLogin() {
    return !AuthService.instance.isLoggingIn.value &&
        !FnConnectionProbeService.instance.isProbing.value;
  }

  /// 手机扫码提交的凭据 → 填充表单并自动登录（与手输一致）。
  Future<void> _handleQrCredentials(LoginCredentials creds) async {
    if (!mounted) return;
    setState(() {
      _serverUrlController.text = creds.serverInput;
      _usernameController.text = creds.username;
      _passwordController.text = creds.password;
      _nameController.text = creds.name;
      _errorMessage = null;
    });
    // 网页表单自带安全码 → 直接写入本地，登录时不再询问。
    if (creds.accessCode != null && creds.accessCode!.isNotEmpty) {
      await AppFnConnectionSettings.setAccessCode(creds.accessCode);
    }
    if (!mounted) return;
    if (_isFnId(creds.serverInput)) {
      await _fnLogin(creds.serverInput, creds.username, creds.password,
          name: creds.name);
    } else {
      await _performLogin(creds.serverInput, creds.username, creds.password,
          name: creds.name);
    }
  }

  /// 预填某个已保存账号的凭据到输入框，供直接登录
  void _fillAccount(AccountEntry account) {
    // FNID 账号预填 FNID（触发探测流程），否则预填服务器地址
    _serverUrlController.text = account.fnId?.isNotEmpty == true
        ? account.fnId!
        : account.serverUrl;
    _usernameController.text = account.username;
    _passwordController.text = account.password ?? '';
    _nameController.text = account.name;
    setState(() => _errorMessage = null);
  }

  /// 已保存账号：下拉选择即填充表单（无账号时不渲染）
  Widget _buildSavedAccounts(BuildContext context) {
    return ValueListenableBuilder<List<AccountEntry>>(
      valueListenable: AccountStore.instance.accounts,
      builder: (context, accounts, _) {
        if (accounts.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '已保存账号',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                TextButton(
                  onPressed: () => _openAccountManagement(context),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('管理账号'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 下拉选择账号 → 填充表单
            // 用 showMenu 自定义定位：菜单固定从输入框正下方弹出，
            // 不受系统 Dropdown 自动上/下定位影响（下方空间不足会弹到上方）。
            Builder(
              builder: (btnContext) {
                final scheme = Theme.of(btnContext).colorScheme;
                final selectedId = _selectedAccountId;
                final selected = selectedId != null
                    ? AccountStore.instance.byId(selectedId)
                    : null;
                return InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () async {
                    final box = btnContext.findRenderObject() as RenderBox?;
                    if (box == null) return;
                    final overlay = Overlay.of(
                      btnContext,
                      rootOverlay: true,
                    );
                    final overlayBox =
                        overlay.context.findRenderObject() as RenderBox?;
                    if (overlayBox == null) return;
                    // 菜单锚点：输入框左下角（含边框内边距）
                    final topLeft = box.localToGlobal(
                      Offset.zero,
                      ancestor: overlayBox,
                    );
                    final position = RelativeRect.fromLTRB(
                      topLeft.dx,
                      topLeft.dy + box.size.height,
                      overlayBox.size.width -
                          topLeft.dx -
                          box.size.width,
                      overlayBox.size.height - topLeft.dy,
                    );
                    final picked = await showMenu<String>(
                      context: btnContext,
                      position: position,
                      color: scheme.surfaceContainerHigh,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 8,
                      items: [
                        for (final account in accounts)
                          PopupMenuItem<String>(
                            value: account.id,
                            height: 52,
                            child: _AccountDropdownItem(account: account),
                          ),
                      ],
                    );
                    if (picked == null || !mounted) return;
                    final account = AccountStore.instance.byId(picked);
                    if (account == null) return;
                    _fillAccount(account);
                    // 复位下拉，避免误以为仍是选中状态
                    setState(() => _selectedAccountId = null);
                  },
                  child: InputDecorator(
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.account_circle_outlined),
                      hintText: '选择已保存的账号',
                      suffixIcon: const Icon(Icons.arrow_drop_down_rounded),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    isEmpty: selected == null,
                    child: selected == null
                        ? null
                        : Text(
                            selected.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }

  void _openAccountManagement(BuildContext context) {
    Navigator.of(
      context,
      rootNavigator: true,
    ).pushNamed(AppRoutes.accounts);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isTv = AppLayoutSettings.tvMode.value;

    // TV 模式：登录页是门控根页面，返回键需「按两次才退出」，与主界面一致。
    // 手机端不经此拦截，行为不变。
    final Widget page = Scaffold(
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
                  const SizedBox(height: 24),

                  // 已保存账号（可一键切换 / 管理）；添加/编辑账号时隐藏，避免干扰
                  if (!widget.isAddMode && widget.editAccount == null)
                    _buildSavedAccounts(context),

                  // 服务器地址 / FNID
                  TextFormField(
                    controller: _serverUrlController,
                    focusNode: _serverUrlFocus,
                    // TV 模式自动聚焦首个输入框，遥控器可直接输入。
                    autofocus: AppLayoutSettings.tvMode.value,
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
                    focusNode: _usernameFocus,
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
                    focusNode: _passwordFocus,
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
                  const SizedBox(height: 16),

                  // 备注名称（可选，仅用于已保存账号列表的展示）
                  TextFormField(
                    controller: _nameController,
                    focusNode: _nameFocus,
                    decoration: InputDecoration(
                      labelText: '备注名称（可选）',
                      hintText: '如：客厅 NAS、公司服务器',
                      prefixIcon: const Icon(Icons.badge_outlined),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
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

    if (!isTv) return page;
    // TV 模式：左码右表单双栏（扫码配对 + 原登录表单），拦截返回键
    // 「再按一次退出」逻辑保持不变。page 本身是带 Center+滚动 的 Scaffold，
    // 直接并列放入 Row（不再套滚动），避免嵌套滚动冲突。
    final Widget tvPage = SafeArea(
      child: Center(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            LoginQrCard(onCredentials: _handleQrCredentials),
            const SizedBox(width: 40),
            Flexible(child: page),
          ],
        ),
      ),
    );
    return PopScope(
      canPop: _armedToExit,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_armedToExit) return; // canPop 已放行，这里不会到
        _exitResetTimer?.cancel();
        _exitResetTimer = Timer(const Duration(seconds: 2), () {
          if (mounted) setState(() => _armedToExit = false);
        });
        AppToast.show(context, '再按一次退出');
        setState(() => _armedToExit = true);
      },
      child: tvPage,
    );
  }
}

/// 已保存账号下拉选项：头像字母 + 备注名 + 用户名 · 服务器
class _AccountDropdownItem extends StatelessWidget {
  final AccountEntry account;

  const _AccountDropdownItem({required this.account});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        CircleAvatar(
          radius: 15,
          backgroundColor: scheme.primary.withValues(alpha: 0.12),
          child: Text(
            account.username.isNotEmpty
                ? account.username.characters.first
                : '?',
            style: TextStyle(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                account.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                '${account.username} · ${account.serverLabel}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
