import 'package:icarus/const/weapons.dart';

/// Icarus weapons by the equippable folder Valorant keeps each gun in, e.g.
/// `/Game/Equippables/Guns/Rifles/AK/...` is the Vandal. The folders are
/// valorant-api.com's asset paths, checked against the economy weapons and
/// kill sources of 13.0x replays; an unknown path shows no weapon. Matched
/// ignoring case: replays carry both `/SniperRifles/DMR/` and `/Dmr/`.
const List<(String, WeaponType)> _weaponsByPathPart = [
  ('/sidearms/basepistol/', WeaponType.classic),
  ('/sidearms/slim/', WeaponType.shorty),
  ('/sidearms/autopistol/', WeaponType.frenzy),
  ('/sidearms/luger/', WeaponType.ghost),
  ('/sidearms/revolver/', WeaponType.sheriff),
  ('/sidearms/compact/', WeaponType.bandit),
  ('/submachineguns/vector/', WeaponType.stinger),
  ('/submachineguns/mp5/', WeaponType.spectre),
  ('/shotguns/pumpshotgun/', WeaponType.bucky),
  ('/shotguns/autoshotgun/', WeaponType.judge),
  ('/rifles/burst/', WeaponType.bulldog),
  ('/rifles/carbine/', WeaponType.phantom),
  ('/rifles/ak/', WeaponType.vandal),
  ('/rifles/battlerifle/', WeaponType.warden),
  ('/sniperrifles/dmr/', WeaponType.guardian),
  ('/sniperrifles/leversniper/', WeaponType.marshal),
  ('/sniperrifles/doublesniper/', WeaponType.outlaw),
  ('/sniperrifles/boltsniper/', WeaponType.operator),
  ('/hvymachineguns/lmg/', WeaponType.ares),
  ('/hvymachineguns/hmg/', WeaponType.odin),
];

WeaponType replayWeaponType(String? equippablePath) {
  if (equippablePath == null) return WeaponType.none;
  final path = equippablePath.toLowerCase();
  for (final (part, weapon) in _weaponsByPathPart) {
    if (path.contains(part)) return weapon;
  }
  return WeaponType.none;
}
