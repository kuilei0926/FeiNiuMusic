# FeiNiuMusic

飞牛私有云（FNOS）平台的第三方音乐客户端。通过飞牛 NAS 自带的音乐服务 API获取音乐库、播放流和歌词数据，提供完整的在线音乐播放体验。

基于 [NagoMusic](https://github.com/Keduoli03/NagoMusic) 项目深度魔改适配。

## 功能

### 连接与账号

- **飞牛 NAS 音乐服务对接** — 通过 FNOS 音乐 API 登录、获取歌曲 / 专辑 / 歌手 / 歌单 / 风格
- **FN Connect 连接** — 支持 FNID 自动探测连接，内网/公网 IPv4/IPv6/中继多层链路探测，断线自动重连
- **多账号管理** — 保存并切换多个飞牛账号，激活账号状态全局同步

### 播放能力

- **在线播放** — 从 NAS 直接获取音频流，支持随机漫游播放
- **双播放器架构** — 系统解码优先，FFmpeg 兜底（`media_kit`），支持 FLAC / DSF 等无损格式
- **DLNA 投屏** — 播放页右上角一键投屏到局域网 DLNA 设备（电视/音响），投屏后手机端遥控播放/暂停/进度/音量；无损格式自动转码为 MP3 投屏（Android）
- **CUE 整轨支持** — 按 CUE 索引拆分整轨专辑，定位到曲目起播位置
- **播放历史** — 记录与浏览播放历史
- **定时音量** — 在设定时间段内自动把音量强制到设定值
- **启动自动打开播放界面** — 可配置启动软件后直接进入播放页

### 歌词与通知

- **歌词展示** — LRC 歌词（含翻译行解析）与歌曲联动
- **车载蓝牙歌词** — 通过 AVRCP TITLE 向车载系统传输当前歌词行
- **状态栏歌词** — 支持魅族 / Lyricon 可选方案
- **媒体通知** — 通知栏播放控制，使用本地封面（携带 Cookie 认证的封面无法直连，自动换用缓存文件）
- **切歌通知弹窗** — 切歌时应用内弹出「正在播放」卡片（封面 + 歌名 + 歌手），可设置提示时长（2–10s），平板/TV 下卡片自动放大且倍数可调（1.0–3.0×），支持手动关闭

### 通知歌词灵动岛

在系统灵动岛显示当前歌词行，支持两种工作模式（设置 → 歌词设置 → 通知歌词灵动岛）：

| 模式 | 说明 | 要求 | 支持机型 |
| :--- | :--- | :--- | :--- |
| **实时通知（实况通知）** | 走系统标准实时通知接口上岛，无 root / Shizuku | Android 16+；HyperOS 需 3.0.300+ | 小米 HyperOS（3.0.300，已验证）；ColorOS、OneUI、AOSP（社区支持） |
| **焦点通知** | 走 MIUI 焦点通知上岛，系统渲染歌词卡片（OS2 模板与 OS3 超级岛模板不同） | HyperOS 2/OS2 起支持 | HyperOS 设备（需加入焦点通知白名单，或开启 Shizuku 绕过） |

- **Shizuku 绕过白名单** — 未加入系统焦点通知白名单的应用，可通过授权 Shizuku 并开启「Shizuku 绕过白名单」临时绕过限制：发送焦点通知时短暂拦截 XMSF 网络，使系统无法向小米服务端校验白名单。注意可能导致耗电增加或消息延迟。

> 低于 Android 16 或 HyperOS 2 的系统不支持原生动态歌词（实时通知需 Android 16+；焦点通知需 HyperOS 2/OS2+）。

### 按设备能力自动隐藏开关

设置页会根据当前设备的能力自动显示/隐藏通知类型开关（对齐小米焦点通知官方文档）：

- **实时通知** 仅在 Android 16+（API 36+）设备上显示；
- **焦点通知** 当焦点通知协议版本 ≥ 2（`notification_focus_protocol`，OS2 / OS3，两版模板不同）+ 应用焦点通知权限已开启（`canShowFocus`）时显示（OS3 的岛渲染能力 `persist.sys.feature.island` 不影响焦点通知可用性）；
- 两种模式都不可用的设备（如旧版 Android / 非小米且非 Android 16）不显示「通知歌词灵动岛」区块；
- 已保存的通知类型在设备上不可用时，自动回退到可用的默认类型（优先实时通知）。

> 注：`focusPermission`（`canShowFocus`）探测是耗时操作，仅在进入歌词设置页时执行一次并缓存。

### 浏览与管理

- **搜索** — 全局搜索歌曲、专辑、歌手
- **收藏与管理** — 收藏歌曲、创建/编辑歌单
- **文件夹视图** — 按 NAS 文件系统目录层级浏览音乐（配合服务端增强应用）：目录树 + 面包屑导航、排序（文件名/创建时间/时长/大小）、随机播放、分页加载更多、CUE 整轨按曲目拆分展示、递归搜索当前目录树、平铺视图（一键展示当前目录及子文件夹全部歌曲）、长按歌曲详情与多选管理
- **数据匹配（Lyrico 数据源）** — 导入 [Lyrico](https://github.com/Replica0110/Lyrico) 搜索源插件（zip），在歌曲信息编辑页**一键匹配**歌曲信息（标题/歌手/专辑/封面），或歌曲页多选后**批量匹配**并回传 NAS；设置页可维护数据源（导入/启用/配置/卸载）与匹配偏好（歌词模式/简繁转换/过滤规则/并发）
- **服务端增强（FnMusicEnhance）** — 配合运行在 NAS 上的[增强应用](https://github.com/kuilei0926/FnMusicEnhance)（端口 38200）：歌词修改（歌曲信息编辑页直接读写歌词）、歌手/专辑编辑（改名 + 封面写入）、文件夹视图；仅非中继（5ddd.com）连接可用，认证使用飞牛音乐登录 token，无需单独配置密钥

### 界面与适配

- **播放器** — 全屏播放器与歌词页切换，底部控制栏，迷你播放器
- **主题与外观** — 动态渐变背景、主题模式切换、播放器样式可选
- **平板模式** — 大屏桌面式布局（侧栏 + 自适应排版）
- **TV 模式** — 自动检测 Android TV（系统权威信号 + 纯 Dart 启发式回退），切换 TV 布局与遥控器方向键焦点导航；播放页、设置页、切歌卡片等均接入遥控操作；支持在设置中手动强制开启预览
- **TV 扫码登录** — 局域网配对 HTTP 服务 + 二维码扫码凭据自动登录
- **听歌统计** — 记录播放时长与次数统计

## 与上游 NagoMusic 的差异

- 从通用 WebDAV/本地播放器改造为飞牛 NAS 专属音乐客户端
- 对接 FNOS 音乐服务 API，使用 Cookie 认证
- 引入双播放器架构（系统解码 + FFmpeg 兜底），扩展无损格式支持
- 新增 TV / 平板自适应布局与遥控器焦点导航
- 净化和精简上游冗余代码，适配飞牛场景

## 适用平台

- Android（手机 / 平板 / Android TV / Android Auto 车机）

## Android Auto 支持

飞牛音乐通过 `audio_service` 注册系统 MediaSession / MediaBrowserService，
支持在 Android Auto（手机投屏）与 Android Automotive OS（车机版）上显示和控制播放：

- **启动器可见**：应用启动即注册媒体会话，Android Auto 启动器可直接发现本应用
- **正在播放卡片**：显示封面、歌名、歌手、专辑与进度，支持上一首 / 播放暂停 / 下一首 / 拖动进度
- **队列列表**：点按队列中的曲目可直接切歌
- **通知联动**：通知栏与车机共用同一媒体会话，自定义按键（收藏 / 关闭）同步生效

### 测试方式

1. 手机安装本应用，并安装 Android Auto 应用
2. 通过数据线连接支持 Android Auto 的车机（或使用 Android Auto 模拟器）
3. 在车机启动器中选择「飞牛音乐」

## 界面预览

<table>
  <tr>
    <th>首页</th>
    <th>侧边栏</th>
  </tr>
  <tr>
    <td><img src="开发文档/home.jpg" width="220" /></td>
    <td><img src="开发文档/sidemenu.jpg" width="220" /></td>
  </tr>
  <tr>
    <th>播放器</th>
    <th>歌词</th>
  </tr>
  <tr>
    <td><img src="开发文档/player.jpg" width="220" /></td>
    <td><img src="开发文档/lyric.jpg" width="220" /></td>
  </tr>
</table>

## 从源码构建

### 前置条件

- Flutter SDK（见 `pubspec.yaml` 中 `environment.sdk` 版本要求）
- Android SDK（API 34+）
- JDK 17+

### 获取依赖

```bash
flutter pub get
```

### 调试运行

连接 Android 设备或启动模拟器后，执行以下命令即可在设备上以调试模式启动应用：

```bash
flutter run
```

如需指定目标设备，先通过 `flutter devices` 查看已连接的设备，然后使用 `-d` 参数：

```bash
flutter devices          # 查看设备列表
flutter run -d 设备ID    # 在指定设备上运行
```

### 运行测试

```bash
flutter test             # 单元测试 + Widget 测试
flutter analyze          # 静态分析
```

### 构建发布版 APK

```bash
# 1. 配置签名（发布版必需）
#    参考 android/key.properties.example 创建 android/key.properties
#    并将 release.keystore 放到 android/app/ 目录下

# 2. 构建 APK（按 CPU 架构拆分）
flutter build apk --release --split-per-abi
```

构建产物位于 `build/app/outputs/flutter-apk/`，按 CPU 架构（arm64-v8a / armeabi-v7a / x86_64）拆分。

## 鸿蒙 / iQOO / VIVO 音乐兼容包（非官方）

某些手机系统（鸿蒙 4 / 鸿蒙 6、iQOO、VIVO）在系统播控中心（控制中心右上角的
媒体卡片）里，默认只对系统「白名单」内的音乐应用显示 **音频控制按钮**。
第三方音乐应用即使正常播放，也不显示入口。

为解决该问题（参考
[lx-music-mobile issue #908](https://github.com/lyswhut/lx-music-mobile/issues/908)），
本项目额外提供一种 **兼容安装包**：该包的 **Android 包名（applicationId）被
覆盖为 `com.luna.music`**，从而让系统将应用识别为受支持的音乐应用来源。

### ⚠️ 非官方声明与法律风险

请在使用该兼容包前仔细阅读以下内容：

- **非官方安装包**：该包不是官方发布的汽水音乐版本。它是为解决特定机型音乐控制问题而生成的改装包，与系统正式包
  （`com.feiniu.music`）可以共存安装，但功能与行为以本仓库源码为准。
- **包名冲突风险**：`com.luna.music` 是字节跳动旗下「汽水音乐」App 使用的包名。
  安装本兼容包后：
  - 若设备上**已安装汽水音乐**，安装本包需要先卸载汽水音乐；
    反之，已安装本包时再安装汽水音乐需要卸载本包。
  - 系统通知、媒体卡片、快捷图标等会**共用同一套包名身份**，可能造成混淆。
  - 因覆盖导致的原应用数据丢失，本项目不承担任何责任。
- **品牌与商标风险**：本兼容包与汽水音乐 / 字节跳动、以及任何其他使用
  `com.luna.music` 或 `luna` 标识的软件**均无任何关联、授权或赞助关系**。冒用
  第三方包名可能涉及商标、不正当竞争等法律风险，请您自行评估后谨慎使用，本项目
  不对由此产生的任何后果负责。
- **卸载方式**：卸载该兼容包等同于卸载一个以 `com.luna.music` 为包名的应用，
  不会影响正式包（`com.feiniu.music`）的数据。

### 如何区分两个安装包

| 安装包 | 包名（applicationId） | 适用 |
| --- | --- | --- |
| `FeiNiuMusic-vX.Y.Z-arm64-v8a.apk` | `com.feiniu.music`（正式） | 常规设备，飞牛音乐正式包（arm64） |
| `FeiNiuMusic-vX.Y.Z-armeabi-v7a.apk` | `com.feiniu.music`（正式） | 常规设备，飞牛音乐正式包（32 位） |
| `FeiNiuMusic-vX.Y.Z-x86_64.apk` | `com.feiniu.music`（正式） | 常规设备，飞牛音乐正式包（x86_64） |
| `FeiNiuMusic-vX.Y.Z-z-luna-arm64-v8a.apk` | `com.luna.music`（音乐控制兼容，非官方） | 鸿蒙 4/6、iQOO、VIVO 汽水音频控制问题（仅 arm64） |

四个安装包可以同时安装、互不影响数据；不确定时请安装正式包。

## 开源协议

本项目基于上游 [NagoMusic](https://github.com/Keduoli03/NagoMusic) 项目的开源协议发布。

音乐数据匹配功能移植自 [Lyrico](https://github.com/Replica0110/Lyrico)（[Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0)）：
- 数据源插件运行引擎（QuickJS）与宿主 API、插件格式（`manifest.json` + `source.js`）均移植自 Lyrico；
- 数据源插件（网易云 / QQ / 酷狗 / 苹果 / 汽水等）为 Lyrico 项目提供的第三方搜索源；
- 歌词格式（逐字 / 增强逐字 / 逐行 / TTML，含翻译、罗马音）对齐 Lyrico 的 `LrcDocumentFormat`。

## 致谢

- [NagoMusic](https://github.com/Keduoli03/NagoMusic) — 本项目的基础
- [Lyrico](https://github.com/Replica0110/Lyrico) — 音乐数据匹配 / 数据源插件引擎 / 歌词格式（Apache-2.0）
- [HyperLyric](https://github.com/limczhh/HyperLyric) — 焦点通知 / 灵动岛 API 及 Shizuku 绕过白名单实现等移植来源