import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/replay/replay_ability_catalog.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_map_projection.dart';
import 'package:icarus/widgets/draggable_widgets/ability/deadlock_barrier_mesh_widget.dart';

void main() {
  late CoordinateSystem coordinates;

  setUp(() {
    coordinates = CoordinateSystem(playAreaSize: const Size(1600, 900));
  });

  ReplayUtility utility(
    String classPath, {
    required ReplayVector position,
    double? yaw,
    List<ReplayVector> points = const [],
    List<ReplayPathPoint> path = const [],
  }) =>
      ReplayUtility(
        id: 1,
        classPath: classPath,
        spawnMs: 1000,
        position: position,
        yaw: yaw,
        points: points,
        path: path,
      );

  PlacedAbility place(
    ReplayUtility utility,
    ReplayMapProjection projection, {
    int timeMs = 1000,
  }) =>
      replayAbilityFor(utility.classPath)!.place(
        utility: utility,
        projection: projection,
        timeMs: timeMs,
        id: 'u',
        isAlly: true,
      );

  double mapScaleOf(ReplayMapProjection projection) =>
      Maps.mapScale[projection.map]!;

  /// Where the editor draws the ability's anchor, in screen pixels.
  Offset drawnAnchor(PlacedAbility ability, ReplayMapProjection projection) =>
      screenAnchorForAbility(
        ability: ability,
        coordinateSystem: coordinates,
        mapScale: mapScaleOf(projection),
      );

  Offset screenOf(ReplayMapProjection projection, ReplayVector point) =>
      coordinates.coordinateToScreen(projection.toWorld(point.x, point.y));

  Offset unitFor(double rotation) =>
      Offset(math.sin(rotation), -math.cos(rotation));

  /// Screen distance from a square's anchor to the near edge of its area.
  double anchorToNearEdge(SquareAbility shape, double mapScale) =>
      coordinates.scale(
        storedAbilityAnchor(ability: shape, mapScale: mapScale).dy -
            shape.height * mapScale,
      );

  Matcher near(Offset expected, {double pixels = 1}) => predicate<Offset>(
        (actual) => (actual - expected).distance <= pixels,
        'within $pixels px of $expected',
      );

  group('class paths seen in the 13.00 replays', () {
    test('map onto the Icarus ability they draw', () {
      for (final MapEntry(key: path, value: (agent, index))
          in observedMapped.entries) {
        final entry = replayAbilityFor(path);
        expect(entry, isNotNull, reason: path);
        expect((entry!.agent, entry.abilityIndex), (agent, index),
            reason: path);
      }
    });

    test('leave projectiles, cosmetics and bookkeeping out', () {
      for (final path in observedIgnored) {
        expect(replayAbilityFor(path), isNull, reason: path);
      }
    });
  });

  test('every entry points at a real Icarus ability', () {
    for (final asset in replayAbilityAssetNames) {
      final entry = replayAbilityFor(asset)!;
      final abilities = AgentData.agents[entry.agent]!.abilities;
      expect(entry.abilityIndex, inInclusiveRange(0, abilities.length - 1),
          reason: asset);
      expect(entry.ability.abilityData, isNotNull, reason: asset);
    }
  });

  test('every Icarus agent has utility in the catalog', () {
    final covered = {
      for (final asset in replayAbilityAssetNames)
        replayAbilityFor(asset)!.agent,
    };
    expect(covered, containsAll(AgentType.values));
  });

  test('rectangles draw as Icarus squares, which run from their start', () {
    for (final asset in replayAbilityAssetNames) {
      final entry = replayAbilityFor(asset)!;
      if (entry.kind != ReplayUtilityKind.rectangle) continue;
      expect(entry.ability.abilityData, isA<SquareAbility>(), reason: asset);
    }
  });

  test('every entry places on a map', () {
    final projection = ReplayMapProjection.forMap(MapValue.ascent);
    for (final asset in replayAbilityAssetNames) {
      final placed = place(
        utility(
          '/Game/Characters/X/S0/$asset.${asset}_C',
          position: const ReplayVector(1000, 2000, 100),
          yaw: 30,
          points: const [
            ReplayVector(1000, 2000, 100),
            ReplayVector(1500, 2500, 100),
          ],
        ),
        projection,
      );
      expect(placed.position.dx.isFinite && placed.position.dy.isFinite, isTrue,
          reason: asset);
      expect(placed.rotation.isFinite, isTrue, reason: asset);
    }
  });

  test('a smoke centres on the projected game position', () {
    // Jett's Cloudburst on Sunset.
    final projection = ReplayMapProjection.forMap(MapValue.sunset);
    const at = ReplayVector(-2100, -3600, 166);
    final smoke = place(
      utility(
        '/Game/Characters/Wushu/S0/Ability_4/GameObject_Wushu_4_SmokeZone.'
        'GameObject_Wushu_4_SmokeZone_C',
        position: at,
        yaw: 120,
      ),
      projection,
    );

    expect((smoke.data.type, smoke.data.index), (AgentType.jett, 0));
    expect(drawnAnchor(smoke, projection), near(screenOf(projection, at)));
    // A dropped ability saves its top-left, not its centre.
    expect((smoke.position - projection.toWorld(at.x, at.y)).distance,
        greaterThan(1));
  });

  test('a marker follows its path to where it is at the moment', () {
    final projection = ReplayMapProjection.forMap(MapValue.split);
    const later = ReplayVector(1200, 400, 300);
    final bot = utility(
      '/Game/Characters/Clay/S0/Ability_E/Pawn_Clay_E_Boomba.'
      'Pawn_Clay_E_Boomba_C',
      position: const ReplayVector(800, 400, 300),
      path: const [ReplayPathPoint(2000, later)],
    );

    expect(drawnAnchor(place(bot, projection, timeMs: 2500), projection),
        near(screenOf(projection, later)));
  });

  test("Sage's wall centres on its actor and runs across its yaw", () {
    // c8989335 (Split) at 79558 ms. Its four 2.6 m segments sit at
    // yaw +/- 90 degrees, 1.3 m and 3.9 m out.
    final projection = ReplayMapProjection.forMap(MapValue.split);
    const at = ReplayVector(6432.3, -7824.8, 100);
    final wall = place(
      utility(
        '/Game/Characters/Thorne/S0/Ability_E/GameObject_Thorne_E_Wall_'
        'Fortifying.GameObject_Thorne_E_Wall_Fortifying_C',
        position: at,
        yaw: 347.68,
      ),
      projection,
    );

    expect(drawnAnchor(wall, projection), near(screenOf(projection, at)));
    expect(
        wall.rotation, closeTo(projection.rotationForYaw(347.68 + 90), 1e-9));
  });

  test("Neon's Fast Lane runs from its first tunnel point to its last", () {
    // c8989335 (Split), the tunnel at 57646 ms.
    final projection = ReplayMapProjection.forMap(MapValue.split);
    const start = ReplayVector(6081, -4858, 210);
    const end = ReplayVector(6399, -8218, 170);
    final lane = place(
      utility(
        '/Game/Characters/Sprinter/S0/Ability_4/GameObject_Sprinter_4_Tunnel.'
        'GameObject_Sprinter_4_Tunnel_C',
        position: start,
        yaw: 275.4,
        points: const [start, ReplayVector(6093, -4983, 210), end],
      ),
      projection,
    );
    final shape = lane.data.abilityData! as ResizableSquareAbility;
    final mapScale = mapScaleOf(projection);
    final anchor = drawnAnchor(lane, projection);
    final direction = unitFor(lane.rotation);
    final nearEdge = anchorToNearEdge(shape, mapScale);
    final drawnLength =
        coordinates.scale(shape.resolveLength(lane.length) * mapScale);

    expect(anchor + direction * nearEdge, near(screenOf(projection, start)));
    expect(anchor + direction * (nearEdge + drawnLength),
        near(screenOf(projection, end)));
  });

  test("Breach's Fault Line starts at the fissure and runs along its yaw", () {
    // dc078274 (Sunset): the fissure spawns 8 m ahead of Breach, on yaw.
    final projection = ReplayMapProjection.forMap(MapValue.sunset);
    const at = ReplayVector(955, -1412, 300);
    final fissure = place(
      utility(
        '/Game/Characters/Breach/S0/Ability_E/GameObject_Breach_E_SweetSpot'
        'Fissure.GameObject_Breach_E_SweetSpotFissure_C',
        position: at,
        yaw: 270.3,
      ),
      projection,
    );
    final shape = fissure.data.abilityData! as SquareAbility;
    final nearEdge = anchorToNearEdge(shape, mapScaleOf(projection));

    expect(fissure.rotation, closeTo(projection.rotationForYaw(270.3), 1e-9));
    expect(
        drawnAnchor(fissure, projection) + unitFor(fissure.rotation) * nearEdge,
        near(screenOf(projection, at)));
  });

  test("Deadlock's Barrier Mesh arms reach each deployer's destination", () {
    // 1fb53a2c (Summit) at 64113 ms: the root and its four
    // CableDeployer MulticastInitialize.Destination values.
    final projection = ReplayMapProjection.forMap(MapValue.summit);
    const root = ReplayVector(7828.8, 2866.4, 157.6);
    const destinations = [
      ReplayVector(8181.6, 3219.3, 101.7),
      ReplayVector(7624.5, 3070.7, 101.1),
      ReplayVector(7419.9, 2457.6, 97.7),
      ReplayVector(8495.3, 2200.0, 100.0),
    ];
    final mesh = place(
      utility(
        '/Game/Characters/Cable/S0/Ability_E/GameObject_CableJamRoot.'
        'GameObject_CableJamRoot_C',
        position: root,
        points: destinations,
      ),
      projection,
    );
    final mapScale = mapScaleOf(projection);
    final centre = drawnAnchor(mesh, projection);
    final ends = [
      for (final arm in DeadlockBarrierMeshArm.values)
        centre +
            _rotate(arm.unitVector, mesh.rotation) *
                coordinates.scale(deadlockBarrierMeshArmLengthVirtual(
                  mesh.armLengthsMeters[arm.index],
                  mapScale,
                )),
    ];

    expect((mesh.data.type, mesh.data.index), (AgentType.deadlock, 2));
    expect(centre, near(screenOf(projection, root)));
    for (final destination in destinations) {
      final target = screenOf(projection, destination);
      final closest = ends.reduce(
          (a, b) => (a - target).distance <= (b - target).distance ? a : b);
      expect(closest, near(target));
    }
  });
}

