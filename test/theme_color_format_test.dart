import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/theme/theme_color_format.dart';

void main() {
  test('parses 6-digit hex and exports without alpha when opaque', () {
    final color = ThemeColorFormat.parseHex('#7C3AED');
    expect(color, isNotNull);
    expect(color!.toARGB32(), 0xFF7C3AED);
    expect(ThemeColorFormat.toHex(color), '#7C3AED');
  });

  test('parses 8-digit hex with alpha and exports with alpha', () {
    final color = ThemeColorFormat.parseHex('#807C3AED');
    expect(color, isNotNull);
    expect(color!.toARGB32(), 0x807C3AED);
    expect(ThemeColorFormat.toHex(color), '#807C3AED');
  });

  test('parses hsl and hsla', () {
    final hsl = ThemeColorFormat.parseHsl('hsl(0, 100%, 50%)');
    expect(hsl, isNotNull);
    expect((hsl!.r * 255).round(), 255);
    expect((hsl.g * 255).round(), 0);
    expect((hsl.b * 255).round(), 0);

    final hsla = ThemeColorFormat.parseHsl('hsla(240, 100%, 50%, 0.5)');
    expect(hsla, isNotNull);
    expect((hsla!.b * 255).round(), 255);
    expect(hsla.a, closeTo(0.5, 0.01));
  });

  test('rejects invalid color strings', () {
    expect(ThemeColorFormat.parseHex('#XYZXYZ'), isNull);
    expect(ThemeColorFormat.parseHsl('hsl(abc)'), isNull);
    expect(ThemeColorFormat.parseFlexible('nope'), isNull);
  });
}
