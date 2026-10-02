import 'dart:math' as math;
import 'dart:ui';

import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_map_projection.dart';
import 'package:icarus/widgets/draggable_widgets/ability/deadlock_barrier_mesh_widget.dart';

/// Which Icarus ability a replay utility actor is, and how to place it.
///
/// Null means the actor is not drawn: the projectile of an ability whose
/// lasting effect is its own actor, a cosmetic, or game bookkeeping.
ReplayAbilityEntry? replayAbilityFor(String classPath) =>
    _catalog[replayAssetName(classPath)];

/// The asset name of a class path, the part Riot names the blueprint by:
/// `/Game/Characters/Wraith/S0/Ability_4/Zone_Wraith_4_Smoke.Zone_Wraith_4_Smoke_C`
/// gives `Zone_Wraith_4_Smoke`. Folder layout moves between patches more
/// often than asset names do, so the catalog keys on this alone.
String replayAssetName(String classPath) =>
    classPath.split('/').last.split('.').first;

/// Every asset name the catalog maps, for tests and tooling.
Iterable<String> get replayAbilityAssetNames => _catalog.keys;

/// How the replay viewer draws a utility while it is active, beyond the
/// Icarus ability [ReplayAbilityEntry.place] gives it.
enum ReplayUtilityKind {
  /// An area centred on the utility: smokes, mollies, slows, reveal pulses.
  area,

  /// A placed device or moving bot shown as its icon: traps, cameras,
  /// Boom Bot. It follows the utility's path.
  marker,

  /// Cover or a wire running from a start to an end (Phoenix's Blaze,
  /// Viper's Toxic Screen, Cypher's Trapwire, Sage's Barrier Orb).
  wall,

  /// A directed area that starts at the utility and runs along its yaw
  /// (Breach's Fault Line, Fade's Nightfall).
  rectangle,

  /// Utility in flight whose effect has no lasting actor of its own
  /// (flashes, Paranoia, Showstopper's rocket).
  projectile,

  /// Deadlock's Barrier Mesh: arms out from a centre.
  barrierMesh,
}

class ReplayAbilityEntry {
  const ReplayAbilityEntry._(
    this.agent,
    this.abilityIndex,
    this.kind,
    this._placement,
  );

  final AgentType agent;

  /// Into `AgentData.agents[agent]!.abilities`, the index a saved ability
  /// persists. It follows the ability's icon and shape in Icarus, which for
  /// a few agents disagree with the display names in agents.dart.
  final int abilityIndex;
  final ReplayUtilityKind kind;
  final _Placement _placement;

  AbilityInfo get ability => AgentData.agents[agent]!.abilities[abilityIndex];

  /// The Icarus ability as it stands at [timeMs] (projectiles follow
  /// utility.positionAt).
  ///
  /// [PlacedAbility.position] is saved as the widget's top-left at the
  /// default marker size, so the shape's anchor ([storedAbilityAnchor]) is
  /// subtracted from the projected game point, exactly as a drop in the
  /// editor stores it.
  PlacedAbility place({
    required ReplayUtility utility,
    required ReplayMapProjection projection,
    required int timeMs,
    required String id,
    required bool isAlly,
  }) {
    final info = ability;
    final shape = info.abilityData!;
    final mapScale = Maps.mapScale[projection.map] ?? 1.0;
    final geometry = _placement.resolve(
      utility: utility,
      projection: projection,
      timeMs: timeMs,
      shape: shape,
      mapScale: mapScale,
    );
    final anchorOffset = CoordinateSystem.instance.virtualOffsetToWorld(
      storedAbilityAnchor(ability: shape, mapScale: mapScale),
    );
    return PlacedAbility(
      data: info,
      position: geometry.anchor - anchorOffset,
      id: id,
      isAlly: isAlly,
      rotation: geometry.rotation,
      length: geometry.length,
      armLengthsMeters: geometry.armLengthsMeters,
    );
  }
}

