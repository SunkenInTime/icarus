import 'package:flutter_test/flutter_test.dart';
import '../tool/prepare_web_fonts.dart';

void main() {
  Map<String, dynamic> family(String name,
      [List<int?> weights = const [null]]) {
    return {
      'family': name,
      'fonts': [
        for (final weight in weights)
          {if (weight != null) 'weight': weight, 'asset': '$name-$weight.otf'},
      ],
    };
  }

  final manifest = [
    family('MaterialIcons'),
    family('packages/shadcn_ui/Geist',
        [100, 200, 300, 400, 500, 600, 700, 800, 900]),
    family('packages/shadcn_ui/GeistMono', [400, 500]),
    family('packages/lucide_icons_flutter/Lucide'),
    family('packages/lucide_icons_flutter/Lucide200'),
    family('packages/lucide_icons_flutter/Lucide500'),
  ];
  // How dart2js writes the family of a const IconData.
  const compiledApp = 'B.a=new A.aW(58757,"Lucide","lucide_icons_flutter",!1)\n'
      'B.b=new A.aW(57426,"Lucide200","lucide_icons_flutter",!1)';

  List<String> names(List<Map<String, dynamic>> families) =>
      [for (final family in families) family['family'] as String];

  test('keeps the Lucide families the app draws and drops the rest', () {
    final kept = names(trimFontManifest(manifest, compiledApp));
    expect(kept, contains('packages/lucide_icons_flutter/Lucide'));
    expect(kept, contains('packages/lucide_icons_flutter/Lucide200'));
    expect(kept, isNot(contains('packages/lucide_icons_flutter/Lucide500')));
  });

  test('drops GeistMono and the Geist weights no text uses', () {
    final kept = trimFontManifest(manifest, compiledApp);
    expect(names(kept), isNot(contains('packages/shadcn_ui/GeistMono')));
    final geist = kept.singleWhere(
      (family) => family['family'] == 'packages/shadcn_ui/Geist',
    );
    expect(
      [for (final font in geist['fonts'] as List) font['weight']],
      [400, 500, 600, 700, 800],
    );
  });

  test('leaves fonts it knows nothing about alone', () {
    expect(names(trimFontManifest(manifest, compiledApp)),
        contains('MaterialIcons'));
  });

  test('refuses to trim Geist when its weights are missing', () {
    final unweighted = [family('packages/shadcn_ui/Geist')];
    expect(() => trimFontManifest(unweighted, compiledApp), throwsStateError);
  });

  test('preloads the manifest and every font kept', () {
    const index = '<head>\n  $fontPreloadsMarker\n</head>';
    final html = addFontPreloads(index, ['fonts/A.otf', 'packages/b/B.ttf']);
    expect(html, isNot(contains(fontPreloadsMarker)));
    for (final path in [
      'FontManifest.json',
      'fonts/A.otf',
      'packages/b/B.ttf',
    ]) {
      expect(
        html,
        contains(
          '<link rel="preload" href="assets/$path" as="fetch" crossorigin>',
        ),
      );
    }
  });

  test('refuses an index.html with nowhere to put the preloads', () {
    expect(() => addFontPreloads('<head></head>', []), throwsStateError);
  });
}
