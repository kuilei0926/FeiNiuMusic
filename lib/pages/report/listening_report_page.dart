import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/playlist_service.dart';
import '../../app/services/report/report_snapshot_builder.dart';
import '../../app/services/report/report_web_config.dart';
import '../../components/index.dart';

/// 听歌报告页：构建本地听歌数据 → 生成报告 payload → 在 WebView 中打开
/// GitHub Pages 上的报告网页（hash 注入数据）。
///
/// 进入后进入全屏沉浸模式（隐藏状态栏/导航栏），退出时恢复系统 UI。
class ListeningReportPage extends StatefulWidget {
  const ListeningReportPage({super.key});

  @override
  State<ListeningReportPage> createState() => _ListeningReportPageState();
}

enum _ReportStage { building, loadingWeb, ready, error }

class _ListeningReportPageState extends State<ListeningReportPage> {
  _ReportStage _stage = _ReportStage.building;
  String? _error;

  /// 待注入的 payload JSON。页面首次加载完成后写入 localStorage 并 reload。
  String? _pendingPayloadJson;

  /// 已注入过 payload（防止 reload 后重复注入形成死循环）。
  bool _payloadInjected = false;

  @override
  void initState() {
    super.initState();
    _enterFullscreen();
    _buildAndOpen();
  }

