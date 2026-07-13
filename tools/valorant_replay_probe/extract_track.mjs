#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { applyValorantSeededPayloadTransform } from './valorant_seeded_payload_transform.mjs';
import { classifyUtilityActorCloses } from './lib/close_signature_classifier.mjs';

const require = createRequire(import.meta.url);
const TOOL_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(TOOL_DIR, '..', '..');
const PROFILE_ENABLED = process.env.VRF_PROFILE === '1';
const profileStartMs = Date.now();

function profile(label) {
  if (PROFILE_ENABLED) {
    const elapsedSeconds = ((Date.now() - profileStartMs) / 1000).toFixed(1);
    console.error(`[vrf-profile +${elapsedSeconds}s] ${label}`);
  }
}

const DEFAULT_REPLAY_DIR =
  'C:\\Users\\shawn\\AppData\\Local\\VALORANT\\Saved\\Demos';
const UNREAL_REPLAY_MAGIC = 0x2cf5a13d;
const CHUNK_TYPES = new Map([
  [0, 'HEADER'],
  [1, 'REPLAY_DATA'],
  [2, 'CHECKPOINT'],
  [3, 'EVENT'],
]);

const REPLAY_CONTROLLER_CANDIDATE_FIELD_HANDLES = new Set([
  1, 2, 3, 8, 10, 16, 21, 23, 24, 26, 28, 29, 30, 32, 34, 35, 37, 40, 46,
  48, 54, 56, 58, 63, 67, 68, 70, 71, 72, 75, 77, 79, 81, 82, 85, 88, 89,
  90, 96, 99, 100, 103, 110, 112, 119, 122, 123, 126, 135,
]);
const REPLAY_CONTROLLER_CANDIDATE_FIELD_TOTAL_SAMPLE_LIMIT = 350_000;
const REPLAY_CONTROLLER_CANDIDATE_FIELD_PER_HANDLE_SAMPLE_LIMIT = 350_000;
const REPLAY_CONTROLLER_CANDIDATE_FIELD_GENERIC_PER_HANDLE_SAMPLE_LIMIT = 1_500;
const REPLAY_CONTROLLER_CANDIDATE_FIELD_GENERIC_PAYLOAD_BIT_LIMIT = 512;
const REPLAY_CONTROLLER_CANDIDATE_FIELD_PAYLOAD_BIT_LIMIT = 8192;
const REPLAY_CONTROLLER_TARGET_FIELD_MIN_CAPTURE_INTERVAL_MS = 50;
const RPC_HIT_PREVIEW_LIMIT = 40;
const UTILITY_ACTOR_SAMPLE_LIMIT = 5000;

const CHARACTER_ID_TO_AGENT = new Map([
  ['e370fa57-4757-3604-3648-499e1f642d3f', 'Gekko'],
  ['dade69b4-4f5a-8528-247b-219e5a1facd6', 'Fade'],
  ['5f8d3a7f-467b-97f3-062c-13acf203c006', 'Breach'],
  ['cc8b64c8-4b25-4ff9-6e7f-37b4da43d235', 'Deadlock'],
  ['b444168c-4e35-8076-db47-ef9bf368f384', 'Tejo'],
  ['f94c3b30-42be-e959-889c-5aa313dba261', 'Raze'],
  ['22697a3d-45bf-8dd7-4fec-84a9e28c69d7', 'Chamber'],
  ['601dbbe7-43ce-be57-2a40-4abd24953621', 'KAY/O'],
  ['6f2a04ca-43e0-be17-7f36-b3908627744d', 'Skye'],
  ['117ed9e3-49f3-6512-3ccf-0cada7e3823b', 'Cypher'],
  ['320b2a48-4d9b-a075-30f1-1f93a9b638fa', 'Sova'],
  ['1e58de9c-4950-5125-93e9-a0aee9f98746', 'Killjoy'],
  ['95b78ed7-4637-86d9-7e41-71ba8c293152', 'Harbor'],
  ['efba5359-4016-a1e5-7626-b1ae76895940', 'Vyse'],
  ['707eab51-4836-f488-046a-cda6bf494859', 'Viper'],
  ['eb93336a-449b-9c1b-0a54-a891f7921d69', 'Phoenix'],
  ['92eeef5d-43b5-1d4a-8d03-b3927a09034b', 'Veto'],
  ['7c8a4701-4de6-9355-b254-e09bc2a34b72', 'Miks'],
  ['41fb69c1-4189-7b37-f117-bcaf1e96f1bf', 'Astra'],
  ['9f0d8ba9-4140-b941-57d3-a7ad57c6b417', 'Brimstone'],
  ['0e38b510-41a8-5780-5e8f-568b2a4f2d6c', 'Iso'],
  ['1dbf2edd-4729-0984-3115-daa5eed44993', 'Clove'],
  ['bb2a4828-46eb-8cd1-e765-15848195d751', 'Neon'],
  ['7f94d92c-4234-0a36-9646-3a87eb8b5c89', 'Yoru'],
  ['df1cb487-4902-002e-5c17-d28e83e78588', 'Waylay'],
  ['569fdd95-4d10-43ab-ca70-79becc718b46', 'Sage'],
  ['a3bfb853-43b2-7238-a4f1-ad90e9e46bcc', 'Reyna'],
  ['8e253930-4c05-31dd-1b6c-968525494517', 'Omen'],
  ['add6443a-41bd-e414-f6ad-e58d267f4e95', 'Jett'],
]);

const MAP_VECTOR_BOUNDS = new Map([
  [
    'ascent',
    {
      xMultiplier: 0.00007,
      yMultiplier: -0.00007,
      xScalarToAdd: 0.813895,
      yScalarToAdd: 0.573242,
      minPercent: -0.08,
      maxPercent: 1.08,
      minZ: -500,
      maxZ: 900,
    },
  ],
]);

const VALORANT_AGENT_ARCHETYPE_TOKENS = new Map([
  ['aggrobot', { agent: 'Gekko', icarusAgentType: 'gekko' }],
  ['astra', { agent: 'Astra', icarusAgentType: 'astra' }],
  ['bountyhunter', { agent: 'Fade', icarusAgentType: 'fade' }],
  ['breach', { agent: 'Breach', icarusAgentType: 'breach' }],
  ['cable', { agent: 'Deadlock', icarusAgentType: 'deadlock' }],
  ['cashew', { agent: 'Tejo', icarusAgentType: 'tejo' }],
  ['clay', { agent: 'Raze', icarusAgentType: 'raze' }],
  ['deadeye', { agent: 'Chamber', icarusAgentType: 'chamber' }],
  ['grenadier', { agent: 'KAY/O', icarusAgentType: 'kayo' }],
  ['guide', { agent: 'Skye', icarusAgentType: 'skye' }],
  ['gumshoe', { agent: 'Cypher', icarusAgentType: 'cypher' }],
  ['harbor', { agent: 'Harbor', icarusAgentType: 'harbor' }],
  ['hunter', { agent: 'Sova', icarusAgentType: 'sova' }],
  ['iris', { agent: 'Miks', icarusAgentType: 'miks' }],
  ['jett', { agent: 'Jett', icarusAgentType: 'jett' }],
  ['kayo', { agent: 'KAY/O', icarusAgentType: 'kayo' }],
  ['killjoy', { agent: 'Killjoy', icarusAgentType: 'killjoy' }],
  ['mage', { agent: 'Harbor', icarusAgentType: 'harbor' }],
  ['miks', { agent: 'Miks', icarusAgentType: 'miks' }],
  ['nox', { agent: 'Vyse', icarusAgentType: 'vyse' }],
  ['pandemic', { agent: 'Viper', icarusAgentType: 'viper' }],
  ['phoenix', { agent: 'Phoenix', icarusAgentType: 'pheonix' }],
  ['pine', { agent: 'Veto', icarusAgentType: 'veto' }],
  ['raze', { agent: 'Raze', icarusAgentType: 'raze' }],
  ['rift', { agent: 'Astra', icarusAgentType: 'astra' }],
  ['sage', { agent: 'Sage', icarusAgentType: 'sage' }],
  ['sarge', { agent: 'Brimstone', icarusAgentType: 'brimstone' }],
  ['sequoia', { agent: 'Iso', icarusAgentType: 'iso' }],
  ['smonk', { agent: 'Clove', icarusAgentType: 'clove' }],
  ['sprinter', { agent: 'Neon', icarusAgentType: 'neon' }],
  ['stealth', { agent: 'Yoru', icarusAgentType: 'yoru' }],
  ['terra', { agent: 'Waylay', icarusAgentType: 'waylay' }],
  ['thorne', { agent: 'Sage', icarusAgentType: 'sage' }],
  ['vampire', { agent: 'Reyna', icarusAgentType: 'reyna' }],
  ['viper', { agent: 'Viper', icarusAgentType: 'viper' }],
  ['wraith', { agent: 'Omen', icarusAgentType: 'omen' }],
  ['wushu', { agent: 'Jett', icarusAgentType: 'jett' }],
  ['yoru', { agent: 'Yoru', icarusAgentType: 'yoru' }],
]);

const AGENT_ABILITY_NAMES = new Map([
  ['Astra', ['Gravity Well', 'Nova Pulse', 'Nebula/Dissipate', 'Cosmic Divide']],
  ['Breach', ['Aftershock', 'Flashpoint', 'Fault Line', 'Rolling Thunder']],
  ['Brimstone', ['Stim Beacon', 'Incendiary', 'Sky Smoke', 'Orbital Strike']],
  ['Chamber', ['Trademark', 'Headhunter', 'Rendezvous', 'Tour De Force']],
  ['Clove', ['Pick-me-up', 'Meddle', 'Ruse', 'Not Dead Yet']],
  ['Cypher', ['Trapwire', 'Cyber Cage', 'Spycam', 'Neural Theft']],
  ['Deadlock', ['Barrier Mesh', 'Sonic Sensor', 'GravNet', 'Annihilation']],
  ['Fade', ['Prowler', 'Seize', 'Haunt', 'Nightfall']],
  ['Gekko', ['Mosh Pit', 'Wingman', 'Dizzy', 'Thrash']],
  ['Harbor', ['Storm Surge', 'High Tide', 'Cove', 'Reckoning']],
  ['Iso', ['Contingency', 'Undercut', 'Double Tap', 'Kill Contract']],
  ['Jett', ['Cloudburst', 'Updraft', 'Tailwind', 'Blade Storm']],
  ['KAY/O', ['FRAG/ment', 'FLASH/drive', 'ZERO/point', 'NULL/cmd']],
  ['Killjoy', ['Nanoswarm', 'Alarmbot', 'Turret', 'Lockdown']],
  ['Miks', ['M-pulse Concuss', 'M-pulse Healing', 'Harmonize', 'Waveform', 'Bassquake']],
  ['Neon', ['Fast Lane', 'Relay Bolt', 'High Gear', 'Overdrive']],
  ['Omen', ['Shrouded Step', 'Paranoia', 'Dark Cover', 'From the Shadows']],
  ['Phoenix', ['Blaze', 'Hot Hands', 'Curveball', 'Run it Back']],
  ['Raze', ['Boom Bot', 'Blast Pack', 'Paint Shells', 'Showstopper']],
  ['Reyna', ['Leer', 'Devour', 'Dismiss', 'Empress']],
  ['Sage', ['Barrier Orb', 'Slow Orb', 'Healing Orb', 'Resurrection']],
  ['Skye', ['Regrowth', 'Trailblazer', 'Guiding Light', 'Seekers']],
  ['Sova', ['Owl Drone', 'Shock Bolt', 'Recon Bolt', "Hunter's Fury"]],
  ['Tejo', ['Stealth Drone', 'Special Delivery', 'Guided Salvo', 'Armageddon']],
  ['Veto', ['Crosscut', 'Chokehold', 'Interceptor', 'Evolution']],
  ['Viper', ['Snake Bite', 'Poison Cloud', 'Toxic Screen', "Viper's Pit"]],
  ['Vyse', ['Razorvine', 'Shear', 'Arc Rose', 'Steel Garden']],
  ['Waylay', ['Saturate', 'Lightspeed', 'Refract', 'Convergent Paths']],
  ['Yoru', ['Fakeout', 'Blindside', 'Gatecrash', 'Dimensional Drift']],
]);

const CLASS_ABILITY_OVERRIDES = [
  { pattern: /Sarge_E_SpeedStim/i, agent: 'Brimstone', abilitySlot: 'Grenade', abilityIndex: 0 },
  { pattern: /Sarge_Q_Molotov/i, agent: 'Brimstone', abilitySlot: 'Ability1', abilityIndex: 1 },
  { pattern: /Sarge_4_(?:MapTargetSmoke|Smoke)/i, agent: 'Brimstone', abilitySlot: 'Ability2', abilityIndex: 2 },
  { pattern: /Sarge_X_OrbitalStrike/i, agent: 'Brimstone', abilitySlot: 'Ultimate', abilityIndex: 3 },
  { pattern: /Aggrobot_(?:C_)?ExplodeyPatch/i, agent: 'Gekko', abilitySlot: 'Grenade', abilityIndex: 0 },
  { pattern: /Aggrobot_(?:Q_)?SeekerNade/i, agent: 'Gekko', abilitySlot: 'Ability1', abilityIndex: 1 },
  { pattern: /Aggrobot_(?:E_)?(?:DiscTurret|OrbSpawner|PowerWave|Zamboni)/i, agent: 'Gekko', abilitySlot: 'Ability2', abilityIndex: 2 },
  { pattern: /Aggrobot_(?:X_|Rolly)/i, agent: 'Gekko', abilitySlot: 'Ultimate', abilityIndex: 3 },
  { pattern: /Phoenix_(?:Q_)?(?:FireballWall|FlameWall)/i, agent: 'Phoenix', abilitySlot: 'Grenade', abilityIndex: 0 },
  { pattern: /Phoenix_(?:4_)?Molotov|Phoenix_MolotovFire/i, agent: 'Phoenix', abilitySlot: 'Ability1', abilityIndex: 1 },
  { pattern: /Phoenix_E_FlareCurve/i, agent: 'Phoenix', abilitySlot: 'Ability2', abilityIndex: 2 },
  { pattern: /Phoenix_X_(?:SelfRes|ResTarget)/i, agent: 'Phoenix', abilitySlot: 'Ultimate', abilityIndex: 3 },
  { pattern: /Nox_(?:4_)?BarbedWire/i, agent: 'Vyse', abilitySlot: 'Grenade', abilityIndex: 0 },
  { pattern: /Nox_(?:Q_)?Wall(?:Trap)?/i, agent: 'Vyse', abilitySlot: 'Ability1', abilityIndex: 1 },
  { pattern: /Nox_(?:E_)?(?:FlashTrap|StealthingTrap_Flash)/i, agent: 'Vyse', abilitySlot: 'Ability2', abilityIndex: 2 },
  { pattern: /Nox_(?:X_)?DisarmPulse/i, agent: 'Vyse', abilitySlot: 'Ultimate', abilityIndex: 3 },
  { pattern: /Clay_E_Boomba|BoomBot|Boomba/i, agent: 'Raze', abilitySlot: 'Grenade', abilityIndex: 0 },
  { pattern: /Clay_Q_Satchel|Satchel|BlastPack/i, agent: 'Raze', abilitySlot: 'Ability1', abilityIndex: 1 },
  { pattern: /Clay_4_ClusterGrenade|PaintShell|ClusterGrenade/i, agent: 'Raze', abilitySlot: 'Ability2', abilityIndex: 2 },
  { pattern: /Hunter_E_(?:Deploy)?Drone|OwlDrone|Drone_Abilities/i, agent: 'Sova', abilitySlot: 'Grenade', abilityIndex: 0 },
  { pattern: /Hunter_4_(?:BoltExplosive|ExplosiveBolt)|ShockBolt|BoltExplosive|ExplosiveBolt/i, agent: 'Sova', abilitySlot: 'Ability1', abilityIndex: 1 },
  { pattern: /^(?:Projectile_|GameObject_|Ability_)?Hunter_Q_(?:RevealBolt|Sonar)/i, agent: 'Sova', abilitySlot: 'Ability2', abilityIndex: 2 },
  { pattern: /Deadeye_4_Trap|Deadeye_E_Trap|Deadeye_E_Slow|Trademark/i, agent: 'Chamber', abilitySlot: 'Grenade', abilityIndex: 0 },
  { pattern: /Deadeye_E_Teleporter|Rendezvous/i, agent: 'Chamber', abilitySlot: 'Ability2', abilityIndex: 2 },
  { pattern: /(?:Neon_C_Tunnel|Sprinter_4_Tunnel|FastLane)/i, agent: 'Neon', abilitySlot: 'Grenade', abilityIndex: 0 },
  { pattern: /Sprinter_4_GroundStrike|RelayBolt|GroundStrike/i, agent: 'Neon', abilitySlot: 'Ability1', abilityIndex: 1 },
  { pattern: /Wraith_E_ShortTeleport|ShroudedStep/i, agent: 'Omen', abilitySlot: 'Grenade', abilityIndex: 0 },
  { pattern: /Wraith_Q_NearsightMissile|Paranoia/i, agent: 'Omen', abilitySlot: 'Ability1', abilityIndex: 1 },
  { pattern: /Wraith_4_Smoke|DarkCover/i, agent: 'Omen', abilitySlot: 'Ability2', abilityIndex: 2 },
  { pattern: /Wraith_X_GlobalTeleport|GlobalTeleport|FromTheShadows/i, agent: 'Omen', abilitySlot: 'Ultimate', abilityIndex: 3 },
];

const ICARUS_AGENT_TYPE_BY_AGENT = new Map(
  [...VALORANT_AGENT_ARCHETYPE_TOKENS.values()].map((entry) => [entry.agent, entry.icarusAgentType]),
);

const ABILITY_KEY_TO_SLOT = new Map([
  ['4', { abilitySlot: 'Grenade', abilityIndex: 0 }],
  ['c', { abilitySlot: 'Grenade', abilityIndex: 0 }],
  ['q', { abilitySlot: 'Ability1', abilityIndex: 1 }],
  ['e', { abilitySlot: 'Ability2', abilityIndex: 2 }],
  ['x', { abilitySlot: 'Ultimate', abilityIndex: 3 }],
]);

const UTILITY_KIND_RULES = [
  // Arc Rose's placed trap class contains "Flash", but it is the persistent
  // device, not the short-lived flash effect produced after activation.
  { pattern: /GameObject_Nox_StealthingTrap_Flash(?:_\d+)?/i, kind: 'deployable' },
  { pattern: /smoke|darkcover|ruse|cove|cybercage|poisoncloud/i, kind: 'smoke' },
  { pattern: /molotov|molly|incendiary|snakebite|nanoswarm|razorvine|slowfield|slow/i, kind: 'area-denial' },
  { pattern: /flash|flarecurve|guidinglight|hawk|arcrose|leer|nearsight/i, kind: 'flash-or-blind' },
  { pattern: /wall|flamewall|barrier|toxicscreen|high_tide|hightide|fastlane/i, kind: 'wall' },
  { pattern: /drone|owldrone|trailblazer|boombot|turret|alarmbot|spycam|trap|trademark|sensor/i, kind: 'deployable' },
  { pattern: /satchel|blastpack|teleport|gatecrash|updraft|cycloneboost|tailwind/i, kind: 'movement-or-mobility' },
  { pattern: /reveal|recon|dart|haunt|locator|zeropoint/i, kind: 'reveal' },
  { pattern: /grenade|projectile|fireball|shock|paintshell|fragment|mosh|undercut/i, kind: 'projectile' },
  { pattern: /ultimate|selfres|postdeath|hunterfury|orbital|lockdown/i, kind: 'ultimate' },
];

const UTILITY_ACTOR_INITIAL_REPLICATION_GRACE_MS = 1_000;
const LEGACY_RESEARCH_ROUND_STATE_LIFETIME_MS = 180_000;
const DEFAULT_ABILITY_SIGNAL_SAMPLE_LIMIT = 50_000;
const DEFAULT_INPUT_EVENT_CAPTURE_SAMPLE_LIMIT = 10_000;
const DEFAULT_NON_MOVEMENT_INPUT_EVENT_SAMPLE_LIMIT = 100_000;
const DEFAULT_DIAGNOSTIC_ACTOR_WIRE_SAMPLE_LIMIT = 100_000;
const ABILITY_SIGNAL_PAYLOAD_HEX_LIMIT = 512;
const DEFAULT_ABILITY_CAST_SIGNAL_SAMPLE_LIMIT = 50_000;
const ABILITY_CAST_SIGNAL_PAYLOAD_HEX_LIMIT = 16_384;
const ABILITY_CAST_PAYLOAD_HEX_LIMIT = 192;
const ABILITY_CAST_UUID_PATTERN =
  /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;

const ARES_ITEM_SLOT_TO_ABILITY_SLOT = new Map([
  [3, 'Grenade'],
  [4, 'Ability1'],
  [5, 'Ability2'],
  // EAresItemSlot 6 is Passive in the local replay schema; ultimates are 9.
  [9, 'Ultimate'],
]);

const INPUT_EVENT_TYPE_NAMES = new Map([
  [0, 'EquippableInput'],
  [1, 'ActivationInput'],
  [3, 'MovementInput'],
  [4, 'EquippableChange'],
  [8, 'EquippableDrop'],
  [10, 'InteractInput'],
]);

const ARES_GAME_PHASE_NAMES = new Map([
  [0, 'NotStarted'],
  [1, 'GameStarted'],
  [2, 'BetweenRounds'],
  [3, 'RoundStarting'],
  [4, 'InRound'],
  [5, 'RoundEnding'],
  [6, 'SwitchingTeams'],
  [7, 'GameEnded'],
  [8, 'Count'],
  [9, 'Invalid'],
]);

const ABILITY_STATISTIC_NAMES = [
  'EnemiesBlinded', 'DamageDone', 'EnemiesKilled', 'KillAssists',
  'EnemiesConcussed', 'EnemiesDisplaced', 'EnemiesRevealed', 'EnemiesBlocked',
  'EnemiesNearsighted', 'HealingDone', 'AlliesStimmed', 'KillsAfterTeleport',
  'EnemiesSlowed', 'DamageSoaked', 'BoostKills', 'EnemiesSpotted',
  'EnemiesVulnerabled', 'AlliesBlinded', 'EnemiesDetained', 'EnemiesSuppressed',
  'ItemsRecalled', 'ConditionsMet', 'TeleportedTo', 'TeleportedFrom',
  'ItemsDestroyed', 'ShotsFired', 'Telemetry', 'TimeSprinting', 'SlideStart',
  'SlideEnd', 'AlliesDowned', 'AlliesRevived', 'InteractedWith', 'Activated',
  'DistanceTraveled', 'EnemiesMarked', 'EnemiesSeized', 'TelemetryMode',
  'Lifetime', 'WasTempCharge', 'PrimarySuccess', 'SecondarySuccess',
  'DistanceFromSpawn', 'DefuseAttempts', 'PlantAttempts', 'AttackMode',
  'FinalHealth', 'Primary', 'Secondary', 'DebuffDuration', 'AlliesConcussed',
  'AlliesSeized', 'TimeSpotted', 'AlliesMarked', 'AlliesKilled',
  'AlliesSpotted', 'AlliesSlowed', 'EnemiesJammed', 'KilledWhileDisarmed',
  'KillsWhileDisarmed', 'HasLineOfSight', 'UtilsDamaged', 'UtilsDestroyed',
  'DamageDoneToUtils', 'TargetKills', 'DebuffResisted',
  'InitialAffectedRoundTime', 'AlliesHealed', 'EnemiesHealed', 'StimDuration',
  'StimRefresh', 'KilledWhileStimmed', 'AlliesSaved',
];

const GENERATED_DECODER_INDEX_DIR = path.join(
  REPO_ROOT,
  'tmp',
  'valorant_export_research',
  'indexes',
);
const BUNDLED_DECODER_INDEX_DIR = path.join(TOOL_DIR, 'static_decoder_indexes');
const VERIFIED_ABILITY_LIFECYCLE_REGISTRY_PATH = path.join(
  TOOL_DIR,
  'verified_ability_lifecycle_registry.json',
);
const STATIC_DECODER_INDEX_DIR = (() => {
  if (process.env.VALORANT_DECODER_INDEX_DIR) {
    return path.resolve(process.env.VALORANT_DECODER_INDEX_DIR);
  }
  if (fs.existsSync(path.join(GENERATED_DECODER_INDEX_DIR, 'ability_identity_index.json'))) {
    return GENERATED_DECODER_INDEX_DIR;
  }
  return BUNDLED_DECODER_INDEX_DIR;
})();

function seconds(value) {
  return Math.round(value * 1000);
}

let verifiedAbilityLifecycleRegistry;

function loadVerifiedAbilityLifecycleRegistry() {
  if (verifiedAbilityLifecycleRegistry !== undefined) {
    return verifiedAbilityLifecycleRegistry;
  }
  if (!fs.existsSync(VERIFIED_ABILITY_LIFECYCLE_REGISTRY_PATH)) {
    verifiedAbilityLifecycleRegistry = { version: 1, abilities: [] };
    return verifiedAbilityLifecycleRegistry;
  }
  try {
    verifiedAbilityLifecycleRegistry = JSON.parse(
      fs.readFileSync(VERIFIED_ABILITY_LIFECYCLE_REGISTRY_PATH, 'utf8'),
    );
  } catch (error) {
    throw new Error(
      `Could not read verified ability lifecycle registry: ${error.message}`,
    );
  }
  return verifiedAbilityLifecycleRegistry;
}

function verifiedUtilityActorLifecycleRule(className) {
  const registry = loadVerifiedAbilityLifecycleRegistry();
  const abilities = Array.isArray(registry?.abilities) ? registry.abilities : [];
  for (const ability of abilities) {
    if (ability?.status === 'proposed') continue;
    const actorRules = Array.isArray(ability?.actorRules)
      ? ability.actorRules
      : Array.isArray(ability?.actors)
        ? ability.actors
        : [];
    for (const actorRule of actorRules) {
      const patternText = actorRule?.classPattern ?? actorRule?.classNamePattern;
      if (!patternText) continue;
      let pattern;
      try {
        pattern = new RegExp(patternText, actorRule?.caseSensitive ? '' : 'i');
      } catch (error) {
        throw new Error(
          `Invalid classPattern for verified lifecycle ${ability.abilityId ?? 'unknown'}: ${error.message}`,
        );
      }
      if (!pattern.test(className)) continue;
      return {
        ...actorRule,
        abilityId: ability.abilityId ?? ability.id ?? null,
        source:
          actorRule.source ??
          `verified-registry:${ability.abilityId ?? ability.id ?? 'unknown'}`,
      };
    }
  }
  return null;
}

