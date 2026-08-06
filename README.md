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

### 浏览与管理

- **搜索** — 全局搜索歌曲、专辑、歌手
- **收藏与管理** — 收藏歌曲、创建/编辑歌单
- **列表加载更多** — 列表支持按数量加载更多

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

- Android（手机 / 平板 / Android TV）

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

## 开源协议

本项目基于上游 [NagoMusic](https://github.com/Keduoli03/NagoMusic) 项目的开源协议发布。