/// Turns [vector] clockwise on screen, as Transform.rotate does.
Offset _rotate(Offset vector, double angle) => Offset(
      vector.dx * math.cos(angle) - vector.dy * math.sin(angle),
      vector.dx * math.sin(angle) + vector.dy * math.cos(angle),
    );

// Every utility class path in the seven 13.00 replays in
// AppData/Local/VALORANT/Saved/Demos (vrfkit 0.2.5 actors.parquet), with the
// Icarus ability it draws as.
const observedMapped = <String, (AgentType, int)>{
  '/Game/Characters/AggroBot/S0/Ability_4/Patch_Aggrobot_C_ExplodeyPatch.Patch_Aggrobot_C_ExplodeyPatch_C':
      (AgentType.gekko, 0),
  '/Game/Characters/AggroBot/S0/Ability_E/Projectile_E_Aggrobot_DiscTurret_PowerWave.Projectile_E_Aggrobot_DiscTurret_PowerWave_C':
      (AgentType.gekko, 2),
  '/Game/Characters/AggroBot/S0/Ability_Q/Pawn_Aggrobot_SeekerNade.Pawn_Aggrobot_SeekerNade_C':
      (AgentType.gekko, 1),
  '/Game/Characters/AggroBot/S0/Ability_X/Pawn_Aggrobot_RollyPolly.Pawn_Aggrobot_RollyPolly_C':
      (AgentType.gekko, 3),
  '/Game/Characters/BountyHunter/S0/Ability_4/Pawn_BountyHunter_4_WolfHound.Pawn_BountyHunter_4_WolfHound_C':
      (AgentType.fade, 0),
  '/Game/Characters/BountyHunter/S0/Ability_E/GameObject_BountyHunter_E_LoSReveal_Source_Reactivate.GameObject_BountyHunter_E_LoSReveal_Source_Reactivate_C':
      (AgentType.fade, 2),
  '/Game/Characters/BountyHunter/S0/Ability_E/Projectile_E_BountyHunter_Divebomb.Projectile_E_BountyHunter_Divebomb_C':
      (AgentType.fade, 2),
  '/Game/Characters/BountyHunter/S0/Ability_Q/GameObject_Q_BountyHunter_Tether_SphereExpansion.GameObject_Q_BountyHunter_Tether_SphereExpansion_C':
      (AgentType.fade, 1),
  '/Game/Characters/BountyHunter/S0/Ability_X/GameObject_BountyHunter_X_WaveForm.GameObject_BountyHunter_X_WaveForm_C':
      (AgentType.fade, 3),
  '/Game/Characters/Breach/S0/Ability_4/GameObject_Breach_4_FusionBlast.GameObject_Breach_4_FusionBlast_C':
      (AgentType.breach, 0),
  '/Game/Characters/Breach/S0/Ability_E/GameObject_Breach_E_SweetSpotFissure.GameObject_Breach_E_SweetSpotFissure_C':
      (AgentType.breach, 2),
  '/Game/Characters/Breach/S0/Ability_Q/Projectile_Breach_Q_ThroughWalls_Flash.Projectile_Breach_Q_ThroughWalls_Flash_C':
      (AgentType.breach, 1),
  '/Game/Characters/Cable/S0/Ability_4/Patch_NetToss.Patch_NetToss_C': (
    AgentType.deadlock,
    0
  ),
  '/Game/Characters/Cable/S0/Ability_E/GameObject_CableJamRoot.GameObject_CableJamRoot_C':
      (AgentType.deadlock, 2),
  '/Game/Characters/Cable/S0/Ability_Q/GameObject_SoundSensor_SweetSpotFissure.GameObject_SoundSensor_SweetSpotFissure_C':
      (AgentType.deadlock, 1),
  '/Game/Characters/Cable/S0/Ability_Q/GameObject_StealthingTrap_SoundSensor.GameObject_StealthingTrap_SoundSensor_C':
      (AgentType.deadlock, 1),
  '/Game/Characters/Cable/S0/Ability_X/Actor_FishingHook.Actor_FishingHook_C': (
    AgentType.deadlock,
    3
  ),
  '/Game/Characters/Cashew/S0/Ability_4/GameObject_Cashew_4_SonarPing.GameObject_Cashew_4_SonarPing_C':
      (AgentType.tejo, 0),
  '/Game/Characters/Cashew/S0/Ability_4/Pawn_Cashew_4_Spider_LockOn.Pawn_Cashew_4_Spider_LockOn_C':
      (AgentType.tejo, 0),
  '/Game/Characters/Cashew/S0/Ability_E/GameObject_Cashew_E_MapMissileMarker.GameObject_Cashew_E_MapMissileMarker_C':
      (AgentType.tejo, 2),
  '/Game/Characters/Cashew/S0/Ability_E/GameObject_Cashew_E_MapMissileMarker_SecondRocket.GameObject_Cashew_E_MapMissileMarker_SecondRocket_C':
      (AgentType.tejo, 2),
  '/Game/Characters/Cashew/S0/Ability_Q/Projectile_Cashew_Q_ShellShockGrenade.Projectile_Cashew_Q_ShellShockGrenade_C':
      (AgentType.tejo, 1),
  '/Game/Characters/Cashew/S0/Ability_Q/Projectile_Cashew_Q_ShellShockGrenade_Bounce.Projectile_Cashew_Q_ShellShockGrenade_Bounce_C':
      (AgentType.tejo, 1),
  '/Game/Characters/Cashew/S0/Ability_X/GameObject_Cashew_X_SegmentManager.GameObject_Cashew_X_SegmentManager_C':
      (AgentType.tejo, 3),
  '/Game/Characters/Clay/S0/Ability_4/Projectile_Clay_4_Projectile_Primary.Projectile_Clay_4_Projectile_Primary_C':
      (AgentType.raze, 2),
  '/Game/Characters/Clay/S0/Ability_E/Pawn_Clay_E_Boomba.Pawn_Clay_E_Boomba_C':
      (AgentType.raze, 0),
  '/Game/Characters/Clay/S0/Ability_Q/Projectile_Clay_Q_Satchel_Arming.Projectile_Clay_Q_Satchel_Arming_C':
      (AgentType.raze, 1),
  '/Game/Characters/Clay/S0/Ability_X/Projectile_Clay_X_Rocket.Projectile_Clay_X_Rocket_C':
      (AgentType.raze, 3),
  '/Game/Characters/Deadeye/S0/Ability_4/GameObject_Deadeye_E_Trap.GameObject_Deadeye_E_Trap_C':
      (AgentType.chamber, 0),
  '/Game/Characters/Deadeye/S0/Ability_4/Patch_Deadeye_E_Slow_Large.Patch_Deadeye_E_Slow_Large_C':
      (AgentType.chamber, 0),
  '/Game/Characters/Deadeye/S0/Ability_E/GameObject_Deadeye_E_Teleporter_Tether.GameObject_Deadeye_E_Teleporter_Tether_C':
      (AgentType.chamber, 2),
  '/Game/Characters/Grenadier/S0/Ability_4/Projectile_C_Grenadier_Flash.Projectile_C_Grenadier_Flash_C':
      (AgentType.kayo, 1),
  '/Game/Characters/Grenadier/S0/Ability_4/Projectile_C_Grenadier_Flash_Underhand.Projectile_C_Grenadier_Flash_Underhand_C':
      (AgentType.kayo, 1),
  '/Game/Characters/Grenadier/S0/Ability_E/Gameobject_Grenadier_E_SuppressionPulse.Gameobject_Grenadier_E_SuppressionPulse_C':
      (AgentType.kayo, 2),
  '/Game/Characters/Grenadier/S0/Ability_E/Projectile_Grenadier_E_SuppressionBlade.Projectile_Grenadier_E_SuppressionBlade_C':
      (AgentType.kayo, 2),
  '/Game/Characters/Guide/S0/Ability_4/GameObject_Guide_4_Heal_AOE.GameObject_Guide_4_Heal_AOE_C':
      (AgentType.skye, 0),
  '/Game/Characters/Guide/S0/Ability_E/GameObject_Guide_E_HawkFlash_FlashSource.GameObject_Guide_E_HawkFlash_FlashSource_C':
      (AgentType.skye, 2),
  '/Game/Characters/Guide/S0/Ability_E/Projectile_Guide_E_HawkFlash.Projectile_Guide_E_HawkFlash_C':
      (AgentType.skye, 2),
  '/Game/Characters/Guide/S0/Ability_Q/Pawn_Guide_Q_PossessableScout.Pawn_Guide_Q_PossessableScout_C':
      (AgentType.skye, 1),
  '/Game/Characters/Guide/S0/Ability_X/Pawn_Guide_X_Pack.Pawn_Guide_X_Pack_C': (
    AgentType.skye,
    3
  ),
  '/Game/Characters/Gumshoe/S0/Ability_4/Projectile_Gumshoe_4_CageTrap.Projectile_Gumshoe_4_CageTrap_C':
      (AgentType.cypher, 1),
  '/Game/Characters/Gumshoe/S0/Ability_4/Zone_Gumshoe_4_Cage.Zone_Gumshoe_4_Cage_C':
      (AgentType.cypher, 1),
  '/Game/Characters/Gumshoe/S0/Ability_E/GameObject_Gumshoe_E_TripWire.GameObject_Gumshoe_E_TripWire_C':
      (AgentType.cypher, 0),
  '/Game/Characters/Gumshoe/S0/Ability_Q/GameObject_RemovableObject_GumshoeTrackingDart.GameObject_RemovableObject_GumshoeTrackingDart_C':
      (AgentType.cypher, 2),
  '/Game/Characters/Gumshoe/S0/Ability_Q/Pawn_Gumshoe_Q_PossessableCamera.Pawn_Gumshoe_Q_PossessableCamera_C':
      (AgentType.cypher, 2),
  '/Game/Characters/Hunter/S0/Ability_4/GameObject_Hunter_4_ExplosiveBolt_Explosion.GameObject_Hunter_4_ExplosiveBolt_Explosion_C':
      (AgentType.sova, 1),
  '/Game/Characters/Hunter/S0/Ability_E/Drone/GameObject_Hunter_E_Drone_RevealDart.GameObject_Hunter_E_Drone_RevealDart_C':
      (AgentType.sova, 0),
  '/Game/Characters/Hunter/S0/Ability_E/Drone/Pawn_Hunter_E_Drone.Pawn_Hunter_E_Drone_C':
      (AgentType.sova, 0),
  '/Game/Characters/Hunter/S0/Ability_Q/GameObject_Hunter_Q_SonarBolt.GameObject_Hunter_Q_SonarBolt_C':
      (AgentType.sova, 2),
  '/Game/Characters/Iris/S0/Ability_4/GameObject_Thumper_Concuss.GameObject_Thumper_Concuss_C':
      (AgentType.miks, 0),
  '/Game/Characters/Iris/S0/Ability_4/GameObject_Thumper_Heal.GameObject_Thumper_Heal_C':
      (AgentType.miks, 1),
  '/Game/Characters/Iris/S0/Ability_E/GameObject_Iris_E_Smoke.GameObject_Iris_E_Smoke_C':
      (AgentType.miks, 2),
  '/Game/Characters/Iris/S0/Ability_X/GameObject_Iris_X_SonicWave.GameObject_Iris_X_SonicWave_C':
      (AgentType.miks, 4),
  '/Game/Characters/Killjoy/S0/Ability_4/GameObject_Killjoy_4_BeeSwarm_Damage.GameObject_Killjoy_4_BeeSwarm_Damage_C':
      (AgentType.killjoy, 0),
  '/Game/Characters/Killjoy/S0/Ability_4/Projectile_Killjoy_4_RemoteBees_MultiDetonate.Projectile_Killjoy_4_RemoteBees_MultiDetonate_C':
      (AgentType.killjoy, 0),
  '/Game/Characters/Killjoy/S0/Ability_E/Pawn_Killjoy_E_Turret.Pawn_Killjoy_E_Turret_C':
      (AgentType.killjoy, 2),
  '/Game/Characters/Killjoy/S0/Ability_Q/Pawn_Killjoy_Q_StealthAlarmbot.Pawn_Killjoy_Q_StealthAlarmbot_C':
      (AgentType.killjoy, 1),
  '/Game/Characters/Killjoy/S0/Ability_X/GameObject_Killjoy_X_Bomb.GameObject_Killjoy_X_Bomb_C':
      (AgentType.killjoy, 3),
  '/Game/Characters/Nox/S0/Ability_4/GameObject_Nox_BarbedWire.GameObject_Nox_BarbedWire_C':
      (AgentType.vyse, 1),
  '/Game/Characters/Nox/S0/Ability_4/Patch_Nox_BarbedWire.Patch_Nox_BarbedWire_C':
      (AgentType.vyse, 1),
  '/Game/Characters/Nox/S0/Ability_E/GameObject_Nox_StealthingTrap_Flash_2.GameObject_Nox_StealthingTrap_Flash_2_C':
      (AgentType.vyse, 2),
  '/Game/Characters/Nox/S0/Ability_Q/GameObject_Nox_Wall.GameObject_Nox_Wall_C':
      (AgentType.vyse, 0),
  '/Game/Characters/Nox/S0/Ability_Q/GameObject_Nox_WallTrap.GameObject_Nox_WallTrap_C':
      (AgentType.vyse, 0),
  '/Game/Characters/Nox/S0/Ability_X/Gameobject_Nox_DisarmPulse.Gameobject_Nox_DisarmPulse_C':
      (AgentType.vyse, 3),
  '/Game/Characters/Phoenix/S0/Ability_4/Production/NewMolotov/Patch_Phoenix_MolotovFire.Patch_Phoenix_MolotovFire_C':
      (AgentType.pheonix, 2),
  '/Game/Characters/Phoenix/S0/Ability_E/Production/Projectile_Phoenix_E_FlareCurve_Synced.Projectile_Phoenix_E_FlareCurve_Synced_C':
      (AgentType.pheonix, 1),
  '/Game/Characters/Phoenix/S0/Ability_E/Production/Projectile_Phoenix_E_FlareCurve_Synced_Right.Projectile_Phoenix_E_FlareCurve_Synced_Right_C':
      (AgentType.pheonix, 1),
  '/Game/Characters/Phoenix/S0/Ability_Q/Production/GameObject_Phoenix_Q_FlameWallManager_Production.GameObject_Phoenix_Q_FlameWallManager_Production_C':
      (AgentType.pheonix, 0),
  '/Game/Characters/Phoenix/S0/Ability_X/Production/GameObject_Phoenix_X_ResTarget_Production.GameObject_Phoenix_X_ResTarget_Production_C':
      (AgentType.pheonix, 3),
  '/Game/Characters/Sarge/S0/Ability_MapTargetSmoke/GameObject_Sarge_4_Smoke_ProductionNEW.GameObject_Sarge_4_Smoke_ProductionNEW_C':
      (AgentType.brimstone, 2),
  '/Game/Characters/Sarge/S0/Ability_Molotov/Patch_Sarge_Q_Molotov_Production.Patch_Sarge_Q_Molotov_Production_C':
      (AgentType.brimstone, 1),
  '/Game/Characters/Sarge/S0/Ability_OrbitalStrike/GameObject_Sarge_X_OrbitalStrike_Production.GameObject_Sarge_X_OrbitalStrike_Production_C':
      (AgentType.brimstone, 3),
  '/Game/Characters/Sarge/S0/Ability_SpeedStim/GameObject_Sarge_E_SpeedStim.GameObject_Sarge_E_SpeedStim_C':
      (AgentType.brimstone, 0),
  '/Game/Characters/Sequoia/S0/Ability_4/GameObject_Sequoia_4_MovingCover.GameObject_Sequoia_4_MovingCover_C':
      (AgentType.iso, 0),
  '/Game/Characters/Sequoia/S0/Ability_E/WreckingBall/GameObject_Sequoia_E_Orb.GameObject_Sequoia_E_Orb_C':
      (AgentType.iso, 2),
  '/Game/Characters/Sequoia/S0/Ability_Q/Projectile_Sequoia_Q_FragileMissile.Projectile_Sequoia_Q_FragileMissile_C':
      (AgentType.iso, 1),
  '/Game/Characters/Sequoia/S0/Ability_X/GameObject_Sequoia_X_LineCapture.GameObject_Sequoia_X_LineCapture_C':
      (AgentType.iso, 3),
  '/Game/Characters/Smonk/S0/Ability_E/MapTargetSmoke/GameObject_Smonk_NewSmoke.GameObject_Smonk_NewSmoke_C':
      (AgentType.clove, 2),
  '/Game/Characters/Smonk/S0/Ability_E/MapTargetSmoke/GameObject_Smonk_NewSmoke_PDS.GameObject_Smonk_NewSmoke_PDS_C':
      (AgentType.clove, 2),
  '/Game/Characters/Smonk/S0/Ability_Q/DebuffKnife/DecayLauncher/GameObject_Smonk_Q_DecayExplosion.GameObject_Smonk_Q_DecayExplosion_C':
      (AgentType.clove, 1),
  '/Game/Characters/Sprinter/S0/Ability_4/GameObject_Sprinter_4_Tunnel.GameObject_Sprinter_4_Tunnel_C':
      (AgentType.neon, 0),
  '/Game/Characters/Sprinter/S0/Ability_Q/GameObject_Sprinter_Q_ElectricSphere.GameObject_Sprinter_Q_ElectricSphere_C':
      (AgentType.neon, 1),
  '/Game/Characters/Stealth/S0/Ability_4/Pawn_Stealth_4_Decoy_V2.Pawn_Stealth_4_Decoy_V2_C':
      (AgentType.yoru, 0),
  '/Game/Characters/Stealth/S0/Ability_E/Pawn_Stealth_E_TeleporterMoving_FakeTP.Pawn_Stealth_E_TeleporterMoving_FakeTP_C':
      (AgentType.yoru, 2),
  '/Game/Characters/Stealth/S0/Ability_E/Pawn_Stealth_E_TeleporterStationary_FakeTP.Pawn_Stealth_E_TeleporterStationary_FakeTP_C':
      (AgentType.yoru, 2),
  '/Game/Characters/Stealth/S0/Ability_Q/Projectile_Stealth_Q_BounceFlash.Projectile_Stealth_Q_BounceFlash_C':
      (AgentType.yoru, 1),
  '/Game/Characters/Thorne/S0/Ability_4/Patch_Thorne_4_SlowField_Production.Patch_Thorne_4_SlowField_Production_C':
      (AgentType.sage, 1),
  '/Game/Characters/Thorne/S0/Ability_E/GameObject_Thorne_E_Wall_Fortifying.GameObject_Thorne_E_Wall_Fortifying_C':
      (AgentType.sage, 0),
  '/Game/Characters/Vampire/S0/Ability_4/GameObject_Vampire_4_NearsightAOE_Source.GameObject_Vampire_4_NearsightAOE_Source_C':
      (AgentType.reyna, 0),
  '/Game/Characters/Wraith/S0/Ability_4/Zone_Wraith_4_Smoke.Zone_Wraith_4_Smoke_C':
      (AgentType.omen, 2),
  '/Game/Characters/Wraith/S0/Ability_Q/Projectile_Wraith_Q_NearsightMissile.Projectile_Wraith_Q_NearsightMissile_C':
      (AgentType.omen, 1),
  '/Game/Characters/Wraith/S0/Ability_X/Intention_Wraith_X_GlobalTeleport.Intention_Wraith_X_GlobalTeleport_C':
      (AgentType.omen, 3),
  '/Game/Characters/Wushu/S0/Ability_4/GameObject_Wushu_4_SmokeZone.GameObject_Wushu_4_SmokeZone_C':
      (AgentType.jett, 0),
};

