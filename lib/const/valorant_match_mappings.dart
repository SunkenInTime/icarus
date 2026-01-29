import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';

class ValorantMapTransform {
  final double xMultiplier;
  final double yMultiplier;
  final double xScalarToAdd;
  final double yScalarToAdd;

  const ValorantMapTransform({
    required this.xMultiplier,
    required this.yMultiplier,
    required this.xScalarToAdd,
    required this.yScalarToAdd,
  });
}

class ValorantMatchMappings {
  /// Valorant match `matchInfo.mapId` values (also called `mapUrl`) -> MapValue.
  static const Map<String, MapValue> riotMapIdToMapValue = {
    '/Game/Maps/Ascent/Ascent': MapValue.ascent,
    '/Game/Maps/Bonsai/Bonsai': MapValue.bind,
    '/Game/Maps/Canyon/Canyon': MapValue.fracture,
    '/Game/Maps/Duality/Duality': MapValue.split,
    '/Game/Maps/Foxtrot/Foxtrot': MapValue.breeze,
    '/Game/Maps/Infinity/Infinity': MapValue.abyss,
    '/Game/Maps/Jam/Jam': MapValue.lotus,
    '/Game/Maps/Juliett/Juliett': MapValue.sunset,
    '/Game/Maps/Pitt/Pitt': MapValue.pearl,
    '/Game/Maps/Port/Port': MapValue.icebox,
    '/Game/Maps/Rook/Rook': MapValue.corrode,
    '/Game/Maps/Triad/Triad': MapValue.haven,
  };

  /// In-game coords -> minimap percent transform.
  ///
  /// u = (gameY * xMultiplier) + xScalarToAdd
  /// v = (gameX * yMultiplier) + yScalarToAdd
  static const Map<MapValue, ValorantMapTransform> mapTransforms = {
    MapValue.ascent: ValorantMapTransform(
      xMultiplier: 0.00007,
      yMultiplier: -0.00007,
      xScalarToAdd: 0.813895,
      yScalarToAdd: 0.573242,
    ),
    MapValue.bind: ValorantMapTransform(
      xMultiplier: 0.000078,
      yMultiplier: -0.000078,
      xScalarToAdd: 0.842188,
      yScalarToAdd: 0.697578,
    ),
    MapValue.breeze: ValorantMapTransform(
      xMultiplier: 0.00007,
      yMultiplier: -0.00007,
      xScalarToAdd: 0.465123,
      yScalarToAdd: 0.833078,
    ),
    MapValue.fracture: ValorantMapTransform(
      xMultiplier: 0.000078,
      yMultiplier: -0.000078,
      xScalarToAdd: 0.556952,
      yScalarToAdd: 1.155886,
    ),
    MapValue.split: ValorantMapTransform(
      xMultiplier: 0.000059,
      yMultiplier: -0.000059,
      xScalarToAdd: 0.576941,
      yScalarToAdd: 0.967566,
    ),
    MapValue.icebox: ValorantMapTransform(
      xMultiplier: 0.000072,
      yMultiplier: -0.000072,
      xScalarToAdd: 0.460214,
      yScalarToAdd: 0.304687,
    ),
    MapValue.lotus: ValorantMapTransform(
      xMultiplier: 0.000072,
      yMultiplier: -0.000072,
      xScalarToAdd: 0.454789,
      yScalarToAdd: 0.917752,
    ),
    MapValue.sunset: ValorantMapTransform(
      xMultiplier: 0.000078,
      yMultiplier: -0.000078,
      xScalarToAdd: 0.5,
      yScalarToAdd: 0.515625,
    ),
    MapValue.pearl: ValorantMapTransform(
      xMultiplier: 0.000078,
      yMultiplier: -0.000078,
      xScalarToAdd: 0.480469,
      yScalarToAdd: 0.916016,
    ),
    MapValue.abyss: ValorantMapTransform(
      xMultiplier: 0.000081,
      yMultiplier: -0.000081,
      xScalarToAdd: 0.5,
      yScalarToAdd: 0.5,
    ),
    MapValue.corrode: ValorantMapTransform(
      xMultiplier: 0.00007,
      yMultiplier: -0.00007,
      xScalarToAdd: 0.526158,
      yScalarToAdd: 0.5,
    ),
    MapValue.haven: ValorantMapTransform(
      xMultiplier: 0.000075,
      yMultiplier: -0.000075,
      xScalarToAdd: 1.09345,
      yScalarToAdd: 0.642728,
    ),
  };

