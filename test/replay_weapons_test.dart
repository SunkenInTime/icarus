import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/replay/replay_weapons.dart';

void main() {
  test('every gun path seen in replays is its weapon', () {
    // Economy weapons and kill sources from three 13.0x replays, plus the
    // Frenzy from valorant-api.com's asset paths (no replay had one).
    const guns = {
      'Sidearms/BasePistol/BasePistol.BasePistol_C': WeaponType.classic,
      'Sidearms/Slim/SawedOffShotgun.SawedOffShotgun_C': WeaponType.shorty,
      'Sidearms/AutoPistol/AutoPistol.AutoPistol_C': WeaponType.frenzy,
      'Sidearms/Luger/LugerPistol.LugerPistol_C': WeaponType.ghost,
      'Sidearms/Revolver/RevolverPistol.RevolverPistol_C': WeaponType.sheriff,
      'Sidearms/Compact/CompactPistol.CompactPistol_C': WeaponType.bandit,
      'SubMachineGuns/Vector/Vector.Vector_C': WeaponType.stinger,
      'SubMachineGuns/MP5/SubMachineGun_MP5.SubMachineGun_MP5_C':
          WeaponType.spectre,
      'Shotguns/PumpShotgun/PumpShotgun.PumpShotgun_C': WeaponType.bucky,
      'Shotguns/AutoShotgun/AutomaticShotgun.AutomaticShotgun_C':
          WeaponType.judge,
      'Rifles/Burst/AssaultRifle_Burst.AssaultRifle_Burst_C':
          WeaponType.bulldog,
      'SniperRifles/DMR/DMR.DMR_C': WeaponType.guardian,
      'SniperRifles/Dmr/DMR.DMR_C': WeaponType.guardian,
      'Rifles/Carbine/AssaultRifle_ACR.AssaultRifle_ACR_C': WeaponType.phantom,
      'Rifles/AK/AssaultRifle_AK.AssaultRifle_AK_C': WeaponType.vandal,
      'Rifles/BattleRifle/BattleRifle.BattleRifle_C': WeaponType.warden,
      'SniperRifles/Leversniper/LeverSniperRifle.LeverSniperRifle_C':
          WeaponType.marshal,
      'SniperRifles/Doublesniper/DS_Gun.DS_Gun_C': WeaponType.outlaw,
      'SniperRifles/Boltsniper/BoltSniper.BoltSniper_C': WeaponType.operator,
      'HvyMachineGuns/LMG/LightMachineGun.LightMachineGun_C': WeaponType.ares,
      'HvyMachineGuns/HMG/HeavyMachineGun.HeavyMachineGun_C': WeaponType.odin,
    };
    for (final MapEntry(key: path, value: weapon) in guns.entries) {
      expect(replayWeaponType('/Game/Equippables/Guns/$path'), weapon,
          reason: path);
    }
  });

  test('an ability or unknown path is no weapon', () {
    expect(
      replayWeaponType('/Game/Characters/Deadeye/S0/Ability_Q/Gun/'
          'Gun_Deadeye_Q_Pistol.Gun_Deadeye_Q_Pistol_C'),
      WeaponType.none,
    );
    expect(replayWeaponType(null), WeaponType.none);
  });
}
