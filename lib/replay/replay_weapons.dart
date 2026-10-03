import 'package:icarus/const/weapons.dart';

/// Icarus weapons by the equippable folder Valorant keeps each gun in, e.g.
/// `/Game/Equippables/Guns/Rifles/AK/...` is the Vandal. Checked against the
/// equippable paths replays carry; an unknown path shows no weapon.
const List<(String, WeaponType)> _weaponsByPathPart = [
  ('/Sidearms/BasePistol/', WeaponType.classic),
  ('/Sidearms/Shotgun/', WeaponType.shorty),
  ('/Sidearms/AutomaticPistol/', WeaponType.frenzy),
  ('/Sidearms/Luger/', WeaponType.ghost),
  ('/Sidearms/Revolver/', WeaponType.sheriff),
  ('/Sidearms/Slim/', WeaponType.bandit),
  ('/SubMachineGuns/Vector/', WeaponType.stinger),
  ('/SubMachineGuns/MP5/', WeaponType.spectre),
  ('/Shotguns/PumpShotgun/', WeaponType.bucky),
  ('/Shotguns/AutomaticShotgun/', WeaponType.judge),
  ('/Rifles/Burst/', WeaponType.bulldog),
  ('/Rifles/DMR/', WeaponType.guardian),
  ('/Rifles/Carbine/', WeaponType.phantom),
  ('/Rifles/AK/', WeaponType.vandal),
  ('/Sniper/LeverSniperRifle/', WeaponType.marshal),
  ('/Sniper/DoubleSniper/', WeaponType.outlaw),
  ('/Sniper/BoltSniper/', WeaponType.operator),
  ('/HvyMachineGuns/LMG/', WeaponType.ares),
  ('/HvyMachineGuns/HMG/', WeaponType.odin),
];

WeaponType replayWeaponType(String? equippablePath) {
  if (equippablePath == null) return WeaponType.none;
  for (final (part, weapon) in _weaponsByPathPart) {
    if (equippablePath.contains(part)) return weapon;
  }
  return WeaponType.none;
}