// Historical research catalog only. The native decoder never reads this table;
// it remains temporarily as a comparison corpus for auditing old tracks. No
// value below may enter utilityActors[], abilityActions[], or map playback.
const LEGACY_RESEARCH_DISPLAY_LIFETIME_RULES = [
  { pattern: /EquippablePickupProjectile/i, lifetimeMs: null, source: 'ignored-non-ability-projectile' },

  { pattern: /GravityWell/i, lifetimeMs: seconds(2), source: 'wiki:astra-gravity-well' },
  { pattern: /NovaPulse/i, lifetimeMs: seconds(2.5), source: 'wiki:astra-nova-pulse-concuss' },
  { pattern: /(?:Nebula|Dissipate|Rift).*Smoke|Smoke.*Rift/i, lifetimeMs: seconds(14.25), source: 'wiki:astra-nebula' },
  { pattern: /CosmicDivide/i, lifetimeMs: seconds(21), source: 'wiki:astra-cosmic-divide' },

  { pattern: /Aftershock/i, lifetimeMs: seconds(2), source: 'heuristic:breach-aftershock' },
  { pattern: /Flashpoint|FlashpointCharge/i, lifetimeMs: seconds(2.25), source: 'wiki:breach-flashpoint-flash' },
  { pattern: /FaultLine/i, lifetimeMs: seconds(2.5), source: 'wiki:breach-fault-line-concuss' },
  { pattern: /RollingThunder/i, lifetimeMs: seconds(4), source: 'wiki:breach-rolling-thunder-concuss' },

  { pattern: /StimBeacon/i, lifetimeMs: seconds(12), source: 'wiki:brimstone-stim-beacon' },
  { pattern: /Incendiary|Sarge.*Molly|Sarge.*Burn/i, lifetimeMs: seconds(8), source: 'wiki:brimstone-incendiary' },
  { pattern: /Sarge.*Smoke|SkySmoke/i, lifetimeMs: seconds(19.25), source: 'wiki:brimstone-sky-smoke' },
  { pattern: /Orbital/i, lifetimeMs: seconds(3.75), source: 'wiki:brimstone-orbital-strike' },

  { pattern: /Trademark|Trap/i, agent: 'chamber', lifetimeMs: LEGACY_RESEARCH_ROUND_STATE_LIFETIME_MS, source: 'wiki:chamber-trademark-until-destroyed' },
  { pattern: /Rendezvous|Teleport/i, agent: 'chamber', lifetimeMs: LEGACY_RESEARCH_ROUND_STATE_LIFETIME_MS, source: 'wiki:chamber-rendezvous-anchor-until-recalled' },
  { pattern: /TourDeForce/i, agent: 'chamber', lifetimeMs: LEGACY_RESEARCH_ROUND_STATE_LIFETIME_MS, source: 'heuristic:chamber-tour-de-force-round-state' },

  { pattern: /Pick.?me.?up|PickMeUp/i, lifetimeMs: seconds(10), source: 'wiki:clove-pick-me-up' },
  { pattern: /Meddle|DebuffKnife/i, lifetimeMs: seconds(5), source: 'wiki:clove-meddle' },
  { pattern: /Smonk.*(?:Smoke|Ruse)|NewSmoke|MapTargetSmoke/i, lifetimeMs: seconds(14), source: 'wiki:clove-ruse' },
  { pattern: /PostDeath|ReactiveRes|NotDeadYet/i, agent: 'clove', lifetimeMs: seconds(10), source: 'wiki:clove-not-dead-yet' },

  { pattern: /Trapwire/i, lifetimeMs: LEGACY_RESEARCH_ROUND_STATE_LIFETIME_MS, source: 'wiki:cypher-trapwire-until-destroyed' },
  { pattern: /CyberCage/i, lifetimeMs: seconds(7.25), source: 'wiki:cypher-cyber-cage' },
  { pattern: /Spycam/i, lifetimeMs: LEGACY_RESEARCH_ROUND_STATE_LIFETIME_MS, source: 'wiki:cypher-spycam-until-destroyed' },
  { pattern: /NeuralTheft/i, lifetimeMs: seconds(2), source: 'heuristic:cypher-neural-theft-pulses' },

  { pattern: /BarrierMesh/i, lifetimeMs: seconds(30), source: 'wiki:deadlock-barrier-mesh' },
  { pattern: /SonicSensor/i, lifetimeMs: LEGACY_RESEARCH_ROUND_STATE_LIFETIME_MS, source: 'wiki:deadlock-sonic-sensor-until-destroyed' },
  { pattern: /GravNet/i, lifetimeMs: seconds(6), source: 'heuristic:deadlock-gravnet-zone' },
  { pattern: /Annihilation/i, lifetimeMs: seconds(10), source: 'wiki:deadlock-annihilation' },

  { pattern: /Prowler/i, lifetimeMs: seconds(2.5), source: 'wiki:fade-prowler' },
  { pattern: /Seize/i, lifetimeMs: seconds(4.5), source: 'wiki:fade-seize' },
  { pattern: /Haunt|Eye/i, agent: 'fade', lifetimeMs: seconds(1.5), source: 'wiki:fade-haunt' },
  { pattern: /Nightfall/i, lifetimeMs: seconds(8), source: 'wiki:fade-nightfall-mark' },

  { pattern: /Mosh/i, lifetimeMs: seconds(4), source: 'heuristic:gekko-mosh-pit' },
  { pattern: /Wingman/i, lifetimeMs: seconds(5), source: 'wiki:gekko-wingman' },
  { pattern: /Dizzy/i, lifetimeMs: seconds(1), source: 'wiki:gekko-dizzy' },
  { pattern: /Thrash/i, lifetimeMs: seconds(6), source: 'wiki:gekko-thrash-search' },

  { pattern: /StormSurge/i, lifetimeMs: seconds(7), source: 'wiki:harbor-storm-surge' },
  { pattern: /HighTide|High_Tide/i, lifetimeMs: seconds(15), source: 'wiki:harbor-high-tide' },
  { pattern: /Cove/i, lifetimeMs: seconds(19.25), source: 'wiki:harbor-cove' },
  { pattern: /Reckoning/i, lifetimeMs: seconds(9), source: 'wiki:harbor-reckoning' },
  { pattern: /Cascade/i, lifetimeMs: seconds(7), source: 'wiki:harbor-cascade' },

  { pattern: /Contingency/i, lifetimeMs: seconds(5.4), source: 'wiki:iso-contingency' },
  { pattern: /Undercut|FragileMissile/i, lifetimeMs: seconds(1.55), source: 'wiki:iso-undercut' },
  { pattern: /DoubleTap|EnergyOrb/i, lifetimeMs: seconds(12), source: 'wiki:iso-double-tap' },
  { pattern: /KillContract|Arena|LineCapture|ArenaCover/i, agent: 'iso', lifetimeMs: seconds(13), source: 'wiki:iso-kill-contract' },

  { pattern: /Cloudburst|Wushu.*Smoke/i, lifetimeMs: seconds(2.5), source: 'wiki:jett-cloudburst' },
  { pattern: /Updraft|CycloneBoost/i, lifetimeMs: seconds(0.6), source: 'wiki:jett-updraft' },
  { pattern: /Tailwind|Dash/i, agent: 'jett', lifetimeMs: seconds(0.45), source: 'wiki:jett-tailwind-dash' },
  { pattern: /BladeStorm|Dagger/i, agent: 'jett', lifetimeMs: LEGACY_RESEARCH_ROUND_STATE_LIFETIME_MS, source: 'heuristic:jett-blade-storm-round-state' },

  { pattern: /Semtex|FRAG|Fragment/i, agent: 'kayo', lifetimeMs: seconds(4), source: 'wiki:kayo-frag-ment' },
  { pattern: /Flash/i, agent: 'kayo', lifetimeMs: seconds(2.25), source: 'wiki:kayo-flash-drive' },
  { pattern: /EMPKnife|SuppressionPulse|ZeroPoint/i, agent: 'kayo', lifetimeMs: seconds(8), source: 'wiki:kayo-zero-point' },
  { pattern: /OverloadPulse|NULL/i, agent: 'kayo', lifetimeMs: seconds(12), source: 'wiki:kayo-null-cmd' },

  { pattern: /Nanoswarm|RemoteBees/i, lifetimeMs: seconds(4), source: 'wiki:killjoy-nanoswarm' },
  { pattern: /Alarmbot/i, lifetimeMs: LEGACY_RESEARCH_ROUND_STATE_LIFETIME_MS, source: 'wiki:killjoy-alarmbot-until-destroyed' },
  { pattern: /Turret(?!Attack)|Pawn_Killjoy_E_Turret/i, agent: 'killjoy', lifetimeMs: LEGACY_RESEARCH_ROUND_STATE_LIFETIME_MS, source: 'wiki:killjoy-turret-until-destroyed' },
  { pattern: /TurretAttack/i, lifetimeMs: seconds(1), source: 'heuristic:killjoy-turret-burst' },
  { pattern: /Lockdown|Killjoy_X_Bomb/i, lifetimeMs: seconds(13), source: 'wiki:killjoy-lockdown' },

  { pattern: /M.?pulse|Thumper|Concuss/i, agent: 'miks', lifetimeMs: seconds(5), source: 'wiki:miks-m-pulse' },
  { pattern: /Harmonize/i, lifetimeMs: seconds(8), source: 'wiki:miks-harmonize' },
  { pattern: /Waveform|Iris.*Smoke/i, lifetimeMs: seconds(16.75), source: 'wiki:miks-waveform' },
  { pattern: /Bassquake|SonicWave/i, lifetimeMs: seconds(8), source: 'wiki:miks-bassquake' },

  { pattern: /FastLane|Tunnel/i, agent: 'neon', lifetimeMs: seconds(4), source: 'wiki:neon-fast-lane' },
  { pattern: /RelayBolt|GroundStrike/i, agent: 'neon', lifetimeMs: seconds(2.5), source: 'wiki:neon-relay-bolt-concuss' },
  { pattern: /HighGear|Slide/i, agent: 'neon', lifetimeMs: seconds(0.6), source: 'wiki:neon-high-gear-slide' },
  { pattern: /Overdrive/i, agent: 'neon', lifetimeMs: LEGACY_RESEARCH_ROUND_STATE_LIFETIME_MS, source: 'heuristic:neon-overdrive-energy-state' },

  { pattern: /FromTheShadows|GlobalTeleport/i, agent: 'omen', lifetimeMs: seconds(4), source: 'wiki:omen-from-the-shadows' },
  { pattern: /ShroudedStep|ShortTeleport/i, agent: 'omen', lifetimeMs: seconds(1.2), source: 'wiki:omen-shrouded-step' },
  { pattern: /Paranoia|NearsightMissile/i, lifetimeMs: seconds(2), source: 'heuristic:omen-paranoia-nearsight' },
  { pattern: /DarkCover|Wraith.*Smoke/i, lifetimeMs: seconds(15), source: 'wiki:omen-dark-cover' },

  { pattern: /FlameWall|Blaze|FireballWall/i, lifetimeMs: seconds(8), source: 'wiki:phoenix-blaze' },
  { pattern: /Molotov|HotHands|MolotovFire/i, agent: 'pheonix', lifetimeMs: seconds(4), source: 'wiki:phoenix-hot-hands' },
  { pattern: /FlareCurve|Curveball/i, lifetimeMs: seconds(1.5), source: 'wiki:phoenix-curveball-flash' },
  { pattern: /SelfRes|RunItBack|ResTarget/i, agent: 'pheonix', lifetimeMs: seconds(10), source: 'wiki:phoenix-run-it-back' },

  { pattern: /BoomBot|Boomba/i, lifetimeMs: seconds(5), source: 'wiki:raze-boom-bot' },
  { pattern: /Satchel|BlastPack/i, lifetimeMs: seconds(5), source: 'wiki:raze-blast-pack' },
  { pattern: /PaintShell|ClusterGrenade|Projectile_Clay_4/i, lifetimeMs: seconds(3), source: 'heuristic:raze-paint-shells' },
  { pattern: /Showstopper|RocketLauncher/i, lifetimeMs: seconds(10), source: 'wiki:raze-showstopper' },

  { pattern: /Leer|Nearsight/i, agent: 'reyna', lifetimeMs: seconds(1.6), source: 'wiki:reyna-leer' },
  { pattern: /Devour|Heal/i, agent: 'reyna', lifetimeMs: seconds(3), source: 'wiki:reyna-devour' },
  { pattern: /Dismiss/i, lifetimeMs: seconds(1.5), source: 'wiki:reyna-dismiss' },
  { pattern: /Empress/i, lifetimeMs: LEGACY_RESEARCH_ROUND_STATE_LIFETIME_MS, source: 'wiki:reyna-empress-round-state' },

  { pattern: /BarrierOrb|Wall_Fortifying|Wall_Segment/i, lifetimeMs: seconds(40), source: 'wiki:sage-barrier-orb' },
  { pattern: /SlowOrb|SlowField|Slow/i, agent: 'sage', lifetimeMs: seconds(7), source: 'wiki:sage-slow-orb' },
  { pattern: /HealingOrb|HealPool/i, agent: 'sage', lifetimeMs: seconds(5), source: 'wiki:sage-healing-orb' },
  { pattern: /Resurrection|ReactiveResStart/i, agent: 'sage', lifetimeMs: seconds(3), source: 'heuristic:sage-resurrection-rise' },

  { pattern: /Regrowth/i, lifetimeMs: seconds(5), source: 'heuristic:skye-regrowth-channel' },
  { pattern: /Trailblazer|Scout/i, agent: 'skye', lifetimeMs: seconds(6), source: 'wiki:skye-trailblazer' },
  { pattern: /GuidingLight|HawkFlash|FlashSource/i, lifetimeMs: seconds(2), source: 'wiki:skye-guiding-light' },
  { pattern: /Seekers/i, lifetimeMs: seconds(15), source: 'wiki:skye-seekers' },

  { pattern: /OwlDrone|Hunter_E_(?:Deploy)?Drone|Drone_Abilities/i, agent: 'sova', lifetimeMs: seconds(7), source: 'wiki:sova-owl-drone' },
  { pattern: /ShockBolt|BoltExplosive|ExplosiveBolt/i, agent: 'sova', lifetimeMs: seconds(2), source: 'heuristic:sova-shock-bolt' },
  { pattern: /RevealBolt|SonarPing|Recon/i, agent: 'sova', lifetimeMs: seconds(4), source: 'wiki:sova-recon-bolt' },
  { pattern: /Hunter.*Fury|LaserMulti/i, agent: 'sova', lifetimeMs: seconds(6), source: 'wiki:sova-hunters-fury' },

  { pattern: /StealthDrone/i, lifetimeMs: seconds(6), source: 'wiki:tejo-stealth-drone' },
  { pattern: /SpecialDelivery/i, lifetimeMs: seconds(2.5), source: 'wiki:tejo-special-delivery-concuss' },
  { pattern: /GuidedSalvo/i, lifetimeMs: seconds(3), source: 'heuristic:tejo-guided-salvo-strike' },
  { pattern: /Armageddon/i, lifetimeMs: seconds(6), source: 'heuristic:tejo-armageddon-strike' },

  { pattern: /Crosscut/i, lifetimeMs: LEGACY_RESEARCH_ROUND_STATE_LIFETIME_MS, source: 'wiki:veto-crosscut-until-destroyed' },
  { pattern: /Chokehold/i, lifetimeMs: seconds(4.5), source: 'wiki:veto-chokehold' },
  { pattern: /Interceptor/i, lifetimeMs: seconds(9), source: 'wiki:veto-interceptor' },
  { pattern: /Evolution/i, lifetimeMs: LEGACY_RESEARCH_ROUND_STATE_LIFETIME_MS, source: 'wiki:veto-evolution-round-state' },

  { pattern: /SnakeBite/i, lifetimeMs: seconds(6.5), source: 'wiki:viper-snake-bite' },
  { pattern: /PoisonCloud/i, lifetimeMs: seconds(12), source: 'wiki:viper-fuel-single-active-max' },
  { pattern: /ToxicScreen/i, lifetimeMs: seconds(12), source: 'wiki:viper-fuel-single-active-max' },
  { pattern: /Viper.*Pit|PoisonPit/i, lifetimeMs: LEGACY_RESEARCH_ROUND_STATE_LIFETIME_MS, source: 'wiki:viper-pit-indefinite-within-cloud' },

  { pattern: /Razorvine/i, lifetimeMs: seconds(6), source: 'wiki:vyse-razorvine' },
  { pattern: /Shear/i, lifetimeMs: seconds(6), source: 'wiki:vyse-shear' },
  { pattern: /ArcRose/i, lifetimeMs: LEGACY_RESEARCH_ROUND_STATE_LIFETIME_MS, source: 'wiki:vyse-arc-rose-until-destroyed' },
  { pattern: /SteelGarden/i, lifetimeMs: seconds(8), source: 'heuristic:vyse-steel-garden-jam' },

  { pattern: /Saturate/i, lifetimeMs: seconds(2.5), source: 'heuristic:waylay-saturate-field' },
  { pattern: /Lightspeed/i, lifetimeMs: seconds(0.9), source: 'wiki:waylay-lightspeed-two-dashes' },
  { pattern: /Refract/i, lifetimeMs: seconds(8), source: 'wiki:waylay-refract' },
  { pattern: /ConvergentPaths/i, lifetimeMs: seconds(7), source: 'wiki:waylay-convergent-paths' },

  { pattern: /Fakeout/i, lifetimeMs: seconds(10), source: 'wiki:yoru-fakeout' },
  { pattern: /Blindside/i, lifetimeMs: seconds(2), source: 'wiki:yoru-blindside' },
  { pattern: /Gatecrash/i, lifetimeMs: seconds(15), source: 'wiki:yoru-gatecrash' },
  { pattern: /DimensionalDrift/i, lifetimeMs: seconds(10), source: 'wiki:yoru-dimensional-drift' },
];

class Cursor {
  constructor(buffer, offset = 0) {
    this.buffer = buffer;
    this.offset = offset;
  }

  readInt32() {
    const value = this.buffer.readInt32LE(this.offset);
    this.offset += 4;
    return value;
  }

  readUInt32() {
    const value = this.buffer.readUInt32LE(this.offset);
    this.offset += 4;
    return value;
  }

  readUInt16() {
    const value = this.buffer.readUInt16LE(this.offset);
    this.offset += 2;
    return value;
  }

  skip(byteCount) {
    this.offset += byteCount;
  }
}

class BitReader {
  constructor(buffer, bitCount = buffer.length * 8, bitOffset = 0) {
    this.buffer = buffer;
    this.offset = bitOffset;
    this.lastBit = bitCount;
    this.isError = false;
  }

  cloneSlice(bitCount) {
    const bytes = this.readBits(bitCount);
    return new BitReader(bytes, bitCount);
  }

  fork(bitCount) {
    const child = new BitReader(this.buffer, this.offset + bitCount, this.offset);
    this.skipBits(bitCount);
    return child;
  }

  canRead(bitCount) {
    return this.offset + bitCount <= this.lastBit;
  }

  atEnd() {
    return this.offset >= this.lastBit;
  }

  get bitsLeft() {
    return this.lastBit - this.offset;
  }

  get byteOffset() {
    return Math.floor(this.offset / 8);
  }

  readBit() {
    if (!this.canRead(1)) {
      this.isError = true;
      return false;
    }
    const value = (this.buffer[Math.floor(this.offset / 8)] >> (this.offset & 7)) & 1;
    this.offset += 1;
    return value === 1;
  }

  readBits(count) {
    const result = Buffer.alloc(Math.ceil(count / 8));
    for (let i = 0; i < count; i += 1) {
      if (this.readBit()) result[Math.floor(i / 8)] |= 1 << (i & 7);
    }
    return result;
  }

  readBitsToUnsignedInt(count) {
    let value = 0;
    let readBits = 0;
    if ((this.offset & 7) === 0) {
      let index = 0;
      while (count >= 8) {
        if (!this.canRead(8)) {
          this.isError = true;
          return 0;
        }
        value |= this.buffer[this.offset / 8] << (index * 8);
        index += 1;
        count -= 8;
        readBits += 8;
        this.offset += 8;
      }
      if (count === 0) return value >>> 0;
    }

    let currentBit = 1 << readBits;
    for (let i = 0; i < count; i += 1) {
      if (this.readBit()) value |= currentBit;
      currentBit *= 2;
    }
    return value >>> 0;
  }

  readSerializedInt(maxValue) {
    let value = 0;
    for (let mask = 1; value + mask < maxValue; mask *= 2) {
      if (this.readBit()) value |= mask;
    }
    return value;
  }

  readByte() {
    return this.readBitsToUnsignedInt(8);
  }

  readBytes(byteCount) {
    if (!this.canRead(byteCount * 8)) {
      this.isError = true;
      return Buffer.from([]);
    }
    if ((this.offset & 7) === 0) {
      const start = this.offset / 8;
      this.offset += byteCount * 8;
      return this.buffer.subarray(start, start + byteCount);
    }
    const result = Buffer.alloc(byteCount);
    for (let i = 0; i < byteCount; i += 1) result[i] = this.readByte();
    return result;
  }

  readInt16() {
    const bytes = this.readBytes(2);
    return bytes.length === 2 ? bytes.readInt16LE(0) : 0;
  }

  readUInt16() {
    return this.readBitsToUnsignedInt(16);
  }

  readUInt32() {
    return this.readBitsToUnsignedInt(32);
  }

  readInt32() {
    const bytes = this.readBytes(4);
    return bytes.length === 4 ? bytes.readInt32LE(0) : 0;
  }

  readUInt64() {
    const bytes = this.readBytes(8);
    return bytes.length === 8 ? bytes.readBigUInt64LE(0) : 0n;
  }

  readFloat32() {
    const bytes = this.readBytes(4);
    return bytes.length === 4 ? bytes.readFloatLE(0) : 0;
  }

  readIntPacked() {
    let remaining = true;
    let value = 0;
    let shift = 1;
    let index = 0;
    while (remaining && index < 5) {
      const currentByte = this.readByte();
      remaining = (currentByte & 1) === 1;
      value += (currentByte >> 1) * shift;
      shift *= 128;
      index += 1;
    }
    if (remaining) this.isError = true;
    return value;
  }

  readString() {
    const length = this.readInt32();
    if (length === 0) return '';
    if (length < 0) {
      const byteCount = -length * 2;
      const bytes = this.readBytes(byteCount);
      return bytes.subarray(0, Math.max(0, bytes.length - 2)).toString('utf16le').trim();
    }
    const bytes = this.readBytes(length);
    return bytes.subarray(0, Math.max(0, bytes.length - 1)).toString('utf8');
  }

  readDouble64() {
    const bytes = this.readBytes(8);
    return bytes.length === 8 ? bytes.readDoubleLE(0) : 0;
  }

  readQuantizedVector(scaleFactor) {
    const bitsAndInfo = this.readSerializedInt(1 << 7);
    const componentBits = bitsAndInfo & 63;
    const extraInfo = bitsAndInfo >> 6;
    if (componentBits > 0) {
      const x = this.readBitsToUnsignedInt(componentBits);
      const y = this.readBitsToUnsignedInt(componentBits);
      const z = this.readBitsToUnsignedInt(componentBits);
      const signBit = 1 << (componentBits - 1);
      const xSign = (x ^ signBit) - signBit;
      const ySign = (y ^ signBit) - signBit;
      const zSign = (z ^ signBit) - signBit;
      return extraInfo
        ? { x: xSign / scaleFactor, y: ySign / scaleFactor, z: zSign / scaleFactor }
        : { x: xSign, y: ySign, z: zSign };
    }
    return extraInfo
      ? { x: this.readDouble64(), y: this.readDouble64(), z: this.readDouble64() }
      : { x: this.readFloat32(), y: this.readFloat32(), z: this.readFloat32() };
  }

  readPackedVector(scaleFactor) {
    return this.readQuantizedVector(scaleFactor);
  }

  readRotationShort() {
    let pitch = 0;
    let yaw = 0;
    let roll = 0;
    if (this.readBit()) pitch = (this.readUInt16() * 360) / 65536;
    if (this.readBit()) yaw = (this.readUInt16() * 360) / 65536;
    if (this.readBit()) roll = (this.readUInt16() * 360) / 65536;
    return { pitch, yaw, roll };
  }

  readFNameByte(header) {
    const isHardcoded = this.readByte();
    if (isHardcoded) {
      const nameIndex = header.engineNetworkVersion < 6 ? this.readUInt32() : this.readIntPacked();
      return `UnrealName_${nameIndex}`;
    }
    const name = this.readString();
    this.skipBytes(4);
    return name;
  }

  readFName(header) {
    const isHardcoded = this.readBit();
    if (isHardcoded) {
      const nameIndex = header.engineNetworkVersion < 6 ? this.readUInt32() : this.readIntPacked();
      return `UnrealName_${nameIndex}`;
    }
    const name = this.readString();
    this.skipBytes(4);
    return name;
  }

  skipBits(bitCount) {
    if (!this.canRead(bitCount)) {
      this.isError = true;
      this.offset = this.lastBit;
      return;
    }
    this.offset += bitCount;
  }

  skipBytes(byteCount) {
    this.skipBits(byteCount * 8);
  }
}

function decodeFStringAt(buffer, offset) {
  if (offset + 4 > buffer.length) return null;

  const length = buffer.readInt32LE(offset);
  const start = offset + 4;

  if (length === 0) {
    return { value: '', byteLength: 4, encoding: 'empty' };
  }

  if (length > 0) {
    const end = start + length;
    if (end > buffer.length || length > 1024 * 1024) return null;
    let raw = buffer.subarray(start, end);
    if (raw.length && raw[raw.length - 1] === 0) raw = raw.subarray(0, -1);
    return {
      value: raw.toString('utf8'),
      byteLength: 4 + length,
      encoding: 'utf8',
    };
  }

  const charCount = -length;
  const byteLength = charCount * 2;
  const end = start + byteLength;
  if (end > buffer.length || charCount > 512 * 1024) return null;
  let raw = buffer.subarray(start, end);
  if (raw.length >= 2 && raw[raw.length - 2] === 0 && raw[raw.length - 1] === 0) {
    raw = raw.subarray(0, -2);
  }
  return {
    value: raw.toString('utf16le'),
    byteLength: 4 + byteLength,
    encoding: 'utf16le',
  };
}

function readFString(cursor) {
  const result = decodeFStringAt(cursor.buffer, cursor.offset);
  if (!result) {
    throw new Error(`Invalid FString at 0x${cursor.offset.toString(16)}`);
  }
  cursor.offset += result.byteLength;
  return result.value;
}

function looksPrintable(value) {
  if (!value || value.length > 2_000_000) return false;
  let printable = 0;
  for (const ch of value) {
    const code = ch.charCodeAt(0);
    if (code === 9 || code === 10 || code === 13 || (code >= 32 && code < 127)) {
      printable += 1;
    }
  }
  return printable / value.length > 0.9;
}

function scanFStrings(buffer) {
  const strings = [];
  for (let offset = 0; offset <= buffer.length - 4; offset += 1) {
    const decoded = decodeFStringAt(buffer, offset);
    if (!decoded || !looksPrintable(decoded.value)) continue;
    const value = decoded.value.trimEnd();
    if (!value) continue;
    strings.push({ offset, value, encoding: decoded.encoding });
  }
  return strings;
}

function findLatestReplayFile() {
  const candidates = fs
    .readdirSync(DEFAULT_REPLAY_DIR)
    .filter((name) => name.toLowerCase().endsWith('.vrf'))
    .map((name) => {
      const fullPath = path.join(DEFAULT_REPLAY_DIR, name);
      return { fullPath, mtimeMs: fs.statSync(fullPath).mtimeMs };
    })
    .sort((a, b) => b.mtimeMs - a.mtimeMs);

  if (!candidates.length) {
    throw new Error(`No .vrf files found in ${DEFAULT_REPLAY_DIR}`);
  }
  return candidates[0].fullPath;
}

function findLocalStreamOffset(buffer) {
  const maxOffset = Math.min(buffer.length - 12, 4096);
  for (let offset = 0; offset <= maxOffset; offset += 1) {
    const chunkType = buffer.readUInt32LE(offset);
    const chunkSize = buffer.readInt32LE(offset + 4);
    const dataOffset = offset + 8;
    if (
      chunkType === 0 &&
      chunkSize > 0 &&
      dataOffset + 4 <= buffer.length &&
      buffer.readUInt32LE(dataOffset) === UNREAL_REPLAY_MAGIC
    ) {
      return offset;
    }
  }
  throw new Error('Could not locate Unreal local replay chunk stream');
}

function parseWrapper(buffer) {
  const possibleReplayId = decodeFStringAt(buffer, 0x2c);
  return {
    magic: buffer.readUInt32LE(0),
    version: buffer.readUInt32LE(4),
    replayId: possibleReplayId?.value.trim() ?? null,
    streamOffset: findLocalStreamOffset(buffer),
  };
}

function parseChunks(buffer, streamOffset) {
  const chunks = [];
  let offset = streamOffset;
  while (offset < buffer.length) {
    const type = buffer.readUInt32LE(offset);
    const size = buffer.readInt32LE(offset + 4);
    const dataOffset = offset + 8;
    const dataEnd = dataOffset + size;
    if (!CHUNK_TYPES.has(type)) {
      throw new Error(`Unknown chunk type ${type} at 0x${offset.toString(16)}`);
    }
    if (size < 0 || dataEnd > buffer.length) {
      throw new Error(`Invalid chunk size ${size} at 0x${offset.toString(16)}`);
    }
    chunks.push({
      index: chunks.length,
      type,
      typeName: CHUNK_TYPES.get(type),
      size,
      offset,
      dataOffset,
      dataEnd,
    });
    offset = dataEnd;
  }
  return chunks;
}

function parseHeader(buffer, chunk) {
  const data = buffer.subarray(chunk.dataOffset, chunk.dataEnd);
  const strings = scanFStrings(data);
  const jsonValues = [];
  for (const entry of strings) {
    if (!entry.value.startsWith('{') && !entry.value.startsWith('[')) continue;
    try {
      jsonValues.push(JSON.parse(entry.value));
    } catch {
      // Ignore non-JSON strings that happen to start with a JSON delimiter.
    }
  }
  const fixed = parseHeaderFixedFields(data);
  return {
    magic: data.readUInt32LE(0),
    networkVersion: data.readUInt32LE(4),
    networkChecksum: fixed.networkChecksum,
    engineNetworkVersion: fixed.engineNetworkVersion,
    gameNetworkProtocolVersion: fixed.gameNetworkProtocolVersion,
    guid: fixed.guid,
    patch: fixed.patch,
    changelist: fixed.changelist,
    flags: fixed.flags,
    parseFlags: fixed.parseFlags,
    mapPath: strings.find((entry) => entry.value.startsWith('/Game/Maps/'))?.value ?? null,
    branch: strings.find((entry) => entry.value.startsWith('++'))?.value ?? null,
    jsonValues,
  };
}

function parseHeaderFixedFields(data) {
  const cursor = new Cursor(data);
  const result = {
    networkChecksum: null,
    engineNetworkVersion: null,
    gameNetworkProtocolVersion: null,
    guid: null,
    patch: null,
    changelist: null,
    flags: 2,
    parseFlags: 'assumed-level-streaming-fixes',
  };

  try {
    const magic = cursor.readUInt32();
    if (magic !== UNREAL_REPLAY_MAGIC) return result;
    const networkVersion = cursor.readUInt32();
    if (networkVersion >= 19) {
      const customVersionCount = cursor.readInt32();
      cursor.skip(customVersionCount * 20);
    }
    result.networkChecksum = cursor.readUInt32();
    result.engineNetworkVersion = cursor.readUInt32();
    result.gameNetworkProtocolVersion = cursor.readUInt32();
    if (networkVersion >= 12) {
      result.guid = cursor.buffer.subarray(cursor.offset, cursor.offset + 16).toString('hex');
      cursor.skip(16);
    }
    if (networkVersion >= 11) {
      cursor.skip(4);
      result.patch = cursor.readUInt16();
      result.changelist = cursor.readUInt32();
      readFString(cursor);
    } else {
      result.changelist = cursor.readUInt32();
    }
  } catch {
    // Valorant's header tail diverges from the public Fortnite parser. The fixed
    // fields above are best-effort; frame parsing validates its own structure.
  }

  return result;
}

function parseReplayDataEnvelope(buffer, chunk) {
  const cursor = new Cursor(buffer, chunk.dataOffset);
  const startMs = cursor.readUInt32();
  const endMs = cursor.readUInt32();
  const payloadSize = cursor.readUInt32();
  const decompressedSize = cursor.readUInt32();
  const repeatedDecompressedSize = cursor.readUInt32();
  const compressedSize = cursor.readUInt32();
  const compressedOffset = cursor.offset;

  if (
    decompressedSize !== repeatedDecompressedSize ||
    compressedSize < 0 ||
    compressedOffset + compressedSize > chunk.dataEnd
  ) {
    throw new Error(`Replay data chunk ${chunk.index} has unknown compression envelope`);
  }

  return {
    index: chunk.index,
    startMs,
    endMs,
    payloadSize,
    decompressedSize,
    compressedSize,
    compressedOffset,
  };
}

function parseTimelineChunk(buffer, chunk) {
  const cursor = new Cursor(buffer, chunk.dataOffset);
  const id = readFString(cursor);
  const group = readFString(cursor);
  const metadata = readFString(cursor);
  const startMs = cursor.readUInt32();
  const endMs = cursor.readUInt32();
  const payloadSize = cursor.readUInt32();
  const payloadEnd = Math.min(chunk.dataEnd, cursor.offset + payloadSize);
  const payload = buffer.subarray(cursor.offset, payloadEnd);
  const decodedPayload = decodeTimelineEventPayload(group, payload);
  return {
    index: chunk.index,
    typeName: chunk.typeName,
    id,
    group,
    metadata,
    startMs,
    endMs,
    payloadSize,
    payloadReadSize: payload.length,
    payloadDecoded: decodedPayload,
  };
}

function decodeTimelineEventPayload(group, payload) {
  if (!Buffer.isBuffer(payload) || payload.length === 0) return null;
  if (group === 'characterDeath') return decodeCharacterDeathPayload(payload);
  if (group === 'characterUltimateUsed') {
    return decodeCharacterUltimateUsedPayload(payload);
  }
  return decodeGenericTimelineEventPayload(payload);
}

function decodeGenericTimelineEventPayload(payload) {
  const uint32Prefix = [];
  const prefixByteLimit = Math.min(payload.length - (payload.length % 4), 16);
  for (let offset = 0; offset < prefixByteLimit; offset += 4) {
    uint32Prefix.push(payload.readUInt32LE(offset));
  }
  return {
    uint32Prefix,
    trailingFloat32:
      payload.length >= 4 ? Number(payload.readFloatLE(payload.length - 4).toFixed(6)) : null,
    payloadHexPrefix: payload.subarray(0, 32).toString('hex'),
  };
}

function decodeCharacterDeathPayload(payload) {
  if (payload.length < 20) {
    return {
      status: 'too-short',
      payloadHexPrefix: payload.toString('hex'),
    };
  }

  const payloadVersion = payload.readUInt32LE(0);
  const killerNetGuid = payload.readUInt32LE(4);
  const victimNetGuid = payload.readUInt32LE(8);
  const labelLength = payload.readInt32LE(12);
  let eventGroupLabel = null;
  const labelStart = 16;
  const labelEnd = labelStart + labelLength;
  if (labelLength > 0 && labelEnd <= payload.length) {
    eventGroupLabel = payload
      .subarray(labelStart, labelEnd)
      .toString('utf8')
      .replace(/\0+$/g, '');
  }

  return {
    status: 'decoded',
    payloadVersion,
    killerNetGuid,
    victimNetGuid,
    eventGroupLabel,
    eventSeconds: Number(payload.readFloatLE(payload.length - 4).toFixed(6)),
  };
}

function decodeCharacterUltimateUsedPayload(payload) {
  if (payload.length < 16) {
    return {
      status: 'too-short',
      payloadHexPrefix: payload.toString('hex'),
    };
  }
  const payloadVersion = payload.readUInt32LE(0);
  const playerNetGuid = payload.readUInt32LE(4);
  const labelLength = payload.readInt32LE(8);
  const labelStart = 12;
  const labelEnd = labelStart + labelLength;
  let eventGroupLabel = null;
  if (labelLength > 0 && labelEnd <= payload.length) {
    eventGroupLabel = payload
      .subarray(labelStart, labelEnd)
      .toString('utf8')
      .replace(/\0+$/g, '');
  }
  return {
    status: 'decoded',
    payloadVersion,
    playerNetGuid,
    eventGroupLabel,
    eventSeconds: Number(payload.readFloatLE(payload.length - 4).toFixed(6)),
  };
}

function parseIntegerMetadata(value) {
  const text = String(value ?? '').trim();
  if (!/^-?\d+$/.test(text)) return null;
  return Number(text);
}

function buildTimelineDiagnostics(events) {
  const eventCounts = events.reduce((counts, event) => {
    counts[event.group] = (counts[event.group] ?? 0) + 1;
    return counts;
  }, {});
  const roundStartEvents = events
    .filter((event) => event.group === 'roundStarted')
    .map((event) => ({
      id: event.id,
      timeMs: event.startMs,
      endMs: event.endMs,
      roundIndex: parseIntegerMetadata(event.metadata),
      source: 'vrf-timeline-roundStarted',
      confidence: 'event-chunk',
    }))
    .sort((a, b) => a.timeMs - b.timeMs || (a.roundIndex ?? 999) - (b.roundIndex ?? 999));
  const deathEvents = events
    .filter((event) => event.group === 'characterDeath')
    .map((event, index) => {
      const decoded = event.payloadDecoded ?? {};
      return {
        id: event.id || `death-${index}`,
        timeMs: event.startMs,
        endMs: event.endMs,
        killerNetGuid: Number.isInteger(decoded.killerNetGuid) ? decoded.killerNetGuid : null,
        victimNetGuid: Number.isInteger(decoded.victimNetGuid) ? decoded.victimNetGuid : null,
        payloadVersion: decoded.payloadVersion ?? null,
        eventGroupLabel: decoded.eventGroupLabel ?? null,
        eventSeconds: decoded.eventSeconds ?? null,
        source: 'vrf-timeline-characterDeath-payload',
        confidence:
          decoded.status === 'decoded' &&
          Number.isInteger(decoded.killerNetGuid) &&
          Number.isInteger(decoded.victimNetGuid)
            ? 'proven-event-payload'
            : 'timeline-event-undecoded-payload',
      };
    })
    .sort((a, b) => a.timeMs - b.timeMs || (a.victimNetGuid ?? 0) - (b.victimNetGuid ?? 0));
  const sideSwitchEvents = events
    .filter((event) => event.group === 'switchTeams')
    .map((event, index) => ({
      id: event.id || `side-switch-${index}`,
      timeMs: event.startMs,
      endMs: event.endMs,
      source: 'vrf-timeline-switchTeams',
      confidence: 'event-chunk',
    }))
    .sort((a, b) => a.timeMs - b.timeMs);
  const ultimateEvents = events
    .filter((event) => event.group === 'characterUltimateUsed')
    .map((event, index) => {
      const decoded = event.payloadDecoded ?? {};
      return {
        id: event.id || `ultimate-${index}`,
        timeMs: event.startMs,
        endMs: event.endMs,
        playerNetGuid: Number.isInteger(decoded.playerNetGuid)
          ? decoded.playerNetGuid
          : null,
        payloadVersion: decoded.payloadVersion ?? null,
        eventGroupLabel: decoded.eventGroupLabel ?? null,
        eventSeconds: decoded.eventSeconds ?? null,
        source: 'vrf-timeline-characterUltimateUsed-payload',
        confidence:
          decoded.status === 'decoded' && Number.isInteger(decoded.playerNetGuid)
            ? 'proven-event-payload'
            : 'timeline-event-undecoded-payload',
      };
    })
    .sort((a, b) => a.timeMs - b.timeMs || (a.playerNetGuid ?? 0) - (b.playerNetGuid ?? 0));

  return {
    eventCounts,
    roundStartEvents,
    deathEvents,
    sideSwitchEvents,
    ultimateEvents,
  };
}

async function decompressReplayData(buffer, replayData) {
  const ooz = require('ooz-wasm');
  const decompressed = [];
  for (const entry of replayData) {
    const compressed = buffer.subarray(
      entry.compressedOffset,
      entry.compressedOffset + entry.compressedSize,
    );
    const data = Buffer.from(
      await ooz.decompressUnsafe(compressed, entry.decompressedSize),
    );
    decompressed.push({ ...entry, data });
  }
  return decompressed;
}

function createFrameContext(header) {
  return {
    header: {
      networkVersion: header.networkVersion,
      engineNetworkVersion: header.engineNetworkVersion ?? 32,
      flags: header.flags ?? 2,
      branch: header.branch ?? null,
    },
    exportGroupsByPath: new Map(),
    exportGroupsByIndex: new Map(),
    netGuidsToPath: new Map(),
  };
}

function hasLevelStreamingFixes(context) {
  return (context.header.flags & 2) === 2;
}

