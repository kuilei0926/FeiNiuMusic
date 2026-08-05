# TV 登录扫码配对设计（Login QR Pair）

## Context（背景与目标）

飞牛音乐 TV 端（同一 Android APK）在登录页上无法方便地输入服务器地址 / FNID / 用户名 / 密码 —— TV 遥控器输入长文本极其低效。本功能让 TV 端在登录页**自动启动一个局域网 HTTP 服务并显示二维码**，用户用手机扫码打开网页，在手机上填写或修改登录信息后提交，**信息自动填充回 APP 并触发登录**。

已确认的产品决策：
- **提交行为**：填充并自动登录（走与手输完全一致的登录流程，含 FNID 探测、安全码询问）。
- **表单字段**：5 字段 —— 服务器地址/FNID、用户名、密码、备注名称、**安全码**。
- **二维码呈现**：TV 登录页左码右表单（双栏）。
- **覆盖场景**：所有登录页实例（首次登录 / 回退登录 / 添加新账号 / 编辑账号）。

## 技术选型（已选）

- **HTTP 服务**：`shelf` + `shelf_io`（`shelf: ^1.4.1` 已在 pubspec；`shelf_io` 为其标准库，需新增依赖）。
- **二维码渲染**：`qr_flutter: ^4.1.0`（纯 Dart 绘制，TV 大屏清晰可放大）。
- 备选（不采用）：`dart:io` `HttpServer` 裸写（手写路由/请求体/CORS，易错）；第三方扫码登录 SDK（绑定移动 UI，TV 适配差）。

## 架构

```
TV 登录页 (LoginPage, TV 模式)
   │ initState
   ▼
LoginPairServer.start()
   │  绑定 0.0.0.0:随机端口
   │  生成本机各网卡 IPv4 的 URL 列表
   │  每个 URL: http://<ip>:<port>/f/<token>
   │  Completer<_PendingLogin> 挂起等待
   ▼
手机扫码 → 打开内嵌网页 → 填写/提交 → POST JSON → 校验 → Completer 完成
   ▼
登录页拿到凭据 → _fnLogin / _performLogin 自动登录 → popUntil 门控
```

## 组件

### 1. `lib/app/services/login_pair_server.dart` — `LoginPairServer`

- 单例，静态状态 + 一次性启动/停止。
- `Future<LoginPairSession> start()`：
  - 幂等：已在运行则返回现有 session。
  - 绑定 `InternetAddress.anyIPv4`，端口 `0`（系统分配，避免冲突）。
  - 自动读取本机各网卡的 IPv4，生成 URL 列表。
  - 为每个 URL 生成随机 token（`Random.secure`，32 字符 hex），URL 即密钥。
  - 返回包含 `urls` 的 session。
- `Future<LoginCredentials?> waitForLogin()`：等待 `Completer` 完成，返回凭据。**一次性**：消费后立即生成新 token 防重放。
- `void stop()`：关服务器、清 pending。幂等。

`LoginCredentials` 数据结构：`serverInput`（服务器地址或 FNID）、`username`、`password`、`name`、`accessCode`（可空）。

### 2. 内嵌 HTML 网页（无外链、纯内网）

- 5 字段：服务器地址/FNID、用户名、密码、备注名称、安全码。
- 纯 HTML + 原生 JS，**无 CDN / 无外链**（TV 无外网要求）。
- App 已保存账号字段时，网页 JS 通过 `/api/poll` 主动拉取预填（复用登录页「已保存账号预填」能力）。
- 提交 → POST JSON → 服务器校验字段 → 完成。

### 3. 填充回 APP 机制

- `LoginPage` 拿到凭据后走与手输完全相同的 `_fnLogin` / `_performLogin` 流程（自动探测、安全码询问、`AuthService.login`、`persistLogin`/`persistLoginForEdit`）。
- 首次登录：凭据填好后自动登录，成功 `popUntil(root)` 进门控。
- 添加/编辑账号：写回对应账号后 `pop`。
- **安全**：token 一次一密、URL 即密钥、服务仅在登录页存活、仅局域网暴露。

### 4. TV 登录页布局（`login_page.dart`）

- TV 模式：`Row` 双栏 —— 左侧二维码卡片（含 `http://<ip>:<port>` 提示 + 刷新按钮），右侧原表单。
- 非 TV 模式：逐字节不变。

## 生命周期

- 服务随登录页：`LoginPage.initState`（TV 模式）→ `await LoginPairServer.start()` → 展示二维码；`dispose` → `stop()`。
- 切换账号 / 退出登录时登录页销毁，服务自动停。
- 服务仅 TV 模式且登录页存活期间监听。
- 登录页 `popUntil(root)` 后，服务随 `dispose` 停止。

## 错误处理

- 端口绑定失败 → 二维码区显示「无法启动配对服务」+ 重试按钮（不阻塞手机端手动登录）。
- 提交字段无效 → 网页内联提示（纯 JS 校验），HTTP 400 + 中文提示。
- 提交时登录页已销毁（用户中途退出）→ 服务 stop，网页请求返回 410，JS 显示「APP 已关闭，请重试」。
- token 不匹配 → 404。
- 登录页正常登录后 → 服务 stop，后续请求 410。
- 所有异常不向上抛，`AppToast` 提示 + 二维码区错误态。

## 测试

- `LoginPairServer`：启动→生成 URL 含 token；提交正确 token → Completer 完成返回凭据；错误 token → 404；`waitForLogin` 消费一次后失效；`stop()` 幂等。
- 网页 HTML：包含 5 字段、无外链（`assert` 不含外部 `http://` URL）、提交路径。
- 登录页：TV 模式显示二维码卡 + 服务启动；非 TV 模式无二维码卡 + 服务不启动。
- 沿用现有约定（`setUp` reset、`tester.pump`）。

## 范围 / 非目标

- 本次**不**做：安全码之外的更多字段、HTTPS、跨设备多终端同时配对、网页修改已保存账号（只能填充新凭据）。

## 依赖变更

- 新增：`qr_flutter: ^4.1.0`、`shelf_io: ^1.2.0`（`shelf` 已有）。