const observedIgnored = <String>[
  '/Game/Characters/AggroBot/S0/Ability_4/Ability_Aggrobot_C_ExplodeyPatch.Ability_Aggrobot_C_ExplodeyPatch_C',
  '/Game/Characters/AggroBot/S0/Ability_4/Projectile_Aggrobot_C_ExplodeyPatch.Projectile_Aggrobot_C_ExplodeyPatch_C',
  '/Game/Characters/AggroBot/S0/Ability_E/Ability_E_Aggrobot_DiscTurret.Ability_E_Aggrobot_DiscTurret_C',
  '/Game/Characters/AggroBot/S0/Ability_E/Projectile_Aggrobot_Zamboni_Rocket.Projectile_Aggrobot_Zamboni_Rocket_C',
  '/Game/Characters/AggroBot/S0/Ability_E/Projectile_E_Aggrobot_OrbSpawner.Projectile_E_Aggrobot_OrbSpawner_C',
  '/Game/Characters/AggroBot/S0/Ability_Q/Ability_Q_Aggrobot_SeekerNade.Ability_Q_Aggrobot_SeekerNade_C',
  '/Game/Characters/AggroBot/S0/Ability_X/Ability_Aggrobot_X_RollyExplosion.Ability_Aggrobot_X_RollyExplosion_C',
  '/Game/Characters/AggroBot/S0/Ability_X/Ability_Pawn_Aggrobot_RollyExplodey.Ability_Pawn_Aggrobot_RollyExplodey_C',
  '/Game/Characters/AggroBot/S0/ReclaimOrbs/GameObject_Aggrobot_Reclaim_Orb_ExplodeyPatch.GameObject_Aggrobot_Reclaim_Orb_ExplodeyPatch_C',
  '/Game/Characters/AggroBot/S0/ReclaimOrbs/GameObject_Aggrobot_Reclaim_Orb_SeekerNade.GameObject_Aggrobot_Reclaim_Orb_SeekerNade_C',
  '/Game/Characters/AggroBot/S0/ReclaimOrbs/GameObject_Aggrobot_Reclaim_Orb_SeekerNadePlantSuccessful.GameObject_Aggrobot_Reclaim_Orb_SeekerNadePlantSuccessful_C',
  '/Game/Characters/AggroBot/S0/ReclaimOrbs/GameObject_Aggrobot_Reclaim_Orb_Turret.GameObject_Aggrobot_Reclaim_Orb_Turret_C',
  '/Game/Characters/AggroBot/S0/ReclaimOrbs/GameObject_Aggrobot_X_Reclaim_Orb.GameObject_Aggrobot_X_Reclaim_Orb_C',
  '/Game/Characters/BountyHunter/S0/Ability_4/Ability_BountyHunter_4_WolfHoundBendable.Ability_BountyHunter_4_WolfHoundBendable_C',
  '/Game/Characters/BountyHunter/S0/Ability_E/Ability_E_BountyHunter_ReconDivebomb.Ability_E_BountyHunter_ReconDivebomb_C',
  '/Game/Characters/BountyHunter/S0/Ability_Q/Ability_Q_BountyHunter_TetherDivebomb.Ability_Q_BountyHunter_TetherDivebomb_C',
  '/Game/Characters/BountyHunter/S0/Ability_Q/Projectile_Q_BountyHunter_TetherGrenade_SphereExpansion.Projectile_Q_BountyHunter_TetherGrenade_SphereExpansion_C',
  '/Game/Characters/BountyHunter/S0/Ability_X/Ability_BountyHunter_X_WaveForm.Ability_BountyHunter_X_WaveForm_C',
  '/Game/Characters/BountyHunter/S0/Global/Trails/Path_BountyHunter_Trail.Path_BountyHunter_Trail_C',
  '/Game/Characters/Breach/S0/Ability_4/Ability_Breach_4_FusionBlast.Ability_Breach_4_FusionBlast_C',
  '/Game/Characters/Breach/S0/Ability_4/Projectile_Breach_4_FusionBlast.Projectile_Breach_4_FusionBlast_C',
  '/Game/Characters/Breach/S0/Ability_E/Ability_Breach_E_Fissure.Ability_Breach_E_Fissure_C',
  '/Game/Characters/Breach/S0/Ability_Q/Ability_Breach_Q_Flash.Ability_Breach_Q_Flash_C',
  '/Game/Characters/Breach/S0/Ability_X/Ability_Breach_X_Shockwave.Ability_Breach_X_Shockwave_C',
  '/Game/Characters/Cable/S0/Ability_4/Ability_Cable_4_NetToss.Ability_Cable_4_NetToss_C',
  '/Game/Characters/Cable/S0/Ability_4/NetTossRemovableDebuff.NetTossRemovableDebuff_C',
  '/Game/Characters/Cable/S0/Ability_4/Projectile_NetToss.Projectile_NetToss_C',
  '/Game/Characters/Cable/S0/Ability_E/Ability_Cable_E_CableJam.Ability_Cable_E_CableJam_C',
  '/Game/Characters/Cable/S0/Ability_E/GameObject_CableJam_CableDeployer_Precomputed.GameObject_CableJam_CableDeployer_Precomputed_C',
  '/Game/Characters/Cable/S0/Ability_E/Projectile_CableJam_InAir.Projectile_CableJam_InAir_C',
  '/Game/Characters/Cable/S0/Ability_Q/Ability_Cable_Q_SoundSensor.Ability_Cable_Q_SoundSensor_C',
  '/Game/Characters/Cable/S0/Ability_X/Ability_Cable_X_FishingHook.Ability_Cable_X_FishingHook_C',
  '/Game/Characters/Cable/S0/Ability_X/GameObject_FishingHook_BouncingTrajectoryWarning.GameObject_FishingHook_BouncingTrajectoryWarning_C',
  '/Game/Characters/Cable/S0/Ability_X/GameObject_FishingHook_CageSphere.GameObject_FishingHook_CageSphere_C',
  '/Game/Characters/Cable/S0/Ability_X/GameObject_FishingHook_EndOfTrajectoryWarning.GameObject_FishingHook_EndOfTrajectoryWarning_C',
  '/Game/Characters/Cable/S0/Ability_X/GameObject_MotherNode.GameObject_MotherNode_C',
  '/Game/Characters/Cable/S0/Ability_X/GameObject_Spline.GameObject_Spline_C',
  '/Game/Characters/Cashew/S0/Ability_4/Ability_Cashew_4_Spider_Abilities_SelfDestruct.Ability_Cashew_4_Spider_Abilities_SelfDestruct_C',
  '/Game/Characters/Cashew/S0/Ability_4/Ability_Cashew_4_Spider_LockOn.Ability_Cashew_4_Spider_LockOn_C',
  '/Game/Characters/Cashew/S0/Ability_E/AIPawn_Cashew_E_SeekingTargetMissile.AIPawn_Cashew_E_SeekingTargetMissile_C',
  '/Game/Characters/Cashew/S0/Ability_E/Ability_Cashew_E_Airstrike.Ability_Cashew_E_Airstrike_C',
  '/Game/Characters/Cashew/S0/Ability_E/GameObject_Cashew_E_AirStrikeMortar.GameObject_Cashew_E_AirStrikeMortar_C',
  '/Game/Characters/Cashew/S0/Ability_Q/Ability_Cashew_Q_ShellShockGrenade.Ability_Cashew_Q_ShellShockGrenade_C',
  '/Game/Characters/Cashew/S0/Ability_X/Ability_Cashew_X_Airstrike.Ability_Cashew_X_Airstrike_C',
  '/Game/Characters/Cashew/S0/Ability_X/GameObject_Cashew_X_Segment.GameObject_Cashew_X_Segment_C',
  '/Game/Characters/Clay/S0/Ability_4/Ability_Clay_4_ClusterGrenade.Ability_Clay_4_ClusterGrenade_C',
  '/Game/Characters/Clay/S0/Ability_4/Projectile_Clay_4_Projectile_Secondary.Projectile_Clay_4_Projectile_Secondary_C',
  '/Game/Characters/Clay/S0/Ability_4/Projectile_Clay_4_Projectile_SecondarySpawner.Projectile_Clay_4_Projectile_SecondarySpawner_C',
  '/Game/Characters/Clay/S0/Ability_E/Ability_Clay_E_Boomba.Ability_Clay_E_Boomba_C',
  '/Game/Characters/Clay/S0/Ability_Q/Ability_Clay_Q_Satchel.Ability_Clay_Q_Satchel_C',
  '/Game/Characters/Clay/S0/Ability_Q/GameObject_Clay_Q_Explosion.GameObject_Clay_Q_Explosion_C',
  '/Game/Characters/Clay/S0/Ability_X/Ability_Clay_X_RocketLauncher.Ability_Clay_X_RocketLauncher_C',
  '/Game/Characters/Deadeye/S0/Ability_4/Ability_Deadeye_4_Trap.Ability_Deadeye_4_Trap_C',
  '/Game/Characters/Deadeye/S0/Ability_4/Projectile_Deadeye_4_Trap_Dart.Projectile_Deadeye_4_Trap_Dart_C',
  '/Game/Characters/Deadeye/S0/Ability_E/Ability_Deadeye_E_Teleporter_Tethers.Ability_Deadeye_E_Teleporter_Tethers_C',
  '/Game/Characters/Deadeye/S0/Ability_Q/Ability_Deadeye_Q_Pistol.Ability_Deadeye_Q_Pistol_C',
  '/Game/Characters/Deadeye/S0/Ability_Q/Gun/Gun_Deadeye_Q_Pistol.Gun_Deadeye_Q_Pistol_C',
  '/Game/Characters/Deadeye/S0/Ability_X/Ability_Deadeye_X_Giantslayer_Prototype_DanPrototype.Ability_Deadeye_X_Giantslayer_Prototype_DanPrototype_C',
  '/Game/Characters/Deadeye/S0/Ability_X/Gun_Giantslayer/Gun_Deadeye_X_Giantslayer_Prototype_FIreRatePrototype.Gun_Deadeye_X_Giantslayer_Prototype_FireRatePrototype_C',
  '/Game/Characters/Grenadier/S0/Ability_4/Ability_Grenadier_C_Flash.Ability_Grenadier_C_Flash_C',
  '/Game/Characters/Grenadier/S0/Ability_E/Ability_E_Grenadier_EMPKnife.Ability_E_Grenadier_EMPKnife_C',
  '/Game/Characters/Grenadier/S0/Ability_Q/Ability_Grenadier_Q_BasicSemtex.Ability_Grenadier_Q_BasicSemtex_C',
  '/Game/Characters/Grenadier/S0/Ability_X/Ability_Grenadier_X_OverloadPulse.Ability_Grenadier_X_OverloadPulse_C',
  '/Game/Characters/Grenadier/S0/Ability_X/Grenadier_Recharge_Usable.Grenadier_Recharge_Usable_C',
  '/Game/Characters/Guide/S0/Ability_4/Ability_Guide_4_Heal.Ability_Guide_4_Heal_C',
  '/Game/Characters/Guide/S0/Ability_E/Ability_Guide_E_HawkFlash.Ability_Guide_E_HawkFlash_C',
  '/Game/Characters/Guide/S0/Ability_Q/Ability_Guide_Q_PossessableScout.Ability_Guide_Q_PossessableScout_C',
  '/Game/Characters/Guide/S0/Ability_Q/Ability_Guide_Q_PossessableScout_ScoutAbilities.Ability_Guide_Q_PossessableScout_ScoutAbilities_C',
  '/Game/Characters/Guide/S0/Ability_X/Ability_Guide_X_Pack.Ability_Guide_X_Pack_C',
  '/Game/Characters/Guide/S0/Ability_X/Equippable_Guide_X_Pack_Attack.Equippable_Guide_X_Pack_Attack_C',
  '/Game/Characters/Guide/S0/Ability_X/Equippable_PlaceholderDefault.Equippable_PlaceholderDefault_C',
  '/Game/Characters/Gumshoe/S0/Ability_4/Ability_Gumshoe_4_CageTrap.Ability_Gumshoe_4_CageTrap_C',
  '/Game/Characters/Gumshoe/S0/Ability_E/Ability_Gumshoe_E_TripWire.Ability_Gumshoe_E_TripWire_C',
  '/Game/Characters/Gumshoe/S0/Ability_E/GameObject_Gumshoe_E_TripWire_SecondWire.GameObject_Gumshoe_E_TripWire_SecondWire_C',
  '/Game/Characters/Gumshoe/S0/Ability_Q/Ability_Gumshoe_Q_Camera.Ability_Gumshoe_Q_Camera_C',
  '/Game/Characters/Gumshoe/S0/Ability_Q/Ability_Gumshoe_Q_Camera_Dart.Ability_Gumshoe_Q_Camera_Dart_C',
  '/Game/Characters/Gumshoe/S0/Ability_Q/Ability_Gumshoe_Q_UnpossessCamera.Ability_Gumshoe_Q_UnpossessCamera_C',
  '/Game/Characters/Gumshoe/S0/Ability_Q/Projectile_Gumshoe_Q_CameraTrackingDart.Projectile_Gumshoe_Q_CameraTrackingDart_C',
  '/Game/Characters/Gumshoe/S0/Ability_X/Ability_Gumshoe_X_InterrogateV2.Ability_Gumshoe_X_InterrogateV2_C',
  '/Game/Characters/Hunter/S0/Ability_4/Ability_Hunter_4_BoltExplosive.Ability_Hunter_4_BoltExplosive_C',
  '/Game/Characters/Hunter/S0/Ability_4/Projectile_Hunter_4_ExplosiveBolt.Projectile_Hunter_4_ExplosiveBolt_C',
  '/Game/Characters/Hunter/S0/Ability_E/Drone/Ability_Hunter_E_DeployDrone.Ability_Hunter_E_DeployDrone_C',
  '/Game/Characters/Hunter/S0/Ability_E/Drone/Ability_Hunter_E_Drone_Abilities.Ability_Hunter_E_Drone_Abilities_C',
  '/Game/Characters/Hunter/S0/Ability_Q/Ability_Hunter_Q_RevealBolt_Signature.Ability_Hunter_Q_RevealBolt_Signature_C',
  '/Game/Characters/Hunter/S0/Ability_Q/GameObject_Hunter_Q_SonarPing.GameObject_Hunter_Q_SonarPing_C',
  '/Game/Characters/Hunter/S0/Ability_Q/Projectile_Hunter_Q_RevealBolt.Projectile_Hunter_Q_RevealBolt_C',
  '/Game/Characters/Hunter/S0/Ability_X/Ability_Hunter_X_LaserMulti.Ability_Hunter_X_LaserMulti_C',
  '/Game/Characters/Iris/S0/Ability_4/Ability_Iris_Thumper.Ability_Iris_Thumper_C',
  '/Game/Characters/Iris/S0/Ability_4/Projectile_Thumper_Concuss.Projectile_Thumper_Concuss_C',
  '/Game/Characters/Iris/S0/Ability_4/Projectile_Thumper_Heal.Projectile_Thumper_Heal_C',
  '/Game/Characters/Iris/S0/Ability_E/Ability_Iris_E_MT_Smoke_Production.Ability_Iris_E_MT_Smoke_Production_C',
  '/Game/Characters/Iris/S0/Ability_Q/Ability_Iris_Harmonize.Ability_Iris_Harmonize_C',
  '/Game/Characters/Iris/S0/Ability_X/Ability_Iris_X_SonicWave.Ability_Iris_X_SonicWave_C',
  '/Game/Characters/Killjoy/S0/Ability_4/Ability_Killjoy_4_RemoteBees_MultiDetonate.Ability_Killjoy_4_RemoteBees_MultiDetonate_C',
  '/Game/Characters/Killjoy/S0/Ability_E/Ability_Killjoy_E_Turret.Ability_Killjoy_E_Turret_C',
  '/Game/Characters/Killjoy/S0/Ability_E/Ability_Killjoy_E_TurretAttack.Ability_Killjoy_E_TurretAttack_C',
  '/Game/Characters/Killjoy/S0/Ability_Q/Ability_Killjoy_Q_Alarmbot.Ability_Killjoy_Q_Alarmbot_C',
  '/Game/Characters/Killjoy/S0/Ability_X/Ability_Killjoy_X_Bomb.Ability_Killjoy_X_Bomb_C',
  '/Game/Characters/Killjoy/S0/Ability_X/GameObject_Killjoy_X_Shockwave.GameObject_Killjoy_X_Shockwave_C',
  '/Game/Characters/Nox/S0/Ability_4/Ability_Nox_BarbedWire.Ability_Nox_BarbedWire_C',
  '/Game/Characters/Nox/S0/Ability_4/Projectile_Nox_BarbedWire.Projectile_Nox_BarbedWire_C',
  '/Game/Characters/Nox/S0/Ability_E/Ability_Nox_FlashTrap.Ability_Nox_FlashTrap_C',
  '/Game/Characters/Nox/S0/Ability_Q/Ability_Nox_Wall.Ability_Nox_Wall_C',
  '/Game/Characters/Nox/S0/Ability_X/Ability_Nox_DisarmPulse.Ability_Nox_DisarmPulse_C',
  '/Game/Characters/Phoenix/S0/Ability_4/Production/Ability_Phoenix_4_Molotov_Production.Ability_Phoenix_4_Molotov_Production_C',
  '/Game/Characters/Phoenix/S0/Ability_4/Production/Projectile_Phoenix_4_Molotov_Production.Projectile_Phoenix_4_Molotov_Production_C',
  '/Game/Characters/Phoenix/S0/Ability_E/Production/Ability_Phoenix_E_FlareCurve_Production.Ability_Phoenix_E_FlareCurve_Production_C',
  '/Game/Characters/Phoenix/S0/Ability_Q/Production/Ability_Phoenix_Q_FireballWall_Production.Ability_Phoenix_Q_FireballWall_Production_C',
  '/Game/Characters/Phoenix/S0/Ability_Q/Production/Projectile_Phoenix_Q_FlameWall_ThroughWall.Projectile_Phoenix_Q_FlameWall_ThroughWall_C',
  '/Game/Characters/Phoenix/S0/Ability_X/Production/Ability_Phoenix_X_SelfRes_Production.Ability_Phoenix_X_SelfRes_Production_C',
  '/Game/Characters/Sarge/S0/Ability_MapTargetSmoke/Ability_Sarge_4_MapTargetSmoke_Production.Ability_Sarge_4_MapTargetSmoke_Production_C',
  '/Game/Characters/Sarge/S0/Ability_MapTargetSmoke/GameObject_Sarge_4_SmokeManager_Production.GameObject_Sarge_4_SmokeManager_Production_C',
  '/Game/Characters/Sarge/S0/Ability_Molotov/Ability_Sarge_Q_Molotov_Production.Ability_Sarge_Q_Molotov_Production_C',
  '/Game/Characters/Sarge/S0/Ability_Molotov/Projectile_Sarge_Q_Molotov_Production.Projectile_Sarge_Q_Molotov_Production_C',
  '/Game/Characters/Sarge/S0/Ability_OrbitalStrike/Ability_Sarge_X_OrbitalStrike.Ability_Sarge_X_OrbitalStrike_C',
  '/Game/Characters/Sarge/S0/Ability_SpeedStim/Ability_Sarge_E_SpeedStim.Ability_Sarge_E_SpeedStim_C',
  '/Game/Characters/Sarge/S0/Ability_SpeedStim/Projectile_Sarge_E_SpeedStim.Projectile_Sarge_E_SpeedStim_C',
  '/Game/Characters/Sequoia/S0/Ability_4/Ability_Sequoia_4_Wave.Ability_Sequoia_4_Wave_C',
  '/Game/Characters/Sequoia/S0/Ability_E/WreckingBall/Ability_Sequoia_E_WreckingBall.Ability_Sequoia_E_WreckingBall_C',
  '/Game/Characters/Sequoia/S0/Ability_E/WreckingBall/GameObject_Sequoia_E_Shield.GameObject_Sequoia_E_Shield_C',
  '/Game/Characters/Sequoia/S0/Ability_Q/Ability_Sequoia_Q_FragileMissilePrototypeEquipped.Ability_Sequoia_Q_FragileMissilePrototypeEquipped_C',
  '/Game/Characters/Sequoia/S0/Ability_Q/GameObject_Sequoia_Q_FragileMissile_TrajectoryWarning.GameObject_Sequoia_Q_FragileMissile_TrajectoryWarning_C',
  '/Game/Characters/Sequoia/S0/Ability_X/Ability_X_Sequoia_ArenaLineCapture.Ability_X_Sequoia_ArenaLineCapture_C',
  '/Game/Characters/Sequoia/S0/Ability_X/Actor_Sequoia_X_StandardArena.Actor_Sequoia_X_StandardArena_C',
  '/Game/Characters/Sequoia/S0/Ability_X/Equippable_Sequoia_X_ArenaTeleport.Equippable_Sequoia_X_ArenaTeleport_C',
  '/Game/Characters/Smonk/S0/Ability_4/ReactiveArmor/Ability_Smonk_BFArmor_Reactive.Ability_Smonk_BFArmor_Reactive_C',
  '/Game/Characters/Smonk/S0/Ability_E/MapTargetSmoke/Ability_Smonk_E_MapTargetSmokeV2.Ability_Smonk_E_MapTargetSmokeV2_C',
  '/Game/Characters/Smonk/S0/Ability_E/MapTargetSmoke/Ability_Smonk_E_PostDeath.Ability_Smonk_E_PostDeath_C',
  '/Game/Characters/Smonk/S0/Ability_Q/DebuffKnife/DecayLauncher/Ability_Q_Smonk_DebuffKnife.Ability_Q_Smonk_DebuffKnife_C',
  '/Game/Characters/Smonk/S0/Ability_Q/DebuffKnife/DecayLauncher/Projectile_Smonk_DecayNade.Projectile_Smonk_DecayNade_C',
  '/Game/Characters/Smonk/S0/Ability_X/ReactiveRes/Ability_Smonk_X_PostDeath_ReactiveResStart.Ability_Smonk_X_PostDeath_ReactiveResStart_C',
  '/Game/Characters/Smonk/S0/Ability_X/ReactiveRes/Ability_Smonk_X_ReactiveRes_Engineering.Ability_Smonk_X_ReactiveRes_Engineering_C',
  '/Game/Characters/Smonk/S0/Global/PostDeath/Equippable_Smonk_PostDeath_Unarmed.Equippable_Smonk_PostDeath_Unarmed_C',
  '/Game/Characters/Sprinter/S0/Ability_4/Ability_Sprinter_4_Tunnel_Production.Ability_Sprinter_4_Tunnel_Production_C',
  '/Game/Characters/Sprinter/S0/Ability_4/Projectile_Neon_C_Tunnel.Projectile_Neon_C_Tunnel_C',
  '/Game/Characters/Sprinter/S0/Ability_4/Projectile_Neon_C_Tunnel_Cosmetic.Projectile_Neon_C_Tunnel_Cosmetic_C',
  '/Game/Characters/Sprinter/S0/Ability_E/Ability_Sprinter_E_Sprint_Production.Ability_Sprinter_E_Sprint_Production_C',
  '/Game/Characters/Sprinter/S0/Ability_Q/Ability_Sprinter_Q_GroundStrike_Production.Ability_Sprinter_Q_GroundStrike_Production_C',
  '/Game/Characters/Sprinter/S0/Ability_Q/Projectile_Sprinter_4_GroundStrike.Projectile_Sprinter_4_GroundStrike_C',
  '/Game/Characters/Sprinter/S0/Ability_X/Ability_Sprinter_X_LightningGun_Production.Ability_Sprinter_X_LightningGun_Production_C',
  '/Game/Characters/Sprinter/S0/Ability_X/Gun_Sprinter_X_HeavyLightningGun_Production.Gun_Sprinter_X_HeavyLightningGun_Production_C',
  '/Game/Characters/Stealth/S0/Ability_4/Ability_Stealth_4_Decoy.Ability_Stealth_4_Decoy_C',
  '/Game/Characters/Stealth/S0/Ability_4/GameObject_Stealth_DecoySpawner.GameObject_Stealth_DecoySpawner_C',
  '/Game/Characters/Stealth/S0/Ability_E/Ability_Stealth_E_Teleport.Ability_Stealth_E_Teleport_C',
  '/Game/Characters/Stealth/S0/Ability_Q/Ability_Stealth_Q_BounceFlash.Ability_Stealth_Q_BounceFlash_C',
  '/Game/Characters/Stealth/S0/Ability_X/Ability_Stealth_X_Cloak_Equip.Ability_Stealth_X_Cloak_Equip_C',
  '/Game/Characters/Thorne/S0/Ability_4/Ability_Thorne_4_SlowField_Production.Ability_Thorne_4_SlowField_Production_C',
  '/Game/Characters/Thorne/S0/Ability_4/Projectile_Thorne_4_SlowFIeld_Production.Projectile_Thorne_4_SlowFIeld_Production_C',
  '/Game/Characters/Thorne/S0/Ability_E/Ability_Thorne_E_Wall_Fortifying.Ability_Thorne_E_Wall_Fortifying_C',
  '/Game/Characters/Thorne/S0/Ability_E/GameObject_Thorne_E_Wall_Segment_Fortifying.GameObject_Thorne_E_Wall_Segment_Fortifying_C',
  '/Game/Characters/Thorne/S0/Ability_Q/Ability_Thorne_Q_Heal_Production_New.Ability_Thorne_Q_Heal_Production_New_C',
  '/Game/Characters/Thorne/S0/Ability_X/Ability_Thorne_X_Resurrect_Production.Ability_Thorne_X_Resurrect_Production_C',
  '/Game/Characters/Vampire/S0/Ability_4/Ability_Vampire_4_NearsightAoE.Ability_Vampire_4_NearsightAoE_C',
  '/Game/Characters/Vampire/S0/Ability_4/Projectile_Vampire_4_NearsightAoE.Projectile_Vampire_4_NearsightAoE_C',
  '/Game/Characters/Vampire/S0/Ability_E/Ability_Vampire_E_Escape.Ability_Vampire_E_Escape_C',
  '/Game/Characters/Vampire/S0/Ability_Q/Ability_Vampire_Q_Heal.Ability_Vampire_Q_Heal_C',
  '/Game/Characters/Vampire/S0/Ability_Q/GameObject_Vampire_Q_Heal_HealPool_AutoActivate.GameObject_Vampire_Q_Heal_HealPool_AutoActivate_C',
  '/Game/Characters/Vampire/S0/Ability_Q/GameObject_Vampire_Q_Heal_HealPool_High.GameObject_Vampire_Q_Heal_HealPool_High_C',
  '/Game/Characters/Vampire/S0/Ability_X/Ability_Vampire_X_Frenzy.Ability_Vampire_X_Frenzy_C',
  '/Game/Characters/Wraith/S0/Ability_4/Ability_Wraith_4_Smoke.Ability_Wraith_4_Smoke_C',
  '/Game/Characters/Wraith/S0/Ability_4/Projectile_Wraith_4_Smoke.Projectile_Wraith_4_Smoke_C',
  '/Game/Characters/Wraith/S0/Ability_E/Ability_Wraith_E_ShortTeleport.Ability_Wraith_E_ShortTeleport_C',
  '/Game/Characters/Wraith/S0/Ability_Q/Ability_Wraith_Q_NearsightMissile.Ability_Wraith_Q_NearsightMissile_C',
  '/Game/Characters/Wraith/S0/Ability_Q/GameObject_Wraith_Q_NearsightMissile_TrajectoryWarning.GameObject_Wraith_Q_NearsightMissile_TrajectoryWarning_C',
  '/Game/Characters/Wraith/S0/Ability_X/Ability_Wraith_X_GlobalTeleport.Ability_Wraith_X_GlobalTeleport_C',
  '/Game/Characters/Wushu/S0/Ability_4/Ability_Wushu_4_Smoke.Ability_Wushu_4_Smoke_C',
  '/Game/Characters/Wushu/S0/Ability_4/Projectile_Wushu_4_Smoke.Projectile_Wushu_4_Smoke_C',
  '/Game/Characters/Wushu/S0/Ability_E/Ability_Wushu_E_Dash.Ability_Wushu_E_Dash_C',
  '/Game/Characters/Wushu/S0/Ability_Q/Ability_Wushu_Q_CycloneBoost.Ability_Wushu_Q_CycloneBoost_C',
  '/Game/Characters/Wushu/S0/Ability_X/Ability_Wushu_X_Dagger_Production.Ability_Wushu_X_Dagger_Production_C',
  '/Game/Characters/Wushu/S0/Glide/Ability_Wushu_Passive_Glide.Ability_Wushu_Passive_Glide_C',
];