  /// Some SVG assets in this project are rotated relative to Valorant's match
  /// coordinate/minimap orientation. For those maps, rotate imported match
  /// positions clockwise to match the displayed map.
  ///
  /// Value is clockwise quarter-turns: 0, 1 (90° CW), 2 (180°), 3 (270° CW).
  static const Map<MapValue, int> importCwQuarterTurns = {
    MapValue.abyss: 1,
    MapValue.ascent: 1,
    MapValue.corrode: 1,
    MapValue.haven: 1,
    MapValue.icebox: 1,
    MapValue.split: 1,
  };

  static int importTurnsForMap(MapValue map) {
    return importCwQuarterTurns[map] ?? 0;
  }

  /// Rotates a (u,v) point in a 0..1 coordinate space clockwise.
  ///
  /// Assumes u increases to the right and v increases downward.
  static ({double u, double v}) rotateUvCw({
    required double u,
    required double v,
    required int turns,
  }) {
    final t = turns % 4;
    if (t == 0) return (u: u, v: v);
    if (t == 1) return (u: 1.0 - v, v: u);
    if (t == 2) return (u: 1.0 - u, v: 1.0 - v);
    return (u: v, v: 1.0 - u);
  }

  /// Valorant `characterId` UUID -> AgentType.
  static const Map<String, AgentType> characterIdToAgentType = {
    'e370fa57-4757-3604-3648-499e1f642d3f': AgentType.gekko,
    'dade69b4-4f5a-8528-247b-219e5a1facd6': AgentType.fade,
    '5f8d3a7f-467b-97f3-062c-13acf203c006': AgentType.breach,
    'cc8b64c8-4b25-4ff9-6e7f-37b4da43d235': AgentType.deadlock,
    'b444168c-4e35-8076-db47-ef9bf368f384': AgentType.tejo,
    'f94c3b30-42be-e959-889c-5aa313dba261': AgentType.raze,
    '22697a3d-45bf-8dd7-4fec-84a9e28c69d7': AgentType.chamber,
    '601dbbe7-43ce-be57-2a40-4abd24953621': AgentType.kayo,
    '6f2a04ca-43e0-be17-7f36-b3908627744d': AgentType.skye,
    '117ed9e3-49f3-6512-3ccf-0cada7e3823b': AgentType.cypher,
    '320b2a48-4d9b-a075-30f1-1f93a9b638fa': AgentType.sova,
    '1e58de9c-4950-5125-93e9-a0aee9f98746': AgentType.killjoy,
    '95b78ed7-4637-86d9-7e41-71ba8c293152': AgentType.harbor,
    'efba5359-4016-a1e5-7626-b1ae76895940': AgentType.vyse,
    '707eab51-4836-f488-046a-cda6bf494859': AgentType.viper,
    'eb93336a-449b-9c1b-0a54-a891f7921d69': AgentType.pheonix,
    '92eeef5d-43b5-1d4a-8d03-b3927a09034b': AgentType.veto,
    '41fb69c1-4189-7b37-f117-bcaf1e96f1bf': AgentType.astra,
    '9f0d8ba9-4140-b941-57d3-a7ad57c6b417': AgentType.brimstone,
    '0e38b510-41a8-5780-5e8f-568b2a4f2d6c': AgentType.iso,
    '1dbf2edd-4729-0984-3115-daa5eed44993': AgentType.clove,
    'bb2a4828-46eb-8cd1-e765-15848195d751': AgentType.neon,
    '7f94d92c-4234-0a36-9646-3a87eb8b5c89': AgentType.yoru,
    'df1cb487-4902-002e-5c17-d28e83e78588': AgentType.waylay,
    '569fdd95-4d10-43ab-ca70-79becc718b46': AgentType.sage,
    'a3bfb853-43b2-7238-a4f1-ad90e9e46bcc': AgentType.reyna,
    '8e253930-4c05-31dd-1b6c-968525494517': AgentType.omen,
    'add6443a-41bd-e414-f6ad-e58d267f4e95': AgentType.jett,
  };

  static AgentType agentTypeFromCharacterId(String? characterId) {
    if (characterId == null) return AgentType.jett;
    return characterIdToAgentType[characterId.toLowerCase()] ?? AgentType.jett;
  }

  static MapValue? mapValueFromMatchMapId(String? mapId) {
    if (mapId == null) return null;
    return riotMapIdToMapValue[mapId];
  }

  static ValorantMapTransform? transformForMap(MapValue map) {
    return mapTransforms[map];
  }
}
