import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/traversal_speed.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:path/path.dart' as path;

const _fixtureName = 'canvas-compatibility-v97.ica';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Archive archive;
  late Map<String, dynamic> payload;
  late List<Map<String, dynamic>> pages;

  setUpAll(() async {
    final fixture = File(
      path.join(
        Directory.current.path,
        'test',
        'fixtures',
        'strategy_integrity',
        _fixtureName,
      ),
    );
    archive = ZipDecoder().decodeBytes(await fixture.readAsBytes());
    final jsonEntry = archive.files.singleWhere(
      (entry) => path.extension(entry.name).toLowerCase() == '.json',
    );
    payload = jsonDecode(
      utf8.decode(jsonEntry.content as List<int>),
    ) as Map<String, dynamic>;
    pages = (payload['pages'] as List<dynamic>)
        .map((page) => Map<String, dynamic>.from(page as Map))
        .toList(growable: false);
  });

  test('is a frozen, importable v97 strategy', () async {
    expect(payload['versionNumber'], '97');
    expect(97, lessThanOrEqualTo(Settings.versionNumber));
    expect(payload['mapData'], 'ascent');
    expect(pages, hasLength(20));

    for (final page in pages) {
      final imported = await StrategyPage.fromJson(
        json: page,
        strategyID: 'canvas-compatibility-import',
        isZip: true,
      );
      expect(imported.name, page['name']);
      expect(imported.isAutoNamed, isFalse);
    }
  });

  test('contains every current agent and ability', () {
    final agents = _entries(pages, 'agentData');
    final actualAgentTypes =
        agents.map((agent) => agent['type'] as String).toSet();
    expect(
      actualAgentTypes,
      AgentType.values.map((type) => type.name).toSet(),
    );
    expect(
      agents.map((agent) => agent['kind'] as String? ?? 'plain').toSet(),
      {'plain', 'viewCone', 'circle'},
    );
    expect(agents.any((agent) => agent['isAlly'] == false), isTrue);
    expect(agents.any((agent) => agent['state'] == 'dead'), isTrue);

    final expectedAbilities = <String>{
      for (final type in AgentType.values)
        for (final info in AgentData.agents[type]!.abilities)
          '${type.name}:${info.index}',
    };
    final actualAbilities = _entries(pages, 'abilityData')
        .map((ability) => Map<String, dynamic>.from(ability['data'] as Map))
        .map((data) => '${data['type']}:${data['index']}')
        .toSet();
    expect(actualAbilities, expectedAbilities);
  });

  test('covers utility, drawing, visibility, and side variants', () {
    final utilities = _entries(pages, 'utilityData');
    expect(
      utilities.map((utility) => utility['type'] as String).toSet(),
      UtilityType.values.map((type) => type.name).toSet(),
    );
    expect(
      utilities.any(
        (utility) => (utility['rotation'] as num).toDouble().abs() > 0.01,
      ),
      isTrue,
    );
    expect(
      utilities.any((utility) => utility['visionElevation'] != null),
      isTrue,
    );

    final drawings = _entries(pages, 'drawingData');
    expect(
      drawings.map((drawing) => drawing['type'] as String).toSet(),
      {
        'freeDrawing',
        'lineDrawing',
        'rectangleDrawing',
        'ellipseDrawing',
      },
    );
    expect(
      drawings
          .where((drawing) => drawing['showTraversalTime'] == true)
          .map((drawing) => drawing['traversalSpeedProfile'] as String)
          .toSet(),
      TraversalSpeedProfile.values.map((profile) => profile.name).toSet(),
    );

    final visualStates = _entries(pages, 'abilityData')
        .map((ability) => ability['visualState'])
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .toList(growable: false);
    for (final field in const [
      'showRangeOutline',
      'showRangeFill',
      'showInnerOutline',
      'showInnerFill',
      'showVisionCone',
    ]) {
      expect(visualStates.any((state) => state[field] == true), isTrue);
      expect(visualStates.any((state) => state[field] == false), isTrue);
    }

    expect(pages.any((page) => page['isAttack'] == 'true'), isTrue);
    expect(pages.any((page) => page['isAttack'] == 'false'), isTrue);
    expect(
      pages.any(
        (page) => (page['settings'] as Map)['useNeutralTeamColors'] == true,
      ),
      isTrue,
    );
  });

  test('covers dynamic text, embedded images, and lineup groups', () {
    final text = _entries(pages, 'textData');
    expect(text.any((entry) => entry['text'] == ''), isTrue);
    expect(
      text.any((entry) => (entry['text'] as String).contains('\n')),
      isTrue,
    );
    expect(
      text.map((entry) => (entry['size'] as num).toDouble()).toSet(),
      containsAll(<double>{90, 460}),
    );
    expect(text.any((entry) => entry['tagColorValue'] != null), isTrue);

    final images = _entries(pages, 'imageData');
    expect(
      images.map((entry) => (entry['aspectRatio'] as num).toDouble()).toSet(),
      containsAll(<double>{1, 16 / 9, 9 / 16, 2}),
    );
    expect(
      images.map((entry) => (entry['scale'] as num).toDouble()).toSet(),
      containsAll(<double>{90, 185, 460}),
    );
    final archiveFiles = archive.files.map((entry) => entry.name).toSet();
    for (final image in images) {
      expect(
        archiveFiles,
        contains('${image['id']}${image['fileExtension']}'),
      );
    }
    expect(archiveFiles, contains('lineup-reference.png'));

    final groups = _entries(pages, 'lineUpGroups');
    expect(groups, isNotEmpty);
    expect(
      groups.any((group) => (group['items'] as List<dynamic>).length >= 3),
      isTrue,
    );
    expect(
      groups
          .expand((group) => group['items'] as List<dynamic>)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .any((item) => (item['notes'] as String).isNotEmpty),
      isTrue,
    );
  });

  test('attack and defense mirror pages store identical canonical content', () {
    final attack = _pageNamed(pages, 'Canonical mirror - attack');
    final defense = _pageNamed(pages, 'Canonical mirror - defense');
    expect(attack['isAttack'], 'true');
    expect(defense['isAttack'], 'false');
    expect(_pageContent(defense), _pageContent(attack));

    final positions = [
      ..._entries([attack], 'agentData'),
      ..._entries([attack], 'abilityData'),
      ..._entries([attack], 'textData'),
      ..._entries([attack], 'imageData'),
      ..._entries([attack], 'utilityData'),
    ].map((entry) => Map<String, dynamic>.from(entry['position'] as Map));
    expect(
      positions.any((position) => (position['dx'] as num) < 100),
      isTrue,
    );
    expect(
      positions.any((position) => (position['dx'] as num) > 1400),
      isTrue,
    );
  });

  test('defense transition pair covers move, appear, and disappear', () {
    final start = _pageNamed(pages, 'Defense transition A');
    final end = _pageNamed(pages, 'Defense transition B');
    final startIds = _canvasIds(start);
    final endIds = _canvasIds(end);

    expect(startIds.intersection(endIds), isNotEmpty);
    expect(startIds.difference(endIds), isNotEmpty);
    expect(endIds.difference(startIds), isNotEmpty);

    final startAgent = _entryWithId(start, 'agentData', 'transition-agent');
    final endAgent = _entryWithId(end, 'agentData', 'transition-agent');
    expect(endAgent['position'], isNot(startAgent['position']));

    final startAbility =
        _entryWithId(start, 'abilityData', 'transition-ability');
    final endAbility = _entryWithId(end, 'abilityData', 'transition-ability');
    expect(endAbility['rotation'], isNot(startAbility['rotation']));
  });
}

