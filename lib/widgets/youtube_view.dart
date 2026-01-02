import 'dart:developer' show log;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:icarus/const/youtube_handler.dart';

import 'package:icarus/main.dart';
import 'package:icarus/widgets/dialogs/web_view_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (!isWebViewInitialized) {
      // showShadDialog<void>(
      //   context: context,
      //   builder: (context) {
      //     return const WebViewDialog();
      //   },
      // );
      return const WebViewDialog();
    }
    return Stack(
      children: [
        const Align(
          alignment: Alignment.center,
          child: CircularProgressIndicator(),
        ),
        Positioned.fill(
          child: InAppWebView(
            onLoadStart: (controller, url) {
              log("Youtube view loading");
            },
            onLoadStop: (controller, url) {
              log("Youtube view loaded");
            },
            webViewEnvironment: webViewEnvironment,
            initialSettings:
                InAppWebViewSettings(allowBackgroundAudioPlaying: false),
            initialUrlRequest: URLRequest(
                url: WebUri(
                    "https://embed.icarus-strats.xyz/?v=${YoutubeHandler.extractYoutubeIdWithTimestamp(widget.youtubeLink)}")),
          ),
        ),
      ],
    );
  }
}
