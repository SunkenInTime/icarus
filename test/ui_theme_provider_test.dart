import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/providers/ui_theme_provider.dart';
import 'package:icarus/theme/ui_theme_tokens.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('icarus_ui_theme_test_');
    Hive.init(tempDir.path);
    await Hive.openBox<String>(HiveBoxNames.uiThemeProfilesBox);
    await Hive.openBox<String>(HiveBoxNames.uiThemePrefsBox);
  });

  tearDown(() async {
    await Hive.box<String>(HiveBoxNames.uiThemeProfilesBox).clear();
    await Hive.box<String>(HiveBoxNames.uiThemePrefsBox).clear();
    await UiThemeProvider.bootstrap();
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('profile CRUD and active profile switching works', () async {
    await UiThemeProvider.bootstrap();
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(uiThemeProvider.notifier);
    final initial = container.read(uiThemeProvider);

    expect(initial.activeProfile.id, UiThemeProvider.builtInProfileId);

    await notifier.createProfileFromActive(name: 'My Theme');
    final createdState = container.read(uiThemeProvider);
    final customProfile = createdState.activeProfile;

    expect(customProfile.name, 'My Theme');
    expect(customProfile.isBuiltIn, isFalse);

    await notifier.renameProfile(
      profileId: customProfile.id,
      newName: 'Renamed Theme',
    );

    final renamedState = container.read(uiThemeProvider);
    expect(renamedState.activeProfile.name, 'Renamed Theme');

    await notifier.deleteProfile(customProfile.id);
    final afterDelete = container.read(uiThemeProvider);
    expect(afterDelete.activeProfile.id, UiThemeProvider.builtInProfileId);
  });

  test(
      'bootstrap ensures both built-ins and defaults active to Tactical Violet',
      () async {
    await UiThemeProvider.bootstrap();
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final state = container.read(uiThemeProvider);
    final ids = state.profiles.map((p) => p.id).toSet();
    expect(ids.contains(UiThemeProvider.builtInProfileId), isTrue);
    expect(
      ids.contains(UiThemeProvider.builtInDesignerContextProfileId),
      isTrue,
    );
    expect(state.activeProfileId, UiThemeProvider.builtInProfileId);
  });

  test('bootstrap recreates missing built-in profile', () async {
    await UiThemeProvider.bootstrap();
    final profilesBox = Hive.box<String>(HiveBoxNames.uiThemeProfilesBox);
    await profilesBox.delete(UiThemeProvider.builtInDesignerContextProfileId);

    await UiThemeProvider.bootstrap();
    final restored =
        profilesBox.get(UiThemeProvider.builtInDesignerContextProfileId);
    expect(restored, isNotNull);
  });

  test('bootstrap does not override valid existing active profile', () async {
    await UiThemeProvider.bootstrap();
    await Hive.box<String>(HiveBoxNames.uiThemePrefsBox).put(
      UiThemeProvider.activeProfileKey,
      UiThemeProvider.builtInDesignerContextProfileId,
    );

    await UiThemeProvider.bootstrap();

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final state = container.read(uiThemeProvider);
    expect(
      state.activeProfileId,
      UiThemeProvider.builtInDesignerContextProfileId,
    );
  });

  test('color and shadow edits propagate reactively', () async {
    await UiThemeProvider.bootstrap();
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(uiThemeProvider.notifier);

    await notifier.createProfileFromActive(name: 'Editable Theme');

    await notifier.updateColorToken(
      tokenId: UiThemeTokenIds.shadPrimary,
      colorValue: 0xFF123456,
    );
    await notifier.updateShadowToken(
      tokenId: UiThemeTokenIds.shadowCard,
      layers: const [
        UiShadowLayerDefinition(
          colorValue: 0xAA010203,
          blurRadius: 11,
          spreadRadius: 1,
          offsetX: 2,
          offsetY: 3,
        ),
      ],
    );

    final effective = container.read(effectiveUiThemeProvider);
    expect(effective.color(UiThemeTokenIds.shadPrimary).toARGB32(), 0xFF123456);
    final shadow = effective.shadowLayers(UiThemeTokenIds.shadowCard).first;
    expect(shadow.colorValue, 0xAA010203);
    expect(shadow.blurRadius, 11);
  });

  test('designer context built-in has expected imported token values',
      () async {
    await UiThemeProvider.bootstrap();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(uiThemeProvider.notifier);

    await notifier
        .setActiveProfile(UiThemeProvider.builtInDesignerContextProfileId);
    final effective = container.read(effectiveUiThemeProvider);

    expect(
        effective.color(UiThemeTokenIds.shadBackground).toARGB32(), 0xFFFFFFFF);
    expect(
        effective.color(UiThemeTokenIds.shadForeground).toARGB32(), 0xFF09090B);
    expect(effective.color(UiThemeTokenIds.shadCard).toARGB32(), 0xFFF4F4F5);
    expect(effective.color(UiThemeTokenIds.shadCardForeground).toARGB32(),
        0xFF18181B);
    expect(effective.color(UiThemeTokenIds.shadPopover).toARGB32(), 0xFFFFFFFF);
    expect(
      effective.color(UiThemeTokenIds.shadPopoverForeground).toARGB32(),
      0xFF18181B,
    );
    expect(
        effective.color(UiThemeTokenIds.shadSecondary).toARGB32(), 0xFFE4E4E7);
    expect(effective.color(UiThemeTokenIds.shadMuted).toARGB32(), 0xFFF4F4F5);
    expect(
      effective.color(UiThemeTokenIds.shadMutedForeground).toARGB32(),
      0xFF71717A,
    );
    expect(effective.color(UiThemeTokenIds.shadPrimary).toARGB32(), 0xFF7C3AED);
    expect(
      effective.color(UiThemeTokenIds.shadPrimaryForeground).toARGB32(),
      0xFFF9FAFB,
    );
    expect(effective.color(UiThemeTokenIds.shadRing).toARGB32(), 0xFF7C3AED);
    expect(
        effective.color(UiThemeTokenIds.shadSelection).toARGB32(), 0xFFEDE9FE);
    expect(effective.color(UiThemeTokenIds.shadDestructive).toARGB32(),
        0xFFEF4444);
    expect(
      effective.color(UiThemeTokenIds.shadDestructiveForeground).toARGB32(),
      0xFFFAFAFA,
    );
    expect(effective.color(UiThemeTokenIds.shadBorder).toARGB32(), 0xFFD4D4D8);
    expect(effective.color(UiThemeTokenIds.shadInput).toARGB32(), 0xFFD4D4D8);
    expect(
        effective.color(UiThemeTokenIds.sidebarSurface).toARGB32(), 0xFFEDE9FE);
    expect(
      effective.color(UiThemeTokenIds.sidebarHighlight).toARGB32(),
      0xFFD4D4D8,
    );
    expect(effective.color(UiThemeTokenIds.abilityBg).toARGB32(), 0xFFE4E4E7);
    expect(effective.color(UiThemeTokenIds.enemyBg).toARGB32(), 0xFFFDE8E8);
    expect(effective.color(UiThemeTokenIds.allyBg).toARGB32(), 0xFFDCFCE7);
    expect(
        effective.color(UiThemeTokenIds.enemyOutline).toARGB32(), 0xFFFCA5A5);
    expect(effective.color(UiThemeTokenIds.allyOutline).toARGB32(), 0xFF6EE7B7);
  });

  test('designer context inherits defaults for unspecified tokens', () async {
    await UiThemeProvider.bootstrap();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(uiThemeProvider.notifier);

    await notifier
        .setActiveProfile(UiThemeProvider.builtInDesignerContextProfileId);
    final effective = container.read(effectiveUiThemeProvider);
    final defaults = UiThemeTokenRegistry.defaultColorMap();

    expect(
      effective.color(UiThemeTokenIds.tagBlue).toARGB32(),
      defaults[UiThemeTokenIds.tagBlue],
    );
    expect(
      effective.color(UiThemeTokenIds.mapBackdropCenter).toARGB32(),
      defaults[UiThemeTokenIds.mapBackdropCenter],
    );
  });

  test('export payload includes ui colors, ui shadows, and map colors',
      () async {
    await UiThemeProvider.bootstrap();
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(uiThemeProvider.notifier);
    await notifier.updateColorToken(
      tokenId: UiThemeTokenIds.shadPrimary,
      colorValue: 0xFFABCDEF,
    );

    final jsonString = notifier.exportActiveThemeJson(
      mapColors: const {
        'base': '#112233',
        'detail': '#223344',
        'highlight': '#334455',
      },
    );

    final decoded = jsonDecode(jsonString) as Map<String, dynamic>;
    expect(decoded['profile'], isA<Map>());
    expect(decoded['uiColors'], isA<Map>());
    expect(decoded['uiShadows'], isA<Map>());
    expect(decoded['mapColors'], isA<Map>());

    final uiColors = Map<String, dynamic>.from(decoded['uiColors'] as Map);
    expect(uiColors[UiThemeTokenIds.shadPrimary], '#ABCDEF');

    final mapColors = Map<String, dynamic>.from(decoded['mapColors'] as Map);
    expect(mapColors['base'], '#112233');
    expect(mapColors['detail'], '#223344');
    expect(mapColors['highlight'], '#334455');
  });
}