  /// 进入全屏沉浸模式（隐藏状态栏与系统导航栏），适配报告网页的动画体验。
  Future<void> _enterFullscreen() async {
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
    );
  }

  /// 退出时恢复系统 UI（回到 App 正常的 edge-to-edge 状态）。
  Future<void> _exitFullscreen() async {
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
    );
  }

  /// 把 FeiNiu 服务器鉴权 cookie（music-token / mode=relay）注入 WebView，
  /// 使报告页里的 `<img>`/PIXI 能加载 `$baseUrl/music/api/v1/static/cover?` 封面图。
  ///
  /// 封面 URL 来自 [FeiNiuApiClient.coverUrl]，鉴权机制见
  /// `api_client.dart:imageAuthHeaders()`（Cookie: music-token=...）。
  ///
  /// 必须在 WebView 创建后调用：启用第三方 cookie（跨域请求携带注入的
  /// music-token）需要拿到 controller。
  Future<void> _injectFeiNiuCookies() async {
    try {
      // 启用第三方 cookie：报告页在 A 域名，封面图在 B 域名（FeiNiu 服务器），
      // 是跨域请求。Android WebView 默认拒绝第三方 cookie，导致注入的
      // music-token 不会随跨域图片请求携带，服务器鉴权失败返回无图。
      _allowThirdPartyCookies();

      final api = FeiNiuApiClient.instance;
      final baseUrl = api.baseUrl;
      final token = api.token;
      if (baseUrl.isEmpty || token.isEmpty) return;

      final host = Uri.tryParse(baseUrl)?.host;
      if (host == null || host.isEmpty) return;
      final domain = host;

      final manager = WebViewCookieManager();
      await manager.setCookie(WebViewCookie(
        name: 'music-token',
        value: token,
        domain: domain,
        path: '/',
      ));
      if (api.relayMode) {
        await manager.setCookie(WebViewCookie(
          name: 'mode',
          value: 'relay',
          domain: domain,
          path: '/',
        ));
      }
    } catch (e) {
      // cookie 注入失败不阻塞报告（仅封面图可能加载失败）
      debugPrint('[Report] cookie inject failed: $e');
    }
  }

  /// Android：允许 WebView 接受第三方 cookie，跨域图片请求才携带注入的 cookie。
  void _allowThirdPartyCookies() {
    try {
      final controller = _controller;
      if (controller == null) return;
      final manager = WebViewCookieManager();
      final platform = manager.platform;
      if (platform is AndroidWebViewCookieManager) {
        final androidController = controller.platform;
        if (androidController is AndroidWebViewController) {
          platform.setAcceptThirdPartyCookies(androidController, true);
        }
      }
    } catch (e) {
      debugPrint('[Report] setAcceptThirdPartyCookies failed: $e');
    }
  }

  /// 调试：把生成的 payload 写到应用文档目录 report_payload_dump.json，
  /// 并打印摘要到 logcat，便于排查头像/专辑图不显示（检查 pic/coverId 是否有值）。
  Future<void> _debugDumpPayload(Map<String, dynamic> payload) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, 'report_payload_dump.json'));
      await file.writeAsString(jsonEncode(payload), flush: true);
      debugPrint('[Report] payload dumped to ${file.path}');

      // 打印 pic 字段摘要到 logcat
      final req0 = (payload['req_0'] as Map?)?['data'] as Map?;
      if (req0 != null) {
        String pickPics(Map? obj) {
          if (obj == null) return '';
          final pic = obj['pic'];
          return pic is String ? pic : '';
        }

        final samplePics = <String>[];
        for (var i = 0; i < 20; i++) {
          final page = req0['page$i'] as Map?;
          if (page == null) continue;
          if (page['singer'] is Map) {
            samplePics.add('page$i.singer.pic=${pickPics(page['singer'] as Map?)}');
          }
          final singers = page['singers'] as List?;
          if (singers != null && singers.isNotEmpty) {
            final first = singers.first as Map?;
            final singer = first?['singer'] as Map?;
            if (singer != null) {
              samplePics.add('page$i.singers[0].singer.pic=${pickPics(singer)}');
            }
          }
        }
        debugPrint('[Report] PICS ${samplePics.join(' | ')}');
      }
    } catch (e) {
      debugPrint('[Report] payload dump failed: $e');
    }
  }

  @override
  void dispose() {
    _exitFullscreen();
    super.dispose();
  }

  Future<void> _buildAndOpen() async {
    // 听歌报告依赖 WebView 渲染；Windows 桌面端无 webview_flutter 实现，
    // 直接进入错误态占位，不构造 WebViewController（会抛错）。
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      if (!mounted) return;
      setState(() {
        _stage = _ReportStage.error;
        _error = '听歌报告暂不支持 Windows 桌面版';
      });
      return;
    }
    setState(() => _stage = _ReportStage.building);
    try {
      // 聚合可能耗时（genre 反查是网络请求），Builder 内部已是异步 IO。
      final payload = await ReportSnapshotBuilder().build();
      // 调试：把生成的 payload 写到应用文档目录 + logcat，便于排查 pic/coverId
      await _debugDumpPayload(payload);
      // payload JSON 待注入（经 localStorage，不占 URL hash，避免 2MB 上限）
      _pendingPayloadJson = jsonEncode(payload);
      if (!mounted) return;
      setState(() => _stage = _ReportStage.loadingWeb);
      // URL 不带 payload（几十字节），避免内嵌 base64 撑爆 WebView 2MB 上限
      final url = ReportWebConfig.buildUrl();
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.black)
        ..setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) {
              // 只允许报告站内导航；外链交给系统浏览器
              if (request.url.startsWith(ReportWebConfig.reportBaseUrl)) {
                return NavigationDecision.navigate;
              }
              return NavigationDecision.prevent;
            },
            // 本地测试/自建服务器用自签名 HTTPS 证书时，忽略证书错误继续加载，
            // 否则 WebView 因证书不受信拒绝加载，导致「只有文字没有动画/图片」。
            onSslAuthError: (error) {
              error.proceed();
            },
            // —— 诊断：捕获子资源（封面图）加载失败，定位 cookie 鉴权问题 ——
            onWebResourceError: (error) {
              debugPrint(
                '[Report] resource error: ${error.url} code=${error.errorCode} ${error.description}',
              );
            },
            onHttpError: (error) {
              debugPrint(
                '[Report] http error: ${error.response?.uri} status=${error.response?.statusCode}',
              );
            },
            onPageFinished: (url) {
              debugPrint('[Report] page finished: $url');
              // —— payload 注入：把报告数据经 localStorage 交给页面 ——
              // URL 不带 payload（避免 2MB 上限）。页面首次加载完成后把 JSON
              // 写入 localStorage 并 reload，index.html 从 localStorage 读取。
              // reload 后再触发 onPageFinished 时 _payloadInjected 已为 true，不再重复。
              final pending = _pendingPayloadJson;
              if (pending != null && !_payloadInjected) {
                _payloadInjected = true;
                debugPrint('[Report] injecting payload via localStorage (${pending.length} chars)');
                _controller?.runJavaScript('''
                  (function(){
                    try {
                      localStorage.setItem('__report_payload', ${jsonEncode(pending)});
                      localStorage.setItem('__report_payload_flag', '1');
                      location.reload();
                    } catch(e) {
                      console.log('[REPORT-DIAG] inject failed: ' + e);
                    }
                  })();
                ''');
                return;
              }
              // 加载完成后注入 JS 检查：cookie 是否注入、图片加载状态
              _controller?.runJavaScript('''
                (function(){
                  var out = {
                    cookie: document.cookie || '(empty)',
                    imgCount: document.querySelectorAll('img').length,
                    failedImgs: 0,
                    sample: ''
                  };
                  document.querySelectorAll('img').forEach(function(img){
                    if (img.complete && img.naturalWidth === 0) { out.failedImgs++; }
                    if (!out.sample && /cover|artist|album/.test(img.src||'')) {
                      out.sample = (img.src||'').slice(0, 120);
                    }
                  });
                  window.console && console.log('[REPORT-DIAG] ' + JSON.stringify(out));
                })();
              ''');
            },
          ),
        );
      // 诊断：JS console 消息回传（[REPORT-DIAG] 由 onPageFinished 注入的 JS 打出）
      try {
        _controller!.addJavaScriptChannel(
          'ReportDiag',
          onMessageReceived: (message) {
            debugPrint('[Report][JS] ${message.message}');
          },
        );
      } catch (e) {
        debugPrint('[Report] addJavaScriptChannel failed: $e');
      }
      // 收藏年度歌单：网页点「收藏年度歌单」→ JS channel 通知 → App 创建歌单并加歌
      try {
        _controller!.addJavaScriptChannel(
          'ReportBridge',
          onMessageReceived: (message) {
            _handleCollectPlaylist(message.message);
          },
        );
      } catch (e) {
        debugPrint('[Report] ReportBridge channel failed: $e');
      }
      // Android：允许混合内容。报告页在 HTTPS（GitHub Pages），但 FeiNiu
      // 服务器可能是 HTTP（内网），否则 HTTP 封面图会被浏览器拦截。
      _allowMixedContent();
      // 允许网页自动播放音频（BGM）：不要求用户手势，否则自动播放的
      // background music 会被 WebView 静音。
      _allowAutoMediaPlayback();
      // 注入 FeiNiu 服务器 cookie + 启用第三方 cookie（跨域加载鉴权封面图）。
      // 必须在 WebView 创建后调用（setAcceptThirdPartyCookies 需要 controller）。
      await _injectFeiNiuCookies();
      // dev 模式绕过缓存：清 WebView 旧缓存，避免加载旧版 bundle/index。
      // 正式模式保留缓存（性能优先）。
      if (kDebugMode) {
        _clearWebViewCache();
      }
      // GPU 加速：WebView 继承 Activity 的 hardwareAccelerated=true（见
      // AndroidManifest.xml），PIXI/Spine/视频动画自动走 GPU 合成。
      await _controller!.loadRequest(Uri.parse(url));
      if (!mounted) return;
      setState(() => _stage = _ReportStage.ready);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _ReportStage.error;
        _error = e.toString();
      });
    }
  }

  /// 收藏年度歌单：网页点「收藏年度歌单」时经 ReportBridge JS channel 调起。
  ///
  /// [raw] 为网页传来的 JSON：`{"name":"2026年度音乐","songIds":["<guid>",...]}`。
  /// 用 FeiNiu 歌单 API 创建歌单并批量加歌，成功后提示。
  Future<void> _handleCollectPlaylist(String raw) async {
    debugPrint('[Report] collect playlist: ${raw.length} chars');
    try {
      final msg = jsonDecode(raw) as Map<String, dynamic>;
      final name = (msg['name'] as String? ?? '').trim();
      final songIds = (msg['songIds'] as List? ?? const [])
          .map((e) => e.toString())
          .where((g) => g.isNotEmpty)
          .toList();
      if (name.isEmpty || songIds.isEmpty) {
        debugPrint('[Report] collect skipped: name/songIds empty');
        return;
      }
      final playlistService = FeiNiuPlaylistService.instance;
      // 创建歌单（无自定义封面时服务器自动分配）
      final playlist = await playlistService.createPlaylist(name);
      debugPrint('[Report] playlist created: ${playlist.guid} ${playlist.name}');
      // 批量加歌（分片避免单次请求过大）
      for (var i = 0; i < songIds.length; i += 50) {
        final chunk = songIds.sublist(
          i,
          i + 50 > songIds.length ? songIds.length : i + 50,
        );
        await playlistService.addTracks(playlist.guid, chunk);
      }
      if (!mounted) return;
      AppToast.show(context, '已创建歌单「$name」并添加 ${songIds.length} 首歌');
    } catch (e) {
      debugPrint('[Report] collect playlist failed: $e');
      if (!mounted) return;
      AppToast.show(context, '歌单创建失败，请稍后重试');
    }
  }

  /// Android：允许 HTTPS 页面加载 HTTP 子资源（FeiNiu 内网服务器的封面图）。
  void _allowMixedContent() {
    try {
      final platform = _controller?.platform;
      if (platform is AndroidWebViewController) {
        platform.setMixedContentMode(MixedContentMode.alwaysAllow);
      }
    } catch (e) {
      debugPrint('[Report] setMixedContentMode failed: $e');
    }
  }

  /// Android：允许网页无用户手势自动播放音频（报告 BGM 需要）。
  ///
  /// WebView 默认要求用户手势才能播放媒体，自动触发的 `<audio>.play()`
  /// 会被拒绝/静音。设为 false 后 BGM 可自动播放出声音。
  void _allowAutoMediaPlayback() {
    try {
      final platform = _controller?.platform;
      if (platform is AndroidWebViewController) {
        platform.setMediaPlaybackRequiresUserGesture(false);
      }
    } catch (e) {
      debugPrint('[Report] setMediaPlaybackRequiresUserGesture failed: $e');
    }
  }

  /// dev 模式清 WebView 缓存：确保加载最新网页，不被旧 bundle/index 干扰。
  void _clearWebViewCache() {
    try {
      final platform = _controller?.platform;
      if (platform is AndroidWebViewController) {
        platform.clearCache();
      }
    } catch (e) {
      debugPrint('[Report] clearCache failed: $e');
    }
  }

  WebViewController? _controller;

  @override
  Widget build(BuildContext context) {
    final ready = _stage == _ReportStage.ready && _controller != null;
    // 报告加载完成后隐藏 App 栏，实现真正的全屏体验
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      // 报告页全屏：关闭 SafeArea 顶部/底部内边距，让 WebView 延伸到
      // 状态栏/导航栏后面（配合 SystemUiMode.immersiveSticky 沉浸模式）。
      useSafeArea: false,
      appBar: ready
          ? null
          : AppTopBar(
              title: '听歌报告',
              backgroundColor: Colors.transparent,
              elevation: 0,
            ),
      showMiniPlayer: false,
      body: switch (_stage) {
        _ReportStage.building => const _CenteredMessage(
            text: '正在生成你的听歌报告…',
            child: CircularProgressIndicator(),
          ),
        _ReportStage.loadingWeb => const _CenteredMessage(
            text: '正在打开报告…',
            child: CircularProgressIndicator(),
          ),
        _ReportStage.error => _CenteredMessage(
            text: '报告生成失败\n$_error',
            showRetry: true,
            onRetry: _buildAndOpen,
            child: Icon(
              Icons.error_outline_rounded,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        _ReportStage.ready => _controller == null
            ? const SizedBox.shrink()
            : WebViewWidget(controller: _controller!),
      },
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({
    required this.child,
    required this.text,
    this.showRetry = false,
    this.onRetry,
  });

  final Widget child;
  final String text;
  final bool showRetry;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          child,
          const SizedBox(height: 16),
          Text(text, textAlign: TextAlign.center),
          if (showRetry && onRetry != null) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重试'),
            ),
          ],
        ],
      ),
    );
  }
}