/// Where the ability's anchor lands, in canonical world units, and the
/// PlacedAbility geometry around it.
class _Geometry {
  const _Geometry(
    this.anchor, {
    this.rotation = 0,
    this.length = 0,
    this.armLengthsMeters,
  });

  final Offset anchor;
  final double rotation;
  final double length;
  final List<double>? armLengthsMeters;
}

sealed class _Placement {
  const _Placement();

  _Geometry resolve({
    required ReplayUtility utility,
    required ReplayMapProjection projection,
    required int timeMs,
    required Ability shape,
    required double mapScale,
  });
}

/// The utility is a point (a smoke, a molly, a trap, a bot) and the
/// ability's anchor, its centre or icon, sits where the utility is at the
/// moment.
class _AtPoint extends _Placement {
  const _AtPoint({this.yawOffset});

  /// Turns the ability to the utility's yaw plus this many degrees. Null
  /// leaves it unrotated, for shapes whose rotation means nothing.
  final double? yawOffset;

  @override
  _Geometry resolve({
    required ReplayUtility utility,
    required ReplayMapProjection projection,
    required int timeMs,
    required Ability shape,
    required double mapScale,
  }) {
    final at = utility.positionAt(timeMs);
    final yaw = utility.yaw;
    return _Geometry(
      projection.toWorld(at.x, at.y),
      rotation: yawOffset == null || yaw == null
          ? 0
          : projection.rotationForYaw(yaw + yawOffset!),
    );
  }
}

/// A wall or directed area that starts at the utility and runs one way.
///
/// With two or more shape points it runs from the first to the last. With
/// one, it runs from the utility to that point (a wire's far anchor). With
/// none, it starts at the utility and runs along its yaw plus [yawOffset].
/// Icarus anchors these squares at the caster, the ability's gap short of
/// the shape's near edge (the squares' widgets lay the area out that way),
/// so the anchor is set back by the gap and the near edge lands on the
/// start. A resizable square also takes its length from start to end.
class _FromStart extends _Placement {
  const _FromStart({this.yawOffset = 0});

  /// Degrees from the utility's yaw to the way the shape runs.
  final double yawOffset;

  @override
  _Geometry resolve({
    required ReplayUtility utility,
    required ReplayMapProjection projection,
    required int timeMs,
    required Ability shape,
    required double mapScale,
  }) {
    final points = utility.points;
    // A shape drawn by its points stays put; otherwise the start travels
    // with the utility (Paranoia, a moving cover).
    final startPoint =
        points.length >= 2 ? points.first : utility.positionAt(timeMs);
    final start = projection.toWorld(startPoint.x, startPoint.y);
    final endPoint = points.isEmpty ? null : points.last;
    final end =
        endPoint == null ? null : projection.toWorld(endPoint.x, endPoint.y);

    final double rotation;
    if (end != null && end != start) {
      rotation = _rotationToward(end - start);
    } else if (utility.yaw != null) {
      rotation = projection.rotationForYaw(utility.yaw! + yawOffset);
    } else {
      rotation = 0;
    }

    final coordinates = CoordinateSystem.instance;
    var nearEdge = 0.0;
    var length = 0.0;
    if (shape is SquareAbility) {
      nearEdge =
          coordinates.virtualLengthToWorld(shape.distanceBetweenAOE * mapScale);
      if (shape is ResizableSquareAbility && end != null) {
        length =
            (end - start).distance / coordinates.virtualLengthToWorld(mapScale);
      }
    }
    return _Geometry(
      start - _unitForRotation(rotation) * nearEdge,
      rotation: rotation,
      length: length,
    );
  }
}