Iterable<Map<String, dynamic>> _entries(
  Iterable<Map<String, dynamic>> pages,
  String key,
) sync* {
  for (final page in pages) {
    for (final entry in page[key] as List<dynamic>) {
      yield Map<String, dynamic>.from(entry as Map);
    }
  }
}

Map<String, dynamic> _pageNamed(
  List<Map<String, dynamic>> pages,
  String suffix,
) {
  return pages.singleWhere(
    (page) => (page['name'] as String).endsWith(suffix),
  );
}

Map<String, dynamic> _pageContent(Map<String, dynamic> page) {
  return Map<String, dynamic>.from(page)
    ..remove('id')
    ..remove('sortIndex')
    ..remove('name')
    ..remove('isAttack');
}

Set<String> _canvasIds(Map<String, dynamic> page) {
  return {
    for (final key in const [
      'drawingData',
      'agentData',
      'abilityData',
      'textData',
      'imageData',
      'utilityData',
    ])
      for (final entry in page[key] as List<dynamic>)
        (entry as Map)['id'] as String,
  };
}

Map<String, dynamic> _entryWithId(
  Map<String, dynamic> page,
  String key,
  String id,
) {
  return (page[key] as List<dynamic>)
      .map((entry) => Map<String, dynamic>.from(entry as Map))
      .singleWhere((entry) => entry['id'] == id);
}
