import 'dart:convert';
import 'dart:io';

/// Flutter web downloads every font in FontManifest.json before it draws the
/// first frame, and only asks for them once main.dart.js is running. This
/// shortens that wait in a finished web build, in two steps.
///
/// It drops fonts Icarus never draws from the manifest:
///
/// - Lucide icon families the compiled app never names. Every Lucide icon
///   names its family ("Lucide", "Lucide200", ...), so a family missing from
///   main.dart.js has no icon to draw. Icon tree-shaking cannot shrink these:
///   Flutter leaves a font no icon points at untouched, in case it is text.
/// - GeistMono. shadcn_ui draws it only in ShadInputOTP, which Icarus does
///   not use.
/// - Geist weights no Icarus text asks for. Text uses 400 to 800; a style
///   asking for another weight gets the nearest weight kept.
///
/// Then it has index.html preload the manifest and every font left, so the
/// browser fetches them alongside main.dart.js instead of after it.
///
/// Usage: dart run tool/prepare_web_fonts.dart build/web
void main(List<String> args) {
  final buildDir = args.single;
  final manifestFile = File('$buildDir/assets/FontManifest.json');
  final indexFile = File('$buildDir/index.html');
  final families = (jsonDecode(manifestFile.readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();
  final compiledApp = File('$buildDir/main.dart.js').readAsStringSync();

  final kept = trimFontManifest(families, compiledApp);
  manifestFile.writeAsStringSync(jsonEncode(kept));
  indexFile.writeAsStringSync(
    addFontPreloads(indexFile.readAsStringSync(), fontAssets(kept)),
  );

  for (final asset in fontAssets(families).difference(fontAssets(kept))) {
    stdout.writeln('Dropped $asset');
  }
}

const _lucidePackage = 'packages/lucide_icons_flutter/';
const _geist = 'packages/shadcn_ui/Geist';
const _geistMono = 'packages/shadcn_ui/GeistMono';
const keptGeistWeights = {400, 500, 600, 700, 800};

List<Map<String, dynamic>> trimFontManifest(
  List<Map<String, dynamic>> families,
  String compiledApp,
) {
  final kept = <Map<String, dynamic>>[];
  for (final family in families) {
    final name = family['family'] as String;
    if (name == _geistMono) continue;
    if (name.startsWith(_lucidePackage)) {
      final lucideFamily = name.substring(_lucidePackage.length);
      if (!compiledApp.contains('"$lucideFamily"')) continue;
    }
    if (name == _geist) {
      final fonts = [
        for (final font in (family['fonts'] as List).cast<Map>())
          if (keptGeistWeights.contains(font['weight'])) font,
      ];
      final weights = {for (final font in fonts) font['weight']};
      if (weights.length != keptGeistWeights.length) {
        throw StateError(
          'Geist no longer ships weights $keptGeistWeights '
          '(found $weights); check shadcn_ui before trimming it.',
        );
      }
      kept.add({...family, 'fonts': fonts});
      continue;
    }
    kept.add(family);
  }
  return kept;
}

/// Where web/index.html asks for the preloads.
const fontPreloadsMarker = '<!-- prepare_web_fonts preloads -->';

/// Replaces [fontPreloadsMarker] with preloads for the manifest and [fonts].
/// They match how Flutter fetches assets (a same-origin `fetch`), so the
/// browser hands Flutter the preloaded response instead of downloading again.
String addFontPreloads(String indexHtml, Iterable<String> fonts) {
  if (!indexHtml.contains(fontPreloadsMarker)) {
    throw StateError('index.html has no "$fontPreloadsMarker" line.');
  }
  final links = [
    for (final path in ['FontManifest.json', ...fonts])
      '<link rel="preload" href="assets/$path" as="fetch" crossorigin>',
  ];
  return indexHtml.replaceFirst(fontPreloadsMarker, links.join('\n  '));
}

Set<String> fontAssets(List<Map<String, dynamic>> families) {
  return {
    for (final family in families)
      for (final font in (family['fonts'] as List).cast<Map>())
        font['asset'] as String,
  };
}
