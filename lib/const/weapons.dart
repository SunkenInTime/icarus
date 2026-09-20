/// Firearms available for a placed agent. Names are the stable JSON values;
/// append new entries rather than reordering the existing Hive enum values.
enum WeaponType {
  none('None', null),
  classic('Classic', WeaponCategory.sidearms),
  shorty('Shorty', WeaponCategory.sidearms),
  frenzy('Frenzy', WeaponCategory.sidearms),
  ghost('Ghost', WeaponCategory.sidearms),
  bandit('Bandit', WeaponCategory.sidearms),
  sheriff('Sheriff', WeaponCategory.sidearms),
  bulldog('Bulldog', WeaponCategory.rifles),
  guardian('Guardian', WeaponCategory.rifles),
  phantom('Phantom', WeaponCategory.rifles),
  vandal('Vandal', WeaponCategory.rifles),
  bucky('Bucky', WeaponCategory.shotguns),
  judge('Judge', WeaponCategory.shotguns),
  stinger('Stinger', WeaponCategory.smgs),
  spectre('Spectre', WeaponCategory.smgs),
  marshal('Marshal', WeaponCategory.snipers),
  outlaw('Outlaw', WeaponCategory.snipers),
  operator('Operator', WeaponCategory.snipers),
  ares('Ares', WeaponCategory.heavies),
  odin('Odin', WeaponCategory.heavies);

  const WeaponType(this.displayName, this.category);

  final String displayName;
  final WeaponCategory? category;

  String get iconPath => 'assets/weapons/$name.png';
}

enum WeaponCategory {
  sidearms('Sidearms'),
  rifles('Rifles'),
  shotguns('Shotguns'),
  smgs('SMGs'),
  snipers('Snipers'),
  heavies('Heavies');

  const WeaponCategory(this.label);

  final String label;

  Iterable<WeaponType> get weapons =>
      WeaponType.values.where((weapon) => weapon.category == this);
}
