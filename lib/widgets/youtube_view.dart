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

        return Stack(
          children: [
            const Align(
              alignment: Alignment.center,
              child: CircularProgressIndicator(),
            ),
            Positioned.fill(
              child: InAppWebView(
                webViewEnvironment: webViewEnvironment,
                initialSettings: InAppWebViewSettings(
                  allowBackgroundAudioPlaying: false,
                  useShouldOverrideUrlLoading: true,
                ),
                initialUrlRequest: URLRequest(
                  url: WebUri.uri(YoutubeHandler.embedUri(video)),
                ),
                shouldOverrideUrlLoading: _keepOnEmbed,
              ),
            ),
          ],
        );
      },
    );
  }

  /// The view only ever shows our embed page. The player inside it loads
  /// in its own frame; anything that would replace the page itself, like
  /// the player's YouTube links, opens in the user's browser instead.
  Future<NavigationActionPolicy> _keepOnEmbed(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    final url = action.request.url;
    if (!action.isForMainFrame ||
        (url != null &&
            url.scheme == 'https' &&
            url.host == YoutubeHandler.embedHost)) {
      return NavigationActionPolicy.ALLOW;
    }
    if (url != null && (url.scheme == 'https' || url.scheme == 'http')) {
      unawaited(launchUrl(url, mode: LaunchMode.externalApplication));
    }
    return NavigationActionPolicy.CANCEL;
  }
}
