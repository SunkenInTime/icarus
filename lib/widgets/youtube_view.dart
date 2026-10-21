import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:icarus/const/youtube_handler.dart';

import 'package:icarus/main.dart';
import 'package:icarus/widgets/dialogs/web_view_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher/url_launcher.dart';

// class YoutubeView extends StatelessWidget {
//   const YoutubeView({
//     super.key,
//     required this.youtubeLink,
//   });
//   final String youtubeLink;

//   @override
//   Widget build(BuildContext context) {
//     return InAppWebView(
//       // key: const Key('youtube_view'),
//       // onWebViewCreated: (controller) {
//       //   log("Youtube view created");

//       //   controller.loadUrl(
//       //       urlRequest: URLRequest(
//       //           url:
//       //               WebUri("https://embed.icarus-strats.xyz/?v=$youtubeLink")));
//       // },

//       webViewEnvironment: webViewEnvironment,
//       initialSettings: InAppWebViewSettings(allowBackgroundAudioPlaying: false),
//       initialUrlRequest: URLRequest(
//           url: WebUri("https://embed.icarus-strats.xyz/?v=$youtubeLink")),
//     );
//   }
// }

class YoutubeView extends StatefulWidget {
  const YoutubeView({
    super.key,
    required this.youtubeLink,
  });
  final String youtubeLink;
  @override
  State<YoutubeView> createState() => _YoutubeViewState();
}

class _YoutubeViewState extends State<YoutubeView>
    with AutomaticKeepAliveClientMixin {
  late final Future<void> _webViewWarmupFuture;

  /// Whether a page replacing the embed goes to the browser. True from the
  /// start, so a click before the embed has finished loading counts; after
  /// a hand-off, only an embed that finishes loading turns it back on.
  bool _handsOff = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _webViewWarmupFuture = warmUpWebViewEnvironment();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return FutureBuilder<void>(
      future: _webViewWarmupFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done &&
            !isWebViewWarmupComplete) {
          return const Center(child: CircularProgressIndicator());
        }

        if (!isWebViewInitialized) {
          return const WebViewDialog();
        }

        final video = YoutubeHandler.parse(widget.youtubeLink);
        if (video == null) {
          return Center(
            child: Text(
              "This link doesn't point at a YouTube video.",
              style: TextStyle(
                color: ShadTheme.of(context).colorScheme.mutedForeground,
              ),
            ),
          );
        }

        final embed = WebUri.uri(YoutubeHandler.embedUri(video));
        return Stack(
          children: [
            const Align(
              alignment: Alignment.center,
              child: CircularProgressIndicator(),
            ),
            Positioned.fill(
              child: InAppWebView(
                webViewEnvironment: webViewEnvironment,
                initialSettings:
                    InAppWebViewSettings(allowBackgroundAudioPlaying: false),
                initialUrlRequest: URLRequest(url: embed),
                onLoadStart: (controller, url) =>
                    _keepOnEmbed(controller, url, embed),
                onLoadStop: (controller, url) => _handsOff = _isEmbed(url),
              ),
            ),
          ],
        );
      },
    );
  }

  static bool _isEmbed(WebUri? url) =>
      url != null &&
      url.scheme == 'https' &&
      url.host == YoutubeHandler.embedHost;

  /// The view is for our embed page. The player inside it loads in its own
  /// frame; a page that would replace the embed, like the one behind the
  /// player's YouTube links, opens in the user's browser and the embed
  /// comes back. On Windows the load can't be refused before it starts:
  /// shouldOverrideUrlLoading misses pages YouTube's service worker serves,
  /// so this catches every load as it starts. On the web nothing reaches
  /// here: the app doesn't load the plugin's web script, and a cross-origin
  /// iframe's address can't be read anyway.
  ///
  /// One hand-off, then none until an embed finishes loading: if the
  /// embed's own address redirected elsewhere, handing each redirect off
  /// and loading the embed again would never end. That redirected page
  /// then stays in the view.
  void _keepOnEmbed(
    InAppWebViewController controller,
    WebUri? url,
    WebUri embed,
  ) {
    if (url == null ||
        (url.scheme != 'https' && url.scheme != 'http') ||
        _isEmbed(url) ||
        !_handsOff) {
      return;
    }
    _handsOff = false;
    unawaited(launchUrl(url, mode: LaunchMode.externalApplication));
    unawaited(controller.loadUrl(urlRequest: URLRequest(url: embed)));
  }
}