function hasGameSpecificFrameData(context) {
  return (context.header.flags & 8) === 8;
}

function isValidNetGuid(value) {
  return value > 0;
}

function isDefaultNetGuid(value) {
  return value === 1;
}

function readInternalLoadObject(reader, isExportingNetGuidBunch, context, depth = 0) {
  if (depth > 16) return 0;
  const netGuid = reader.readIntPacked();
  if (!isValidNetGuid(netGuid)) return netGuid;

  if (isDefaultNetGuid(netGuid) || isExportingNetGuidBunch) {
    const flags = reader.readByte();
    if ((flags & 1) === 1) {
      readInternalLoadObject(reader, true, context, depth + 1);
      const pathName = reader.readString();
      if ((flags & 4) === 4) reader.readUInt32();
      if (isExportingNetGuidBunch) context.netGuidsToPath.set(netGuid, pathName);
    }
  }

  return netGuid;
}

function readNetFieldExport(reader, context) {
  const isExported = reader.readByte();
  if (!isExported) return null;
  const netField = {
    handle: reader.readIntPacked(),
    compatibleChecksum: reader.readUInt32(),
    name: null,
  };
  if (context.header.engineNetworkVersion < 9) {
    netField.name = reader.readString();
    netField.type = reader.readString();
  } else if (context.header.engineNetworkVersion < 10) {
    netField.name = reader.readString();
  } else {
    netField.name = reader.readFNameByte(context.header);
  }
  return netField;
}

function readNetFieldExports(reader, context) {
  const groupsRead = [];
  const numLayoutCmdExports = reader.readIntPacked();
  if (numLayoutCmdExports > 20_000) {
    reader.isError = true;
    return groupsRead;
  }

  for (let i = 0; i < numLayoutCmdExports; i += 1) {
    const pathNameIndex = reader.readIntPacked();
    const isExported = reader.readIntPacked() === 1;
    let group = context.exportGroupsByIndex.get(pathNameIndex);
    if (isExported) {
      const pathName = reader.readString();
      const numExports = reader.readIntPacked();
      group = {
        pathName,
        pathNameIndex,
        netFieldExportsLength: numExports,
        netFieldExports: [],
      };
      context.exportGroupsByPath.set(pathName, group);
      context.exportGroupsByIndex.set(pathNameIndex, group);
      groupsRead.push(pathName);
    }

    const netField = readNetFieldExport(reader, context);
    if (netField && group) {
      group.netFieldExports[netField.handle] = netField;
    }
    if (reader.isError) break;
  }

  return groupsRead;
}

function readNetExportGuids(reader, context) {
  const count = reader.readIntPacked();
  if (count > 20_000) {
    reader.isError = true;
    return 0;
  }
  for (let i = 0; i < count; i += 1) {
    const size = reader.readInt32();
    if (size < 0 || size * 8 > reader.bitsLeft) {
      reader.isError = true;
      return i;
    }
    const endOffset = reader.offset + size * 8;
    readInternalLoadObject(reader, true, context);
    reader.offset = endOffset;
  }
  return count;
}

function readExternalData(reader) {
  const external = [];
  while (!reader.atEnd()) {
    const externalDataNumBits = reader.readIntPacked();
    if (externalDataNumBits === 0) return external;
    if (externalDataNumBits % 8 !== 0 || externalDataNumBits < 24) {
      reader.isError = true;
      return external;
    }
    const netGuid = reader.readIntPacked();
    const externalDataNumBytes = externalDataNumBits / 8;
    if (externalDataNumBytes * 8 > reader.bitsLeft) {
      reader.isError = true;
      return external;
    }
    const handle = reader.readByte();
    const something1 = reader.readByte();
    const something2 = reader.readByte();
    const payload = reader.readBytes(externalDataNumBytes - 3);
    external.push({ netGuid, externalDataNumBits, handle, something1, something2, payload });
  }
  return external;
}

function readPlaybackFrame(data, startOffset, chunk, context) {
  const reader = new BitReader(data, data.length * 8, startOffset * 8);
  const frame = {
    offset: startOffset,
    length: 0,
    timeMs: null,
    currentLevelIndex: null,
    exportGroups: [],
    netExportGuidCount: 0,
    external: [],
    packets: [],
  };

  if (context.header.networkVersion >= 6) frame.currentLevelIndex = reader.readInt32();
  const timeSeconds = reader.readFloat32();
  if (
    !Number.isFinite(timeSeconds) ||
    timeSeconds < chunk.startMs / 1000 - 1 ||
    timeSeconds > chunk.endMs / 1000 + 1
  ) {
    return null;
  }
  frame.timeMs = Math.round(timeSeconds * 1000);

  if (context.header.networkVersion >= 10) {
    frame.exportGroups = readNetFieldExports(reader, context);
    frame.netExportGuidCount = readNetExportGuids(reader, context);
  }

  if (!hasLevelStreamingFixes(context)) return null;
  const numStreamingLevels = reader.readIntPacked();
  if (numStreamingLevels > 10_000) return null;
  for (let i = 0; i < numStreamingLevels; i += 1) reader.readString();
  reader.skipBytes(8);

  frame.external = readExternalData(reader);

  if (hasGameSpecificFrameData(context)) {
    const skipExternalOffset = reader.readUInt64();
    if (skipExternalOffset > 0n) reader.skipBytes(Number(skipExternalOffset));
  }

  while (!reader.atEnd()) {
    const packetStart = reader.byteOffset;
    const streamingFix = reader.readIntPacked();
    const size = reader.readInt32();
    if (size === 0) break;
    if (size < 0 || size > 2048 || size * 8 > reader.bitsLeft) {
      reader.isError = true;
      break;
    }
    const packetData = reader.readBytes(size);
    frame.packets.push({
      kind: 'network',
      offset: packetStart,
      size,
      streamingFix,
      payload: packetData,
    });
  }

  if (reader.isError) return null;
  frame.length = reader.byteOffset - startOffset;
  if (frame.length <= 0) return null;
  return frame;
}

function parseFramesInChunk(chunk, context) {
  const frames = [];
  let offset = 0;
  while (offset < chunk.data.length - 12) {
    const frame = readPlaybackFrame(chunk.data, offset, chunk, context);
    if (!frame) break;
    frames.push(frame);
    offset += frame.length;
  }
  return frames;
}

function createPacketContext(frameContext) {
  return {
    frameContext,
    channels: [],
    ignoredChannels: [],
    inPacketId: 0,
    inReliable: 0,
    rawPacketsScanned: 0,
    rawPacketScanLimit: null,
    rawPacketWarmupToMs: null,
    rawPacketTimeFromMs: null,
    rawPacketTimeToMs: null,
    rawFocusChannels: null,
    rawPacketScanLimitReached: false,
    rawPacketScanSkipped: false,
    partialBunches: new Map(),
    rpcHitCount: 0,
    rpcHits: [],
    rpcCandidateSamples: [],
    classNetCacheSamples: [],
    classNetCacheFieldStats: new Map(),
    replayControllerClassNetCacheSamples: [],
    replayControllerClassNetCacheFieldStats: new Map(),
    replayControllerVectorLaneStats: new Map(),
    replayControllerKnownGuidHits: [],
    replayControllerCandidateFieldSamples: [],
    replayControllerCandidateFieldSampleCounts: new Map(),
    replayControllerCandidateFieldLastCapturedTimeMs: new Map(),
    replayControllerTargetPayloadStats: new Map(),
    replayControllerTargetNativeRecordStats: new Map(),
    replayControllerTargetNativeRecordSamples: [],
    valorantPayloadTransformSamples: [],
    replicatorSamples: [],
    repLayoutSamples: [],
    abilitySignalSamples: [],
    abilitySignalSampleLimit: DEFAULT_ABILITY_SIGNAL_SAMPLE_LIMIT,
    abilitySignalOverflowCount: 0,
    diagnosticActorNetGuids: null,
    diagnosticActorWireSamples: [],
    diagnosticActorWireSampleLimit: DEFAULT_DIAGNOSTIC_ACTOR_WIRE_SAMPLE_LIMIT,
    diagnosticActorWireOverflowCount: 0,
    abilityCastSignalSamples: [],
    abilityCastSignalSampleLimit: DEFAULT_ABILITY_CAST_SIGNAL_SAMPLE_LIMIT,
    inputEventCaptureSamples: [],
    inputEventCaptureSampleLimit: DEFAULT_INPUT_EVENT_CAPTURE_SAMPLE_LIMIT,
    nonMovementInputEventSampleLimit:
      DEFAULT_NON_MOVEMENT_INPUT_EVENT_SAMPLE_LIMIT,
    inputEventCaptureKeys: new Set(),
    nonMovementInputEventSamples: [],
    nonMovementInputEventSampleLimit:
      DEFAULT_NON_MOVEMENT_INPUT_EVENT_SAMPLE_LIMIT,
    nonMovementInputEventKeys: new Set(),
    nonMovementInputEventTypeCounts: new Map(),
    nonMovementInputEventOverflowCount: 0,
    identityLinkSamples: [],
    actorChannelOpenCount: 0,
    channelOpenSamples: [],
    utilityActorOpenSamples: [],
    utilityActorCloseSamples: [],
    utilityActorOpenByNetGuid: new Map(),
    replayControllerPayloadSamples: [],
    errors: new Map(),
  };
}

function notePacketError(packetContext, key) {
  packetContext.errors.set(key, (packetContext.errors.get(key) ?? 0) + 1);
}

function getPathForNetGuid(context, netGuid) {
  return context.netGuidsToPath.get(netGuid) ?? '';
}

function normalizePathToken(value) {
  return String(value ?? '')
    .split('/')
    .at(-1)
    .split('.')
    .at(-1)
    .replace(/^Default__/, '')
    .replace(/_C$/, '')
    .toLowerCase();
}

function archetypeClassName(value) {
  return String(value ?? '')
    .split('/')
    .at(-1)
    .split('.')
    .at(-1)
    .replace(/^Default__/, '')
    .replace(/_C$/, '');
}

function normalizeAssetClassName(value) {
  return archetypeClassName(value).toLowerCase();
}

function archetypeTokens(value) {
  return archetypeClassName(value)
    .split(/[^A-Za-z0-9]+/)
    .map((token) => token.toLowerCase())
    .filter(Boolean);
}

let staticDecoderIndexes = null;