/// Deadlock's Barrier Mesh: centred on the utility, with arms reaching to
/// the shape points (each deployer's replicated destination).
///
/// Icarus draws an arm of `n` at `n * AgentData.inGameMetersDiameter`, twice
/// the scale of its other ranges, so arms are converted through that same
/// helper and each end lands on its game destination. The game lays the
/// arms on the world diagonals; with no points, the default arms are turned
/// to match.
class _BarrierMesh extends _Placement {
  const _BarrierMesh();

  // Michel Giehl's ValorantReplayParser (MIT) has no Barrier Mesh
  // descriptor; the arms come from GameObject_CableJam_CableDeployer_
  // Precomputed's MulticastInitialize.Destination, observed in 13.00 replays.

  @override
  _Geometry resolve({
    required ReplayUtility utility,
    required ReplayMapProjection projection,
    required int timeMs,
    required Ability shape,
    required double mapScale,
  }) {
    final centre = projection.toWorld(utility.position.x, utility.position.y);
    double slotOffset(DeadlockBarrierMeshArm arm) => arm.angle + math.pi / 2;

    if (utility.points.isEmpty) {
      return _Geometry(
        centre,
        rotation: projection.rotationForYaw(45) -
            slotOffset(DeadlockBarrierMeshArm.topRight),
      );
    }

    final arms = [
      for (final point in utility.points)
        projection.toWorld(point.x, point.y) - centre,
    ];
    final rotation = _rotationToward(arms.first) -
        slotOffset(DeadlockBarrierMeshArm.topRight);
    final worldPerArmMeter = CoordinateSystem.instance.virtualLengthToWorld(
      deadlockBarrierMeshArmLengthVirtual(1, mapScale),
    );
    // A blocked arm has no deployer; it shows at the shortest Icarus allows.
    final lengths = List<double>.filled(
      DeadlockBarrierMeshArm.values.length,
      DeadlockBarrierMeshAbility.minArmLengthMeters,
    );
    for (final arm in arms) {
      final relative = _rotationToward(arm) - rotation;
      final slot = DeadlockBarrierMeshArm.values.reduce(
        (best, next) => _angleBetween(relative, slotOffset(next)) <
                _angleBetween(relative, slotOffset(best))
            ? next
            : best,
      );
      lengths[slot.index] = arm.distance / worldPerArmMeter;
    }
    return _Geometry(centre, rotation: rotation, armLengthsMeters: lengths);
  }
}

/// Icarus rotation for a world direction: 0 points up, clockwise positive.
double _rotationToward(Offset direction) =>
    math.atan2(direction.dy, direction.dx) + math.pi / 2;

Offset _unitForRotation(double rotation) =>
    Offset(math.sin(rotation), -math.cos(rotation));

double _angleBetween(double a, double b) {
  final difference = (a - b) % (2 * math.pi);
  return math.min(difference, 2 * math.pi - difference);
}

const _point = _AtPoint();
const _facing = _AtPoint(yawOffset: 0);
const _fromStart = _FromStart();

ReplayAbilityEntry _area(AgentType agent, int index) =>
    ReplayAbilityEntry._(agent, index, ReplayUtilityKind.area, _point);
ReplayAbilityEntry _marker(AgentType agent, int index) =>
    ReplayAbilityEntry._(agent, index, ReplayUtilityKind.marker, _point);
ReplayAbilityEntry _projectile(AgentType agent, int index) =>
    ReplayAbilityEntry._(agent, index, ReplayUtilityKind.projectile, _point);
ReplayAbilityEntry _wall(AgentType agent, int index) =>
    ReplayAbilityEntry._(agent, index, ReplayUtilityKind.wall, _fromStart);
ReplayAbilityEntry _rectangle(AgentType agent, int index) =>
    ReplayAbilityEntry._(agent, index, ReplayUtilityKind.rectangle, _fromStart);

