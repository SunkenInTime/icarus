import 'package:icarus/const/agents.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/replay/replay_ability_catalog.dart';

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

/// The ability [damageSource] is, as an Icarus ability of the [killer]'s
/// agent, or null for a gun, an unknown source, or an ability Icarus lacks.
///
/// A source the ability catalog knows (a molly zone, a projectile) is that
/// ability. Otherwise an ability's guns and blades live in its slot folder,
/// e.g. `/Game/Characters/Deadeye/S0/Ability_Q/Gun/Gun_Deadeye_Q_Pistol...`
/// is Chamber's Headhunter. The folder is not Icarus's order and differs
/// per agent (see replay_ability_catalog.dart), so only slots checked
/// against kill sources map: the ultimate (Ability_X) is Icarus index 3,
/// as every ultimate in the catalog is but Miks's, and the rest are listed.
AbilityInfo? replayKillAbility(String? damageSource, AgentType? killer) {
  if (damageSource == null) return null;
  final catalogued = replayAbilityFor(damageSource);
  if (catalogued != null) return catalogued.ability;
  if (killer == null) return null;
  final slot = RegExp(r'/Ability_([^/]+)/').firstMatch(damageSource)?.group(1);
  final index = _killSlots[killer]?[slot] ?? (slot == 'X' ? 3 : null);
  final abilities = AgentData.agents[killer]?.abilities;
  if (index == null || abilities == null || index >= abilities.length) {
    return null;
  }
  return abilities[index];
}

/// Icarus ability index by slot folder, where the rule above doesn't hold.
const Map<AgentType, Map<String, int>> _killSlots = {
  AgentType.chamber: {'Q': 1}, // Headhunter
  AgentType.miks: {'X': 4},
};