function readJsonIfExists(filePath) {
  try {
    if (!fs.existsSync(filePath)) return null;
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch {
    return null;
  }
}

function inferSlotFromAssetPath(value) {
  const tokens = String(value ?? '')
    .split(/[^A-Za-z0-9]+/)
    .map((token) => token.toLowerCase())
    .filter(Boolean);
  return tokens.map((token) => ABILITY_KEY_TO_SLOT.get(token)).find(Boolean) ?? null;
}

function contentKindFromStaticKind(kind) {
  switch (kind) {
    case 'ability':
      return 'ability-class';
    case 'projectile':
      return 'projectile-class';
    case 'game_object':
      return 'game-object-class';
    case 'patch':
      return 'area-patch-class';
    case 'deployable_pawn':
      return 'pawn-deployable';
    case 'equippable':
      return 'equippable-class';
    case 'force_module':
      return 'force-module';
    case 'damage_metadata':
      return 'damage-metadata';
    case 'buff':
      return 'buff';
    case 'fx':
      return 'fx';
    default:
      return null;
  }
}

function phaseFromContentKind(contentKind, className) {
  if (/EquippablePickupProjectile/i.test(className)) return 'pickup-drop';
  if (/Aggrobot_.*Reclaim_Orb/i.test(className)) return 'reclaimable-object';
  if (
    /Hunter_Q_SonarPing|Hunter_4_ExplosiveBolt_Explosion|Vampire_Q_Heal_HealPool|Sarge_4_SmokeManager|Phoenix_Q_FlameWallManager/i.test(
      className,
    )
  ) {
    return 'effect-only';
  }
  if (
    /Aggrobot_(?:Zamboni_Rocket|OrbSpawner)|Deadeye_4_Trap_Dart/i.test(
      className,
    )
  ) {
    return 'generated-child';
  }
  switch (contentKind) {
    case 'ability-class':
      return 'cast-identity';
    case 'projectile-class':
      return /Secondary/i.test(className) ? 'submunition' : 'projectile-flight';
    case 'game-object-class':
      return 'placed-object';
    case 'area-patch-class':
      return 'area-patch';
    case 'pawn-deployable':
      return 'deployable-pawn';
    case 'force-module':
    case 'damage-metadata':
    case 'buff':
    case 'fx':
      return 'effect-only';
    case 'generated-child':
      return 'generated-child';
    case 'pickup-drop':
      return 'pickup-drop';
    default:
      return null;
  }
}

function fallbackContentKind(className) {
  if (/EquippablePickupProjectile/i.test(className)) return 'pickup-drop';
  if (/^(?:Pawn|AIPawn)_/i.test(className)) return 'pawn-deployable';
  if (/^Ability_/i.test(className)) return 'ability-class';
  if (/^Projectile_/i.test(className)) return 'projectile-class';
  if (/^GameObject_/i.test(className)) return 'game-object-class';
  if (/^Patch_/i.test(className)) return 'area-patch-class';
  if (/^Equippable_/i.test(className)) return 'equippable-class';
  if (/^FXC_/i.test(className)) return 'fx';
  if (/ChildActor|Generated/i.test(className)) return 'generated-child';
  return 'unknown';
}

function addStaticRecordKey(map, key, record) {
  const normalized = normalizeAssetClassName(key);
  if (normalized && !map.has(normalized)) map.set(normalized, record);
}

function addStaticIdentityKey(map, key, identity) {
  const normalized = normalizeAssetClassName(key);
  if (normalized && !map.has(normalized)) map.set(normalized, identity);
}

function normalizeExactAssetPath(value) {
  const match = String(value ?? '').match(/\/Game\/[^'"\s]+/i);
  if (!match) return null;
  return match[0].split('.')[0].toLowerCase();
}

function loadStaticDecoderIndexes() {
  if (staticDecoderIndexes) return staticDecoderIndexes;

  const abilityActorIndex = readJsonIfExists(
    path.join(STATIC_DECODER_INDEX_DIR, 'ability_actor_index.json'),
  );
  let agentPrimaryIndex = readJsonIfExists(
    path.join(STATIC_DECODER_INDEX_DIR, 'agent_primary_index.json'),
  );
  if (
    !(agentPrimaryIndex?.agents ?? []).some(
      (agent) => Array.isArray(agent.abilities) && agent.abilities.length > 0,
    )
  ) {
    agentPrimaryIndex = readJsonIfExists(
      path.join(BUNDLED_DECODER_INDEX_DIR, 'agent_primary_index.json'),
    );
  }
  const abilityIdentityIndex = readJsonIfExists(
    path.join(STATIC_DECODER_INDEX_DIR, 'ability_identity_index.json'),
  );
  const spawnGraphPath = path.join(STATIC_DECODER_INDEX_DIR, 'ability_spawn_graph_edges.jsonl');
  const indexSummary = readJsonIfExists(
    path.join(STATIC_DECODER_INDEX_DIR, 'static_decoder_index_summary.json'),
  );

  const recordsByClassName = new Map();
  for (const record of abilityActorIndex?.records ?? []) {
    addStaticRecordKey(recordsByClassName, record.name, record);
    addStaticRecordKey(recordsByClassName, record.type, record);
    addStaticRecordKey(recordsByClassName, record.assetPath, record);
    addStaticRecordKey(recordsByClassName, record.class, record);
  }

  const abilityIdentityByClassName = new Map();
  for (const [className, identity] of Object.entries(abilityIdentityIndex?.classes ?? {})) {
    addStaticIdentityKey(abilityIdentityByClassName, className, identity);
  }
  const abilityIdentityByAssetPath = new Map();
  for (const [assetPath, identity] of Object.entries(abilityIdentityIndex?.assets ?? {})) {
    abilityIdentityByAssetPath.set(assetPath.toLowerCase(), identity);
  }

  const agentsByDeveloperName = new Map();
  const agentsByShippingName = new Map();
  const agentsByUuid = new Map();
  for (const agent of agentPrimaryIndex?.agents ?? []) {
    if (agent.developerName) {
      agentsByDeveloperName.set(agent.developerName.toLowerCase(), agent);
      agentsByDeveloperName.set(
        agent.developerName.toLowerCase().replace(/[^a-z0-9]/g, ''),
        agent,
      );
    }
    if (agent.shippingName) {
      agentsByShippingName.set(agent.shippingName.toLowerCase(), agent);
      agentsByShippingName.set(
        agent.shippingName.toLowerCase().replace(/[^a-z0-9]/g, ''),
        agent,
      );
    }
    if (agent.uuid) {
      agentsByUuid.set(
        String(agent.uuid).toLowerCase().replace(/[^a-z0-9]/g, ''),
        agent,
      );
    }
  }

  const sourceEdgesByTargetClassName = new Map();
  try {
    if (fs.existsSync(spawnGraphPath)) {
      for (const line of fs.readFileSync(spawnGraphPath, 'utf8').split(/\r?\n/)) {
        if (!line.trim()) continue;
        const edge = JSON.parse(line);
        const key = normalizeAssetClassName(edge.target);
        if (key && !sourceEdgesByTargetClassName.has(key)) {
          sourceEdgesByTargetClassName.set(key, edge);
        }
      }
    }
  } catch {
    // Static catalog joins are diagnostics only; replay extraction should still work without them.
  }

  staticDecoderIndexes = {
    recordsByClassName,
    abilityIdentityByClassName,
    abilityIdentityByAssetPath,
    agentsByDeveloperName,
    agentsByShippingName,
    agentsByUuid,
    sourceEdgesByTargetClassName,
    summary: indexSummary
      ? {
          generatedAt: indexSummary.generatedAt ?? null,
          contentVersion: indexSummary.contentVersion ?? null,
          agentCount: indexSummary.agentCount ?? null,
          abilityActorCount: indexSummary.abilityActorCount ?? null,
          abilityIdentityClassCount: indexSummary.abilityIdentityClassCount ?? null,
          abilityIdentityAssetCount: indexSummary.abilityIdentityAssetCount ?? null,
        }
      : null,
  };
  return staticDecoderIndexes;
}

function agentNameFromCharacterId(characterId) {
  const normalized = String(characterId ?? '').toLowerCase();
  const staticAgent = loadStaticDecoderIndexes().agentsByUuid.get(
    normalized.replace(/[^a-z0-9]/g, ''),
  );
  return staticAgent?.shippingName ?? CHARACTER_ID_TO_AGENT.get(normalized) ?? 'Unknown';
}

function abilityNameFor(agent, abilityIndex) {
  if (!agent || !Number.isInteger(abilityIndex)) return null;
  return AGENT_ABILITY_NAMES.get(agent)?.[abilityIndex] ?? null;
}

function staticAbilityForSlot(agent, abilitySlot) {
  if (!agent || !abilitySlot) return null;
  const indexes = loadStaticDecoderIndexes();
  const normalizedAgent = String(agent).toLowerCase().replace(/[^a-z0-9]/g, '');
  const staticAgent =
    indexes.agentsByShippingName.get(String(agent).toLowerCase()) ??
    indexes.agentsByShippingName.get(normalizedAgent) ??
    indexes.agentsByDeveloperName.get(String(agent).toLowerCase()) ??
    indexes.agentsByDeveloperName.get(normalizedAgent) ??
    null;
  return (
    (staticAgent?.abilities ?? []).find(
      (ability) => ability?.abilitySlot === abilitySlot,
    ) ?? null
  );
}

// Miks exposes four replay/equippable slots but five Icarus visuals because
// M-pulse has separate concuss and healing modes. Keep replay slots as the
// network identity and resolve the app-facing visual index from the actor
// class when the subtype is observable.
function abilityIdentityForSlot(
  agent,
  abilitySlot,
  { className = null, canonicalName = null } = {},
) {
  const staticAbility = staticAbilityForSlot(agent, abilitySlot);
  if (agent === 'Miks') {
    switch (abilitySlot) {
      case 'Grenade':
        if (/heal/i.test(className ?? '')) {
          return {
            abilityIndex: 1,
            abilityName: 'M-pulse Healing',
            sourceAbilityAsset: staticAbility?.sourceAbilityAsset ?? null,
            identitySource: staticAbility ? 'static-agent-ui-slot+observed-subtype' : 'observed-subtype',
          };
        }
        if (/concuss/i.test(className ?? '')) {
          return {
            abilityIndex: 0,
            abilityName: 'M-pulse Concuss',
            sourceAbilityAsset: staticAbility?.sourceAbilityAsset ?? null,
            identitySource: staticAbility ? 'static-agent-ui-slot+observed-subtype' : 'observed-subtype',
          };
        }
        return {
          abilityIndex: 0,
          abilityName: staticAbility?.abilityName ?? canonicalName ?? 'M-pulse',
          sourceAbilityAsset: staticAbility?.sourceAbilityAsset ?? null,
          identitySource: staticAbility ? 'static-agent-ui-slot' : 'legacy-agent-name-map',
        };
      case 'Ability1':
        return {
          abilityIndex: 2,
          abilityName: staticAbility?.abilityName ?? 'Harmonize',
          sourceAbilityAsset: staticAbility?.sourceAbilityAsset ?? null,
          identitySource: staticAbility ? 'static-agent-ui-slot' : 'legacy-agent-name-map',
        };
      case 'Ability2':
        return {
          abilityIndex: 3,
          abilityName: staticAbility?.abilityName ?? 'Waveform',
          sourceAbilityAsset: staticAbility?.sourceAbilityAsset ?? null,
          identitySource: staticAbility ? 'static-agent-ui-slot' : 'legacy-agent-name-map',
        };
      case 'Ultimate':
        return {
          abilityIndex: 4,
          abilityName: staticAbility?.abilityName ?? 'Bassquake',
          sourceAbilityAsset: staticAbility?.sourceAbilityAsset ?? null,
          identitySource: staticAbility ? 'static-agent-ui-slot' : 'legacy-agent-name-map',
        };
    }
  }

  const abilityIndex = sourceAbilityIndex(abilitySlot);
  return {
    abilityIndex,
    abilityName:
      staticAbility?.abilityName ??
      canonicalName ??
      abilityNameFor(agent, abilityIndex) ??
      null,
    sourceAbilityAsset: staticAbility?.sourceAbilityAsset ?? null,
    identitySource: staticAbility ? 'static-agent-ui-slot' : 'legacy-agent-name-map',
  };
}

function classAbilityOverride(actorPath) {
  const className = archetypeClassName(actorPath);
  const override = CLASS_ABILITY_OVERRIDES.find((entry) => entry.pattern.test(className));
  if (!override) return null;
  return {
    agent: override.agent,
    icarusAgentType: ICARUS_AGENT_TYPE_BY_AGENT.get(override.agent) ?? null,
    abilitySlot: override.abilitySlot,
    abilityIndex: override.abilityIndex,
    abilityName: abilityNameFor(override.agent, override.abilityIndex),
  };
}

function inferAbilityIdentityFromLeafTokenFallback(actorPath) {
  const tokens = archetypeTokens(actorPath);
  const agentEntry = tokens
    .map((token) => VALORANT_AGENT_ARCHETYPE_TOKENS.get(token))
    .find(Boolean) ?? null;
  const slotEntry = tokens
    .map((token) => ABILITY_KEY_TO_SLOT.get(token))
    .find(Boolean) ?? null;
  const override = classAbilityOverride(actorPath);
  const agent = override?.agent ?? agentEntry?.agent ?? null;
  const abilitySlot = override?.abilitySlot ?? slotEntry?.abilitySlot ?? null;
  const slotIdentity = abilityIdentityForSlot(agent, abilitySlot, {
    className: archetypeClassName(actorPath),
  });
  const abilityIndex = override?.abilityIndex ?? slotIdentity.abilityIndex;
  return {
    agent,
    icarusAgentType:
      override?.icarusAgentType ??
      (agent ? ICARUS_AGENT_TYPE_BY_AGENT.get(agent) : null) ??
      agentEntry?.icarusAgentType ??
      null,
    abilitySlot,
    abilityIndex,
    abilityName:
      override?.abilityName ??
      slotIdentity.abilityName ??
      abilityNameFor(agent, abilityIndex),
    identitySource: override ? 'class-name-override-fallback' : 'leaf-token-fallback',
    identityConfidence: override ? 'medium' : 'low',
  };
}

function staticUtilityMetadata(className, classification) {
  const indexes = loadStaticDecoderIndexes();
  const key = normalizeAssetClassName(className);
  const exactAssetPath = normalizeExactAssetPath(className);
  const identity =
    (exactAssetPath
      ? indexes.abilityIdentityByAssetPath.get(exactAssetPath)
      : null) ??
    indexes.abilityIdentityByClassName.get(key) ??
    null;
  const record = indexes.recordsByClassName.get(key) ?? null;
  const sourceEdge = indexes.sourceEdgesByTargetClassName.get(key) ?? null;
  const hasClassOverride =
    !identity &&
    classification.identitySource === 'class-name-override-fallback' &&
    classification.abilitySlot;
  const sourceSlot = hasClassOverride
    ? {
        abilitySlot: classification.abilitySlot,
        abilityIndex: classification.abilityIndex,
      }
    : identity?.abilitySlot
    ? { abilitySlot: identity.abilitySlot, abilityIndex: identity.abilityIndex }
    : inferSlotFromAssetPath(sourceEdge?.source ?? record?.assetPath);
  const agent =
    indexes.agentsByShippingName.get(
      String(
        (hasClassOverride ? classification.agent : identity?.agent) ??
          classification.agent ??
          '',
      ).toLowerCase(),
    ) ??
    indexes.agentsByDeveloperName.get(String(record?.inferredAgent ?? sourceEdge?.inferredAgent ?? '').toLowerCase()) ??
    null;
  const contentKind =
    (record ? contentKindFromStaticKind(record.kind) : null) ??
    (sourceEdge ? contentKindFromStaticKind(sourceEdge.targetKind) : null) ??
    fallbackContentKind(className);
  const phase = phaseFromContentKind(contentKind, className) ?? 'unknown';

  return {
    hasStaticIdentity: identity != null,
    contentKind,
    phase,
    sourceAbilityClass:
      identity?.sourceAbilityAsset ??
      sourceEdge?.source ??
      (contentKind === 'ability-class' ? record?.assetPath : null) ??
      null,
    sourceAbilitySlot: sourceSlot?.abilitySlot ?? classification.abilitySlot ?? null,
    sourceAbilityName:
      (hasClassOverride ? classification.abilityName : identity?.abilityName) ??
      abilityNameFor(agent?.shippingName ?? classification.agent, sourceSlot?.abilityIndex) ??
      classification.abilityName,
    sourceAbilityAssetPath: identity?.sourceAbilityAsset ?? sourceEdge?.source ?? null,
    sourceContentKind: sourceEdge?.sourceKind ? contentKindFromStaticKind(sourceEdge.sourceKind) : null,
    staticAssetPath: identity?.staticAssetPath ?? record?.assetPath ?? null,
    staticAssetKind: identity?.staticAssetKind ?? record?.kind ?? null,
    agentUuid: identity?.agentUuid ?? agent?.uuid ?? record?.inferredAgentUuid ?? null,
    characterId: identity?.characterId ?? agent?.characterId ?? record?.inferredCharacterId ?? null,
    agentDeveloperName: identity?.agentDeveloperName ?? agent?.developerName ?? record?.inferredAgent ?? null,
    agentShippingName:
      (hasClassOverride ? classification.agent : identity?.agent) ??
      agent?.shippingName ??
      classification.agent ??
      null,
    staticAbilitySlot: identity?.abilitySlot ?? null,
    staticAbilityName: identity?.abilityName ?? null,
    identitySource: hasClassOverride
      ? 'class-name-override'
      : identity
      ? `static-${identity.source ?? 'ability-identity'}`
      : classification.identitySource ?? null,
    identityConfidence:
      hasClassOverride || identity
        ? 'high'
        : classification.identityConfidence ?? null,
  };
}

function utilityActorDisplayLifetime(className, classification) {
  if (
    ['effect-only', 'generated-child', 'pickup-drop'].includes(
      classification.phase,
    )
  ) {
    return {
      lifetimeMs: null,
      source: `ignored-${classification.phase}`,
      ignored: true,
    };
  }
  const verifiedRule = verifiedUtilityActorLifecycleRule(className);
  if (verifiedRule) {
    const observedOnly =
      verifiedRule.timingPolicy === 'observed-actor' ||
      verifiedRule.timingPolicy === 'observed-channel';
    const lifetimeMs = observedOnly
      ? null
      : Number.isFinite(verifiedRule.fallbackLifetimeMs)
        ? verifiedRule.fallbackLifetimeMs
        : null;
    return {
      lifetimeMs,
      source: verifiedRule.source,
      ignored: false,
      observedOnly,
    };
  }
  // App-facing lifetimes must come from this replay's channel/state evidence.
  // Static content remains useful for identity and phase labels, but wiki
  // durations and kind-based timers are not gameplay facts and must never
  // become an effective end timestamp.
  return {
    lifetimeMs: null,
    source: 'replay-observed-channel-only',
    ignored: false,
    observedOnly: true,
  };
}

function classifyUtilityActorArchetype(archetypePath) {
  const className = archetypeClassName(archetypePath);
  if (!className) return null;
  if (/\/Missions\/|mission|contract/i.test(String(archetypePath ?? ''))) {
    return null;
  }
  if (/^(?:base)?(?:pistol|rifle|sniper|shotgun|smg|machinegun)|weapon|melee/i.test(className)) {
    return null;
  }
  if (isPlayerCharacterArchetype(archetypePath) || /postdeath_pc/i.test(className)) {
    return null;
  }

  const utilityPrefix =
    /^(?:Ability|Projectile|Patch|FXC|GameObject|Pawn|AIPawn)_/i.test(className) ||
    /EquippablePickupProjectile|ChildActor/i.test(className) ||
    UTILITY_KIND_RULES.some((rule) => rule.pattern.test(className));
  if (!utilityPrefix) return null;

  const verifiedLifecycleRule = verifiedUtilityActorLifecycleRule(className);
  const fallbackIdentity = inferAbilityIdentityFromLeafTokenFallback(archetypePath);
  const kind =
    verifiedLifecycleRule?.utilityKind ??
    UTILITY_KIND_RULES.find((rule) => rule.pattern.test(className))?.kind ??
    (/^(?:Ability|Projectile|Patch|FXC|GameObject|Pawn|AIPawn)_/i.test(className)
      ? 'ability-actor'
      : 'utility-actor');
  const confidence = [
    fallbackIdentity.agent ? 'agent-token' : null,
    fallbackIdentity.abilitySlot ? 'slot-key-fallback' : null,
    kind ? 'kind-keyword' : null,
  ]
    .filter(Boolean)
    .join('+') || 'utility-class-shape';
  const preliminaryClassification = {
    agent: fallbackIdentity.agent,
    icarusAgentType: fallbackIdentity.icarusAgentType,
    abilitySlot: fallbackIdentity.abilitySlot,
    abilityIndex: fallbackIdentity.abilityIndex,
    abilityName: fallbackIdentity.abilityName,
    identitySource: fallbackIdentity.identitySource,
    identityConfidence: fallbackIdentity.identityConfidence,
    utilityKind: kind,
  };
  const staticMetadata = staticUtilityMetadata(className, preliminaryClassification);
  const resolvedAgent = staticMetadata.hasStaticIdentity
    ? staticMetadata.agentShippingName
    : null;
  const resolvedAbilitySlot = staticMetadata.hasStaticIdentity
    ? staticMetadata.sourceAbilitySlot
    : null;
  if (!resolvedAgent || !resolvedAbilitySlot) {
    // A generic GameObject_/Projectile_ prefix is not sufficient evidence of
    // a player ability (maps also contain classes with those names). Hand-made
    // class overrides and E/Q/C/X path tokens are diagnostics hints only.
    // Preserve such rows below the app-facing lane unless an exact or
    // unambiguous exported-content identity proves agent + slot.
    return null;
  }
  const slotIdentity = abilityIdentityForSlot(resolvedAgent, resolvedAbilitySlot, {
    className,
    canonicalName: staticMetadata.sourceAbilityName,
  });
  const resolvedAbilityIndex =
    slotIdentity.abilityIndex ?? preliminaryClassification.abilityIndex;
  const resolvedAbilityName =
    slotIdentity.abilityName ?? preliminaryClassification.abilityName;
  const resolvedIcarusAgentType =
    (resolvedAgent ? ICARUS_AGENT_TYPE_BY_AGENT.get(resolvedAgent) : null) ??
    preliminaryClassification.icarusAgentType;
  const resolvedClassification = {
    ...preliminaryClassification,
    phase: verifiedLifecycleRule?.phase ?? staticMetadata.phase,
    agent: resolvedAgent ?? null,
    icarusAgentType: resolvedIcarusAgentType ?? null,
    abilitySlot: resolvedAbilitySlot ?? null,
    abilityIndex: resolvedAbilityIndex ?? null,
    abilityName: resolvedAbilityName ?? null,
    identitySource: staticMetadata.identitySource ?? preliminaryClassification.identitySource,
    identityConfidence:
      staticMetadata.identityConfidence ?? preliminaryClassification.identityConfidence,
    lifecyclePolicy:
      verifiedLifecycleRule?.timingPolicy ??
      (['placed-object', 'area-patch', 'projectile-flight', 'submunition', 'deployable-pawn', 'reclaimable-object']
        .includes(staticMetadata.phase)
        ? 'observed-channel'
        : null),
    lifecyclePolicySource:
      verifiedLifecycleRule?.source ??
      (['placed-object', 'area-patch', 'projectile-flight', 'submunition', 'deployable-pawn', 'reclaimable-object']
        .includes(staticMetadata.phase)
        ? 'replay-evidence-policy'
        : null),
    verifiedAbilityId: verifiedLifecycleRule?.abilityId ?? null,
  };
  const displayLifetime = utilityActorDisplayLifetime(className, resolvedClassification);

  return {
    className,
    ...staticMetadata,
    ...resolvedClassification,
    sourceAbilitySlot: staticMetadata.sourceAbilitySlot,
    sourceAbilityName:
      (staticMetadata.staticAssetPath ? staticMetadata.sourceAbilityName : null) ??
      resolvedAbilityName ??
      null,
    displayLifetimeMs: displayLifetime?.lifetimeMs ?? null,
    durationSource: displayLifetime?.source ?? null,
    ignoredAsAbility:
      Boolean(displayLifetime?.ignored) ||
      staticMetadata.contentKind === 'pickup-drop' ||
      staticMetadata.phase === 'pickup-drop',
    confidence: [
      confidence,
      staticMetadata.staticAssetPath ? 'static-catalog' : null,
      staticMetadata.sourceAbilityClass ? 'spawn-graph' : null,
    ]
      .filter(Boolean)
      .join('+'),
  };
}

function sourceAbilityIndex(slot) {
  switch (slot) {
    case 'Grenade':
      return 0;
    case 'Ability1':
      return 1;
    case 'Ability2':
      return 2;
    case 'Ultimate':
      return 3;
    default:
      return null;
  }
}

function toRoundedVector(value) {
  if (!value) return null;
  return {
    x: Number(value.x.toFixed(2)),
    y: Number(value.y.toFixed(2)),
    z: Number(value.z.toFixed(2)),
  };
}

function applyObservedUtilityActorClose(
  entry,
  { timeMs, closeReason = 0, dormant = false },
) {
  if (!entry || !Number.isFinite(timeMs) || timeMs < entry.observedStartMs) {
    return false;
  }
  const observedLifetimeMs = timeMs - entry.observedStartMs;
  entry.closedAtMs = timeMs;
  entry.observedEndMs = timeMs;
  entry.observedLifetimeMs = observedLifetimeMs;
  entry.closeReason = closeReason;
  entry.dormant = Boolean(dormant);
  entry.endReason = dormant ? 'channel-dormancy' : 'actor-channel-close';
  entry.endReasonEvidence = 'observed-channel-close';
  entry.lifecycleEvidence = 'observed';
  entry.effectiveEndMs = timeMs;
  entry.durationSource = 'observed-channel-close';
  entry.evidenceRoles = [...new Set([...(entry.evidenceRoles ?? []), 'actor-channel-close'])];
  if (!entry.ignoredAsAbility) {
    // Legacy consumers still read lifetimeMs. It must reflect the strongest
    // available evidence, never an earlier wiki or generic fallback.
    entry.lifetimeMs = observedLifetimeMs;
  }
  return true;
}

function annotateUtilityActorEndReasons(
  actors,
  roundStartEvents = [],
  { observationEndMs = null, observationComplete = false } = {},
) {
  const sortedRoundStarts = [...(roundStartEvents ?? [])]
    .filter((event) => Number.isFinite(event?.timeMs))
    .sort((a, b) => a.timeMs - b.timeMs);
  for (const actor of actors ?? []) {
    if (!Number.isFinite(actor?.observedEndMs)) {
      const observedActorPolicy =
        actor?.lifecyclePolicy === 'observed-actor' ||
        actor?.lifecyclePolicy === 'observed-channel';
      const nextRound = observedActorPolicy
        ? sortedRoundStarts.find((event) => event.timeMs > actor.observedStartMs)
        : null;
      if (nextRound) {
        actor.endReason = 'round-teardown';
        actor.endReasonEvidence = 'derived:open-channel-at-next-round-start';
        actor.roundTeardownEventId = nextRound.id ?? null;
        actor.roundTeardownAtMs = nextRound.timeMs;
        actor.effectiveEndMs = nextRound.timeMs;
        actor.durationSource = 'derived:round-start-boundary';
        actor.lifecycleEvidence = 'derived';
        actor.evidenceRoles = [
          ...new Set([...(actor.evidenceRoles ?? []), 'round-start-boundary']),
        ];
        if (!actor.ignoredAsAbility) {
          actor.lifetimeMs = nextRound.timeMs - actor.observedStartMs;
        }
        continue;
      }
      if (
        observedActorPolicy &&
        observationComplete &&
        Number.isFinite(observationEndMs) &&
        Number.isFinite(actor?.observedStartMs) &&
        actor.observedStartMs <= observationEndMs
      ) {
        // The boundary is observed; the lifecycle end is not. Do not convert
        // this into an observed end or an invented lifetime.
        actor.endReason = 'recording-censored';
        actor.endReasonEvidence = 'derived:complete-observation-without-close';
        actor.censoredAtMs = observationEndMs;
        actor.effectiveEndMs = observationEndMs;
        actor.durationSource = 'derived:recording-censored';
        actor.lifecycleEvidence = 'derived';
        actor.evidenceRoles = [
          ...new Set([...(actor.evidenceRoles ?? []), 'recording-boundary']),
        ];
        if (!actor.ignoredAsAbility) {
          actor.lifetimeMs = observationEndMs - actor.observedStartMs;
        }
      }
      continue;
    }
    if (actor.dormant) continue;
    const nextRound = sortedRoundStarts.find(
      (event) =>
        event.timeMs >= actor.observedEndMs &&
        event.timeMs - actor.observedEndMs <= 1_000,
    );
    if (!nextRound) continue;
    actor.endReason = 'round-teardown';
    actor.endReasonEvidence = 'derived:actor-close-before-round-start';
    actor.roundTeardownEventId = nextRound.id ?? null;
    actor.roundTeardownAtMs = nextRound.timeMs;
    actor.evidenceRoles = [
      ...new Set([...(actor.evidenceRoles ?? []), 'round-start-boundary']),
    ];
  }
  return actors;
}

function noteUtilityActorOpen(packetContext, sample) {
  const classification = classifyUtilityActorArchetype(sample.archetypePath);
  if (!classification) return;
  if (packetContext.utilityActorOpenSamples.length >= UTILITY_ACTOR_SAMPLE_LIMIT) return;
  const position = toRoundedVector(sample.location);
  if (
    position &&
    (!Number.isFinite(position.x) || !Number.isFinite(position.y) || !Number.isFinite(position.z))
  ) {
    return;
  }

  const entry = {
    id: `actor-${sample.actorNetGuid ?? sample.chIndex}`,
    timeMs: sample.timeMs,
    observedStartMs: sample.timeMs,
    observedEndMs: null,
    fallbackEndMs: null,
    effectiveEndMs: null,
    closedAtMs: null,
    lifetimeMs: null,
    observedLifetimeMs: null,
    fallbackLifetimeMs: null,
    fallbackDurationSource: null,
    durationSource: null,
    lifecycleEvidence: 'absent',
    endReason: null,
    endReasonEvidence: null,
    closeReason: null,
    dormant: false,
    chIndex: sample.chIndex,
    actorNetGuid: sample.actorNetGuid,
    archetype: sample.archetype,
    archetypePath: sample.archetypePath,
    className: classification.className,
    agent: classification.agent,
    icarusAgentType: classification.icarusAgentType,
    abilitySlot: classification.abilitySlot,
    abilityIndex: classification.abilityIndex,
    abilityName: classification.abilityName,
    utilityKind: classification.utilityKind,
    contentKind: classification.contentKind,
    phase: classification.phase,
    sourceAbilityClass: classification.sourceAbilityClass,
    sourceAbilitySlot: classification.sourceAbilitySlot,
    sourceAbilityName: classification.sourceAbilityName ?? classification.abilityName,
    sourceAbilityAssetPath: classification.sourceAbilityAssetPath,
    sourceContentKind: classification.sourceContentKind,
    staticAbilitySlot: classification.staticAbilitySlot,
    staticAbilityName: classification.staticAbilityName,
    staticAssetPath: classification.staticAssetPath,
    staticAssetKind: classification.staticAssetKind,
    identitySource: classification.identitySource,
    identityConfidence: classification.identityConfidence,
    agentUuid: classification.agentUuid,
    characterId: classification.characterId,
    agentDeveloperName: classification.agentDeveloperName,
    agentShippingName: classification.agentShippingName,
    lifecyclePolicy: classification.lifecyclePolicy,
    lifecyclePolicySource: classification.lifecyclePolicySource,
    verifiedAbilityId: classification.verifiedAbilityId,
    evidenceRoles: ['actor-channel-open', classification.staticAssetPath ? 'static-catalog' : null]
      .filter(Boolean),
    phaseGroupId: classification.sourceAbilityClass
      ? `${classification.sourceAbilityClass}:${sample.timeMs}`
      : null,
    confidence: classification.confidence,
    ignoredAsAbility: classification.ignoredAsAbility || undefined,
    position,
    velocity: toRoundedVector(sample.velocity),
    yawDegrees: Number((sample.rotation?.yaw ?? 0).toFixed(2)),
    rotation: {
      pitchDegrees: Number((sample.rotation?.pitch ?? 0).toFixed(2)),
      yawDegrees: Number((sample.rotation?.yaw ?? 0).toFixed(2)),
      rollDegrees: Number((sample.rotation?.roll ?? 0).toFixed(2)),
    },
    samples: position
      ? [
          {
            timeMs: sample.timeMs,
            position,
            yawDegrees: Number((sample.rotation?.yaw ?? 0).toFixed(2)),
          },
        ]
      : [],
  };
  if (sample.timeMs > UTILITY_ACTOR_INITIAL_REPLICATION_GRACE_MS) {
    if (Number.isFinite(classification.displayLifetimeMs)) {
      entry.fallbackLifetimeMs = classification.displayLifetimeMs;
      entry.fallbackEndMs = sample.timeMs + classification.displayLifetimeMs;
      entry.fallbackDurationSource = classification.durationSource;
      entry.effectiveEndMs = entry.fallbackEndMs;
      entry.lifetimeMs = classification.displayLifetimeMs;
      entry.durationSource = classification.durationSource;
      entry.lifecycleEvidence = 'fallback';
    } else {
      entry.durationSource = classification.durationSource;
    }
  } else {
    entry.ignoredAsAbility = true;
    entry.durationSource = 'ignored-initial-replication';
  }

  packetContext.utilityActorOpenSamples.push(entry);
  if (Number.isInteger(entry.actorNetGuid)) {
    packetContext.utilityActorOpenByNetGuid.set(entry.actorNetGuid, entry);
  }
}

function noteUtilityActorClose(packetContext, bunch, channel) {
  const actor = channel?.actor;
  const actorNetGuid = actor?.actorNetGuid?.value ?? null;
  const archetypePath = getPathForNetGuid(packetContext.frameContext, actor?.archetype?.value ?? 0);
  const classification = classifyUtilityActorArchetype(archetypePath);
  if (!classification) return;

  const closeEntry = {
    timeMs: bunch.timeMs,
    chIndex: bunch.chIndex,
    actorNetGuid,
    closeReason: bunch.closeReason,
    dormant: Boolean(bunch.bDormant),
    archetypePath,
    className: classification.className,
  };
  if (packetContext.utilityActorCloseSamples.length < UTILITY_ACTOR_SAMPLE_LIMIT) {
    packetContext.utilityActorCloseSamples.push(closeEntry);
  }

  const openEntry = Number.isInteger(actorNetGuid)
    ? packetContext.utilityActorOpenByNetGuid.get(actorNetGuid)
    : null;
  if (openEntry && openEntry.closedAtMs == null && bunch.timeMs >= openEntry.timeMs) {
    const ignoredAsAbility =
      classification.ignoredAsAbility ||
      openEntry.ignoredAsAbility ||
      /^ignored-/i.test(openEntry.durationSource ?? classification.durationSource ?? '');
    if (ignoredAsAbility) openEntry.ignoredAsAbility = true;
    applyObservedUtilityActorClose(openEntry, {
      timeMs: bunch.timeMs,
      closeReason: bunch.closeReason,
      dormant: Boolean(bunch.bDormant),
    });
  }
}

function findExportGroupForNetGuid(context, netGuid) {
  const pathName = getPathForNetGuid(context, netGuid);
  const token = normalizePathToken(pathName);
  if (!token) return null;
  for (const group of context.exportGroupsByPath.values()) {
    if (group.pathName.endsWith('_ClassNetCache')) continue;
    const groupToken = normalizePathToken(group.pathName);
    if (groupToken && (groupToken.includes(token) || token.includes(groupToken))) {
      return group;
    }
  }
  return null;
}

function findClassNetCacheForGroup(context, group) {
  if (!group) return null;
  return (
    context.exportGroupsByPath.get(`${group.pathName}_ClassNetCache`) ??
    context.exportGroupsByPath.get(`${group.pathName.split('/').at(-1)}_ClassNetCache`) ??
    null
  );
}

function findTargetRpcGroup(context) {
  for (const group of context.exportGroupsByPath.values()) {
    if (group.pathName.includes('ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous')) {
      return group;
    }
  }
  return null;
}

function findRpcGroupByPath(context, pattern) {
  for (const group of context.exportGroupsByPath.values()) {
    if (pattern.test(group.pathName)) return group;
  }
  return null;
}

function peekBitsHex(reader, bitCount = 128) {
  const oldOffset = reader.offset;
  const oldError = reader.isError;
  const bits = Math.min(bitCount, Math.max(0, reader.bitsLeft));
  const value = reader.readBits(bits).toString('hex');
  reader.offset = oldOffset;
  reader.isError = oldError;
  return value;
}

function copyBitsFromReader(reader, bitCount) {
  const oldOffset = reader.offset;
  const oldError = reader.isError;
  const bits = Math.min(bitCount, Math.max(0, reader.bitsLeft));
  const value = reader.readBits(bits);
  reader.offset = oldOffset;
  reader.isError = oldError;
  return value;
}

function incrementCountMap(map, key, amount = 1) {
  map.set(key, (map.get(key) ?? 0) + amount);
}

function bumpNestedCount(stat, name, key) {
  stat[name] ??= new Map();
  incrementCountMap(stat[name], key);
}

function topCounts(map, limit = 20) {
  return [...(map ?? new Map()).entries()]
    .map(([key, count]) => ({ key, count }))
    .sort((a, b) => b.count - a.count || String(a.key).localeCompare(String(b.key)))
    .slice(0, limit);
}

function isAbilitySignalFieldName(name) {
  return /Ability|Equippable|Input|Cast|RoundPhase|Slot_|Player_|EffectLocations|DestroyedCount|Statistic/i.test(
    name ?? '',
  ) || /FocusProjectiles/i.test(name ?? '');
}

function isInputEventCaptureFunction(name) {
  return /ClientReplayReceiveInputEventProcessingCapture/i.test(name ?? '');
}

function isAbilityCastsThisRoundField(name) {
  return name === 'AbilityCastsThisRound';
}

function decodeFocusProjectileReferences(packetContext, payloadHex, numBits) {
  if (!payloadHex || !Number.isFinite(numBits)) return [];
  const buffer = Buffer.from(payloadHex, 'hex');
  const bitLimit = Math.min(numBits, buffer.length * 8);
  const references = [];
  const seen = new Set();
  for (let bitOffset = 0; bitOffset + 8 <= bitLimit; bitOffset += 8) {
    const reader = new BitReader(buffer, bitLimit, bitOffset);
    const netGuid = reader.readIntPacked();
    if (reader.isError || netGuid < 256) continue;
    const pathName = getPathForNetGuid(packetContext.frameContext, netGuid);
    const key = `${bitOffset}:${netGuid}`;
    if (seen.has(key)) continue;
    seen.add(key);
    references.push({
      bitOffset,
      netGuid,
      pathName: pathName || null,
    });
  }
  return references;
}

function isAbilitySignalGroupPath(pathName) {
  return /Comp_AbilityStatisticsReplicator|AbilityTrackingDelegateComponent|AresAbilitySystemComponent|AresInputStateComponent|AresInventory|AresEquippable|EquipmentChargeComponent|EquippableStateMachineComponent/i.test(
    pathName ?? '',
  );
}

function isAbilitySignalPath(pathName) {
  return /\/Game\/Characters\/.*(?:Ability|Equippable|Projectile|GameObject|Patch)/i.test(
    pathName ?? '',
  );
}

function isAbilitySignalSample(sample) {
  return (
    isAbilitySignalGroupPath(sample.actorGroup) ||
    isAbilitySignalGroupPath(sample.repObjectPath) ||
    isAbilitySignalFieldName(sample.fieldName) ||
    isInputEventCaptureFunction(sample.functionName ?? sample.fieldName) ||
    isAbilitySignalPath(sample.actorPath) ||
    isAbilitySignalPath(sample.repObjectPath)
  );
}

function noteAbilitySignalSample(packetContext, sample) {
  if (!isAbilitySignalSample(sample)) return;
  const payloadHex = sample.payloadHex ?? '';
  const numBits = sample.numBits ?? sample.numPayloadBits ?? null;
  const payloadHexTruncated =
    sample.payloadHexTruncated ||
    (Number.isFinite(numBits) && payloadHex.length * 4 < numBits) ||
    undefined;
  const fieldName = sample.fieldName ?? sample.functionName ?? null;
  const baseSample = {
    timeMs: sample.timeMs,
    chIndex: sample.chIndex,
    actorNetGuid: sample.actorNetGuid ?? null,
    actorPath: sample.actorPath ?? null,
    actorGroup: sample.actorGroup ?? null,
    repObject: sample.repObject ?? null,
    repObjectPath: sample.repObjectPath ?? null,
    source: sample.source,
    handle: sample.handle ?? sample.fieldHandle ?? null,
    rawHandle: sample.rawHandle ?? null,
    fieldName,
    numBits,
  };
  if (/FocusProjectiles/i.test(fieldName ?? '')) {
    baseSample.focusProjectileReferences = decodeFocusProjectileReferences(
      packetContext,
      payloadHex,
      numBits,
    );
  }
  if (
    /^(?:CurrentState|OwnerActor|AvatarActor|MyEquippable|AbilityTrackingComponent|CachedAttributeSet)$/i.test(
      fieldName ?? '',
    )
  ) {
    baseSample.netGuidReferences = decodeFocusProjectileReferences(
      packetContext,
      payloadHex,
      numBits,
    );
  }

  if (
    isAbilityCastsThisRoundField(fieldName) &&
    packetContext.abilityCastSignalSamples.length <
      packetContext.abilityCastSignalSampleLimit
  ) {
    packetContext.abilityCastSignalSamples.push({
      ...baseSample,
      payloadHex: payloadHex.slice(0, ABILITY_CAST_SIGNAL_PAYLOAD_HEX_LIMIT),
      payloadHexTruncated:
        payloadHexTruncated ||
        payloadHex.length > ABILITY_CAST_SIGNAL_PAYLOAD_HEX_LIMIT ||
        undefined,
    });
  }

  if (packetContext.abilitySignalSamples.length >= packetContext.abilitySignalSampleLimit) {
    packetContext.abilitySignalOverflowCount += 1;
    return;
  }
  packetContext.abilitySignalSamples.push({
    ...baseSample,
    payloadHex: payloadHex.slice(0, ABILITY_SIGNAL_PAYLOAD_HEX_LIMIT),
    payloadHexTruncated:
      payloadHexTruncated ||
      payloadHex.length > ABILITY_SIGNAL_PAYLOAD_HEX_LIMIT ||
      undefined,
  });
}

function noteDiagnosticActorWireSample(packetContext, sample) {
  if (
    !packetContext.diagnosticActorNetGuids?.has(sample.actorNetGuid) ||
    packetContext.diagnosticActorWireSamples.length >=
      packetContext.diagnosticActorWireSampleLimit
  ) {
    if (
      packetContext.diagnosticActorNetGuids?.has(sample.actorNetGuid) &&
      packetContext.diagnosticActorWireSamples.length >=
        packetContext.diagnosticActorWireSampleLimit
    ) {
      packetContext.diagnosticActorWireOverflowCount += 1;
    }
    return;
  }

  const payloadHex = sample.payloadHex ?? '';
  const numBits = sample.numBits ?? sample.numPayloadBits ?? null;
  packetContext.diagnosticActorWireSamples.push({
    timeMs: sample.timeMs,
    chIndex: sample.chIndex,
    actorNetGuid: sample.actorNetGuid,
    actorPath: sample.actorPath ?? null,
    actorGroup: sample.actorGroup ?? null,
    repObject: sample.repObject ?? null,
    repObjectPath: sample.repObjectPath ?? null,
    classNetCache: sample.classNetCache ?? null,
    source: sample.source,
    handle: sample.handle ?? sample.fieldHandle ?? null,
    rawHandle: sample.rawHandle ?? null,
    fieldName: sample.fieldName ?? sample.functionName ?? null,
    numBits,
    payloadHex: payloadHex.slice(0, ABILITY_SIGNAL_PAYLOAD_HEX_LIMIT),
    payloadHexTruncated:
      sample.payloadHexTruncated ||
      payloadHex.length > ABILITY_SIGNAL_PAYLOAD_HEX_LIMIT ||
      (Number.isFinite(numBits) && payloadHex.length * 4 < numBits) ||
      undefined,
  });
}

function decodeInputEventCaptureFields(fields = []) {
  const playerIdField = fields.find((field) => field.name === 'PlayerID');
  const eventDataField = fields.find((field) => field.name === 'InputEventData');
  const playerIdBuffer = Buffer.from(playerIdField?.payloadHex ?? '', 'hex');
  const eventDataBuffer = Buffer.from(eventDataField?.payloadHex ?? '', 'hex');
  if (playerIdBuffer.length < 4 || eventDataBuffer.length < 2) return null;

  const bitCount = readByteIntPacked(eventDataBuffer, 0);
  if (!bitCount || bitCount.value < 4) return null;
  const serializedByteCount = Math.ceil(bitCount.value / 8);
  const serializedEnd = bitCount.offset + serializedByteCount;
  if (serializedEnd > eventDataBuffer.length) return null;
  const serializedData = eventDataBuffer.subarray(bitCount.offset, serializedEnd);
  if (serializedData.length === 0) return null;

  const eventTypeValue = serializedData[0] & 0x0f;
  const playerReplayId = playerIdBuffer.readUInt32LE(0);
  return {
    playerReplayId,
    // Replay captures encode the ten match-player IDs as 0x100..0x109.
    // Keep the raw ID and expose the low byte as a candidate header-loadout
    // join; the native emitter validates it against the actual header roster.
    candidateLoadoutIndex:
      (playerReplayId & 0xffffff00) === 0x100
        ? playerReplayId & 0xff
        : null,
    eventTypeValue,
    eventType: INPUT_EVENT_TYPE_NAMES.get(eventTypeValue) ?? `Unknown(${eventTypeValue})`,
    eventValueNibble: serializedData[0] >> 4,
    serializedBitCount: bitCount.value,
    serializedDataHex: serializedData.toString('hex'),
    eventProcessingResult:
      serializedEnd < eventDataBuffer.length
        ? eventDataBuffer[serializedEnd]
        : null,
    rawInputEventDataHex: eventDataBuffer.toString('hex'),
  };
}

function noteInputEventCaptureSample(packetContext, sample, fields = []) {
  const decoded = decodeInputEventCaptureFields(fields);
  const compactKey = decoded
    ? `${sample.timeMs}|${decoded.playerReplayId}|${decoded.rawInputEventDataHex}`
    : null;

  if (
    decoded &&
    decoded.eventTypeValue !== 3 &&
    !packetContext.nonMovementInputEventKeys.has(compactKey)
  ) {
    packetContext.nonMovementInputEventKeys.add(compactKey);
    incrementCountMap(
      packetContext.nonMovementInputEventTypeCounts,
      decoded.eventType,
    );
    if (
      packetContext.nonMovementInputEventSamples.length <
        packetContext.nonMovementInputEventSampleLimit
    ) {
      packetContext.nonMovementInputEventSamples.push({
        id: `input-${packetContext.nonMovementInputEventSamples.length}`,
        timeMs: sample.timeMs,
        ...decoded,
        evidenceSource:
          '/Game/Characters/_Core/BaseReplayController:ClientReplayReceiveInputEventProcessingCapture',
      });
    } else {
      packetContext.nonMovementInputEventOverflowCount += 1;
    }
  }

  if (
    packetContext.inputEventCaptureSamples.length >=
      packetContext.inputEventCaptureSampleLimit ||
    (compactKey && packetContext.inputEventCaptureKeys.has(compactKey))
  ) {
    return;
  }
  if (compactKey) packetContext.inputEventCaptureKeys.add(compactKey);
  const payloadHex = sample.payloadHex ?? '';
  packetContext.inputEventCaptureSamples.push({
    timeMs: sample.timeMs,
    chIndex: sample.chIndex,
    actorNetGuid: sample.actorNetGuid ?? null,
    actorPath: sample.actorPath ?? null,
    actorGroup: sample.actorGroup ?? null,
    repObject: sample.repObject ?? null,
    repObjectPath: sample.repObjectPath ?? null,
    source: 'classnet-rpc',
    classNetCache: sample.classNetCache ?? null,
    functionHandle: sample.fieldHandle ?? null,
    functionName: sample.fieldName ?? null,
    numPayloadBits: sample.numPayloadBits ?? null,
    payloadHex: payloadHex.slice(0, ABILITY_SIGNAL_PAYLOAD_HEX_LIMIT),
    payloadHexTruncated: payloadHex.length > ABILITY_SIGNAL_PAYLOAD_HEX_LIMIT || undefined,
    decoded,
    fields: fields.slice(0, 24),
  });
}

function summarizeNonMovementInputEvents(packetContext) {
  return {
    count: packetContext.nonMovementInputEventSamples.length,
    overflowCount: packetContext.nonMovementInputEventOverflowCount,
    sampleLimit: packetContext.nonMovementInputEventSampleLimit,
    byType: topCounts(packetContext.nonMovementInputEventTypeCounts, 16),
  };
}

function abilitySlotFromAresItemSlot(value) {
  return ARES_ITEM_SLOT_TO_ABILITY_SLOT.get(value) ?? null;
}

function abilityIndexFromAresItemSlot(value) {
  const abilitySlot = abilitySlotFromAresItemSlot(value);
  return sourceAbilityIndex(abilitySlot);
}

function abilitySignalMetadataFromActorPath(actorPath) {
  const fallbackMetadata = inferAbilityIdentityFromLeafTokenFallback(actorPath);
  const genericMetadata = {
    agent: fallbackMetadata.agent,
    icarusAgentType: fallbackMetadata.icarusAgentType,
    abilitySlot: fallbackMetadata.abilitySlot,
    abilityIndex: fallbackMetadata.abilityIndex,
    abilityName: fallbackMetadata.abilityName,
    identitySource: fallbackMetadata.identitySource,
    identityConfidence: fallbackMetadata.identityConfidence,
    utilityKind: null,
  };
  const staticMetadata = staticUtilityMetadata(archetypeClassName(actorPath), genericMetadata);
  const abilitySlot = staticMetadata.sourceAbilitySlot ?? genericMetadata.abilitySlot;
  const agent = staticMetadata.agentShippingName ?? genericMetadata.agent;
  const slotIdentity = abilityIdentityForSlot(agent, abilitySlot, {
    className: archetypeClassName(actorPath),
    canonicalName: staticMetadata.sourceAbilityName,
  });
  const abilityIndex = slotIdentity.abilityIndex ?? genericMetadata.abilityIndex;
  return {
    agent: agent ?? null,
    icarusAgentType:
      (agent ? ICARUS_AGENT_TYPE_BY_AGENT.get(agent) : null) ??
      genericMetadata.icarusAgentType,
    abilitySlot: abilitySlot ?? null,
    abilityIndex,
    abilityName: slotIdentity.abilityName ?? genericMetadata.abilityName,
    identitySource: staticMetadata.identitySource ?? genericMetadata.identitySource,
    identityConfidence: staticMetadata.identityConfidence ?? genericMetadata.identityConfidence,
  };
}

function decodeMapTargetingSingleClickVector(sample) {
  if (sample?.fieldName !== 'MulticastRespondToValidSingleMapClick') return null;
  if (!/MapTargetingStateComponent/i.test(sample.actorGroup ?? '')) return null;
  const payloadHex = sample.payloadHex ?? '';
  if (!payloadHex || sample.payloadHexTruncated) return null;

  const bitCount = sample.numBits ?? sample.numPayloadBits ?? payloadHex.length * 4;
  const reader = new BitReader(Buffer.from(payloadHex, 'hex'), bitCount);
  reader.skipBits(1);
  const rawHandle = reader.readIntPacked();
  if (rawHandle !== 1) return null;
  const vectorBits = reader.readIntPacked();
  if (vectorBits !== 192 || !reader.canRead(vectorBits)) return null;
  const vectorBuffer = reader.readBits(vectorBits);
  if (reader.isError) return null;
  return readAbilityVectorDouble64(vectorBuffer, 0);
}

function placementSignalsFromAbilitySignalSamples(samples) {
  const placements = [];
  for (const sample of samples ?? []) {
    const position = decodeMapTargetingSingleClickVector(sample);
    if (!position) continue;
    const metadata = abilitySignalMetadataFromActorPath(sample.actorPath);
    if (!metadata.agent || !metadata.abilitySlot) continue;
    placements.push({
      id: `placement-${placements.length}`,
      timeMs: sample.timeMs,
      position,
      agent: metadata.agent,
      icarusAgentType: metadata.icarusAgentType,
      abilitySlot: metadata.abilitySlot,
      abilityIndex: metadata.abilityIndex,
      abilityName: metadata.abilityName ?? null,
      source: 'MapTargetingStateComponent.MulticastRespondToValidSingleMapClick',
      actorNetGuid: sample.actorNetGuid ?? null,
      actorPath: sample.actorPath ?? null,
      actorGroup: sample.actorGroup ?? null,
      repObject: sample.repObject ?? null,
      repObjectPath: sample.repObjectPath ?? null,
      fieldName: sample.fieldName ?? null,
      numBits: sample.numBits ?? sample.numPayloadBits ?? null,
      payloadHex: (sample.payloadHex ?? '').slice(0, ABILITY_SIGNAL_PAYLOAD_HEX_LIMIT),
    });
  }
  return placements.sort((a, b) => a.timeMs - b.timeMs);
}

function attachPlacementSignalsToAbilityCasts(casts, placementSignals) {
  if (!casts.length || !placementSignals.length) return casts;
  const usedPlacementIds = new Set();
  return casts.map((cast) => {
    const candidates = placementSignals
      .filter((placement) => {
        if (usedPlacementIds.has(placement.id)) return false;
        if (placement.agent && cast.agent && placement.agent !== cast.agent) return false;
        if (placement.abilitySlot && cast.abilitySlot && placement.abilitySlot !== cast.abilitySlot) {
          return false;
        }
        const deltaMs = cast.timeMs - placement.timeMs;
        return deltaMs >= -250 && deltaMs <= 3500;
      })
      .sort((a, b) => Math.abs(cast.timeMs - a.timeMs) - Math.abs(cast.timeMs - b.timeMs));
    const placement = candidates[0] ?? null;
    if (!placement) return cast;
    usedPlacementIds.add(placement.id);
    const evidenceRoles = [
      ...(cast.evidenceRoles ?? []),
      'MapTargetingStateComponent',
      'MapTargetingStateComponent-ValidSingleMapClick-vector',
    ];
    return {
      ...cast,
      placementLocations: [placement.position],
      placementTimeMs: placement.timeMs,
      placementSource: placement.source,
      placementActorNetGuid: placement.actorNetGuid,
      confidence: `${cast.confidence}+placement-map-click`,
      evidenceRoles: [...new Set(evidenceRoles)],
      raw: {
        ...(cast.raw ?? {}),
        placementSignal: {
          timeMs: placement.timeMs,
          actorNetGuid: placement.actorNetGuid,
          actorPath: placement.actorPath,
          actorGroup: placement.actorGroup,
          repObject: placement.repObject,
          repObjectPath: placement.repObjectPath,
          fieldName: placement.fieldName,
          numBits: placement.numBits,
          payloadHex: placement.payloadHex,
        },
      },
    };
  });
}

function readByteIntPacked(buffer, offset) {
  let value = 0;
  let shift = 1;
  let cursor = offset;
  for (let index = 0; index < 5; index += 1) {
    if (cursor >= buffer.length) return null;
    const currentByte = buffer[cursor];
    value += (currentByte >> 1) * shift;
    cursor += 1;
    if ((currentByte & 1) === 0) return { value, offset: cursor };
    shift *= 128;
  }
  return null;
}

function roundReplayNumber(value, digits = 3) {
  if (!Number.isFinite(value)) return null;
  return Number(value.toFixed(digits));
}

function isPlausibleAbilityVector(vector) {
  return (
    vector != null &&
    Number.isFinite(vector.x) &&
    Number.isFinite(vector.y) &&
    Number.isFinite(vector.z) &&
    Math.abs(vector.x) <= 20000 &&
    Math.abs(vector.y) <= 20000 &&
    vector.z >= -1000 &&
    vector.z <= 2000 &&
    (Math.abs(vector.x) >= 50 || Math.abs(vector.y) >= 50)
  );
}

function readAbilityVectorDouble64(buffer, offset) {
  if (offset + 24 > buffer.length) return null;
  const vector = {
    x: roundReplayNumber(buffer.readDoubleLE(offset)),
    y: roundReplayNumber(buffer.readDoubleLE(offset + 8)),
    z: roundReplayNumber(buffer.readDoubleLE(offset + 16)),
  };
  return isPlausibleAbilityVector(vector) ? vector : null;
}

function parseAbilityEffectLocations(buffer, offset) {
  if (buffer[offset] !== 0x14) return { locations: [], offset, layout: null };
  const fieldBits = readByteIntPacked(buffer, offset + 1);
  if (!fieldBits || fieldBits.value <= 0 || fieldBits.value % 8 !== 0) {
    return { locations: [], offset, layout: null };
  }

  const payloadStart = fieldBits.offset;
  const payloadEnd = payloadStart + fieldBits.value / 8;
  if (payloadEnd > buffer.length) return { locations: [], offset, layout: null };

  const arrayCount = readByteIntPacked(buffer, payloadStart);
  if (!arrayCount || arrayCount.value < 0 || arrayCount.value > 32) {
    return { locations: [], offset, layout: null };
  }

  let cursor = arrayCount.offset;
  const locations = [];
  const elementLayouts = [];
  for (let index = 0; index < arrayCount.value; index += 1) {
    const elementStart = cursor;
    if (buffer[cursor] === 0x02) cursor += 1;
    if (buffer[cursor] !== 0x16) return { locations: [], offset, layout: null };
    const vectorBits = readByteIntPacked(buffer, cursor + 1);
    if (!vectorBits || vectorBits.value !== 192) {
      return { locations: [], offset, layout: null };
    }
    const vector = readAbilityVectorDouble64(buffer, vectorBits.offset);
    if (!vector) return { locations: [], offset, layout: null };
    locations.push(vector);
    cursor = vectorBits.offset + 24;
    while (cursor < payloadEnd && buffer[cursor] === 0x00) cursor += 1;
    elementLayouts.push({
      elementIndex: index,
      elementOffset: elementStart,
      vectorOffset: vectorBits.offset,
      vectorBits: vectorBits.value,
    });
  }

  return {
    locations,
    offset: payloadEnd,
    layout: {
      fieldOffset: offset,
      fieldBits: fieldBits.value,
      arrayCount: arrayCount.value,
      elementLayouts,
    },
  };
}

function readFStringFromBitReader(reader) {
  if (!reader.canRead(32)) return null;
  const rawLength = reader.readUInt32();
  const length = rawLength > 0x7fffffff ? rawLength - 0x100000000 : rawLength;
  if (length === 0) return '';
  if (length > 0) {
    if (length > 1_000_000 || !reader.canRead(length * 8)) return null;
    const bytes = reader.readBytes(length);
    return bytes.subarray(0, Math.max(0, bytes.length - 1)).toString('utf8');
  }
  const charCount = -length;
  if (charCount > 500_000 || !reader.canRead(charCount * 16)) return null;
  const bytes = reader.readBytes(charCount * 2);
  return bytes.subarray(0, Math.max(0, bytes.length - 2)).toString('utf16le');
}

function parseStringTableTextPayload(buffer, bitCount) {
  const reader = new BitReader(buffer, bitCount);
  if (!reader.canRead(1 + 32 + 8)) return null;
  const prefixBit = reader.readBit() ? 1 : 0;
  const flags = reader.readUInt32();
  const historyType = reader.readByte();
  if (reader.isError || historyType !== 5) {
    return { prefixBit, flags, historyType, tableId: null, key: null };
  }
  const tableId = readFStringFromBitReader(reader);
  if (tableId == null || !reader.canRead(32)) {
    return { prefixBit, flags, historyType, tableId, key: null };
  }
  const tableIdNumber = reader.readUInt32();
  const key = readFStringFromBitReader(reader);
  return { prefixBit, flags, historyType, tableId, tableIdNumber, key };
}

function readUserStructFields(reader) {
  const fields = new Map();
  while (!reader.atEnd() && reader.bitsLeft >= 8) {
    const handle = reader.readIntPacked();
    if (reader.isError) break;
    if (handle === 0) return { fields, terminated: true };
    const bitCount = reader.readIntPacked();
    if (
      reader.isError ||
      !Number.isInteger(bitCount) ||
      bitCount < 0 ||
      !reader.canRead(bitCount)
    ) {
      return { fields, terminated: false, error: 'invalid-field-bit-count' };
    }
    fields.set(handle, {
      handle,
      bitCount,
      payload: reader.readBits(bitCount),
    });
  }
  return { fields, terminated: false };
}

function floatFromStructField(field) {
  if (!field || field.bitCount !== 32 || field.payload.length < 4) return null;
  const value = field.payload.readFloatLE(0);
  return Number.isFinite(value) ? Number(value.toFixed(6)) : null;
}

function parseAbilityAffectedTargets(field) {
  if (!field || field.bitCount <= 0) return [];
  const reader = new BitReader(field.payload, field.bitCount);
  const count = reader.readIntPacked();
  if (reader.isError || count < 0 || count > 64) return [];
  const targets = [];
  for (let index = 0; index < count; index += 1) {
    const elementMarker = reader.readIntPacked();
    if (reader.isError || elementMarker !== 1) break;
    const parsed = readUserStructFields(reader);
    const playerField = parsed.fields.get(20);
    const valueField = parsed.fields.get(21);
    let affectedPlayerNetGuid = null;
    if (playerField) {
      const playerReader = new BitReader(playerField.payload, playerField.bitCount);
      affectedPlayerNetGuid = playerReader.readIntPacked();
      if (playerReader.isError) affectedPlayerNetGuid = null;
    }
    targets.push({
      affectedPlayerNetGuid,
      value: floatFromStructField(valueField),
    });
  }
  return targets;
}

function parseCharacterAbilityEffects(buffer, bitCount) {
  if (!buffer?.length || !(bitCount > 0)) return [];
  const reader = new BitReader(buffer, Math.min(bitCount, buffer.length * 8));
  const count = reader.readIntPacked();
  if (reader.isError || count < 0 || count > 64) return [];
  const effects = [];
  for (let index = 0; index < count; index += 1) {
    const elementMarker = reader.readIntPacked();
    if (reader.isError || elementMarker !== 1) break;
    const parsed = readUserStructFields(reader);
    const statisticField = parsed.fields.get(15);
    const localizedField = parsed.fields.get(16);
    const statisticIndex = statisticField
      ? new BitReader(statisticField.payload, statisticField.bitCount)
          .readBitsToUnsignedInt(statisticField.bitCount)
      : null;
    const localizedStat = localizedField
      ? parseStringTableTextPayload(localizedField.payload, localizedField.bitCount)
      : null;
    effects.push({
      statisticIndex,
      statistic:
        (Number.isInteger(statisticIndex)
          ? ABILITY_STATISTIC_NAMES[statisticIndex]
          : null) ??
        localizedStat?.key ??
        null,
      localizedStatKey: localizedStat?.key ?? null,
      localizedStatTable: localizedStat?.tableId ?? null,
      value: floatFromStructField(parsed.fields.get(17)),
      timeSeconds: floatFromStructField(parsed.fields.get(18)),
      affectedTargets: parseAbilityAffectedTargets(parsed.fields.get(19)),
      sourceStruct: 'CharacterAbilityEffectInfo',
      evidence: 'replay-CharacterAbilityCastInfo-Effects',
    });
  }
  return effects;
}

function parseCharacterAbilityCastScalarFields(buffer, afterNull) {
  const result = {
    roundIndex: null,
    roundPhaseValue: null,
    roundPhase: null,
    castTimeSeconds: null,
  };
  let cursor = afterNull + 3;
  if (buffer[cursor] !== 0x0c) return result;
  const roundBits = readByteIntPacked(buffer, cursor + 1);
  if (!roundBits || roundBits.value !== 32 || roundBits.offset + 4 > buffer.length) {
    return result;
  }
  result.roundIndex = buffer.readInt32LE(roundBits.offset);
  cursor = roundBits.offset + 4;
  if (buffer[cursor] !== 0x0e) return result;
  const phaseBits = readByteIntPacked(buffer, cursor + 1);
  if (!phaseBits || phaseBits.value !== 8 || phaseBits.offset >= buffer.length) {
    return result;
  }
  result.roundPhaseValue = buffer[phaseBits.offset];
  result.roundPhase =
    ARES_GAME_PHASE_NAMES.get(result.roundPhaseValue) ??
    `Unknown(${result.roundPhaseValue})`;
  cursor = phaseBits.offset + 1;
  if (buffer[cursor] !== 0x10) return result;
  const castTimeBits = readByteIntPacked(buffer, cursor + 1);
  if (!castTimeBits || castTimeBits.value !== 32 || castTimeBits.offset + 4 > buffer.length) {
    return result;
  }
  const castTimeSeconds = buffer.readFloatLE(castTimeBits.offset);
  if (Number.isFinite(castTimeSeconds) && castTimeSeconds >= 0) {
    result.castTimeSeconds = Number(castTimeSeconds.toFixed(3));
  }
  return result;
}

function parseCharacterAbilityCastInfoTail(buffer, afterNull) {
  const layout = {};
  const evidenceRoles = [];
  let castLocation = null;
  let effectLocations = [];
  let destroyedCount = null;
  let effects = [];

  const castLocationHeaderOffset = afterNull + 18;
  if (buffer[castLocationHeaderOffset] === 0x12) {
    const vectorBits = readByteIntPacked(buffer, castLocationHeaderOffset + 1);
    if (vectorBits?.value === 192) {
      const vector = readAbilityVectorDouble64(buffer, vectorBits.offset);
      if (vector) {
        castLocation = vector;
        evidenceRoles.push('CharacterAbilityCastInfo-CastLocation-double64');
        layout.castLocation = {
          fieldOffset: castLocationHeaderOffset,
          vectorOffset: vectorBits.offset,
          vectorBits: vectorBits.value,
        };

        const parsedEffects = parseAbilityEffectLocations(buffer, vectorBits.offset + 24);
        if (parsedEffects.layout) {
          effectLocations = parsedEffects.locations;
          evidenceRoles.push('CharacterAbilityCastInfo-EffectLocations-double64-array');
          layout.effectLocations = parsedEffects.layout;

          const destroyedFieldOffset = parsedEffects.offset;
          if (buffer[destroyedFieldOffset] === 0x1a) {
            const destroyedBits = readByteIntPacked(buffer, destroyedFieldOffset + 1);
            if (
              destroyedBits?.value === 32 &&
              destroyedBits.offset + 4 <= buffer.length
            ) {
              destroyedCount = buffer.readInt32LE(destroyedBits.offset);
              evidenceRoles.push('CharacterAbilityCastInfo-DestroyedCount-int32');
              layout.destroyedCount = {
                fieldOffset: destroyedFieldOffset,
                valueOffset: destroyedBits.offset,
                valueBits: destroyedBits.value,
              };
              const nextFieldOffset = destroyedBits.offset + 4;
              if (buffer[nextFieldOffset] === 0x1c) {
                const effectsBits = readByteIntPacked(buffer, nextFieldOffset + 1);
                if (effectsBits && effectsBits.value > 0 && effectsBits.value % 8 === 0) {
                  layout.effects = {
                    fieldOffset: nextFieldOffset,
                    fieldBits: effectsBits.value,
                    payloadHex: buffer
                      .subarray(
                        effectsBits.offset,
                        Math.min(buffer.length, effectsBits.offset + effectsBits.value / 8),
                      )
                      .toString('hex'),
                    status: 'decoded-CharacterAbilityEffectInfo-array',
                  };
                  const effectsPayload = buffer.subarray(
                    effectsBits.offset,
                    Math.min(buffer.length, effectsBits.offset + Math.ceil(effectsBits.value / 8)),
                  );
                  effects = parseCharacterAbilityEffects(
                    effectsPayload,
                    effectsBits.value,
                  );
                  if (effects.length > 0) {
                    evidenceRoles.push(
                      'CharacterAbilityCastInfo-Effects-CharacterAbilityEffectInfo-array',
                    );
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  return {
    castLocation,
    effectLocations,
    destroyedCount,
    effects,
    layout,
    evidenceRoles,
  };
}

function playerAgentFromActorPath(actorPath) {
  const className = archetypeClassName(actorPath);
  const token = className.replace(/_PC$/i, '').toLowerCase();
  return VALORANT_AGENT_ARCHETYPE_TOKENS.get(token) ?? null;
}

function decodeAbilityCastEntriesFromSample(sample) {
  if (sample?.fieldName !== 'AbilityCastsThisRound') return [];
  const payloadHex = sample.payloadHex ?? '';
  if (!payloadHex || sample.payloadHexTruncated) return [];

  const buffer = Buffer.from(payloadHex, 'hex');
  const ascii = buffer.toString('latin1');
  const entries = [];
  ABILITY_CAST_UUID_PATTERN.lastIndex = 0;
  let match;
  while ((match = ABILITY_CAST_UUID_PATTERN.exec(ascii))) {
    const uuidStart = match.index;
    const uuidEnd = uuidStart + match[0].length;
    const nullTerminatorOffset = uuidEnd;
    if (buffer[nullTerminatorOffset] !== 0) continue;

    const afterNull = nullTerminatorOffset + 1;
    const slotEnumValue = buffer[afterNull + 2];
    if (!ARES_ITEM_SLOT_TO_ABILITY_SLOT.has(slotEnumValue)) continue;
    const scalarFields = parseCharacterAbilityCastScalarFields(buffer, afterNull);
    if (scalarFields.castTimeSeconds == null) continue;

    const agentEntry = playerAgentFromActorPath(sample.actorPath);
    const abilitySlot = abilitySlotFromAresItemSlot(slotEnumValue);
    const slotIdentity = abilityIdentityForSlot(agentEntry?.agent, abilitySlot, {
      className: sample.actorPath,
    });
    const abilityIndex = slotIdentity.abilityIndex;
    const abilityName = slotIdentity.abilityName;
    const decodedTail = parseCharacterAbilityCastInfoTail(buffer, afterNull);
    const evidenceRoles = [
      'rep-layout',
      'AbilityCastsThisRound',
      'CharacterAbilityCastInfo',
      'CharacterAbilityCastInfo-Round-int32',
      'CharacterAbilityCastInfo-RoundPhase-EAresGamePhase',
      'CharacterAbilityCastInfo-CastTime-float32',
      ...decodedTail.evidenceRoles,
    ];
    const confidence = decodedTail.effects.length > 0
      ? 'native-CharacterAbilityCastInfo-with-effects'
      : 'native-CharacterAbilityCastInfo';
    entries.push({
      id: null,
      timeMs: sample.timeMs,
      replicationTimeMs: sample.timeMs,
      playerSubject: match[0],
      playerNetGuid: sample.actorNetGuid ?? null,
      actorPath: sample.actorPath ?? null,
      agent: agentEntry?.agent ?? null,
      icarusAgentType: agentEntry?.icarusAgentType ?? null,
      abilitySlot,
      abilityIndex,
      abilityName,
      sourceAbilityClass: slotIdentity.sourceAbilityAsset ?? null,
      sourceAbilityAssetPath: slotIdentity.sourceAbilityAsset ?? null,
      abilityIdentitySource: slotIdentity.identitySource ?? null,
      slotEnum: 'EAresItemSlot',
      slotEnumValue,
      castTimeSeconds: scalarFields.castTimeSeconds,
      roundIndex: scalarFields.roundIndex,
      roundPhaseValue: scalarFields.roundPhaseValue,
      roundPhase: scalarFields.roundPhase,
      timeSource: 'AbilityCastsThisRound-replication-observation',
      castLocation: decodedTail.castLocation,
      effectLocations: decodedTail.effectLocations,
      destroyedCount: decodedTail.destroyedCount,
      effects: decodedTail.effects,
      confidence,
      evidenceRoles,
      raw: {
        payloadOffset: uuidStart,
        payloadHex: payloadHex.slice(0, ABILITY_CAST_PAYLOAD_HEX_LIMIT),
        fieldName: sample.fieldName,
        actorGroup: sample.actorGroup ?? null,
        repObject: sample.repObject ?? null,
        repObjectPath: sample.repObjectPath ?? null,
        numBits: sample.numBits ?? null,
        characterAbilityCastInfoLayout: decodedTail.layout,
        characterAbilityCastInfoScalarFields: scalarFields,
      },
    });
  }
  return entries;
}

function replayRoundIndexAt(roundStartEvents, timeMs) {
  let roundIndex = null;
  for (let index = 0; index < (roundStartEvents?.length ?? 0); index += 1) {
    const event = roundStartEvents[index];
    if (event.timeMs > timeMs) break;
    roundIndex = Number.isInteger(event.roundIndex) ? event.roundIndex : index;
  }
  return roundIndex;
}

function abilityCastsFromAbilitySignalSamples(
  samples,
  placementSamples = samples,
  roundStartEvents = [],
) {
  const casts = [];
  const seen = new Map();
  for (const sample of samples ?? []) {
    for (const decodedEntry of decodeAbilityCastEntriesFromSample(sample)) {
      const entry = {
        ...decodedEntry,
        roundIndex:
          decodedEntry.roundIndex ??
          replayRoundIndexAt(roundStartEvents, decodedEntry.timeMs),
      };
      const key = [
        entry.playerSubject,
        entry.roundIndex,
        entry.abilitySlot,
        entry.slotEnumValue,
        entry.castTimeSeconds,
        entry.actorPath,
      ].join('|');
      const existing = seen.get(key);
      if (existing && existing.replicationTimeMs <= entry.replicationTimeMs) continue;
      const id = `cast-${casts.length}`;
      const cast = { ...entry, id };
      if (existing) {
        const index = casts.indexOf(existing);
        if (index !== -1) casts[index] = cast;
      } else {
        casts.push(cast);
      }
      seen.set(key, cast);
    }
  }
  casts.sort((a, b) => a.timeMs - b.timeMs || a.id.localeCompare(b.id));
  const sortedCasts = casts.map((cast, index) => ({ ...cast, id: `cast-${index}` }));
  return attachPlacementSignalsToAbilityCasts(
    sortedCasts,
    placementSignalsFromAbilitySignalSamples(placementSamples),
  );
}

function summarizeAbilitySignalSamples(samples, limit = 32) {
  const countsBySource = new Map();
  const countsByActorGroup = new Map();
  const countsByRepObjectPath = new Map();
  const countsByField = new Map();
  for (const sample of samples ?? []) {
    incrementCountMap(countsBySource, sample.source ?? 'unknown');
    incrementCountMap(countsByActorGroup, sample.actorGroup ?? 'unknown');
    incrementCountMap(countsByRepObjectPath, sample.repObjectPath ?? 'unknown');
    incrementCountMap(countsByField, sample.fieldName ?? sample.functionName ?? 'unknown');
  }
  return {
    count: samples?.length ?? 0,
    bySource: topCounts(countsBySource, 8),
    byActorGroup: topCounts(countsByActorGroup, limit),
    byRepObjectPath: topCounts(countsByRepObjectPath, limit),
    byField: topCounts(countsByField, limit),
  };
}

function isReplayControllerClassNetCache(pathName) {
  return /BaseReplayController.*_ClassNetCache/i.test(pathName ?? '');
}

function isPlayerCharacterArchetype(pathName) {
  return /Default__[^/]+_PC_C$/i.test(pathName ?? '') && !/Ability|PostDeath/i.test(pathName ?? '');
}

function knownPlayerActorNetGuids(packetContext) {
  return new Set(
    packetContext.channels
      .filter((channel) => channel?.actor?.actorNetGuid?.value)
      .filter((channel) =>
        isPlayerCharacterArchetype(
          getPathForNetGuid(packetContext.frameContext, channel.actor.archetype?.value ?? 0),
        ),
      )
      .map((channel) => channel.actor.actorNetGuid.value),
  );
}

function scanKnownNetGuidCandidates(payload, bitCount, knownGuids, maxHits = 12) {
  if (!knownGuids.size) return [];
  const hits = [];
  const maxOffset = Math.min(128, bitCount);
  for (let bitOffset = 0; bitOffset < maxOffset && hits.length < maxHits; bitOffset += 1) {
    const packedReader = new BitReader(payload, bitCount, bitOffset);
    const packed = packedReader.readIntPacked();
    if (!packedReader.isError && knownGuids.has(packed)) {
      hits.push({ encoding: 'intPacked', bitOffset, value: packed });
    }

    if (bitCount - bitOffset >= 32) {
      const uintReader = new BitReader(payload, bitCount, bitOffset);
      const value = uintReader.readBitsToUnsignedInt(32);
      if (!uintReader.isError && knownGuids.has(value)) {
        hits.push({ encoding: 'uint32', bitOffset, value });
      }
    }
  }
  return hits;
}

function updateClassNetCacheFieldStats(statsMap, sample, payloadHex) {
  const key = [
    sample.classNetCache,
    sample.fieldHandle,
    sample.fieldName ?? '',
  ].join('|');
  let stat = statsMap.get(key);
  if (!stat) {
    stat = {
      classNetCache: sample.classNetCache,
      fieldHandle: sample.fieldHandle,
      fieldName: sample.fieldName ?? null,
      count: 0,
      firstTimeMs: sample.timeMs,
      lastTimeMs: sample.timeMs,
      payloadBitCounts: new Map(),
      payloadHexCounts: new Map(),
      samples: [],
    };
    statsMap.set(key, stat);
  }
  stat.count += 1;
  stat.firstTimeMs = Math.min(stat.firstTimeMs, sample.timeMs);
  stat.lastTimeMs = Math.max(stat.lastTimeMs, sample.timeMs);
  bumpNestedCount(stat, 'payloadBitCounts', sample.numPayloadBits);
  if (
    !sample.isTargetFunction ||
    stat.payloadHexCounts.has(payloadHex) ||
    stat.payloadHexCounts.size < 32
  ) {
    bumpNestedCount(stat, 'payloadHexCounts', payloadHex);
  }
  const sampleLimit =
    sample.fieldName === 'ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous' ? 64 : 8;
  if (stat.samples.length < sampleLimit) {
    const payloadHexLimit =
      sample.fieldName === 'ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous'
        ? 4096
        : 128;
    stat.samples.push({
      timeMs: sample.timeMs,
      chIndex: sample.chIndex,
      actorNetGuid: sample.actorNetGuid,
      numPayloadBits: sample.numPayloadBits,
      payloadHex: payloadHex.slice(0, payloadHexLimit),
    });
  }
}

function noteReplayControllerVectorLane(packetContext, sample, vector) {
  const laneKey = [
    sample.fieldHandle,
    vector.bitOffset,
    vector.scaleFactor ?? 10,
    vector.componentBits,
    vector.extraInfo,
  ].join('|');
  let lane = packetContext.replayControllerVectorLaneStats.get(laneKey);
  if (!lane) {
    lane = {
      fieldHandle: sample.fieldHandle,
      fieldName: sample.fieldName ?? null,
      vectorBitOffset: vector.bitOffset,
      scaleFactor: vector.scaleFactor ?? 10,
      componentBits: vector.componentBits,
      extraInfo: vector.extraInfo,
      count: 0,
      uniquePositions: new Set(),
      firstTimeMs: sample.timeMs,
      lastTimeMs: sample.timeMs,
      minX: Infinity,
      maxX: -Infinity,
      minY: Infinity,
      maxY: -Infinity,
      minZ: Infinity,
      maxZ: -Infinity,
      totalStepDistance: 0,
      maxStepDistance: 0,
      totalSpeed: 0,
      maxSpeed: 0,
      stepCount: 0,
      samplePayloadHexes: new Map(),
      samples: [],
      lastSample: null,
    };
    packetContext.replayControllerVectorLaneStats.set(laneKey, lane);
  }

  const x = Number(vector.x.toFixed(2));
  const y = Number(vector.y.toFixed(2));
  const z = Number(vector.z.toFixed(2));
  lane.count += 1;
  lane.uniquePositions.add(`${Math.round(x * 10)}:${Math.round(y * 10)}:${Math.round(z * 10)}`);
  lane.firstTimeMs = Math.min(lane.firstTimeMs, sample.timeMs);
  lane.lastTimeMs = Math.max(lane.lastTimeMs, sample.timeMs);
  lane.minX = Math.min(lane.minX, x);
  lane.maxX = Math.max(lane.maxX, x);
  lane.minY = Math.min(lane.minY, y);
  lane.maxY = Math.max(lane.maxY, y);
  lane.minZ = Math.min(lane.minZ, z);
  lane.maxZ = Math.max(lane.maxZ, z);
  incrementCountMap(lane.samplePayloadHexes, sample.payloadHex.slice(0, 64));

  if (lane.lastSample && sample.timeMs >= lane.lastSample.timeMs) {
    const dtMs = sample.timeMs - lane.lastSample.timeMs;
    const distance = Math.hypot(x - lane.lastSample.x, y - lane.lastSample.y);
    lane.totalStepDistance += distance;
    lane.maxStepDistance = Math.max(lane.maxStepDistance, distance);
    if (dtMs > 0) {
      const speed = distance / (dtMs / 1000);
      lane.totalSpeed += speed;
      lane.maxSpeed = Math.max(lane.maxSpeed, speed);
      lane.stepCount += 1;
    }
  }
  lane.lastSample = { timeMs: sample.timeMs, x, y, z };

  if (lane.samples.length < 16) {
    lane.samples.push({
      timeMs: sample.timeMs,
      x,
      y,
      z,
      mapPercent: vector.mapPercent
        ? {
            u: Number(vector.mapPercent.u.toFixed(4)),
            v: Number(vector.mapPercent.v.toFixed(4)),
          }
        : null,
      payloadBits: sample.numPayloadBits,
      payloadHex: sample.payloadHex.slice(0, 96),
    });
  }
}

function noteReplayControllerTargetPayload(packetContext, sample, payload, bitCount) {
  const fullRecordCount = Math.floor(bitCount / 80);
  const trailingBits = bitCount % 80;
  const payloadKey = [sample.numPayloadBits, fullRecordCount, trailingBits].join('|');
  let payloadStat = packetContext.replayControllerTargetPayloadStats.get(payloadKey);
  if (!payloadStat) {
    payloadStat = {
      numPayloadBits: sample.numPayloadBits,
      fullRecordCount,
      trailingBits,
      count: 0,
      firstTimeMs: sample.timeMs,
      lastTimeMs: sample.timeMs,
      samples: [],
    };
    packetContext.replayControllerTargetPayloadStats.set(payloadKey, payloadStat);
  }
  payloadStat.count += 1;
  payloadStat.firstTimeMs = Math.min(payloadStat.firstTimeMs, sample.timeMs);
  payloadStat.lastTimeMs = Math.max(payloadStat.lastTimeMs, sample.timeMs);
  if (payloadStat.samples.length < 64) {
    payloadStat.samples.push({
      timeMs: sample.timeMs,
      bitCount,
      payloadHex: payload.toString('hex').slice(0, Math.ceil(bitCount / 4)),
    });
  }

  for (let recordIndex = 0; recordIndex < fullRecordCount; recordIndex += 1) {
    const start = recordIndex * 10;
    const record = payload.subarray(start, start + 10);
    const prefix3 = record.subarray(0, 3).toString('hex');
    const firstPackedByteValue = record[0] >> 1;
    let recordStat = packetContext.replayControllerTargetNativeRecordStats.get(prefix3);
    if (!recordStat) {
      recordStat = {
        prefix3,
        firstPackedByteValue,
        count: 0,
        firstTimeMs: sample.timeMs,
        lastTimeMs: sample.timeMs,
        payloadBitCounts: new Map(),
        recordIndexCounts: new Map(),
        byteValueCounts: Array.from({ length: 10 }, () => new Map()),
        samples: [],
      };
      packetContext.replayControllerTargetNativeRecordStats.set(prefix3, recordStat);
    }
    recordStat.count += 1;
    recordStat.firstTimeMs = Math.min(recordStat.firstTimeMs, sample.timeMs);
    recordStat.lastTimeMs = Math.max(recordStat.lastTimeMs, sample.timeMs);
    incrementCountMap(recordStat.payloadBitCounts, sample.numPayloadBits);
    incrementCountMap(recordStat.recordIndexCounts, recordIndex);
    for (let byteIndex = 0; byteIndex < record.length; byteIndex += 1) {
      incrementCountMap(recordStat.byteValueCounts[byteIndex], record[byteIndex]);
    }
    if (recordStat.samples.length < 16) {
      recordStat.samples.push({
        timeMs: sample.timeMs,
        recordIndex,
        hex: record.toString('hex'),
      });
    }
    if (packetContext.replayControllerTargetNativeRecordSamples.length < 500) {
      packetContext.replayControllerTargetNativeRecordSamples.push({
        timeMs: sample.timeMs,
        parentPayloadBits: sample.numPayloadBits,
        parentFullRecordCount: fullRecordCount,
        parentTrailingBits: trailingBits,
        recordIndex,
        recordBitOffset: recordIndex * 80,
        prefix3,
        firstPackedByteValue,
        hex: record.toString('hex'),
      });
    }
  }
}

function noteClassNetCachePayload(packetContext, sample, payload, bitCount) {
  const statsPayloadHex = sample.isTargetFunction
    ? payload.subarray(0, 64).toString('hex')
    : payload.toString('hex');
  updateClassNetCacheFieldStats(packetContext.classNetCacheFieldStats, sample, statsPayloadHex);

  if (!isReplayControllerClassNetCache(sample.classNetCache)) return;
  const isDeepCandidateField =
    REPLAY_CONTROLLER_CANDIDATE_FIELD_HANDLES.has(sample.fieldHandle) || sample.isTargetFunction;
  const shouldCaptureCandidateField =
    isDeepCandidateField ||
    bitCount <= REPLAY_CONTROLLER_CANDIDATE_FIELD_GENERIC_PAYLOAD_BIT_LIMIT;
  const perHandleCandidateLimit = isDeepCandidateField
    ? REPLAY_CONTROLLER_CANDIDATE_FIELD_PER_HANDLE_SAMPLE_LIMIT
    : REPLAY_CONTROLLER_CANDIDATE_FIELD_GENERIC_PER_HANDLE_SAMPLE_LIMIT;
  const capturedForHandle =
    packetContext.replayControllerCandidateFieldSampleCounts.get(sample.fieldHandle) ?? 0;
  const lastCapturedTimeMs =
    packetContext.replayControllerCandidateFieldLastCapturedTimeMs.get(sample.fieldHandle);
  const passesTargetCadence =
    !sample.isTargetFunction ||
    lastCapturedTimeMs == null ||
    sample.timeMs - lastCapturedTimeMs >= REPLAY_CONTROLLER_TARGET_FIELD_MIN_CAPTURE_INTERVAL_MS;
  const shouldCaptureThisCandidate =
    shouldCaptureCandidateField &&
    passesTargetCadence &&
    capturedForHandle < perHandleCandidateLimit &&
    packetContext.replayControllerCandidateFieldSamples.length <
      REPLAY_CONTROLLER_CANDIDATE_FIELD_TOTAL_SAMPLE_LIMIT;
  if (
    shouldCaptureThisCandidate
  ) {
    const payloadHex = payload.toString('hex');
    packetContext.replayControllerCandidateFieldSampleCounts.set(
      sample.fieldHandle,
      capturedForHandle + 1,
    );
    packetContext.replayControllerCandidateFieldLastCapturedTimeMs.set(
      sample.fieldHandle,
      sample.timeMs,
    );
    packetContext.replayControllerCandidateFieldSamples.push({
      timeMs: sample.timeMs,
      chIndex: sample.chIndex,
      actorNetGuid: sample.actorNetGuid,
      classNetCache: sample.classNetCache,
      fieldHandle: sample.fieldHandle,
      fieldName: sample.fieldName ?? null,
      numPayloadBits: sample.numPayloadBits,
      captureMode: isDeepCandidateField ? 'selected' : 'small-payload',
      payloadHex: payloadHex.slice(
        0,
        Math.ceil(Math.min(bitCount, REPLAY_CONTROLLER_CANDIDATE_FIELD_PAYLOAD_BIT_LIMIT) / 8) *
          2,
      ),
      payloadHexTruncated: bitCount > REPLAY_CONTROLLER_CANDIDATE_FIELD_PAYLOAD_BIT_LIMIT,
    });
  }
  updateClassNetCacheFieldStats(
    packetContext.replayControllerClassNetCacheFieldStats,
    sample,
    statsPayloadHex,
  );
  if (sample.isTargetFunction && shouldCaptureThisCandidate) {
    noteReplayControllerTargetPayload(packetContext, sample, payload, bitCount);
  }
  const replayControllerSample = {
    ...sample,
    payloadHex: statsPayloadHex.slice(0, 512),
  };
  if (packetContext.replayControllerClassNetCacheSamples.length < 240) {
    packetContext.replayControllerClassNetCacheSamples.push(replayControllerSample);
  }

  if (sample.isTargetFunction && !shouldCaptureThisCandidate) {
    return;
  }

  const knownGuids = knownPlayerActorNetGuids(packetContext);
  const guidHits = scanKnownNetGuidCandidates(payload, bitCount, knownGuids);
  if (guidHits.length && packetContext.replayControllerKnownGuidHits.length < 80) {
    packetContext.replayControllerKnownGuidHits.push({
      timeMs: sample.timeMs,
      chIndex: sample.chIndex,
      actorNetGuid: sample.actorNetGuid,
      fieldHandle: sample.fieldHandle,
      fieldName: sample.fieldName ?? null,
      numPayloadBits: sample.numPayloadBits,
      hits: guidHits,
      payloadHex: statsPayloadHex.slice(0, 160),
    });
  }

  const vectors = decodePackedVectorCandidates(
    payload,
    bitCount,
    packetContext.frameContext.header.mapPath,
    24,
  );
  for (const vector of vectors) {
    noteReplayControllerVectorLane(packetContext, replayControllerSample, vector);
  }
}

function finalizeClassNetCacheFieldStats(statsMap, limit = 120) {
  return [...statsMap.values()]
    .map((stat) => ({
      classNetCache: stat.classNetCache,
      fieldHandle: stat.fieldHandle,
      fieldName: stat.fieldName,
      count: stat.count,
      firstTimeMs: stat.firstTimeMs,
      lastTimeMs: stat.lastTimeMs,
      payloadBitCounts: topCounts(stat.payloadBitCounts, 12),
      uniquePayloadCount: stat.payloadHexCounts.size,
      topPayloadHexes: topCounts(stat.payloadHexCounts, 8),
      samples: stat.samples,
    }))
    .sort((a, b) => b.count - a.count || a.fieldHandle - b.fieldHandle)
    .slice(0, limit);
}

function finalizeReplayControllerVectorLanes(packetContext, limit = 80, predicate = null) {
  return [...packetContext.replayControllerVectorLaneStats.values()]
    .filter((lane) => (predicate ? predicate(lane) : true))
    .map((lane) => ({
      fieldHandle: lane.fieldHandle,
      fieldName: lane.fieldName,
      vectorBitOffset: lane.vectorBitOffset,
      scaleFactor: lane.scaleFactor,
      componentBits: lane.componentBits,
      extraInfo: lane.extraInfo,
      count: lane.count,
      uniquePositionCount: lane.uniquePositions.size,
      firstTimeMs: lane.firstTimeMs,
      lastTimeMs: lane.lastTimeMs,
      spanMs: lane.lastTimeMs - lane.firstTimeMs,
      bounds: {
        minX: Number(lane.minX.toFixed(2)),
        maxX: Number(lane.maxX.toFixed(2)),
        minY: Number(lane.minY.toFixed(2)),
        maxY: Number(lane.maxY.toFixed(2)),
        minZ: Number(lane.minZ.toFixed(2)),
        maxZ: Number(lane.maxZ.toFixed(2)),
      },
      meanStepDistance:
        lane.count > 1 ? Number((lane.totalStepDistance / (lane.count - 1)).toFixed(2)) : null,
      maxStepDistance: Number(lane.maxStepDistance.toFixed(2)),
      meanSpeed:
        lane.stepCount > 0 ? Number((lane.totalSpeed / lane.stepCount).toFixed(2)) : null,
      maxSpeed: lane.stepCount > 0 ? Number(lane.maxSpeed.toFixed(2)) : null,
      topPayloadHexes: topCounts(lane.samplePayloadHexes, 6),
      samples: lane.samples,
    }))
    .sort((a, b) => {
      if (b.count !== a.count) return b.count - a.count;
      if (a.meanStepDistance == null) return 1;
      if (b.meanStepDistance == null) return -1;
      return a.meanStepDistance - b.meanStepDistance;
    })
    .slice(0, limit);
}

function isTargetReplayControllerLane(lane) {
  return (
    lane.fieldHandle === 3 ||
    lane.fieldName?.includes('ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous')
  );
}

function finalizeReplayControllerTargetPayloads(packetContext, limit = 80) {
  return [...packetContext.replayControllerTargetPayloadStats.values()]
    .map((stat) => ({
      numPayloadBits: stat.numPayloadBits,
      fullRecordCount: stat.fullRecordCount,
      trailingBits: stat.trailingBits,
      count: stat.count,
      firstTimeMs: stat.firstTimeMs,
      lastTimeMs: stat.lastTimeMs,
      samples: stat.samples,
    }))
    .sort((a, b) => b.count - a.count || a.numPayloadBits - b.numPayloadBits)
    .slice(0, limit);
}

function finalizeReplayControllerTargetNativeRecords(packetContext, limit = 120) {
  return [...packetContext.replayControllerTargetNativeRecordStats.values()]
    .map((stat) => ({
      prefix3: stat.prefix3,
      firstPackedByteValue: stat.firstPackedByteValue,
      count: stat.count,
      firstTimeMs: stat.firstTimeMs,
      lastTimeMs: stat.lastTimeMs,
      payloadBitCounts: topCounts(stat.payloadBitCounts, 8),
      recordIndexCounts: topCounts(stat.recordIndexCounts, 12),
      byteValueCounts: stat.byteValueCounts.map((counts, byteIndex) => ({
        byteIndex,
        uniqueValueCount: counts.size,
        topValues: topCounts(counts, 12).map((entry) => ({
          hex: Number(entry.key).toString(16).padStart(2, '0'),
          count: entry.count,
        })),
      })),
      samples: stat.samples,
    }))
    .sort((a, b) => b.count - a.count || a.prefix3.localeCompare(b.prefix3))
    .slice(0, limit);
}

function decodeValorantReplicatorPayload(payloadReader, actorNetGuid, branch = null) {
  const payloadBits = payloadReader.bitsLeft;
  if (payloadBits <= 0) {
    return {
      reader: payloadReader,
      transformed: false,
      payloadBits,
      seed: null,
      leadingBit: null,
      rawPayload: Buffer.from([]),
      transformedPayload: Buffer.from([]),
      rawPayloadHex: '',
      transformedPayloadHex: '',
    };
  }

  const rawPayload = payloadReader.readBits(payloadBits);
  const seed = (payloadBits ^ (actorNetGuid ?? 0)) >>> 0;
  const transformedPayload = applyValorantSeededPayloadTransform(rawPayload, payloadBits, seed, branch);
  const reader = new BitReader(transformedPayload, payloadBits);
  const leadingBit = new BitReader(transformedPayload, payloadBits).readBit();
  return {
    reader,
    transformed: true,
    payloadBits,
    seed,
    branch,
    leadingBit,
    rawPayload,
    transformedPayload,
    rawPayloadHex: rawPayload.subarray(0, 64).toString('hex'),
    transformedPayloadHex: transformedPayload.subarray(0, 64).toString('hex'),
  };
}

function summarizePropertyFields(fields) {
  return fields.slice(0, 10).map((field) => ({
    handle: field.handle,
    rawHandle: field.rawHandle,
    numBits: field.numBits,
    bad: Boolean(field.bad),
    terminator: Boolean(field.terminator),
    payloadHex: field.payload?.subarray(0, 24).toString('hex') ?? null,
  }));
}

function probeValorantSeedVariants(rawPayload, payloadBits, actorNetGuid, repObject, branch = null) {
  const seedValues = [
    { label: 'none', seed: null, payload: rawPayload },
    { label: 'payloadBits', seed: payloadBits },
    actorNetGuid == null ? null : { label: 'payloadBits^actorNetGuid', seed: payloadBits ^ actorNetGuid },
    repObject == null ? null : { label: 'payloadBits^repObject', seed: payloadBits ^ repObject },
    actorNetGuid == null ? null : { label: 'actorNetGuid', seed: actorNetGuid },
    repObject == null ? null : { label: 'repObject', seed: repObject },
    { label: 'zero', seed: 0 },
  ].filter(Boolean);
  const seen = new Set();
  const baseReplayHandles = new Set([3, 12, 14, 18]);
  return seedValues
    .filter((entry) => {
      const key = `${entry.label}:${entry.seed ?? 'raw'}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .map((entry) => {
      const payload =
        entry.seed == null
          ? entry.payload
          : applyValorantSeededPayloadTransform(rawPayload, payloadBits, entry.seed >>> 0, branch);
      const leadingBit = new BitReader(payload, payloadBits).readBit();
      const fieldsWithLeading = parseReplayPropertyFieldsAt(payload, payloadBits, 0, true);
      const fieldsWithoutLeading = parseReplayPropertyFieldsAt(payload, payloadBits, 0, false);
      const scoredFields = fieldsWithLeading.filter((field) => field.handle != null && !field.bad);
      const validBaseReplayHandleCount = scoredFields.filter((field) =>
        baseReplayHandles.has(field.handle),
      ).length;
      const lowHandleCount = scoredFields.filter(
        (field) => field.handle >= 0 && field.handle < 256,
      ).length;
      return {
        label: entry.label,
        seed: entry.seed,
        branch,
        leadingBit,
        validBaseReplayHandleCount,
        lowHandleCount,
        fieldsWithLeading: summarizePropertyFields(fieldsWithLeading),
        fieldsWithoutLeading: summarizePropertyFields(fieldsWithoutLeading),
        firstBytes: payload.subarray(0, 96).toString('hex'),
      };
    })
    .sort((a, b) => {
      if (b.validBaseReplayHandleCount !== a.validBaseReplayHandleCount) {
        return b.validBaseReplayHandleCount - a.validBaseReplayHandleCount;
      }
      return b.lowHandleCount - a.lowHandleCount;
    });
}

function readConditionalQuantizedVector(reader, defaultVector) {
  if (!reader.readBit()) return defaultVector;
  const shouldQuantize = reader.readBit();
  return shouldQuantize
    ? reader.readPackedVector(10)
    : { x: reader.readDouble64(), y: reader.readDouble64(), z: reader.readDouble64() };
}

function receiveNetGuidBunch(reader, packetContext) {
  const hasRepLayoutExport = reader.readBit();
  if (hasRepLayoutExport) {
    const count = reader.readUInt32();
    if (count < 0 || count > 20_000) {
      reader.isError = true;
      return;
    }
    for (let i = 0; i < count; i += 1) {
      const pathNameIndex = reader.readIntPacked();
      let group = packetContext.frameContext.exportGroupsByIndex.get(pathNameIndex);
      if (reader.readBit()) {
        const pathName = reader.readString();
        const numExports = reader.readUInt32();
        group = {
          pathName,
          pathNameIndex,
          netFieldExportsLength: numExports,
          netFieldExports: [],
        };
        packetContext.frameContext.exportGroupsByPath.set(pathName, group);
        packetContext.frameContext.exportGroupsByIndex.set(pathNameIndex, group);
      }
      const netField = readNetFieldExport(reader, packetContext.frameContext);
      if (netField && group) group.netFieldExports[netField.handle] = netField;
    }
    return;
  }
  const count = reader.readInt32();
  if (count < 0 || count > 2048) return;
  for (let i = 0; i < count; i += 1) {
    readInternalLoadObject(reader, true, packetContext.frameContext);
  }
}

function parseRpcProperties(reader, targetGroup, { skipLeadingBit = true } = {}) {
  const fields = [];
  if (skipLeadingBit) reader.skipBits(1);
  while (!reader.atEnd() && !reader.isError) {
    let handle = reader.readIntPacked();
    if (handle === 0) break;
    handle -= 1;
    const numBits = reader.readIntPacked();
    if (numBits < 0 || numBits > reader.bitsLeft) {
      reader.isError = true;
      break;
    }
    const fieldReader = reader.fork(numBits);
    const field = targetGroup.netFieldExports[handle];
    fields.push({
      handle,
      name: field?.name ?? `handle_${handle}`,
      numBits,
      payloadHex: fieldReader.readBits(numBits).toString('hex'),
    });
  }
  return fields;
}

function readContentBlockHeader(bunch, packetContext) {
  const reader = bunch.archive;
  const bOutHasRepLayout = reader.readBit();
  const bIsActor = reader.readBit();
  const actor = packetContext.channels[bunch.chIndex]?.actor;
  if (bIsActor) {
    return {
      bObjectDeleted: false,
      bOutHasRepLayout,
      repObject: actor?.archetype?.value ?? actor?.actorNetGuid?.value ?? 0,
      bIsActor,
    };
  }

  const netGuid = readInternalLoadObject(reader, false, packetContext.frameContext);
  const bStablyNamed = reader.readBit();
  if (bStablyNamed) {
    return {
      bObjectDeleted: false,
      bOutHasRepLayout,
      repObject: netGuid,
      bIsActor,
    };
  }

  let bDeleteSubObject = false;
  let bSerializeClass = true;
  if (packetContext.frameContext.header.engineNetworkVersion >= 30) {
    const isDestroyMessage = reader.readBit();
    if (isDestroyMessage) {
      bDeleteSubObject = true;
      bSerializeClass = false;
      reader.skipBits(8);
    }
  }

  let classNetGuid = 0;
  if (bSerializeClass) {
    classNetGuid = readInternalLoadObject(reader, false, packetContext.frameContext);
    bDeleteSubObject = !isValidNetGuid(classNetGuid);
  }

  if (bDeleteSubObject) {
    return {
      bObjectDeleted: true,
      bOutHasRepLayout,
      repObject: netGuid,
      bIsActor,
    };
  }

  if (packetContext.frameContext.header.engineNetworkVersion >= 18) {
    const bActorIsOuter = reader.atEnd() || reader.readBit();
    if (!bActorIsOuter) readInternalLoadObject(reader, false, packetContext.frameContext);
  }

  return {
    bObjectDeleted: false,
    bOutHasRepLayout,
    repObject: classNetGuid,
    bIsActor,
  };
}

function processReplicatorPayload(bunch, payloadReader, repObject, bHasRepLayout, packetContext) {
  const frameContext = packetContext.frameContext;
  const actor = packetContext.channels[bunch.chIndex]?.actor;
  const actorGroup = findExportGroupForNetGuid(frameContext, repObject);
  const classNetCache = findClassNetCacheForGroup(frameContext, actorGroup);
  const targetRpcGroup = findTargetRpcGroup(frameContext);
  const inputEventCaptureRpcGroup = findRpcGroupByPath(
    frameContext,
    /ClientReplayReceiveInputEventProcessingCapture/i,
  );
  if (!actorGroup) return;

  const decodedPayload = decodeValorantReplicatorPayload(
    payloadReader,
    actor?.actorNetGuid?.value ?? null,
    frameContext.header.branch,
  );
  payloadReader = decodedPayload.reader;
  if (
    packetContext.valorantPayloadTransformSamples.length < 80 &&
    (bunch.chIndex === 2 || /Replay|Character|Player/i.test(actorGroup?.pathName ?? ''))
  ) {
    packetContext.valorantPayloadTransformSamples.push({
      timeMs: bunch.timeMs,
      chIndex: bunch.chIndex,
      actorNetGuid: actor?.actorNetGuid?.value ?? null,
      actorPath: getPathForNetGuid(frameContext, actor?.archetype?.value ?? 0),
      actorGroup: actorGroup?.pathName ?? null,
      repObject,
      repObjectPath: getPathForNetGuid(frameContext, repObject),
      payloadBits: decodedPayload.payloadBits,
      seed: decodedPayload.seed,
      branch: decodedPayload.branch,
      leadingBit: decodedPayload.leadingBit,
      rawPayloadHex: decodedPayload.rawPayloadHex,
      transformedPayloadHex: decodedPayload.transformedPayloadHex,
    });
  }

  if (
    packetContext.replayControllerPayloadSamples.length < 80 &&
    /BaseReplayController/i.test(actorGroup?.pathName ?? getPathForNetGuid(frameContext, repObject))
  ) {
    packetContext.replayControllerPayloadSamples.push({
      timeMs: bunch.timeMs,
      chIndex: bunch.chIndex,
      actorNetGuid: actor?.actorNetGuid?.value ?? null,
      actorPath: getPathForNetGuid(frameContext, actor?.archetype?.value ?? 0),
      actorGroup: actorGroup?.pathName ?? null,
      repObject,
      repObjectPath: getPathForNetGuid(frameContext, repObject),
      bHasRepLayout,
      payloadBits: decodedPayload.payloadBits,
      seed: decodedPayload.seed,
      branch: decodedPayload.branch,
      leadingBit: decodedPayload.leadingBit,
      rawPayloadHex: decodedPayload.rawPayload.toString('hex'),
      transformedPayloadHex: decodedPayload.transformedPayload.toString('hex'),
      seedProbes: probeValorantSeedVariants(
        decodedPayload.rawPayload,
        decodedPayload.payloadBits,
        actor?.actorNetGuid?.value ?? null,
        repObject,
        frameContext.header.branch,
      ),
    });
  }

  if (bHasRepLayout) {
    payloadReader.skipBits(1);
    while (!payloadReader.atEnd() && !payloadReader.isError) {
      const rawHandle = payloadReader.readIntPacked();
      if (rawHandle === 0) break;
      const handle = rawHandle - 1;
      const numBits = payloadReader.readIntPacked();
      if (numBits < 0 || numBits > payloadReader.bitsLeft) {
        payloadReader.isError = true;
        break;
      }
      const field = actorGroup?.netFieldExports?.[handle] ?? null;
      const payloadStart = payloadReader.offset;
      const payloadHex = peekBitsHex(
        payloadReader,
        Math.min(
          numBits,
          isAbilityCastsThisRoundField(field?.name)
            ? ABILITY_CAST_SIGNAL_PAYLOAD_HEX_LIMIT * 4
            : ABILITY_SIGNAL_PAYLOAD_HEX_LIMIT * 4,
        ),
      );
      const payloadHexTruncated = payloadHex.length * 4 < numBits;
      const linkFieldName = field?.name ?? '';
      if (
        packetContext.identityLinkSamples.length < 2000 &&
        /^(Owner|PlayerState|Controller|SubjectUniqueId)$/.test(linkFieldName)
      ) {
        const fieldReader = payloadReader.fork(numBits);
        let decodedNetGuid = null;
        if (/^(Owner|PlayerState|Controller)$/.test(linkFieldName)) {
          decodedNetGuid = readInternalLoadObject(fieldReader, false, frameContext);
          if (fieldReader.isError) decodedNetGuid = null;
        }
        packetContext.identityLinkSamples.push({
          timeMs: bunch.timeMs,
          chIndex: bunch.chIndex,
          actorNetGuid: actor?.actorNetGuid?.value ?? null,
          actorPath: getPathForNetGuid(frameContext, actor?.archetype?.value ?? 0),
          actorGroup: actorGroup?.pathName ?? null,
          repObject,
          repObjectPath: getPathForNetGuid(frameContext, repObject),
          handle,
          rawHandle,
          decodedHandle: handle,
          fieldName: linkFieldName,
          numBits,
          payloadHex,
          decodedNetGuid,
          decodedNetGuidPath: decodedNetGuid == null ? null : getPathForNetGuid(frameContext, decodedNetGuid),
        });
        payloadReader.offset = payloadStart;
      }
      if (
        packetContext.repLayoutSamples.length < 160 &&
        (bunch.chIndex === 2 || /Replay|Character|Player/i.test(actorGroup?.pathName ?? ''))
      ) {
        packetContext.repLayoutSamples.push({
          timeMs: bunch.timeMs,
          chIndex: bunch.chIndex,
          actorNetGuid: actor?.actorNetGuid?.value ?? null,
          actorPath: getPathForNetGuid(frameContext, actor?.archetype?.value ?? 0),
          actorGroup: actorGroup?.pathName ?? null,
          handle,
          rawHandle,
          decodedHandle: handle,
          fieldName: field?.name ?? null,
          numBits,
          payloadHex,
        });
      }
      noteDiagnosticActorWireSample(packetContext, {
        timeMs: bunch.timeMs,
        chIndex: bunch.chIndex,
        actorNetGuid: actor?.actorNetGuid?.value ?? null,
        actorPath: getPathForNetGuid(frameContext, actor?.archetype?.value ?? 0),
        actorGroup: actorGroup?.pathName ?? null,
        repObject,
        repObjectPath: getPathForNetGuid(frameContext, repObject),
        source: 'rep-layout',
        handle,
        rawHandle,
        fieldName: field?.name ?? null,
        numBits,
        payloadHex,
        payloadHexTruncated,
      });
      noteAbilitySignalSample(packetContext, {
        timeMs: bunch.timeMs,
        chIndex: bunch.chIndex,
        actorNetGuid: actor?.actorNetGuid?.value ?? null,
        actorPath: getPathForNetGuid(frameContext, actor?.archetype?.value ?? 0),
        actorGroup: actorGroup?.pathName ?? null,
        repObject,
        repObjectPath: getPathForNetGuid(frameContext, repObject),
        source: 'rep-layout',
        handle,
        rawHandle,
        fieldName: field?.name ?? null,
        numBits,
        payloadHex,
        payloadHexTruncated,
      });
      payloadReader.skipBits(numBits);
    }
  }

  if (classNetCache) {
    while (!payloadReader.atEnd() && !payloadReader.isError) {
      const fieldHandle = payloadReader.readSerializedInt(Math.max(classNetCache.netFieldExportsLength, 2));
      if (payloadReader.isError || payloadReader.bitsLeft <= 0) break;
      const field = classNetCache.netFieldExports[fieldHandle];
      const isTargetFunction = field?.name?.includes(
        'ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous',
      );
      const beforePayloadBits = payloadReader.bitsLeft;
      const beforePayloadHex = isTargetFunction ? peekBitsHex(payloadReader, 256) : null;
      const numPayloadBits = payloadReader.readIntPacked();
      if (payloadReader.isError) break;
      if (numPayloadBits < 0 || numPayloadBits > payloadReader.bitsLeft) {
        payloadReader.isError = true;
        break;
      }
      const fieldReader = payloadReader.fork(numPayloadBits);
      const payloadBits = copyBitsFromReader(fieldReader, numPayloadBits);
      const payloadHex = payloadBits.toString('hex');
      const sample = {
        timeMs: bunch.timeMs,
        chIndex: bunch.chIndex,
        actorNetGuid: actor?.actorNetGuid?.value ?? null,
        actorPath: getPathForNetGuid(frameContext, actor?.archetype?.value ?? 0),
        actorGroup: actorGroup?.pathName ?? null,
        repObject,
        repObjectPath: getPathForNetGuid(frameContext, repObject),
        classNetCache: classNetCache.pathName,
        fieldHandle,
        fieldName: field?.name ?? null,
        isTargetFunction,
        beforePayloadBits,
        beforePayloadHex,
        numPayloadBits,
        payloadHex,
        afterPayloadBits: payloadReader.bitsLeft,
      };
      noteClassNetCachePayload(packetContext, sample, payloadBits, numPayloadBits);
      noteDiagnosticActorWireSample(packetContext, {
        ...sample,
        source: 'classnet-rpc',
      });
      noteAbilitySignalSample(packetContext, {
        ...sample,
        source: 'classnet-rpc',
        payloadHex,
      });
      if (isInputEventCaptureFunction(field?.name)) {
        const inputFields = inputEventCaptureRpcGroup
          ? parseRpcProperties(new BitReader(payloadBits, numPayloadBits), inputEventCaptureRpcGroup, {
              skipLeadingBit: true,
            })
          : [];
        noteInputEventCaptureSample(packetContext, sample, inputFields);
      }
      if (
        packetContext.classNetCacheSamples.length < 20000 &&
        /Replay|Character|Player/i.test(actorGroup?.pathName ?? '')
      ) {
        packetContext.classNetCacheSamples.push({
          ...sample,
          payloadHex: payloadHex.slice(0, Math.ceil(Math.min(numPayloadBits, 512) / 4)),
        });
      }
      if (!isTargetFunction) {
        continue;
      }
      if (!targetRpcGroup) {
        continue;
      }
      if (packetContext.rpcCandidateSamples.length < 40) {
        packetContext.rpcCandidateSamples.push({
          timeMs: bunch.timeMs,
          chIndex: bunch.chIndex,
          actorNetGuid: actor?.actorNetGuid?.value ?? null,
          fieldHandle,
          functionName: field.name,
          beforePayloadBits,
          beforePayloadHex,
          numPayloadBits,
          payloadHex: payloadHex.slice(0, Math.ceil(Math.min(numPayloadBits, 512) / 4)),
          afterPayloadBits: payloadReader.bitsLeft,
          afterPayloadHex: peekBitsHex(payloadReader, 256),
        });
      }
      packetContext.rpcHitCount += 1;
      if (packetContext.rpcHits.length < RPC_HIT_PREVIEW_LIMIT) {
        const fields = parseRpcProperties(fieldReader, targetRpcGroup, {
          skipLeadingBit: true,
        });
        packetContext.rpcHits.push({
          timeMs: bunch.timeMs,
          chIndex: bunch.chIndex,
          actorNetGuid: actor?.actorNetGuid?.value ?? null,
          actorPath: getPathForNetGuid(frameContext, actor?.archetype?.value ?? 0),
          classNetCache: classNetCache.pathName,
          functionHandle: fieldHandle,
          functionName: field.name,
          numPayloadBits,
          fields,
        });
      }
    }
  }
}

function processBunchPayload(bunch, packetContext) {
  const channel = packetContext.channels[bunch.chIndex];
  const reader = bunch.archive;
  if (bunch.bHasMustBeMappedGUIDs) {
    const count = reader.readUInt16();
    if (count > 2048) {
      reader.isError = true;
      return;
    }
    for (let i = 0; i < count; i += 1) reader.readIntPacked();
  }
  if (channel && (!channel.actor || bunch.bOpen)) {
    if (!bunch.bOpen) return;
    const actor = {
      actorNetGuid: { value: readInternalLoadObject(reader, false, packetContext.frameContext) },
    };
    if (actor.actorNetGuid.value > 0 && (actor.actorNetGuid.value & 1) !== 1) {
      actor.archetype = { value: readInternalLoadObject(reader, false, packetContext.frameContext) };
      if (packetContext.frameContext.header.engineNetworkVersion >= 5) {
        actor.level = { value: readInternalLoadObject(reader, false, packetContext.frameContext) };
      }
      actor.location = readConditionalQuantizedVector(reader, { x: 0, y: 0, z: 0 });
      actor.rotation = reader.readBit() ? reader.readRotationShort() : { pitch: 0, yaw: 0, roll: 0 };
      actor.scale = readConditionalQuantizedVector(reader, { x: 1, y: 1, z: 1 });
      actor.velocity = readConditionalQuantizedVector(reader, { x: 0, y: 0, z: 0 });
    }
    channel.actor = actor;
    packetContext.actorChannelOpenCount += 1;
    const archetypePath = getPathForNetGuid(packetContext.frameContext, actor.archetype?.value ?? 0);
    if (
      packetContext.channelOpenSamples.length < 100 ||
      /Replay|Controller|\/Game\/Characters/i.test(archetypePath)
    ) {
      packetContext.channelOpenSamples.push({
        timeMs: bunch.timeMs,
        chIndex: bunch.chIndex,
        actorNetGuid: actor.actorNetGuid.value,
        archetype: actor.archetype?.value ?? null,
        archetypePath,
        location: actor.location ?? null,
        rotation: actor.rotation ?? null,
        velocity: actor.velocity ?? null,
      });
    }
    noteUtilityActorOpen(packetContext, {
      timeMs: bunch.timeMs,
      chIndex: bunch.chIndex,
      actorNetGuid: actor.actorNetGuid.value,
      archetype: actor.archetype?.value ?? null,
      archetypePath,
      location: actor.location ?? null,
      rotation: actor.rotation ?? null,
      velocity: actor.velocity ?? null,
    });
  }

  while (!reader.atEnd() && !reader.isError) {
    const content = readContentBlockHeader(bunch, packetContext);
    if (reader.isError) break;
    const numPayloadBits = content.bObjectDeleted ? 0 : reader.readIntPacked();
    if (numPayloadBits < 0 || numPayloadBits > reader.bitsLeft) {
      reader.isError = true;
      break;
    }
    if (packetContext.replicatorSamples.length < 120 && bunch.chIndex === 2) {
      const actor = packetContext.channels[bunch.chIndex]?.actor;
      packetContext.replicatorSamples.push({
        timeMs: bunch.timeMs,
        chIndex: bunch.chIndex,
        bOpen: bunch.bOpen,
        bPartial: bunch.bPartial,
        bHasRepLayout: content.bOutHasRepLayout,
        bIsActor: content.bIsActor,
        bObjectDeleted: content.bObjectDeleted,
        repObject: content.repObject,
        repObjectPath: getPathForNetGuid(packetContext.frameContext, content.repObject),
        actorNetGuid: actor?.actorNetGuid?.value ?? null,
        actorPath: getPathForNetGuid(packetContext.frameContext, actor?.archetype?.value ?? 0),
        numPayloadBits,
        payloadHex: peekBitsHex(reader, Math.min(numPayloadBits, 512)),
        remainingBitsAfterLength: reader.bitsLeft,
      });
    }
    const payloadReader = numPayloadBits > 0 ? reader.fork(numPayloadBits) : null;
    if (!content.bObjectDeleted && payloadReader && content.repObject) {
      processReplicatorPayload(
        bunch,
        payloadReader,
        content.repObject,
        content.bOutHasRepLayout,
        packetContext,
      );
    }
  }
}

function concatBitParts(parts) {
  const totalBits = parts.reduce((sum, part) => sum + part.bitCount, 0);
  const output = Buffer.alloc(Math.ceil(totalBits / 8));
  let writeBit = 0;
  for (const part of parts) {
    for (let bit = 0; bit < part.bitCount; bit += 1) {
      if ((part.buffer[Math.floor(bit / 8)] >> (bit & 7)) & 1) {
        output[Math.floor(writeBit / 8)] |= 1 << (writeBit & 7);
      }
      writeBit += 1;
    }
  }
  return { buffer: output, bitCount: totalBits };
}

function consumePartialBunch(bunch, packetContext) {
  const bitsLeft = bunch.archive.bitsLeft;
  const part = {
    buffer: bunch.archive.readBits(bitsLeft),
    bitCount: bitsLeft,
  };
  const key = bunch.chIndex;
  if (bunch.bPartialInitial || !packetContext.partialBunches.has(key)) {
    packetContext.partialBunches.set(key, {
      ...bunch,
      parts: [part],
    });
  } else {
    const existing = packetContext.partialBunches.get(key);
    existing.parts.push(part);
    existing.bClose = bunch.bClose;
    existing.bDormant = bunch.bDormant;
    existing.closeReason = bunch.closeReason;
    existing.bIsReplicationPaused = bunch.bIsReplicationPaused;
    existing.bHasMustBeMappedGUIDs = bunch.bHasMustBeMappedGUIDs;
    existing.timeMs = bunch.timeMs;
  }

  if (!bunch.bPartialFinal) return null;

  const existing = packetContext.partialBunches.get(key);
  packetContext.partialBunches.delete(key);
  const combined = concatBitParts(existing.parts);
  return {
    ...existing,
    bPartial: false,
    bPartialInitial: false,
    bPartialFinal: false,
    archive: new BitReader(combined.buffer, combined.bitCount),
  };
}

function packetBitSize(payload) {
  let lastByte = payload[payload.length - 1];
  if (!lastByte) return 0;
  let bitSize = payload.length * 8 - 1;
  while ((lastByte & 0x80) !== 0x80) {
    lastByte *= 2;
    bitSize -= 1;
  }
  return bitSize;
}

function parseCompactReplayPacket(payload, header) {
  const bitSize = packetBitSize(payload);
  if (bitSize <= 0) return { ok: false, bunches: [], error: 'invalid-bit-size' };
  const reader = new BitReader(payload, bitSize);
  const bunches = [];

  while (!reader.isError && reader.bitsLeft > 24 && bunches.length < 64) {
    const startBit = reader.offset;
    const bControl = reader.readBit();
    let bOpen = false;
    let bClose = false;
    let closeReason = 0;
    if (bControl) {
      bOpen = reader.readBit();
      bClose = reader.readBit();
      if (bClose) closeReason = reader.readSerializedInt(15);
    }

    const bIsReplicationPaused = reader.readBit();
    const bReliable = reader.readBit();
    const chIndex = reader.readSerializedInt(1024);
    const bHasPackageExportMaps = reader.readBit();
    const bHasMustBeMappedGUIDs = reader.readBit();
    const bPartial = reader.readBit();
    const bPartialInitial = bPartial ? reader.readBit() : false;
    const bPartialFinal = bPartial ? reader.readBit() : false;
    const compactMarker = reader.readBits(6).toString('hex');
    const bunchDataBits = reader.readSerializedInt(16 * 1024);
    if (reader.isError || bunchDataBits > reader.bitsLeft) {
      return {
        ok: bunches.length > 0,
        bunches,
        error: `invalid-bunch-bits:${bunchDataBits}:left:${reader.bitsLeft}`,
      };
    }
    const data = reader.readBits(bunchDataBits);
    bunches.push({
      startBit,
      bControl,
      bOpen,
      bClose,
      closeReason,
      bIsReplicationPaused,
      bReliable,
      chIndex,
      bHasPackageExportMaps,
      bHasMustBeMappedGUIDs,
      bPartial,
      bPartialInitial,
      bPartialFinal,
      compactMarker,
      bunchDataBits,
      data,
    });
  }

  return { ok: !reader.isError, bunches, error: reader.isError ? 'reader-error' : null };
}

function appendBitParts(parts) {
  const bitCount = parts.reduce((sum, part) => sum + part.bitCount, 0);
  const buffer = Buffer.alloc(Math.ceil(bitCount / 8));
  let writeBit = 0;
  for (const part of parts) {
    for (let bit = 0; bit < part.bitCount; bit += 1) {
      if ((part.buffer[Math.floor(bit / 8)] >> (bit & 7)) & 1) {
        buffer[Math.floor(writeBit / 8)] |= 1 << (writeBit & 7);
      }
      writeBit += 1;
    }
  }
  return { buffer, bitCount };
}

function inspectAssembledReplayPayload(buffer, bitCount) {
  const byteLength = Math.ceil(bitCount / 8);
  const bytes = buffer.subarray(0, byteLength);
  const plausibleInt16Triples = [];
  const plausibleFloatTriples = [];

  for (let offset = 0; offset + 5 < bytes.length && plausibleInt16Triples.length < 24; offset += 1) {
    const x = bytes.readInt16LE(offset);
    const y = bytes.readInt16LE(offset + 2);
    const z = bytes.readInt16LE(offset + 4);
    if (
      Math.abs(x) >= 500 &&
      Math.abs(y) >= 500 &&
      Math.abs(x) <= 20_000 &&
      Math.abs(y) <= 20_000 &&
      Math.abs(z) <= 3_000
    ) {
      plausibleInt16Triples.push({ offset, x, y, z });
    }
  }

  for (let offset = 0; offset + 11 < bytes.length && plausibleFloatTriples.length < 24; offset += 1) {
    const x = bytes.readFloatLE(offset);
    const y = bytes.readFloatLE(offset + 4);
    const z = bytes.readFloatLE(offset + 8);
    if (
      Number.isFinite(x) &&
      Number.isFinite(y) &&
      Number.isFinite(z) &&
      Math.abs(x) >= 100 &&
      Math.abs(y) >= 100 &&
      Math.abs(x) <= 20_000 &&
      Math.abs(y) <= 20_000 &&
      Math.abs(z) <= 5_000
    ) {
      plausibleFloatTriples.push({
        offset,
        x: Number(x.toFixed(3)),
        y: Number(y.toFixed(3)),
        z: Number(z.toFixed(3)),
      });
    }
  }

  return {
    bitCount,
    byteLength,
    firstBytes: bytes.subarray(0, 96).toString('hex'),
    plausibleInt16Triples,
    plausibleFloatTriples,
  };
}

function createCompactReplaySummary(maxAssemblies = 40) {
  return {
    maxAssemblies,
    counts: new Map(),
    parseErrors: new Map(),
    openPartials: new Map(),
    assemblies: [],
    parsedPackets: 0,
    compactBunches: 0,
  };
}

function summarizeCompactReplayPackets(frames, header, summary = createCompactReplaySummary()) {
  for (const frame of frames) {
    for (const packet of frame.packets) {
      const parsed = parseCompactReplayPacket(packet.payload, header);
      if (!parsed.ok && !parsed.bunches.length) {
        summary.parseErrors.set(
          parsed.error,
          (summary.parseErrors.get(parsed.error) ?? 0) + 1,
        );
        continue;
      }
      summary.parsedPackets += 1;
      summary.compactBunches += parsed.bunches.length;
      if (parsed.error) {
        summary.parseErrors.set(
          parsed.error,
          (summary.parseErrors.get(parsed.error) ?? 0) + 1,
        );
      }

      for (const bunch of parsed.bunches) {
        const key = [
          `ch-${bunch.chIndex}`,
          bunch.bPartial ? 'partial' : 'whole',
          bunch.bPartialInitial ? 'initial' : '',
          bunch.bPartialFinal ? 'final' : '',
          `bits-${bunch.bunchDataBits}`,
          `marker-${bunch.compactMarker}`,
        ]
          .filter(Boolean)
          .join(':');
        summary.counts.set(key, (summary.counts.get(key) ?? 0) + 1);

        if (bunch.chIndex !== 2) continue;

        if (!bunch.bPartial) {
          if (summary.assemblies.length < summary.maxAssemblies) {
            summary.assemblies.push({
              startMs: frame.timeMs,
              endMs: frame.timeMs,
              partCount: 1,
              source: 'whole',
              ...inspectAssembledReplayPayload(bunch.data, bunch.bunchDataBits),
            });
          }
          continue;
        }

        if (bunch.bPartialInitial || !summary.openPartials.has(bunch.chIndex)) {
          summary.openPartials.set(bunch.chIndex, {
            startMs: frame.timeMs,
            parts: [],
          });
        }

        const partial = summary.openPartials.get(bunch.chIndex);
        partial.parts.push({ buffer: bunch.data, bitCount: bunch.bunchDataBits });

        if (bunch.bPartialFinal) {
          const assembled = appendBitParts(partial.parts);
          if (summary.assemblies.length < summary.maxAssemblies) {
            summary.assemblies.push({
              startMs: partial.startMs,
              endMs: frame.timeMs,
              partCount: partial.parts.length,
              source: 'partial',
              ...inspectAssembledReplayPayload(assembled.buffer, assembled.bitCount),
            });
          }
          summary.openPartials.delete(bunch.chIndex);
        }
      }
    }
  }

  return summary;
}

function finalizeCompactReplaySummary(summary) {
  return {
    parsedPackets: summary.parsedPackets,
    compactBunches: summary.compactBunches,
    counts: [...summary.counts.entries()]
      .map(([key, count]) => ({ key, count }))
      .sort((a, b) => b.count - a.count)
      .slice(0, 80),
    parseErrors: [...summary.parseErrors.entries()]
      .map(([key, count]) => ({ key, count }))
      .sort((a, b) => b.count - a.count),
    openPartialChannels: [...summary.openPartials.entries()].map(([chIndex, value]) => ({
      chIndex,
      startMs: value.startMs,
      partCount: value.parts.length,
      bitCount: value.parts.reduce((sum, part) => sum + part.bitCount, 0),
    })),
    assemblies: summary.assemblies,
  };
}

function parseReplayPropertyFieldsAt(buffer, bitCount, bitOffset, skipLeadingBit = false) {
  const reader = new BitReader(buffer, bitCount, bitOffset);
  if (skipLeadingBit) reader.readBit();
  const fields = [];
  for (let i = 0; i < 12 && reader.bitsLeft > 0 && !reader.isError; i += 1) {
    const rawHandle = reader.readIntPacked();
    if (rawHandle === 0) {
      fields.push({ handle: -1, rawHandle, terminator: true });
      break;
    }
    const handle = rawHandle - 1;
    const numBits = reader.readIntPacked();
    if (numBits < 0 || numBits > reader.bitsLeft) {
      fields.push({ handle, rawHandle, numBits, bad: true });
      break;
    }
    fields.push({
      handle,
      rawHandle,
      numBits,
      payload: reader.readBits(numBits),
    });
  }
  return fields;
}

function mapKeyFromPath(mapPath) {
  const lowered = String(mapPath ?? '').toLowerCase();
  if (lowered.includes('ascent')) return 'ascent';
  return null;
}

function projectGameVectorToMapPercent(vector, mapPath) {
  const bounds = MAP_VECTOR_BOUNDS.get(mapKeyFromPath(mapPath));
  if (!bounds) return null;
  return {
    u: vector.y * bounds.xMultiplier + bounds.xScalarToAdd,
    v: vector.x * bounds.yMultiplier + bounds.yScalarToAdd,
  };
}

function isPlausibleMapVector(vector, mapPath) {
  const bounds = MAP_VECTOR_BOUNDS.get(mapKeyFromPath(mapPath));
  if (!bounds) {
    return (
      Math.abs(vector.x) <= 20_000 &&
      Math.abs(vector.y) <= 20_000 &&
      vector.z >= -500 &&
      vector.z <= 3_000
    );
  }
  const percent = projectGameVectorToMapPercent(vector, mapPath);
  return (
    percent &&
    percent.u >= bounds.minPercent &&
    percent.u <= bounds.maxPercent &&
    percent.v >= bounds.minPercent &&
    percent.v <= bounds.maxPercent &&
    vector.z >= bounds.minZ &&
    vector.z <= bounds.maxZ
  );
}

function decodeFirstPackedVectorCandidate(payload, bitCount, mapPath) {
  const maxOffset = Math.min(512, bitCount);
  for (let offset = 0; offset < maxOffset; offset += 1) {
    for (const scaleFactor of [1, 10, 100]) {
      const reader = new BitReader(payload, bitCount, offset);
      const vector = reader.readPackedVector(scaleFactor);
      if (reader.isError) continue;
      if (!Number.isFinite(vector.componentBits)) continue;
      if (!isPlausibleMapVector(vector, mapPath)) continue;
      if (Math.abs(vector.x) < 100 && Math.abs(vector.y) < 100) continue;
      const percent = projectGameVectorToMapPercent(vector, mapPath);
      return { bitOffset: offset, scaleFactor, mapPercent: percent, ...vector };
    }
  }
  return null;
}

function decodePackedVectorCandidates(payload, bitCount, mapPath, maxVectors = 12) {
  const vectors = [];
  const seen = new Set();
  const maxOffset = Math.min(768, bitCount);
  for (let offset = 0; offset < maxOffset && vectors.length < maxVectors; offset += 1) {
    for (const scaleFactor of [1, 10, 100]) {
      const reader = new BitReader(payload, bitCount, offset);
      const vector = reader.readPackedVector(scaleFactor);
      if (reader.isError) continue;
      if (!Number.isFinite(vector.componentBits)) continue;
      if (vector.componentBits < 7 || vector.componentBits > 19) continue;
      if (!isPlausibleMapVector(vector, mapPath)) continue;
      if (Math.abs(vector.x) < 50 && Math.abs(vector.y) < 50) continue;
      const key = [
        scaleFactor,
        Math.round(vector.x * 10),
        Math.round(vector.y * 10),
        Math.round(vector.z * 10),
      ].join(':');
      if (seen.has(key)) continue;
      seen.add(key);
      vectors.push({
        bitOffset: offset,
        scaleFactor,
        mapPercent: projectGameVectorToMapPercent(vector, mapPath),
        ...vector,
      });
      if (vectors.length >= maxVectors) break;
    }
  }
  return vectors;
}

function decodeGuidFieldPayload(field) {
  if (!field?.payload || field.numBits < 8) return null;
  const values = [];
  for (const bitOffset of [0, 1, 2, 3, 4, 5, 6, 7]) {
    if (field.numBits - bitOffset >= 32) {
      const uintReader = new BitReader(field.payload, field.numBits, bitOffset);
      const value = uintReader.readUInt32();
      if (!uintReader.isError && value > 0) {
        values.push({ encoding: 'uint32', bitOffset, value });
      }
    }
    const packedReader = new BitReader(field.payload, field.numBits, bitOffset);
    const packed = packedReader.readIntPacked();
    if (!packedReader.isError && packed > 0) {
      values.push({ encoding: 'intPacked', bitOffset, value: packed });
    }
  }
  if (!values.length) return null;
  values.sort((a, b) => {
    if (a.bitOffset !== b.bitOffset) return a.bitOffset - b.bitOffset;
    if (a.encoding !== b.encoding) return a.encoding === 'intPacked' ? -1 : 1;
    return a.value - b.value;
  });
  const best = values[0];
  return {
    ...best,
    rawHex: field.payload.toString('hex').slice(0, 32),
    numBits: field.numBits,
  };
}

function chooseComponentVectorCandidate(assembled, mapPath) {
  let best = null;
  const maxOffset = Math.min(1200, assembled.bitCount);
  for (let bitOffset = 0; bitOffset < maxOffset; bitOffset += 1) {
    for (const skipLeadingBit of [false, true]) {
      const fields = parseReplayPropertyFieldsAt(
        assembled.buffer,
        assembled.bitCount,
        bitOffset,
        skipLeadingBit,
      );
      const hasGuidField = fields.some(
        (field) => field.handle === 2 && field.numBits >= 8 && field.numBits <= 160,
      );
      for (const field of fields) {
        if (field.handle !== 3 || field.bad || field.numBits < 80 || !field.payload) {
          continue;
        }
        const vector = decodeFirstPackedVectorCandidate(field.payload, field.numBits, mapPath);
        if (!vector) continue;
        const magnitude = Math.abs(vector.x) + Math.abs(vector.y);
        const score =
          (hasGuidField ? 100_000 : 0) +
          magnitude -
          Math.abs(vector.z) * 0.25 -
          vector.bitOffset * 8;
        if (!best || score > best.score) {
          best = {
            score,
            propertyBitOffset: bitOffset,
            skipLeadingBit,
            componentBits: field.numBits,
            vector,
            hasGuidField,
          };
        }
      }
    }
  }
  return best;
}

function findAssemblyVectorCandidates(assembled, mapPath, metadata) {
  const candidates = [];
  const seen = new Set();
  const maxOffset = Math.min(1200, assembled.bitCount);
  for (let bitOffset = 0; bitOffset < maxOffset; bitOffset += 1) {
    for (const skipLeadingBit of [false, true]) {
      const fields = parseReplayPropertyFieldsAt(
        assembled.buffer,
        assembled.bitCount,
        bitOffset,
        skipLeadingBit,
      );
      const guidField = fields.find(
        (field) => field.handle === 2 && !field.bad && field.numBits >= 8 && field.numBits <= 160,
      );
      const decodedGuid = decodeGuidFieldPayload(guidField);
      for (const field of fields) {
        if (field.bad || !field.payload || field.numBits < 64) continue;
        if (![1, 3].includes(field.handle)) continue;
        const vectors = decodePackedVectorCandidates(field.payload, field.numBits, mapPath);
        for (let vectorIndex = 0; vectorIndex < vectors.length; vectorIndex += 1) {
          const vector = vectors[vectorIndex];
          const entityKey = decodedGuid
            ? `guid-${decodedGuid.value}:field-${field.handle}:vector-${vectorIndex}`
            : [
                `ch-${metadata.chIndex}`,
                `field-${field.handle}`,
                `vector-${vectorIndex}`,
                `bits-${vector.componentBits}`,
                `extra-${vector.extraInfo}`,
              ].join(':');
          const uniqueKey = [
            metadata.timeMs,
            entityKey,
            Math.round(vector.x * 10),
            Math.round(vector.y * 10),
            Math.round(vector.z * 10),
          ].join(':');
          if (seen.has(uniqueKey)) continue;
          seen.add(uniqueKey);
          candidates.push({
            entityKey,
            timeMs: metadata.timeMs,
            x: Number(vector.x.toFixed(2)),
            y: Number(vector.y.toFixed(2)),
            z: Number(vector.z.toFixed(2)),
            yawDegrees: 0,
            source: metadata.source,
            chIndex: metadata.chIndex,
            fieldHandle: field.handle,
            vectorIndex,
            propertyBitOffset: bitOffset,
            skipLeadingBit,
            vectorBitOffset: vector.bitOffset,
            componentBits: vector.componentBits,
            extraInfo: vector.extraInfo,
            hasGuidField: Boolean(decodedGuid),
            decodedGuid,
          });
        }
      }
    }
  }
  return candidates;
}

function extractHeuristicComponentVectorSamples(decompressedChunks, header) {
  const context = createFrameContext(header);
  const openPartials = new Map();
  const samples = [];
  const seen = new Set();

  function maybeAddSample(timeMs, assembled, source) {
    const candidate = chooseComponentVectorCandidate(assembled, header.mapPath);
    if (!candidate) return;
    const { vector } = candidate;
    const key = [
      timeMs,
      Math.round(vector.x * 10),
      Math.round(vector.y * 10),
      Math.round(vector.z * 10),
    ].join(':');
    if (seen.has(key)) return;
    seen.add(key);
    samples.push({
      timeMs,
      x: Number(vector.x.toFixed(2)),
      y: Number(vector.y.toFixed(2)),
      z: Number(vector.z.toFixed(2)),
      yawDegrees: 0,
      source,
      componentBits: candidate.componentBits,
      propertyBitOffset: candidate.propertyBitOffset,
      vectorBitOffset: candidate.vector.bitOffset,
      hasGuidField: candidate.hasGuidField,
    });
  }

  for (const chunk of decompressedChunks) {
    const frames = parseFramesInChunk(chunk, context);
    for (const frame of frames) {
      for (const packet of frame.packets) {
        const parsed = parseCompactReplayPacket(packet.payload, context.header);
        for (const bunch of parsed.bunches) {
          if (bunch.chIndex !== 2) continue;
          if (!bunch.bPartial) {
            maybeAddSample(
              frame.timeMs,
              { buffer: bunch.data, bitCount: bunch.bunchDataBits },
              'compact-channel-2-whole',
            );
            continue;
          }

          if (bunch.bPartialInitial || !openPartials.has(bunch.chIndex)) {
            openPartials.set(bunch.chIndex, { startMs: frame.timeMs, parts: [] });
          }
          const partial = openPartials.get(bunch.chIndex);
          partial.parts.push({ buffer: bunch.data, bitCount: bunch.bunchDataBits });
          if (!bunch.bPartialFinal) continue;

          const assembled = appendBitParts(partial.parts);
          openPartials.delete(bunch.chIndex);
          maybeAddSample(frame.timeMs, assembled, 'compact-channel-2-partial');
        }
      }
    }
  }

  samples.sort((a, b) => a.timeMs - b.timeMs);
  for (let i = 0; i < samples.length; i += 1) {
    const previous = samples[i - 1];
    const next = samples[i + 1];
    const reference = next ?? previous;
    if (!reference) continue;
    const dx = reference.x - samples[i].x;
    const dy = reference.y - samples[i].y;
    if (Math.hypot(dx, dy) > 1) {
      samples[i].yawDegrees = (Math.atan2(dy, dx) * 180) / Math.PI;
    }
  }
  return samples;
}

function addYawFromNeighboringSamples(samples) {
  samples.sort((a, b) => a.timeMs - b.timeMs);
  for (let i = 0; i < samples.length; i += 1) {
    const previous = samples[i - 1];
    const next = samples[i + 1];
    const reference = next ?? previous;
    if (!reference) continue;
    const dx = reference.x - samples[i].x;
    const dy = reference.y - samples[i].y;
    if (Math.hypot(dx, dy) > 1) {
      samples[i].yawDegrees = Number(((Math.atan2(dy, dx) * 180) / Math.PI).toFixed(2));
    }
  }
}

function buildCandidateEntityTracks(decompressedChunks, header) {
  const context = createFrameContext(header);
  const openPartials = new Map();
  const tracks = new Map();
  const maxInspectedAssemblies = 5000;
  let inspectedAssemblies = 0;
  const trackColors = [
    '#69F0AF',
    '#FF5252',
    '#7C3AED',
    '#F97316',
    '#38BDF8',
    '#F43F5E',
    '#A3E635',
    '#FACC15',
    '#C084FC',
    '#2DD4BF',
  ];

  function ensureTrack(id, seed) {
    if (!tracks.has(id)) {
      tracks.set(id, {
        id,
        displayName: '',
        agent: seed.hasGuidField ? 'GUID candidate' : 'Stream candidate',
        teamColor: trackColors[tracks.size % trackColors.length],
        kind: seed.hasGuidField ? 'candidate-guid-entity' : 'candidate-stream-entity',
        sourceTag: seed.source,
        confidence: seed.hasGuidField ? 'guid-adjacent' : 'stream-signature',
        notes: seed.hasGuidField
          ? `Grouped by decoded handle-2 NetGUID candidate ${seed.decodedGuid.value}.`
          : 'Grouped by repeated channel/field/vector signature. Identity is not proven.',
        samples: [],
      });
    }
    return tracks.get(id);
  }

  function addCandidate(candidate) {
    const track = ensureTrack(candidate.entityKey, candidate);
    track.samples.push({
      timeMs: candidate.timeMs,
      x: candidate.x,
      y: candidate.y,
      z: candidate.z,
      yawDegrees: candidate.yawDegrees,
      source: candidate.source,
      chIndex: candidate.chIndex,
      fieldHandle: candidate.fieldHandle,
      vectorIndex: candidate.vectorIndex,
      propertyBitOffset: candidate.propertyBitOffset,
      vectorBitOffset: candidate.vectorBitOffset,
      componentBits: candidate.componentBits,
      decodedGuid: candidate.decodedGuid?.value ?? null,
    });
  }

  function inspectAssembly(timeMs, assembled, source, chIndex) {
    if (chIndex !== 2 || inspectedAssemblies >= maxInspectedAssemblies) return;
    inspectedAssemblies += 1;
    const candidates = findAssemblyVectorCandidates(assembled, header.mapPath, {
      timeMs,
      source,
      chIndex,
    });
    for (const candidate of candidates) addCandidate(candidate);
  }

  for (const chunk of decompressedChunks) {
    const frames = parseFramesInChunk(chunk, context);
    for (const frame of frames) {
      if (frame.timeMs < 0) continue;
      for (const packet of frame.packets) {
        const parsed = parseCompactReplayPacket(packet.payload, context.header);
        for (const bunch of parsed.bunches) {
          if (!bunch.bPartial) {
            inspectAssembly(
              frame.timeMs,
              { buffer: bunch.data, bitCount: bunch.bunchDataBits },
              `compact-ch-${bunch.chIndex}-whole`,
              bunch.chIndex,
            );
            continue;
          }

          if (bunch.bPartialInitial || !openPartials.has(bunch.chIndex)) {
            openPartials.set(bunch.chIndex, { startMs: frame.timeMs, parts: [] });
          }
          const partial = openPartials.get(bunch.chIndex);
          partial.parts.push({ buffer: bunch.data, bitCount: bunch.bunchDataBits });
          if (!bunch.bPartialFinal) continue;

          const assembled = appendBitParts(partial.parts);
          openPartials.delete(bunch.chIndex);
          inspectAssembly(
            frame.timeMs,
            assembled,
            `compact-ch-${bunch.chIndex}-partial`,
            bunch.chIndex,
          );
        }
      }
    }
  }

  const sorted = [...tracks.values()]
    .map((track) => {
      addYawFromNeighboringSamples(track.samples);
      return track;
    })
    .filter((track) => track.samples.length >= 2 || track.confidence === 'guid-adjacent')
    .sort((a, b) => {
      const confidenceDelta =
        (b.confidence === 'guid-adjacent' ? 1 : 0) - (a.confidence === 'guid-adjacent' ? 1 : 0);
      if (confidenceDelta) return confidenceDelta;
      return b.samples.length - a.samples.length;
    })
    .slice(0, 120);

  return sorted.map((track, index) => ({
    ...track,
    displayName: `${String(index + 1).padStart(2, '0')} ${track.id}`,
  }));
}

function buildConfirmedActorOpenTracks(frameSummary, header) {
  const colors = ['#38BDF8', '#A3E635', '#FACC15', '#C084FC'];
  return (frameSummary.compactChannelOpenSamples ?? [])
    .filter(
      (sample) =>
        sample.location &&
        isPlausibleMapVector(sample.location, header.mapPath) &&
        (Math.abs(sample.location.x) >= 50 || Math.abs(sample.location.y) >= 50),
    )
    .map((sample, index) => ({
      id: `actor-open-${sample.actorNetGuid ?? sample.chIndex}`,
      displayName: `Actor open ${sample.actorNetGuid ?? sample.chIndex}`,
      agent: 'Confirmed actor transform',
      teamColor: colors[index % colors.length],
      kind: 'confirmed-actor-open-transform',
      sourceTag: `compact-ch-${sample.chIndex}-open`,
      confidence: 'confirmed-unreal-actor-open',
      notes: sample.archetypePath || 'Actor channel-open transform decoded by Unreal bunch parsing.',
      samples: [
        {
          timeMs: sample.timeMs,
          x: Number(sample.location.x.toFixed(2)),
          y: Number(sample.location.y.toFixed(2)),
          z: Number(sample.location.z.toFixed(2)),
          yawDegrees: Number((sample.rotation?.yaw ?? 0).toFixed(2)),
        },
      ],
    }));
}

function summarizeUtilityActors(samples, limit = 80) {
  const countsByArchetype = new Map();
  const countsByAgent = new Map();
  const countsByKind = new Map();
  const countsByContentKind = new Map();
  const countsByPhase = new Map();
  const countsBySlot = new Map();
  for (const sample of samples ?? []) {
    incrementCountMap(countsByArchetype, sample.className ?? sample.archetypePath ?? 'unknown');
    incrementCountMap(countsByAgent, sample.agent ?? 'unknown');
    incrementCountMap(countsByKind, sample.utilityKind ?? 'unknown');
    incrementCountMap(countsByContentKind, sample.contentKind ?? 'unknown');
    incrementCountMap(countsByPhase, sample.phase ?? 'unknown');
    incrementCountMap(countsBySlot, sample.abilitySlot ?? 'unknown');
  }

  return {
    count: samples?.length ?? 0,
    withAgentCount: (samples ?? []).filter((sample) => sample.agent).length,
    withAbilitySlotCount: (samples ?? []).filter((sample) => sample.abilitySlot).length,
    withCloseCount: (samples ?? []).filter((sample) => sample.closedAtMs != null).length,
    byAgent: topCounts(countsByAgent, 16),
    byKind: topCounts(countsByKind, 16),
    byContentKind: topCounts(countsByContentKind, 16),
    byPhase: topCounts(countsByPhase, 16),
    byAbilitySlot: topCounts(countsBySlot, 8),
    byArchetype: topCounts(countsByArchetype, limit),
  };
}

function summarizeAbilityCasts(casts, limit = 32) {
  const countsByAgent = new Map();
  const countsBySlot = new Map();
  const countsByConfidence = new Map();
  for (const cast of casts ?? []) {
    incrementCountMap(countsByAgent, cast.agent ?? 'unknown');
    incrementCountMap(countsBySlot, cast.abilitySlot ?? `slot-${cast.slotEnumValue ?? 'unknown'}`);
    incrementCountMap(countsByConfidence, cast.confidence ?? 'unknown');
  }
  return {
    count: casts?.length ?? 0,
    byAgent: topCounts(countsByAgent, limit),
    byAbilitySlot: topCounts(countsBySlot, 8),
    byConfidence: topCounts(countsByConfidence, 8),
  };
}

function processRawPacket(payload, timeMs, packetContext) {
  const bitSize = packetBitSize(payload);
  if (bitSize <= 0) return;
  const reader = new BitReader(payload, bitSize);
  packetContext.inPacketId += 1;
  let bunchesRead = 0;
  while (!reader.atEnd() && !reader.isError) {
    const loopStart = reader.offset;
    bunchesRead += 1;
    if (bunchesRead > 64) {
      notePacketError(packetContext, 'raw-packet-too-many-bunches');
      break;
    }
    const bunch = { timeMs, packetId: packetContext.inPacketId };
    const bControl = reader.readBit();
    bunch.bOpen = bControl ? reader.readBit() : false;
    bunch.bClose = bControl ? reader.readBit() : false;
    bunch.closeReason = bunch.bClose ? reader.readSerializedInt(15) : 0;
    bunch.bDormant = bunch.closeReason === 1;
    bunch.bIsReplicationPaused = reader.readBit();
    bunch.bReliable = reader.readBit();
    bunch.chIndex = reader.readIntPacked();
    bunch.bHasPackageExportMaps = reader.readBit();
    bunch.bHasMustBeMappedGUIDs = reader.readBit();
    bunch.bPartial = reader.readBit();
    bunch.chSequence = bunch.bReliable
      ? packetContext.inReliable + 1
      : bunch.bPartial
        ? packetContext.inPacketId
        : 0;
    bunch.bPartialInitial = bunch.bPartial ? reader.readBit() : false;
    bunch.bPartialFinal = bunch.bPartial ? reader.readBit() : false;
    let chName = 'None';
    let chType = 0;
    if (packetContext.frameContext.header.engineNetworkVersion >= 6) {
      reader.readBit();
      if (bunch.bReliable || bunch.bOpen) {
        chName = reader.readFName(packetContext.frameContext.header);
        if (chName === 'Control') chType = 1;
        if (chName === 'Actor') chType = 2;
        if (chName === 'Voice') chType = 4;
      }
    } else {
      const type = reader.readSerializedInt(4);
      if (bunch.bReliable || bunch.bOpen) chType = type;
    }
    bunch.chName = chName;
    bunch.chType = chType;
    const bunchDataBits = reader.readSerializedInt(1024 * 2 * 8);
    if (bunchDataBits > reader.bitsLeft) {
      reader.isError = true;
      break;
    }
    bunch.archive = reader.fork(bunchDataBits);

    if (bunch.bHasPackageExportMaps) receiveNetGuidBunch(bunch.archive, packetContext);
    if (
      packetContext.rawFocusChannels &&
      !packetContext.rawFocusChannels.has(bunch.chIndex)
    ) {
      continue;
    }
    if (bunch.bPartial) {
      const assembled = consumePartialBunch(bunch, packetContext);
      if (!assembled) continue;
      bunch.archive = assembled.archive;
      bunch.bPartial = false;
      bunch.bPartialInitial = false;
      bunch.bPartialFinal = false;
      bunch.bHasMustBeMappedGUIDs = assembled.bHasMustBeMappedGUIDs;
    }
    let channel = packetContext.channels[bunch.chIndex];
    if (!channel && !bunch.bReliable && !(bunch.bOpen && (bunch.bClose || bunch.bPartial))) {
      continue;
    }
    if (!channel) {
      channel = { channelIndex: bunch.chIndex, channelName: bunch.chName, channelType: bunch.chType };
      packetContext.channels[bunch.chIndex] = channel;
    }
    processBunchPayload(bunch, packetContext);
    if (bunch.bClose) {
      noteUtilityActorClose(packetContext, bunch, channel);
      delete packetContext.channels[bunch.chIndex];
    }
    if (reader.offset <= loopStart) {
      notePacketError(packetContext, 'raw-packet-no-progress');
      break;
    }
  }
  if (reader.isError) notePacketError(packetContext, 'raw-packet-parse-error');
}

function captureMovementRpcHits(
  frames,
  packetContext,
  maxHits = Number.POSITIVE_INFINITY,
  maxPackets = 0,
) {
  if (packetContext.rawPacketScanLimit == null) packetContext.rawPacketScanLimit = maxPackets;
  if (packetContext.rawPacketScanLimit <= 0) {
    packetContext.rawPacketScanSkipped = true;
    return;
  }
  for (const frame of frames) {
    const isWarmupFrame =
      packetContext.rawPacketWarmupToMs != null &&
      frame.timeMs <= packetContext.rawPacketWarmupToMs;
    const isBeforeWindow =
      packetContext.rawPacketTimeFromMs != null &&
      frame.timeMs < packetContext.rawPacketTimeFromMs;
    const isAfterWindow =
      packetContext.rawPacketTimeToMs != null &&
      frame.timeMs > packetContext.rawPacketTimeToMs;
    if (!isWarmupFrame && isBeforeWindow) {
      continue;
    }
    if (!isWarmupFrame && isAfterWindow) {
      continue;
    }
    for (const packet of frame.packets) {
      if (packetContext.rawPacketsScanned >= packetContext.rawPacketScanLimit) {
        packetContext.rawPacketScanLimitReached = true;
        return;
      }
      packetContext.rawPacketsScanned += 1;
      processRawPacket(packet.payload, frame.timeMs, packetContext);
      if (packetContext.rpcHitCount >= maxHits) return;
    }
  }
}

function processCompactPacket(packet, timeMs, packetContext) {
  const parsed = parseCompactReplayPacket(packet.payload, packetContext.frameContext.header);
  if (!parsed.ok && !parsed.bunches.length) {
    notePacketError(packetContext, `compact-packet:${parsed.error}`);
    return;
  }
  if (parsed.error) notePacketError(packetContext, `compact-packet:${parsed.error}`);

  packetContext.inPacketId += 1;
  for (const compactBunch of parsed.bunches) {
    const bunch = {
      timeMs,
      packetId: packetContext.inPacketId,
      archive: new BitReader(compactBunch.data, compactBunch.bunchDataBits),
      bOpen: compactBunch.bOpen,
      bClose: compactBunch.bClose,
      bDormant: compactBunch.closeReason === 1,
      closeReason: compactBunch.closeReason,
      bIsReplicationPaused: compactBunch.bIsReplicationPaused,
      bReliable: compactBunch.bReliable,
      chIndex: compactBunch.chIndex,
      chName: 'Actor',
      chType: 2,
      chSequence: packetContext.inPacketId,
      bHasPackageExportMaps: compactBunch.bHasPackageExportMaps,
      bHasMustBeMappedGUIDs: compactBunch.bHasMustBeMappedGUIDs,
      bPartial: compactBunch.bPartial,
      bPartialInitial: compactBunch.bPartialInitial,
      bPartialFinal: compactBunch.bPartialFinal,
    };

    if (bunch.bHasPackageExportMaps) receiveNetGuidBunch(bunch.archive, packetContext);
    if (bunch.bPartial) {
      const assembled = consumePartialBunch(bunch, packetContext);
      if (!assembled) continue;
      bunch.archive = assembled.archive;
      bunch.bPartial = false;
      bunch.bPartialInitial = false;
      bunch.bPartialFinal = false;
      bunch.bHasMustBeMappedGUIDs = assembled.bHasMustBeMappedGUIDs;
      bunch.bOpen = assembled.bOpen;
      bunch.bClose = assembled.bClose;
      bunch.bDormant = assembled.bDormant;
      bunch.closeReason = assembled.closeReason;
    }

    let channel = packetContext.channels[bunch.chIndex];
    if (!channel) {
      channel = { channelIndex: bunch.chIndex, channelName: bunch.chName, channelType: bunch.chType };
      packetContext.channels[bunch.chIndex] = channel;
    }
    processBunchPayload(bunch, packetContext);
    if (bunch.bClose) {
      noteUtilityActorClose(packetContext, bunch, channel);
      delete packetContext.channels[bunch.chIndex];
    }
  }
}

function captureCompactMovementRpcHits(frames, packetContext, maxHits = 250) {
  for (const frame of frames) {
    for (const packet of frame.packets) {
      processCompactPacket(packet, frame.timeMs, packetContext);
      if (packetContext.rpcHitCount >= maxHits) return;
    }
  }
}

function summarizeFrames(
  decompressedChunks,
  header,
  {
    rawPacketLimit = 0,
    rawPacketWarmupToMs = null,
    rawPacketTimeFromMs = null,
    rawPacketTimeToMs = null,
    rawFocusChannels = null,
    abilitySignalSampleLimit = DEFAULT_ABILITY_SIGNAL_SAMPLE_LIMIT,
    diagnosticActorNetGuids = null,
    diagnosticActorWireSampleLimit = DEFAULT_DIAGNOSTIC_ACTOR_WIRE_SAMPLE_LIMIT,
    abilityCastSignalSampleLimit = DEFAULT_ABILITY_CAST_SIGNAL_SAMPLE_LIMIT,
    inputEventCaptureSampleLimit = DEFAULT_INPUT_EVENT_CAPTURE_SAMPLE_LIMIT,
    nonMovementInputEventSampleLimit =
      DEFAULT_NON_MOVEMENT_INPUT_EVENT_SAMPLE_LIMIT,
    skipCompactDiagnostics = false,
  } = {},
) {
  const context = createFrameContext(header);
  const packetContext = createPacketContext(context);
  packetContext.rawPacketScanLimit = rawPacketLimit;
  packetContext.rawPacketWarmupToMs = rawPacketWarmupToMs;
  packetContext.rawPacketTimeFromMs = rawPacketTimeFromMs;
  packetContext.rawPacketTimeToMs = rawPacketTimeToMs;
  packetContext.rawFocusChannels = rawFocusChannels;
  packetContext.abilitySignalSampleLimit = abilitySignalSampleLimit;
  packetContext.diagnosticActorNetGuids = diagnosticActorNetGuids;
  packetContext.diagnosticActorWireSampleLimit = diagnosticActorWireSampleLimit;
  packetContext.abilityCastSignalSampleLimit = abilityCastSignalSampleLimit;
  packetContext.inputEventCaptureSampleLimit = inputEventCaptureSampleLimit;
  packetContext.nonMovementInputEventSampleLimit =
    nonMovementInputEventSampleLimit;
  const compactPacketContext = createPacketContext(context);
  compactPacketContext.abilitySignalSampleLimit = abilitySignalSampleLimit;
  compactPacketContext.diagnosticActorNetGuids = diagnosticActorNetGuids;
  compactPacketContext.diagnosticActorWireSampleLimit = diagnosticActorWireSampleLimit;
  compactPacketContext.abilityCastSignalSampleLimit = abilityCastSignalSampleLimit;
  compactPacketContext.inputEventCaptureSampleLimit = inputEventCaptureSampleLimit;
  compactPacketContext.nonMovementInputEventSampleLimit =
    nonMovementInputEventSampleLimit;
  const compactReplaySummary = createCompactReplaySummary();
  const chunks = [];
  let totalFrames = 0;
  const packetKinds = new Map();
  const externalSizes = new Map();
  const sampleFrames = [];

  for (const chunk of decompressedChunks) {
    profile(`chunk ${chunk.index}: parsing frames`);
    const frames = parseFramesInChunk(chunk, context);
    profile(`chunk ${chunk.index}: raw packet scan (${frames.length} frames)`);
    captureMovementRpcHits(frames, packetContext);
    if (!skipCompactDiagnostics) {
      profile(`chunk ${chunk.index}: compact packet scan`);
      captureCompactMovementRpcHits(frames, compactPacketContext);
      profile(`chunk ${chunk.index}: compact summary`);
      summarizeCompactReplayPackets(frames, header, compactReplaySummary);
    }
    profile(`chunk ${chunk.index}: aggregate samples`);
    for (let index = 0; index < frames.length; index += 1) {
      const frame = frames[index];
      totalFrames += 1;
      for (const packet of frame.packets) {
        const key = `${packet.kind}:stream-${packet.streamingFix}:size-${packet.size}`;
        packetKinds.set(key, (packetKinds.get(key) ?? 0) + 1);
      }
      for (const external of frame.external) {
        const size = external.externalDataNumBits / 8;
        externalSizes.set(size, (externalSizes.get(size) ?? 0) + 1);
      }
      if (sampleFrames.length < 12 && frame.packets.length) {
        sampleFrames.push({
          chunkIndex: chunk.index,
          offset: frame.offset,
          timeMs: frame.timeMs,
          length: frame.length,
          exportGroups: frame.exportGroups.slice(0, 6),
          externalSummary: frame.external.slice(0, 6).map((external) => ({
            netGuid: external.netGuid,
            handle: external.handle,
            bytes: external.externalDataNumBits / 8,
            firstBytes: external.payload.subarray(0, 24).toString('hex'),
          })),
          packetSummary: frame.packets.slice(0, 8).map((packet) => ({
            kind: packet.kind,
            size: packet.size,
            streamingFix: packet.streamingFix,
            firstBytes: packet.payload.subarray(0, 24).toString('hex'),
          })),
        });
      }
    }
    chunks.push({
      chunkIndex: chunk.index,
      startMs: chunk.startMs,
      endMs: chunk.endMs,
      decompressedSize: chunk.data.length,
      frameCount: frames.length,
      firstFrameMs: frames[0]?.timeMs ?? null,
      lastFrameMs: frames.at(-1)?.timeMs ?? null,
    });
  }

  const exportGroups = [...context.exportGroupsByPath.values()].map((group) => ({
    pathName: group.pathName,
    pathNameIndex: group.pathNameIndex,
    netFieldExportsLength: group.netFieldExportsLength,
    knownExports: group.netFieldExports
      .filter(Boolean)
      .slice(0, 12)
      .map((entry) => ({ handle: entry.handle, name: entry.name, type: entry.type ?? null })),
  }));

  return {
    totalFrames,
    chunks,
    exportGroupCount: exportGroups.length,
    exportGroups: exportGroups
      .filter((group) => /Replay|Character|PlayerController|Remote/i.test(group.pathName))
      .slice(0, 100),
    netGuidPathSamples: [...context.netGuidsToPath.entries()]
      .slice(0, 100)
      .map(([netGuid, pathName]) => ({ netGuid, pathName })),
    characterNetGuidPaths: [...context.netGuidsToPath.entries()]
      .filter(([, pathName]) => /\/Game\/Characters|PlayerState|ReplayController|BaseReplayController/i.test(pathName))
      .map(([netGuid, pathName]) => ({ netGuid, pathName }))
      .slice(0, 500),
    actorChannelOpenCount: packetContext.actorChannelOpenCount,
    channelOpenSamples: packetContext.channelOpenSamples,
    movementRpcHitCount: packetContext.rpcHitCount,
    movementRpcHits: packetContext.rpcHits.slice(0, 20),
    rawPacketsScanned: packetContext.rawPacketsScanned,
    rawPacketScanLimit: packetContext.rawPacketScanLimit,
    rawPacketWarmupToMs: packetContext.rawPacketWarmupToMs,
    rawPacketTimeFromMs: packetContext.rawPacketTimeFromMs,
    rawPacketTimeToMs: packetContext.rawPacketTimeToMs,
    rawFocusChannels: packetContext.rawFocusChannels
      ? [...packetContext.rawFocusChannels.values()]
      : null,
    rawPacketScanLimitReached: packetContext.rawPacketScanLimitReached,
    rawPacketScanSkipped: packetContext.rawPacketScanSkipped,
    valorantPayloadTransformSamples: packetContext.valorantPayloadTransformSamples,
    replayControllerPayloadSamples: packetContext.replayControllerPayloadSamples,
    classNetCacheSamples: packetContext.classNetCacheSamples,
    rpcCandidateSamples: packetContext.rpcCandidateSamples,
    classNetCacheFieldSummary: finalizeClassNetCacheFieldStats(
      packetContext.classNetCacheFieldStats,
      180,
    ),
    replayControllerClassNetCacheSamples: packetContext.replayControllerClassNetCacheSamples,
    replayControllerClassNetCacheFieldSummary: finalizeClassNetCacheFieldStats(
      packetContext.replayControllerClassNetCacheFieldStats,
      120,
    ),
    replayControllerVectorLaneSummary: finalizeReplayControllerVectorLanes(packetContext, 120),
    replayControllerTargetVectorLaneSummary: finalizeReplayControllerVectorLanes(
      packetContext,
      120,
      isTargetReplayControllerLane,
    ),
    replayControllerKnownGuidHits: packetContext.replayControllerKnownGuidHits,
    replayControllerCandidateFieldCapture: {
      handles: [...REPLAY_CONTROLLER_CANDIDATE_FIELD_HANDLES.values()].sort((a, b) => a - b),
      totalSampleLimit: REPLAY_CONTROLLER_CANDIDATE_FIELD_TOTAL_SAMPLE_LIMIT,
      perHandleSampleLimit: REPLAY_CONTROLLER_CANDIDATE_FIELD_PER_HANDLE_SAMPLE_LIMIT,
      genericPerHandleSampleLimit:
        REPLAY_CONTROLLER_CANDIDATE_FIELD_GENERIC_PER_HANDLE_SAMPLE_LIMIT,
      genericPayloadBitLimit: REPLAY_CONTROLLER_CANDIDATE_FIELD_GENERIC_PAYLOAD_BIT_LIMIT,
      payloadBitLimit: REPLAY_CONTROLLER_CANDIDATE_FIELD_PAYLOAD_BIT_LIMIT,
      targetFieldMinCaptureIntervalMs: REPLAY_CONTROLLER_TARGET_FIELD_MIN_CAPTURE_INTERVAL_MS,
      capturedCounts: topCounts(packetContext.replayControllerCandidateFieldSampleCounts, 80),
    },
    replayControllerCandidateFieldSamples: packetContext.replayControllerCandidateFieldSamples,
    replayControllerTargetPayloadSummary: finalizeReplayControllerTargetPayloads(
      packetContext,
      120,
    ),
    replayControllerTargetNativeRecordSummary: finalizeReplayControllerTargetNativeRecords(
      packetContext,
      160,
    ),
    replayControllerTargetNativeRecordSamples:
      packetContext.replayControllerTargetNativeRecordSamples,
    identityLinkSamples: packetContext.identityLinkSamples,
    abilitySignalSampleLimit: packetContext.abilitySignalSampleLimit,
    abilitySignalOverflowCount: packetContext.abilitySignalOverflowCount,
    abilitySignalSummary: summarizeAbilitySignalSamples(packetContext.abilitySignalSamples),
    abilitySignalSamples: packetContext.abilitySignalSamples,
    diagnosticActorWireCapture: {
      actorNetGuids: packetContext.diagnosticActorNetGuids
        ? [...packetContext.diagnosticActorNetGuids.values()].sort((a, b) => a - b)
        : [],
      sampleLimit: packetContext.diagnosticActorWireSampleLimit,
      sampleCount: packetContext.diagnosticActorWireSamples.length,
      overflowCount: packetContext.diagnosticActorWireOverflowCount,
    },
    diagnosticActorWireSamples: packetContext.diagnosticActorWireSamples,
    abilityCastSignalSampleLimit: packetContext.abilityCastSignalSampleLimit,
    abilityCastSignalSummary: summarizeAbilitySignalSamples(packetContext.abilityCastSignalSamples),
    abilityCastSignalSamples: packetContext.abilityCastSignalSamples,
    inputEventCaptureSampleLimit: packetContext.inputEventCaptureSampleLimit,
    inputEventCaptureSummary: summarizeAbilitySignalSamples(packetContext.inputEventCaptureSamples),
    inputEventCaptureSamples: packetContext.inputEventCaptureSamples,
    nonMovementInputEventSummary:
      summarizeNonMovementInputEvents(packetContext),
    nonMovementInputEventSamples:
      packetContext.nonMovementInputEventSamples,
    utilityActorSummary: summarizeUtilityActors(packetContext.utilityActorOpenSamples),
    utilityActorOpenSamples: packetContext.utilityActorOpenSamples,
    utilityActorCloseSamples: packetContext.utilityActorCloseSamples,
    packetParseErrors: [...packetContext.errors.entries()].map(([key, count]) => ({ key, count })),
    compactActorChannelOpenCount: compactPacketContext.actorChannelOpenCount,
    compactChannelOpenSamples: compactPacketContext.channelOpenSamples,
    compactMovementRpcHitCount: compactPacketContext.rpcHitCount,
    compactMovementRpcHits: compactPacketContext.rpcHits.slice(0, 20),
    compactValorantPayloadTransformSamples: compactPacketContext.valorantPayloadTransformSamples,
    compactReplayControllerPayloadSamples: compactPacketContext.replayControllerPayloadSamples,
    compactClassNetCacheSamples: compactPacketContext.classNetCacheSamples,
    compactClassNetCacheFieldSummary: finalizeClassNetCacheFieldStats(
      compactPacketContext.classNetCacheFieldStats,
      120,
    ),
    compactReplayControllerClassNetCacheFieldSummary: finalizeClassNetCacheFieldStats(
      compactPacketContext.replayControllerClassNetCacheFieldStats,
      80,
    ),
    compactReplayControllerVectorLaneSummary: finalizeReplayControllerVectorLanes(
      compactPacketContext,
      80,
    ),
    compactReplayControllerTargetVectorLaneSummary: finalizeReplayControllerVectorLanes(
      compactPacketContext,
      80,
      isTargetReplayControllerLane,
    ),
    compactRpcCandidateSamples: compactPacketContext.rpcCandidateSamples,
    compactReplicatorSamples: compactPacketContext.replicatorSamples,
    compactRepLayoutSamples: compactPacketContext.repLayoutSamples,
    compactIdentityLinkSamples: compactPacketContext.identityLinkSamples,
    compactAbilitySignalSampleLimit: compactPacketContext.abilitySignalSampleLimit,
    compactAbilitySignalOverflowCount:
      compactPacketContext.abilitySignalOverflowCount,
    compactAbilitySignalSummary: summarizeAbilitySignalSamples(
      compactPacketContext.abilitySignalSamples,
    ),
    compactAbilitySignalSamples: compactPacketContext.abilitySignalSamples,
    compactDiagnosticActorWireCapture: {
      actorNetGuids: compactPacketContext.diagnosticActorNetGuids
        ? [...compactPacketContext.diagnosticActorNetGuids.values()].sort((a, b) => a - b)
        : [],
      sampleLimit: compactPacketContext.diagnosticActorWireSampleLimit,
      sampleCount: compactPacketContext.diagnosticActorWireSamples.length,
      overflowCount: compactPacketContext.diagnosticActorWireOverflowCount,
    },
    compactDiagnosticActorWireSamples: compactPacketContext.diagnosticActorWireSamples,
    compactAbilityCastSignalSampleLimit: compactPacketContext.abilityCastSignalSampleLimit,
    compactAbilityCastSignalSummary: summarizeAbilitySignalSamples(
      compactPacketContext.abilityCastSignalSamples,
    ),
    compactAbilityCastSignalSamples: compactPacketContext.abilityCastSignalSamples,
    compactInputEventCaptureSampleLimit: compactPacketContext.inputEventCaptureSampleLimit,
    compactInputEventCaptureSummary: summarizeAbilitySignalSamples(
      compactPacketContext.inputEventCaptureSamples,
    ),
    compactInputEventCaptureSamples: compactPacketContext.inputEventCaptureSamples,
    compactNonMovementInputEventSummary:
      summarizeNonMovementInputEvents(compactPacketContext),
    compactNonMovementInputEventSamples:
      compactPacketContext.nonMovementInputEventSamples,
    compactUtilityActorSummary: summarizeUtilityActors(compactPacketContext.utilityActorOpenSamples),
    compactUtilityActorOpenSamples: compactPacketContext.utilityActorOpenSamples,
    compactUtilityActorCloseSamples: compactPacketContext.utilityActorCloseSamples,
    compactPacketParseErrors: [...compactPacketContext.errors.entries()]
      .map(([key, count]) => ({ key, count }))
      .sort((a, b) => b.count - a.count),
    compactReplaySummary: finalizeCompactReplaySummary(compactReplaySummary),
    packetKinds: [...packetKinds.entries()]
      .map(([key, count]) => ({ key, count }))
      .sort((a, b) => b.count - a.count),
    externalSizes: [...externalSizes.entries()]
      .map(([size, count]) => ({ size, count }))
      .sort((a, b) => b.count - a.count),
    sampleFrames,
  };
}

function buildPlayersFromHeader(header) {
  const loadoutEnvelope = header.jsonValues.find((value) =>
    Array.isArray(value?.playerLoadouts),
  );
  const loadouts = loadoutEnvelope?.playerLoadouts ?? [];
  return loadouts.map((loadout, index) => {
    const characterId = String(loadout.characterId ?? '').toLowerCase();
    const agent = agentNameFromCharacterId(characterId);
    const subject = String(loadout.subject ?? `player-${index + 1}`);
    const loadoutIndex = Number.isInteger(loadout.index) ? loadout.index : index;
    const initialSide = loadoutIndex < 5 ? 'defender' : 'attacker';
    return {
      id: subject,
      displayName: `${agent}-${index + 1}`,
      agent,
      initialSide,
      loadoutIndex,
      sideSource: 'header-playerLoadouts-order',
      teamColor: initialSide === 'defender' ? '#3A7E5D' : '#772727',
      samples: [],
    };
  });
}

function extractHeaderPlayerLoadouts(header) {
  const loadoutEnvelope = header.jsonValues.find((value) =>
    Array.isArray(value?.playerLoadouts),
  );
  const loadouts = loadoutEnvelope?.playerLoadouts ?? [];
  return loadouts.map((loadout, index) => {
    const characterId = String(loadout.characterId ?? '').toLowerCase();
    const loadoutIndex = Number.isInteger(loadout.index) ? loadout.index : index;
    return {
      index: loadoutIndex,
      subject: loadout.subject ?? null,
      characterId: characterId || null,
      agent: agentNameFromCharacterId(characterId),
      initialSide: loadoutIndex < 5 ? 'defender' : 'attacker',
      sideSource: 'header-playerLoadouts-order',
      teamId: loadout.teamId ?? loadout.teamID ?? null,
      playerCardId: loadout.playerCardId ?? loadout.playerCard ?? null,
      playerTitleId: loadout.playerTitleId ?? loadout.playerTitle ?? null,
      competitiveTier: loadout.competitiveTier ?? null,
    };
  });
}

function parseArgs(argv) {
  const options = {
    input: null,
    out: null,
    diagnostics: null,
    dumpPackets: false,
    rawPacketLimit: 0,
    rawPacketWarmupToMs: null,
    rawPacketTimeFromMs: null,
    rawPacketTimeToMs: null,
    rawFocusChannels: null,
    abilitySignalSampleLimit: DEFAULT_ABILITY_SIGNAL_SAMPLE_LIMIT,
    diagnosticActorNetGuids: null,
    diagnosticActorWireSampleLimit: DEFAULT_DIAGNOSTIC_ACTOR_WIRE_SAMPLE_LIMIT,
    abilityCastSignalSampleLimit: DEFAULT_ABILITY_CAST_SIGNAL_SAMPLE_LIMIT,
    inputEventCaptureSampleLimit: DEFAULT_INPUT_EVENT_CAPTURE_SAMPLE_LIMIT,
    diagnosticsOnly: false,
    skipCompactDiagnostics: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--out') {
      options.out = argv[++i];
    } else if (arg === '--diagnostics') {
      options.diagnostics = argv[++i];
    } else if (arg === '--dump-packets') {
      options.dumpPackets = true;
    } else if (arg === '--raw-packet-limit') {
      options.rawPacketLimit = Number(argv[++i] ?? 0);
    } else if (arg === '--raw-warmup-to-ms') {
      options.rawPacketWarmupToMs = Number(argv[++i] ?? 0);
    } else if (arg === '--raw-time-from-ms') {
      options.rawPacketTimeFromMs = Number(argv[++i] ?? 0);
    } else if (arg === '--raw-time-to-ms') {
      options.rawPacketTimeToMs = Number(argv[++i] ?? 0);
    } else if (arg === '--raw-focus-channel') {
      options.rawFocusChannels ??= new Set();
      options.rawFocusChannels.add(Number(argv[++i] ?? -1));
    } else if (arg === '--ability-signal-sample-limit') {
      options.abilitySignalSampleLimit = Number(argv[++i] ?? DEFAULT_ABILITY_SIGNAL_SAMPLE_LIMIT);
    } else if (arg === '--diagnostic-actor-net-guid') {
      options.diagnosticActorNetGuids ??= new Set();
      options.diagnosticActorNetGuids.add(Number(argv[++i] ?? -1));
    } else if (arg === '--diagnostic-actor-wire-sample-limit') {
      options.diagnosticActorWireSampleLimit = Number(
        argv[++i] ?? DEFAULT_DIAGNOSTIC_ACTOR_WIRE_SAMPLE_LIMIT,
      );
    } else if (arg === '--ability-cast-signal-sample-limit') {
      options.abilityCastSignalSampleLimit = Number(
        argv[++i] ?? DEFAULT_ABILITY_CAST_SIGNAL_SAMPLE_LIMIT,
      );
    } else if (arg === '--input-event-capture-sample-limit') {
      options.inputEventCaptureSampleLimit = Number(
        argv[++i] ?? DEFAULT_INPUT_EVENT_CAPTURE_SAMPLE_LIMIT,
      );
    } else if (arg === '--non-movement-input-event-sample-limit') {
      options.nonMovementInputEventSampleLimit = Number(
        argv[++i] ?? DEFAULT_NON_MOVEMENT_INPUT_EVENT_SAMPLE_LIMIT,
      );
    } else if (arg === '--diagnostics-only') {
      options.diagnosticsOnly = true;
    } else if (arg === '--skip-compact-diagnostics') {
      options.skipCompactDiagnostics = true;
    } else {
      options.input = arg;
    }
  }
  return options;
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function resolveUserPath(value) {
  if (value == null) return null;
  if (path.isAbsolute(value)) return value;
  return path.resolve(process.env.INIT_CWD ?? process.cwd(), value);
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const inputPath = resolveUserPath(options.input) ?? findLatestReplayFile();
  const outPath =
    resolveUserPath(options.out) ??
    path.join(process.env.INIT_CWD ?? process.cwd(), `${path.basename(inputPath, '.vrf')}.track.json`);
  const diagnosticsPath =
    resolveUserPath(options.diagnostics) ??
    outPath.replace(/\.json$/i, '.diagnostics.json');

  profile('reading replay file');
  const buffer = fs.readFileSync(inputPath);
  profile('parsing wrapper/chunks/header');
  const wrapper = parseWrapper(buffer);
  const chunks = parseChunks(buffer, wrapper.streamOffset);
  const headerChunk = chunks.find((chunk) => chunk.type === 0);
  if (!headerChunk) throw new Error('Replay has no header chunk');
  const header = parseHeader(buffer, headerChunk);
  const replayData = chunks
    .filter((chunk) => chunk.type === 1)
    .map((chunk) => parseReplayDataEnvelope(buffer, chunk));
  const events = chunks
    .filter((chunk) => chunk.type === 3)
    .map((chunk) => parseTimelineChunk(buffer, chunk));
  const timelineDiagnostics = buildTimelineDiagnostics(events);
  profile('decompressing replay data');
  const decompressed = await decompressReplayData(buffer, replayData);
  profile('summarizing frames');
  const frameSummary = summarizeFrames(decompressed, header, {
    rawPacketLimit: options.rawPacketLimit,
    rawPacketWarmupToMs: options.rawPacketWarmupToMs,
    rawPacketTimeFromMs: options.rawPacketTimeFromMs,
    rawPacketTimeToMs: options.rawPacketTimeToMs,
    rawFocusChannels: options.rawFocusChannels,
    abilitySignalSampleLimit: options.abilitySignalSampleLimit,
    diagnosticActorNetGuids: options.diagnosticActorNetGuids,
    diagnosticActorWireSampleLimit: options.diagnosticActorWireSampleLimit,
    abilityCastSignalSampleLimit: options.abilityCastSignalSampleLimit,
    inputEventCaptureSampleLimit: options.inputEventCaptureSampleLimit,
    nonMovementInputEventSampleLimit:
      options.nonMovementInputEventSampleLimit,
    skipCompactDiagnostics: options.skipCompactDiagnostics,
  });
  profile('extracting heuristic component samples');
  const componentVectorSamples = options.diagnosticsOnly
    ? []
    : extractHeuristicComponentVectorSamples(decompressed, header);
  profile('building candidate entity tracks');
  const candidateEntityTracks = options.diagnosticsOnly
    ? []
    : buildCandidateEntityTracks(decompressed, header);
  profile('building confirmed actor-open tracks');
  const confirmedActorOpenTracks = buildConfirmedActorOpenTracks(frameSummary, header);
  const rawUtilityActors = frameSummary.utilityActorOpenSamples ?? [];
  const compactUtilityActors = frameSummary.compactUtilityActorOpenSamples ?? [];
  const utilityActors = rawUtilityActors.length >= compactUtilityActors.length
    ? rawUtilityActors
    : compactUtilityActors;
  annotateUtilityActorEndReasons(
    utilityActors,
    timelineDiagnostics.roundStartEvents,
    {
      observationEndMs: replayData.at(-1)?.endMs ?? null,
      observationComplete:
        utilityActors === rawUtilityActors &&
        Number.isFinite(frameSummary.rawPacketScanLimit) &&
        frameSummary.rawPacketScanLimit > 0 &&
        frameSummary.rawPacketScanLimitReached === false &&
        frameSummary.rawPacketScanSkipped === false &&
        frameSummary.rawPacketTimeToMs == null,
    },
  );
  classifyUtilityActorCloses({
    utilityActors,
    abilitySignals: [
      ...(frameSummary.abilitySignalSamples ?? []),
      ...(frameSummary.compactAbilitySignalSamples ?? []),
    ],
    roundStartEvents: timelineDiagnostics.roundStartEvents,
    deathEvents: timelineDiagnostics.deathEvents,
  });
  const rawAbilityCastSamples = frameSummary.abilityCastSignalSamples?.length
    ? frameSummary.abilityCastSignalSamples
    : frameSummary.abilitySignalSamples;
  const compactAbilityCastSamples = frameSummary.compactAbilityCastSignalSamples?.length
    ? frameSummary.compactAbilityCastSignalSamples
    : frameSummary.compactAbilitySignalSamples;
  const abilityCasts = abilityCastsFromAbilitySignalSamples([
    ...(rawAbilityCastSamples ?? []),
    ...(compactAbilityCastSamples ?? []),
  ], [
    ...(frameSummary.abilitySignalSamples ?? []),
    ...(frameSummary.compactAbilitySignalSamples ?? []),
  ], timelineDiagnostics.roundStartEvents);
  const players = candidateEntityTracks.length
    ? [...confirmedActorOpenTracks, ...candidateEntityTracks]
    : componentVectorSamples.length
      ? [
          ...confirmedActorOpenTracks,
          {
            id: 'vrf-component-stream',
            displayName: 'VRF component stream',
            agent: 'Unknown',
            teamColor: '#69F0AF',
            kind: 'candidate-stream-entity',
            sourceTag: 'legacy-best-component-vector',
            confidence: 'single-blended-stream',
            samples: componentVectorSamples.map(
              ({
                timeMs,
                x,
                y,
                z,
                yawDegrees,
              }) => ({
                timeMs,
                x,
                y,
                z,
                yawDegrees,
              }),
            ),
          },
        ]
      : confirmedActorOpenTracks.length
        ? confirmedActorOpenTracks
      : buildPlayersFromHeader(header);

  const track = {
    abilitySchemaVersion: 3,
    sourceLabel: `VRF extraction: ${path.basename(inputPath)}`,
    coordinateSpace: 'game',
    mapId: header.mapPath,
    durationMs: replayData.at(-1)?.endMs ?? 0,
    notes:
      candidateEntityTracks.length
        ? 'Actual .vrf data decoded from Oodle replay chunks. Tracks are candidate entities grouped by GUID-adjacent fields or repeated stream signatures. Use the one-minute review graph and map trails to classify which tracks are players, abilities, or false positives.'
        : componentVectorSamples.length
          ? 'Actual .vrf data decoded from Oodle replay chunks and compact channel-2 component streams. This first extractor pass uses a conservative packed-vector heuristic; player identity and exact view yaw are not fully resolved yet.'
        : 'VRF metadata was parsed, replay chunks were decompressed, and frame packets were isolated. Continuous player movement is not emitted yet because the Valorant replay-controller RPC payload still needs field-level decoding.',
    players,
    utilityActors,
    deathEvents: timelineDiagnostics.deathEvents,
    roundStartEvents: timelineDiagnostics.roundStartEvents,
    sideSwitchEvents: timelineDiagnostics.sideSwitchEvents,
    ultimateEvents: timelineDiagnostics.ultimateEvents,
  };
  track.abilityCasts = abilityCasts;

  const diagnostics = {
    status: 'raw-replay-capture-complete',
    inputPath,
    outPath,
    wrapper,
    header: {
      magic: header.magic,
      networkVersion: header.networkVersion,
      networkChecksum: header.networkChecksum,
      engineNetworkVersion: header.engineNetworkVersion,
      gameNetworkProtocolVersion: header.gameNetworkProtocolVersion,
      flags: header.flags,
      parseFlags: header.parseFlags,
      mapPath: header.mapPath,
      branch: header.branch,
      playerCount: track.players.length,
      headerPlayerLoadouts: extractHeaderPlayerLoadouts(header),
    },
    staticDecoderIndex: loadStaticDecoderIndexes().summary,
    extractedComponentVectorSampleCount: componentVectorSamples.length,
    extractedComponentVectorSamples: componentVectorSamples.slice(0, 80),
    confirmedActorOpenTrackCount: confirmedActorOpenTracks.length,
    confirmedActorOpenTrackSummary: confirmedActorOpenTracks,
    candidateEntityTrackCount: candidateEntityTracks.length,
    candidateEntityTrackSummary: candidateEntityTracks.slice(0, 80).map((track) => ({
      id: track.id,
      displayName: track.displayName,
      kind: track.kind,
      confidence: track.confidence,
      sourceTag: track.sourceTag,
      sampleCount: track.samples.length,
      firstTimeMs: track.samples[0]?.timeMs ?? null,
      lastTimeMs: track.samples.at(-1)?.timeMs ?? null,
      firstSamples: track.samples.slice(0, 4),
    })),
    abilityCastCount: abilityCasts.length,
    abilityCastSummary: summarizeAbilityCasts(abilityCasts),
    utilityActorCount: utilityActors.length,
    utilityActorSummary: summarizeUtilityActors(utilityActors),
    abilitySignalSummary: frameSummary.abilitySignalSummary,
    inputEventCaptureSummary: frameSummary.inputEventCaptureSummary,
    deathEventCount: timelineDiagnostics.deathEvents.length,
    deathEvents: timelineDiagnostics.deathEvents,
    roundStartEvents: timelineDiagnostics.roundStartEvents,
    sideSwitchEvents: timelineDiagnostics.sideSwitchEvents,
    ultimateEvents: timelineDiagnostics.ultimateEvents,
    chunkCount: chunks.length,
    replayDataChunks: replayData.map((chunk) => ({
      index: chunk.index,
      startMs: chunk.startMs,
      endMs: chunk.endMs,
      compressedSize: chunk.compressedSize,
      decompressedSize: chunk.decompressedSize,
    })),
    eventCounts: timelineDiagnostics.eventCounts,
    frameSummary,
    nextDecoderTarget:
      '/Script/ShooterGame.ReplayPlayerController:ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous',
  };

  writeJson(diagnosticsPath, diagnostics);

  if (options.diagnosticsOnly) {
    console.log(`wrote diagnostics ${diagnosticsPath}`);
    return;
  }

  if (options.dumpPackets) {
    const packetDir = diagnosticsPath.replace(/\.json$/i, '_packets');
    const assemblyDir = diagnosticsPath.replace(/\.json$/i, '_assemblies');
    fs.mkdirSync(packetDir, { recursive: true });
    fs.mkdirSync(assemblyDir, { recursive: true });
    const dumpContext = createFrameContext(header);
    const interestingSizes = new Set([22, 36, 132, 133, 520, 524, 525, 615]);
    let written = 0;
    let assembliesWritten = 0;
    const openPartials = new Map();
    for (const chunk of decompressed) {
      const frames = parseFramesInChunk(chunk, dumpContext);
      for (let index = 0; index < frames.length && written < 240; index += 1) {
        const frame = frames[index];
        if (frame.timeMs < 0) continue;
        for (let packetIndex = 0; packetIndex < frame.packets.length && written < 240; packetIndex += 1) {
          const packet = frame.packets[packetIndex];
          if (!interestingSizes.has(packet.size)) continue;
          fs.writeFileSync(
            path.join(
              packetDir,
              `chunk${chunk.index}_frame${index}_t${frame.timeMs}_${packetIndex}_${packet.kind}_${packet.size}_${packet.streamingFix}.bin`,
            ),
            packet.payload,
          );
          written += 1;
        }
      }
      for (let index = 0; index < frames.length && assembliesWritten < 1000; index += 1) {
        const frame = frames[index];
        for (let packetIndex = 0; packetIndex < frame.packets.length && assembliesWritten < 120; packetIndex += 1) {
          const parsed = parseCompactReplayPacket(frame.packets[packetIndex].payload, dumpContext.header);
          for (const bunch of parsed.bunches) {
            if (bunch.chIndex !== 2) continue;
            if (!bunch.bPartial) {
              if (frame.timeMs < 0) continue;
              const name = `assembly${assembliesWritten}_t${frame.timeMs}_whole_bits${bunch.bunchDataBits}`;
              fs.writeFileSync(path.join(assemblyDir, `${name}.bin`), bunch.data);
              writeJson(path.join(assemblyDir, `${name}.json`), {
                timeMs: frame.timeMs,
                source: 'whole',
                bitCount: bunch.bunchDataBits,
                firstBytes: bunch.data.subarray(0, 96).toString('hex'),
              });
              assembliesWritten += 1;
              continue;
            }

            if (bunch.bPartialInitial || !openPartials.has(bunch.chIndex)) {
              openPartials.set(bunch.chIndex, { startMs: frame.timeMs, parts: [] });
            }
            const partial = openPartials.get(bunch.chIndex);
            partial.parts.push({ buffer: bunch.data, bitCount: bunch.bunchDataBits });
            if (!bunch.bPartialFinal) continue;

            const assembled = appendBitParts(partial.parts);
            openPartials.delete(bunch.chIndex);
            if (frame.timeMs < 0) continue;
            const name = `assembly${assembliesWritten}_t${partial.startMs}-${frame.timeMs}_partial_parts${partial.parts.length}_bits${assembled.bitCount}`;
            fs.writeFileSync(path.join(assemblyDir, `${name}.bin`), assembled.buffer);
            writeJson(path.join(assemblyDir, `${name}.json`), {
              startMs: partial.startMs,
              endMs: frame.timeMs,
              source: 'partial',
              partCount: partial.parts.length,
              bitCount: assembled.bitCount,
              firstBytes: assembled.buffer.subarray(0, 96).toString('hex'),
            });
            assembliesWritten += 1;
          }
        }
      }
    }
  }

  const hasSamples = track.players.some((player) => player.samples.length > 0);
  if (!hasSamples) {
    console.error(
      `Parsed VRF metadata and frame packets, but did not emit ${outPath} because movement decoding is not complete.`,
    );
    console.error(`Diagnostics written to ${diagnosticsPath}`);
    process.exitCode = 2;
    return;
  }

  writeJson(outPath, track);
  console.log(`wrote ${outPath}`);
}

const invokedAsScript =
  process.argv[1] != null &&
  path.resolve(process.argv[1]).toLowerCase() ===
    path.resolve(fileURLToPath(import.meta.url)).toLowerCase();

if (invokedAsScript) {
  main().catch((error) => {
    console.error(error.stack || error.message);
    process.exitCode = 1;
  });
}

export {
  annotateUtilityActorEndReasons,
  applyObservedUtilityActorClose,
  classifyUtilityActorArchetype,
  decodeCharacterUltimateUsedPayload,
  decodeInputEventCaptureFields,
  loadVerifiedAbilityLifecycleRegistry,
  noteUtilityActorClose,
  noteUtilityActorOpen,
  parseCharacterAbilityCastScalarFields,
  parseCharacterAbilityEffects,
  verifiedUtilityActorLifecycleRule,
};