// Keyed by asset name. Agents go by Riot's codenames in class paths (paired
// through valorant-api.com's developerName). The slot folder in a path
// (Ability_4, _Q, _E, _X) is not Icarus's order and differs per agent:
// Cypher's Trapwire lives in Ability_E, Sage's Barrier Orb in Ability_E.
// Agents marked "asset index" were absent from the replays we have; their
// entries come from the 13.05 package index and Michel Giehl's
// ValorantReplayParser (MIT) descriptors, and are unverified against data.
final Map<String, ReplayAbilityEntry> _catalog = {
  // Astra (Rift), asset index. Astra Star (index 4) has no actor we know of.
  'GameObject_Rift_4_BlackHole': _area(AgentType.astra, 0),
  'GameObject_Rift_Q_FlashBurst': _area(AgentType.astra, 1),
  'GameObject_Rift_E_SmokeZone': _area(AgentType.astra, 2),
  'GameObject_Rift_E_SmokeZone_Fake': _area(AgentType.astra, 2),
  'GameObject_Rift_X_GlobalWall': const ReplayAbilityEntry._(
      AgentType.astra, 3, ReplayUtilityKind.wall, _facing),

  // Breach. Rolling Thunder from the asset index.
  'GameObject_Breach_4_FusionBlast': _rectangle(AgentType.breach, 0),
  'Projectile_Breach_Q_ThroughWalls_Flash': _projectile(AgentType.breach, 1),
  'GameObject_Breach_E_SweetSpotFissure': _rectangle(AgentType.breach, 2),
  'GameObject_Breach_X_Shockwave': _rectangle(AgentType.breach, 3),

  // Brimstone (Sarge).
  'GameObject_Sarge_E_SpeedStim': _area(AgentType.brimstone, 0),
  'Patch_Sarge_Q_Molotov_Production': _area(AgentType.brimstone, 1),
  'GameObject_Sarge_4_Smoke_ProductionNEW': _area(AgentType.brimstone, 2),
  'GameObject_Sarge_X_OrbitalStrike_Production': _area(AgentType.brimstone, 3),

  // Chamber (Deadeye). Headhunter and Tour De Force are guns.
  'GameObject_Deadeye_E_Trap': _area(AgentType.chamber, 0),
  'Patch_Deadeye_E_Slow_Large': _area(AgentType.chamber, 0),
  'GameObject_Deadeye_E_Teleporter_Tether': _area(AgentType.chamber, 2),

  // Clove (Smonk). Pick-me-up and Not Dead Yet have no actor.
  'GameObject_Smonk_Q_DecayExplosion': _area(AgentType.clove, 1),
  'GameObject_Smonk_NewSmoke': _area(AgentType.clove, 2),
  'GameObject_Smonk_NewSmoke_PDS': _area(AgentType.clove, 2),

  // Cypher (Gumshoe). The Trapwire actor sits on its first anchor, its yaw
  // toward the second, which is the _SecondWire actor's position. Given
  // that as a shape point the wire runs to it; without one it runs along the
  // yaw at full length. The thrown cage never replicates where it lands
  // (its actor stays on Cypher), so only the cage zone is drawn.
  'GameObject_Gumshoe_E_TripWire': _wall(AgentType.cypher, 0),
  'Zone_Gumshoe_4_Cage': _area(AgentType.cypher, 1),
  'Pawn_Gumshoe_Q_PossessableCamera': _marker(AgentType.cypher, 2),
  'GameObject_RemovableObject_GumshoeTrackingDart':
      _marker(AgentType.cypher, 2),

  // Deadlock (Cable). Icarus index 0 draws GravNet and index 2 the Barrier
  // Mesh (by icon and shape), though agents.dart names them the other way.
  // Sonic Sensor's yaw faces out of the surface it is stuck to. Annihilation's
  // own actor stays on Deadlock; the cocoon is where it caught someone.
  'Patch_NetToss': _area(AgentType.deadlock, 0),
  'GameObject_StealthingTrap_SoundSensor': _rectangle(AgentType.deadlock, 1),
  'GameObject_SoundSensor_SweetSpotFissure': _rectangle(AgentType.deadlock, 1),
  'GameObject_CableJamRoot': const ReplayAbilityEntry._(
      AgentType.deadlock, 2, ReplayUtilityKind.barrierMesh, _BarrierMesh()),
  'GameObject_FishingHook_CageSphere': _marker(AgentType.deadlock, 3),

  // Fade (BountyHunter).
  'Pawn_BountyHunter_4_WolfHound': _marker(AgentType.fade, 0),
  'GameObject_Q_BountyHunter_Tether_SphereExpansion': _area(AgentType.fade, 1),
  'Projectile_E_BountyHunter_Divebomb': _projectile(AgentType.fade, 2),
  'GameObject_BountyHunter_E_LoSReveal_Source_Reactivate':
      _area(AgentType.fade, 2),
  'GameObject_BountyHunter_X_WaveForm': _rectangle(AgentType.fade, 3),

  // Gekko (AggroBot). Reclaim globules are left out: placing one as its
  // ability would draw Mosh Pit's circle where no Mosh Pit is.
  'Patch_Aggrobot_C_ExplodeyPatch': _area(AgentType.gekko, 0),
  'Pawn_Aggrobot_SeekerNade': _marker(AgentType.gekko, 1),
  'Projectile_E_Aggrobot_DiscTurret_PowerWave': _projectile(AgentType.gekko, 2),
  'Pawn_Aggrobot_RollyPolly': _marker(AgentType.gekko, 3),

  // Harbor (Mage), asset index. Icarus draws High Tide as its icon, so it
  // follows the wall's guided head (Giehl's MageWallDescriptor).
  'GameObject_Mage_4_SplashGrenade': _area(AgentType.harbor, 0),
  'Projectile_Mage_Q_Wall': _projectile(AgentType.harbor, 1),
  'GameObject_Mage_E_WorldSmoke': _area(AgentType.harbor, 2),
  'GameObject_Mage_X_TidalWave': _rectangle(AgentType.harbor, 3),

  // Iso (Sequoia).
  'GameObject_Sequoia_4_MovingCover': _rectangle(AgentType.iso, 0),
  'GameObject_Sequoia_4_MovingCover_Slower': _rectangle(AgentType.iso, 0),
  'Projectile_Sequoia_Q_FragileMissile': const ReplayAbilityEntry._(
      AgentType.iso, 1, ReplayUtilityKind.projectile, _fromStart),
  'GameObject_Sequoia_E_Orb': _marker(AgentType.iso, 2),
  'GameObject_Sequoia_X_LineCapture': _rectangle(AgentType.iso, 3),

  // Jett (Wushu). Updraft, Tailwind and Blade Storm have no lasting actor.
  'GameObject_Wushu_4_SmokeZone': _area(AgentType.jett, 0),

  // KAY/O (Grenadier). FRAG/ment and NULL/cmd from the asset index.
  'Projectile_Grenadier_Q_SemtexBasic': _projectile(AgentType.kayo, 0),
  'Projectile_C_Grenadier_Flash': _projectile(AgentType.kayo, 1),
  'Projectile_C_Grenadier_Flash_Underhand': _projectile(AgentType.kayo, 1),
  'Projectile_Grenadier_E_SuppressionBlade': _projectile(AgentType.kayo, 2),
  'Gameobject_Grenadier_E_SuppressionPulse': _area(AgentType.kayo, 2),
  'Gameobject_Grenadier_X_UltPulse': _area(AgentType.kayo, 3),

  // Killjoy.
  'Projectile_Killjoy_4_RemoteBees_MultiDetonate': _area(AgentType.killjoy, 0),
  'GameObject_Killjoy_4_BeeSwarm_Damage': _area(AgentType.killjoy, 0),
  'Pawn_Killjoy_Q_StealthAlarmbot': _area(AgentType.killjoy, 1),
  'Pawn_Killjoy_E_Turret': _area(AgentType.killjoy, 2),
  'GameObject_Killjoy_X_Bomb': _area(AgentType.killjoy, 3),

  // Miks (Iris). Icarus index 2 draws Waveform's smoke and index 3 is
  // Harmonize (by icon), though agents.dart names them the other way.
  // Harmonize is a buff with no actor.
  'GameObject_Thumper_Concuss': _area(AgentType.miks, 0),
  'GameObject_Thumper_Heal': _area(AgentType.miks, 1),
  'GameObject_Iris_E_Smoke': _area(AgentType.miks, 2),
  'GameObject_Iris_X_SonicWave': const ReplayAbilityEntry._(
      AgentType.miks, 4, ReplayUtilityKind.area, _facing),

  // Neon (Sprinter). High Gear and Overdrive have no actor.
  'GameObject_Sprinter_4_Tunnel': _wall(AgentType.neon, 0),
  'GameObject_Sprinter_Q_ElectricSphere': _area(AgentType.neon, 1),

  // Omen (Wraith). Shrouded Step has no actor.
  'Projectile_Wraith_Q_NearsightMissile': const ReplayAbilityEntry._(
      AgentType.omen, 1, ReplayUtilityKind.projectile, _fromStart),
  'Zone_Wraith_4_Smoke': _area(AgentType.omen, 2),
  'Intention_Wraith_X_GlobalTeleport': _marker(AgentType.omen, 3),

  // Phoenix. Icarus index 1 is Curveball and index 2 Hot Hands (by icon and
  // shape), though agents.dart names them the other way. Curveball's actors
  // stay on Phoenix and never replicate the flare's flight, so it is not
  // drawn.
  'GameObject_Phoenix_Q_FlameWallManager_Production':
      _wall(AgentType.pheonix, 0),
  'Patch_Phoenix_MolotovFire': _area(AgentType.pheonix, 2),
  'GameObject_Phoenix_X_ResTarget_Production': _marker(AgentType.pheonix, 3),

  // Raze (Clay).
  'Pawn_Clay_E_Boomba': _marker(AgentType.raze, 0),
  'Projectile_Clay_Q_Satchel_Arming': _marker(AgentType.raze, 1),
  'Projectile_Clay_4_Projectile_Primary': _projectile(AgentType.raze, 2),
  'Projectile_Clay_X_Rocket': _projectile(AgentType.raze, 3),

  // Reyna (Vampire). Devour and Dismiss spend soul orbs, which come from
  // kills, not from an ability; Empress has no actor.
  'GameObject_Vampire_4_NearsightAOE_Source': _marker(AgentType.reyna, 0),

  // Sage (Thorne). The wall's actor is its centre and the wall runs across
  // its yaw. Healing Orb and Resurrection have no actor.
  'GameObject_Thorne_E_Wall_Fortifying': const ReplayAbilityEntry._(
      AgentType.sage, 0, ReplayUtilityKind.wall, _AtPoint(yawOffset: 90)),
  'Patch_Thorne_4_SlowField_Production': _area(AgentType.sage, 1),

  // Skye (Guide).
  'GameObject_Guide_4_Heal_AOE': _area(AgentType.skye, 0),
  'Pawn_Guide_Q_PossessableScout': _marker(AgentType.skye, 1),
  'Projectile_Guide_E_HawkFlash': _projectile(AgentType.skye, 2),
  'GameObject_Guide_E_HawkFlash_FlashSource': _marker(AgentType.skye, 2),
  'Pawn_Guide_X_Pack': _marker(AgentType.skye, 3),

  // Sova (Hunter). Hunter's Fury has no actor.
  'Pawn_Hunter_E_Drone': _marker(AgentType.sova, 0),
  'GameObject_Hunter_E_Drone_RevealDart': _marker(AgentType.sova, 0),
  'GameObject_Hunter_4_ExplosiveBolt_Explosion': _area(AgentType.sova, 1),
  'GameObject_Hunter_Q_SonarBolt': _area(AgentType.sova, 2),

  // Tejo (Cashew). Explosions from the asset index.
  'Pawn_Cashew_4_Spider_LockOn': _marker(AgentType.tejo, 0),
  'GameObject_Cashew_4_SonarPing': _area(AgentType.tejo, 0),
  'Projectile_Cashew_Q_ShellShockGrenade': _projectile(AgentType.tejo, 1),
  'Projectile_Cashew_Q_ShellShockGrenade_Bounce':
      _projectile(AgentType.tejo, 1),
  'GameObject_Cashew_Q_ShellShockGrenade': _area(AgentType.tejo, 1),
  'GameObject_Cashew_E_MapMissileMarker': _area(AgentType.tejo, 2),
  'GameObject_Cashew_E_MapMissileMarker_SecondRocket': _area(AgentType.tejo, 2),
  'GameObject_Cashew_E_Explosion': _area(AgentType.tejo, 2),
  'GameObject_Cashew_X_SegmentManager': _rectangle(AgentType.tejo, 3),

  // Veto (Pine), asset index. Evolution is a self-buff with no actor.
  'GameObject_Pine_4_UsableTeleport': _area(AgentType.veto, 0),
  'GameObject_Pine_Q_SeizeTrap': _area(AgentType.veto, 1),
  'GameObject_Pine_Q_Tether_SphereExpansion': _area(AgentType.veto, 1),
  'Pawn_Pine_E_RadEater': _area(AgentType.veto, 2),

  // Viper (Pandemic), asset index. Toxic Screen's points come from its
  // manager's MulticastAddSmokeScreenPoint (Giehl's SmokeScreenManager).
  'Patch_Pandemic_AcidMolotov_NewMolotov': _area(AgentType.viper, 0),
  'GameObject_Pandemic_4_SmokeZone': _area(AgentType.viper, 1),
  'GameObject_Pandemic_E_SmokeScreenManager': _wall(AgentType.viper, 2),
  'Patch_Pandemic_X_Circular': _area(AgentType.viper, 3),

  // Vyse (Nox). Icarus index 0 draws Shear and index 1 Razorvine (by icon
  // and shape), though agents.dart names them the other way. Shear's armed
  // trap and its raised wall both sit on the wall's start; the trap's yaw
  // runs along the wall and the raised wall's faces across it.
  'GameObject_Nox_Wall': const ReplayAbilityEntry._(
      AgentType.vyse, 0, ReplayUtilityKind.wall, _FromStart(yawOffset: -90)),
  'GameObject_Nox_WallTrap': _wall(AgentType.vyse, 0),
  'GameObject_Nox_BarbedWire': _area(AgentType.vyse, 1),
  'Patch_Nox_BarbedWire': _area(AgentType.vyse, 1),
  'GameObject_Nox_StealthingTrap_Flash_2': _marker(AgentType.vyse, 2),
  'Gameobject_Nox_DisarmPulse': _area(AgentType.vyse, 3),

  // Waylay (Terra), asset index. Lightspeed has no actor.
  'GameObject_Terra_C_TimeSlowGrenade_Explosion': _area(AgentType.waylay, 0),
  'GameObject_Terra_E_RewindTime_RewindTarget': _marker(AgentType.waylay, 2),
  'GameObject_Terra_X_DelayedBeam_Beam': _rectangle(AgentType.waylay, 3),

  // Yoru (Stealth). Dimensional Drift has no actor.
  'Pawn_Stealth_4_Decoy_V2': _marker(AgentType.yoru, 0),
  'Projectile_Stealth_Q_BounceFlash': _projectile(AgentType.yoru, 1),
  'Pawn_Stealth_E_TeleporterMoving_FakeTP': _marker(AgentType.yoru, 2),
  'Pawn_Stealth_E_TeleporterStationary_FakeTP': _marker(AgentType.yoru, 2),
};
