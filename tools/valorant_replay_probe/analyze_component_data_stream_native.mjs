#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  classifyUtilityActorCloses,
  decorateAbilityActionsWithLifecycle,
} from './lib/close_signature_classifier.mjs';

const TARGET_FUNCTION_NAME = 'ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous';
const TOOL_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(TOOL_DIR, '..', '..');
const GENERATED_DECODER_INDEX_DIR = path.join(
  REPO_ROOT,
  'tmp',
  'valorant_export_research',
  'indexes',
);
const BUNDLED_DECODER_INDEX_DIR = path.join(TOOL_DIR, 'static_decoder_indexes');
const STATIC_DECODER_INDEX_DIR = (() => {
  if (process.env.VALORANT_DECODER_INDEX_DIR) {
    return path.resolve(process.env.VALORANT_DECODER_INDEX_DIR);
  }
  if (fs.existsSync(path.join(GENERATED_DECODER_INDEX_DIR, 'ability_identity_index.json'))) {
    return GENERATED_DECODER_INDEX_DIR;
  }
  return BUNDLED_DECODER_INDEX_DIR;
})();
const MOVEMENT_MAGIC = 0x52;
const MAX_MOVEMENT_PADDING_BITS = 31;
const ABILITY_CAST_PAYLOAD_HEX_LIMIT = 192;
const ABILITY_SIGNAL_PAYLOAD_HEX_LIMIT = 512;
const ABILITY_CAST_UUID_PATTERN =
  /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;

const ARES_ITEM_SLOT_TO_ABILITY_SLOT = new Map([
  [3, 'Grenade'],
  [4, 'Ability1'],
  [5, 'Ability2'],
  // EAresItemSlot 6 is Passive in the local replay schema; ultimates are 9.
  [9, 'Ultimate'],
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

// /Script/ShooterGame.ECharacterAbilityStatisticList in the release-13.00
// replay schema. Numeric values are replay data; these names are schema
// labels, not gameplay guesses.
const ABILITY_STATISTIC_NAMES = [
  'EnemiesBlinded',
  'DamageDone',
  'EnemiesKilled',
  'KillAssists',
  'EnemiesConcussed',
  'EnemiesDisplaced',
  'EnemiesRevealed',
  'EnemiesBlocked',
  'EnemiesNearsighted',
  'HealingDone',
  'AlliesStimmed',
  'KillsAfterTeleport',
  'EnemiesSlowed',
  'DamageSoaked',
  'BoostKills',
  'EnemiesSpotted',
  'EnemiesVulnerabled',
  'AlliesBlinded',
  'EnemiesDetained',
  'EnemiesSuppressed',
  'ItemsRecalled',
  'ConditionsMet',
  'TeleportedTo',
  'TeleportedFrom',
  'ItemsDestroyed',
  'ShotsFired',
  'Telemetry',
  'TimeSprinting',
  'SlideStart',
  'SlideEnd',
  'AlliesDowned',
  'AlliesRevived',
  'InteractedWith',
  'Activated',
  'DistanceTraveled',
  'EnemiesMarked',
  'EnemiesSeized',
  'TelemetryMode',
  'Lifetime',
  'WasTempCharge',
  'PrimarySuccess',
  'SecondarySuccess',
  'DistanceFromSpawn',
  'DefuseAttempts',
  'PlantAttempts',
  'AttackMode',
  'FinalHealth',
  'Primary',
  'Secondary',
  'DebuffDuration',
  'AlliesConcussed',
  'AlliesSeized',
  'TimeSpotted',
  'AlliesMarked',
  'AlliesKilled',
  'AlliesSpotted',
  'AlliesSlowed',
  'EnemiesJammed',
  'KilledWhileDisarmed',
  'KillsWhileDisarmed',
  'HasLineOfSight',
  'UtilsDamaged',
  'UtilsDestroyed',
  'DamageDoneToUtils',
  'TargetKills',
  'DebuffResisted',
  'InitialAffectedRoundTime',
  'AlliesHealed',
  'EnemiesHealed',
  'StimDuration',
  'StimRefresh',
  'KilledWhileStimmed',
  'AlliesSaved',
];

const ABILITY_KEY_TO_SLOT = new Map([
  ['4', { abilitySlot: 'Grenade', abilityIndex: 0 }],
  ['c', { abilitySlot: 'Grenade', abilityIndex: 0 }],
  ['q', { abilitySlot: 'Ability1', abilityIndex: 1 }],
  ['e', { abilitySlot: 'Ability2', abilityIndex: 2 }],
  ['x', { abilitySlot: 'Ultimate', abilityIndex: 3 }],
]);

function abilityIndexFromAresItemSlot(value) {
  switch (ARES_ITEM_SLOT_TO_ABILITY_SLOT.get(value)) {
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

const TARGET_RPC_FIELDS = new Map([
  [0, 'bIsReplayFastForwardImportant'],
  [1, 'RemoteCharacterUpdates'],
  [2, 'ShooterCharacterNetGuidValue'],
  [3, 'ComponentDataStream'],
]);

const DEFAULT_POSITION_BOUNDS = {
  minPercent: -0.08,
  maxPercent: 1.08,
  minZ: -500,
  maxZ: 1200,
};

const MAP_VECTOR_BOUNDS = new Map([
  [
    'ascent',
    {
      ...DEFAULT_POSITION_BOUNDS,
      xMultiplier: 0.00007,
      yMultiplier: -0.00007,
      xScalarToAdd: 0.813895,
      yScalarToAdd: 0.573242,
    },
  ],
  [
    'bind',
    {
      ...DEFAULT_POSITION_BOUNDS,
      xMultiplier: 0.000078,
      yMultiplier: -0.000078,
      xScalarToAdd: 0.842188,
      yScalarToAdd: 0.697578,
    },
  ],
  [
    'breeze',
    {
      ...DEFAULT_POSITION_BOUNDS,
      xMultiplier: 0.00007,
      yMultiplier: -0.00007,
      xScalarToAdd: 0.465123,
      yScalarToAdd: 0.833078,
    },
  ],
  [
    'fracture',
    {
      ...DEFAULT_POSITION_BOUNDS,
      xMultiplier: 0.000078,
      yMultiplier: -0.000078,
      xScalarToAdd: 0.556952,
      yScalarToAdd: 1.155886,
    },
  ],
  [
    'split',
    {
      ...DEFAULT_POSITION_BOUNDS,
      xMultiplier: 0.000059,
      yMultiplier: -0.000059,
      xScalarToAdd: 0.576941,
      yScalarToAdd: 0.967566,
    },
  ],
  [
    'icebox',
    {
      ...DEFAULT_POSITION_BOUNDS,
      xMultiplier: 0.000072,
      yMultiplier: -0.000072,
      xScalarToAdd: 0.460214,
      yScalarToAdd: 0.304687,
    },
  ],
  [
    'lotus',
    {
      ...DEFAULT_POSITION_BOUNDS,
      xMultiplier: 0.000072,
      yMultiplier: -0.000072,
      xScalarToAdd: 0.454789,
      yScalarToAdd: 0.917752,
    },
  ],
  [
    'sunset',
    {
      ...DEFAULT_POSITION_BOUNDS,
      xMultiplier: 0.000078,
      yMultiplier: -0.000078,
      xScalarToAdd: 0.5,
      yScalarToAdd: 0.515625,
    },
  ],
  [
    'pearl',
    {
      ...DEFAULT_POSITION_BOUNDS,
      xMultiplier: 0.000078,
      yMultiplier: -0.000078,
      xScalarToAdd: 0.480469,
      yScalarToAdd: 0.916016,
    },
  ],
  [
    'abyss',
    {
      ...DEFAULT_POSITION_BOUNDS,
      xMultiplier: 0.000081,
      yMultiplier: -0.000081,
      xScalarToAdd: 0.5,
      yScalarToAdd: 0.5,
    },
  ],
  [
    'corrode',
    {
      ...DEFAULT_POSITION_BOUNDS,
      xMultiplier: 0.00007,
      yMultiplier: -0.00007,
      xScalarToAdd: 0.526158,
      yScalarToAdd: 0.5,
    },
  ],
  [
    'haven',
    {
      ...DEFAULT_POSITION_BOUNDS,
      xMultiplier: 0.000075,
      yMultiplier: -0.000075,
      xScalarToAdd: 1.09345,
      yScalarToAdd: 0.642728,
    },
  ],
]);

const MAP_PATH_TOKENS = [
  ['ascent', 'ascent'],
  ['bonsai', 'split'],
  ['bind', 'bind'],
  ['foxtrot', 'breeze'],
  ['breeze', 'breeze'],
  ['canyon', 'fracture'],
  ['fracture', 'fracture'],
  ['duality', 'bind'],
  ['split', 'split'],
  ['port', 'icebox'],
  ['icebox', 'icebox'],
  ['jam', 'lotus'],
  ['lotus', 'lotus'],
  ['juliett', 'sunset'],
  ['sunset', 'sunset'],
  ['pitt', 'pearl'],
  ['pearl', 'pearl'],
  ['infinity', 'abyss'],
  ['plummet', 'summit'],
  ['abyss', 'abyss'],
  ['rook', 'corrode'],
  ['corrode', 'corrode'],
  ['triad', 'haven'],
  ['haven', 'haven'],
];

function parseArgs(argv) {
  const options = {
    diagnostics: null,
    out: null,
    samplesOut: null,
    trackOut: null,
    maxExamples: 24,
    maxSamples: 10_000,
    trackMinSampleIntervalMs: 50,
    includeSamplesInReport: true,
    minPositionComponentBits: 7,
    requireMapPlausiblePosition: true,
    includeUnknownReplayControllerFields: false,
    unknownReplayControllerFieldHandles: null,
    minUnknownReplayControllerPayloadBits: 512,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--samples-out') options.samplesOut = argv[++index];
    else if (arg === '--track-out') options.trackOut = argv[++index];
    else if (arg === '--max-examples') options.maxExamples = Number(argv[++index]);
    else if (arg === '--max-samples') options.maxSamples = Number(argv[++index]);
    else if (arg === '--track-min-sample-interval-ms') {
      options.trackMinSampleIntervalMs = Number(argv[++index]);
    }
    else if (arg === '--omit-samples-in-report') options.includeSamplesInReport = false;
    else if (arg === '--min-position-component-bits') {
      options.minPositionComponentBits = Number(argv[++index]);
    } else if (arg === '--allow-off-map-position') {
      options.requireMapPlausiblePosition = false;
    } else if (arg === '--include-unknown-replay-controller-fields') {
      options.includeUnknownReplayControllerFields = true;
    } else if (arg === '--unknown-replay-controller-field-handles') {
      options.unknownReplayControllerFieldHandles = new Set(
        String(argv[++index] ?? '')
          .split(',')
          .map((value) => Number(value.trim()))
          .filter(Number.isInteger),
      );
    } else if (arg === '--min-unknown-replay-controller-payload-bits') {
      options.minUnknownReplayControllerPayloadBits = Number(argv[++index]);
    }
  }

  return options;
}

function resolveUserPath(value) {
  if (!value) return null;
  if (path.isAbsolute(value)) return value;
  return path.resolve(process.env.INIT_CWD ?? process.cwd(), value);
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function round(value, digits = 3) {
  if (value == null || !Number.isFinite(value)) return null;
  return Number(value.toFixed(digits));
}

function normalizeHexToFullBytes(hex) {
  if (typeof hex !== 'string') return '';
  return hex.length % 2 === 0 ? hex : `${hex}0`;
}

function readBit(buffer, bitOffset) {
  return (buffer[bitOffset >> 3] >> (bitOffset & 7)) & 1;
}

function readBitsUnsignedAt(buffer, bitLimit, bitOffset, bitCount) {
  if (bitOffset < 0 || bitOffset + bitCount > bitLimit) return null;
  let value = 0;
  let bitValue = 1;
  for (let bit = 0; bit < bitCount; bit += 1) {
    if (readBit(buffer, bitOffset + bit)) value += bitValue;
    bitValue *= 2;
  }
  return value;
}

function copyBits(buffer, sourceBitOffset, bitCount) {
  const result = Buffer.alloc(Math.ceil(bitCount / 8));
  for (let bit = 0; bit < bitCount; bit += 1) {
    if (readBit(buffer, sourceBitOffset + bit)) result[bit >> 3] |= 1 << (bit & 7);
  }
  return result;
}

function bitsToHex(buffer, bitOffset, bitCount) {
  if (bitCount <= 0) return '';
  return copyBits(buffer, bitOffset, bitCount).toString('hex');
}

function increment(map, key, amount = 1) {
  map.set(key, (map.get(key) ?? 0) + amount);
}

function topCounts(valuesOrMap, limit = 16) {
  const map = valuesOrMap instanceof Map ? valuesOrMap : new Map();
  if (!(valuesOrMap instanceof Map)) {
    for (const value of valuesOrMap) increment(map, value);
  }
  return [...map.entries()]
    .map(([key, count]) => ({ key, count }))
    .sort((a, b) => b.count - a.count || String(a.key).localeCompare(String(b.key)))
    .slice(0, limit);
}

const TRACK_COLORS = [
  '#69F0AF',
  '#3A7E5D',
  '#4ADE80',
  '#22C55E',
  '#84CC16',
  '#FF5252',
  '#EF4444',
  '#F97316',
  '#F43F5E',
  '#C084FC',
];
const DEFENDER_TEAM_COLOR = '#3A7E5D';
const ATTACKER_TEAM_COLOR = '#772727';

const ARCHETYPE_AGENT_NAMES = new Map([
  ['aggrobot', 'Gekko'],
  ['astra', 'Astra'],
  ['bountyhunter', 'Fade'],
  ['breach', 'Breach'],
  ['cable', 'Deadlock'],
  ['cashew', 'Tejo'],
  ['clay', 'Raze'],
  ['deadeye', 'Chamber'],
  ['grenadier', 'KAY/O'],
  ['guide', 'Skye'],
  ['gumshoe', 'Cypher'],
  ['harbor', 'Harbor'],
  ['hunter', 'Sova'],
  ['iris', 'Miks'],
  ['jett', 'Jett'],
  ['killjoy', 'Killjoy'],
  ['mage', 'Harbor'],
  ['miks', 'Miks'],
  ['nox', 'Vyse'],
  ['pandemic', 'Viper'],
  ['phoenix', 'Phoenix'],
  ['pine', 'Veto'],
  ['raze', 'Raze'],
  ['rift', 'Astra'],
  ['sage', 'Sage'],
  ['sarge', 'Brimstone'],
  ['sequoia', 'Iso'],
  ['smonk', 'Clove'],
  ['sprinter', 'Neon'],
  ['stealth', 'Yoru'],
  ['terra', 'Waylay'],
  ['thorne', 'Sage'],
  ['vampire', 'Reyna'],
  ['viper', 'Viper'],
  ['wraith', 'Omen'],
  ['wushu', 'Jett'],
  ['yoru', 'Yoru'],
]);

function archetypeToken(archetypePath) {
  return String(archetypePath ?? '')
    .split('/')
    .at(-1)
    .split('.')
    .at(-1)
    .replace(/^Default__/i, '')
    .replace(/_PC_C$/i, '')
    .toLowerCase();
}

function agentNameFromArchetype(archetypePath) {
  const token = archetypeToken(archetypePath);
  if (!token) return 'Unknown';
  return ARCHETYPE_AGENT_NAMES.get(token) ?? token.replace(/(^|_)([a-z])/g, (_, prefix, ch) => `${prefix ? ' ' : ''}${ch.toUpperCase()}`);
}

function normalizedAgentName(agent) {
  return String(agent ?? '').toLowerCase().replace(/[^a-z0-9]/g, '');
}

function headerPlayerLoadoutsFromDiagnostics(diagnostics) {
  const loadouts = diagnostics.header?.headerPlayerLoadouts ?? [];
  if (!Array.isArray(loadouts)) return [];
  return loadouts.map((loadout, index) => {
    const loadoutIndex = Number.isInteger(loadout.index)
      ? loadout.index
      : index;
    return {
      loadoutIndex,
      subject: loadout.subject ?? null,
      agent: loadout.agent ?? 'Unknown',
      initialSide: loadoutIndex < 5 ? 'defender' : 'attacker',
      sideSource: 'header-playerLoadouts-order',
    };
  });
}

function abilityCastLoadoutsByNetGuid(loadouts, abilityCasts) {
  if (!Array.isArray(abilityCasts) || abilityCasts.length === 0) {
    return new Map();
  }

  const loadoutBySubject = new Map(
    loadouts
      .filter((loadout) => loadout.subject)
      .map((loadout) => [loadout.subject, loadout]),
  );
  const subjectCountsByNetGuid = new Map();
  for (const cast of abilityCasts) {
    if (!Number.isInteger(cast.playerNetGuid) || !cast.playerSubject) continue;
    if (!loadoutBySubject.has(cast.playerSubject)) continue;
    if (!subjectCountsByNetGuid.has(cast.playerNetGuid)) {
      subjectCountsByNetGuid.set(cast.playerNetGuid, new Map());
    }
    const subjectCounts = subjectCountsByNetGuid.get(cast.playerNetGuid);
    subjectCounts.set(
      cast.playerSubject,
      (subjectCounts.get(cast.playerSubject) ?? 0) + 1,
    );
  }

  const result = new Map();
  for (const [netGuid, subjectCounts] of subjectCountsByNetGuid.entries()) {
    const [subject] = [...subjectCounts.entries()].sort((a, b) => b[1] - a[1])[0] ?? [];
    const loadout = loadoutBySubject.get(subject);
    if (loadout) result.set(netGuid, loadout);
  }
  return result;
}

function attachLoadoutSides(playerRefs, diagnostics, abilityCasts = []) {
  const loadouts = headerPlayerLoadoutsFromDiagnostics(diagnostics);
  if (!loadouts.length) return playerRefs;

  const usedLoadoutIndexes = new Set();
  const exactLoadoutByNetGuid = abilityCastLoadoutsByNetGuid(loadouts, abilityCasts);
  const withExactMatches = playerRefs.map((player) => {
    const loadout = exactLoadoutByNetGuid.get(player.netGuid);
    if (
      !loadout ||
      normalizedAgentName(loadout.agent) !== normalizedAgentName(player.agent)
    ) {
      return player;
    }
    usedLoadoutIndexes.add(loadout.loadoutIndex);
    return {
      ...player,
      loadoutIndex: loadout.loadoutIndex,
      subject: loadout.subject,
      initialSide: loadout.initialSide,
      sideSource: 'ability-cast-subject-netguid',
    };
  });

  const loadoutsByAgent = new Map();
  for (const loadout of loadouts) {
    if (usedLoadoutIndexes.has(loadout.loadoutIndex)) continue;
    const key = normalizedAgentName(loadout.agent);
    if (!key) continue;
    if (!loadoutsByAgent.has(key)) loadoutsByAgent.set(key, []);
    loadoutsByAgent.get(key).push(loadout);
  }

  const unmatchedPlayersByAgent = new Map();
  for (const player of withExactMatches) {
    if (player.initialSide) continue;
    const key = normalizedAgentName(player.agent);
    if (!key) continue;
    if (!unmatchedPlayersByAgent.has(key)) unmatchedPlayersByAgent.set(key, []);
    unmatchedPlayersByAgent.get(key).push(player);
  }

  return withExactMatches.map((player) => {
    if (player.initialSide) return player;
    const key = normalizedAgentName(player.agent);
    const candidates = loadoutsByAgent.get(key) ?? [];
    const unmatchedPlayers = unmatchedPlayersByAgent.get(key) ?? [];
    const loadout =
      candidates.length === 1 && unmatchedPlayers.length === 1
        ? candidates[0]
        : null;
    if (!loadout) return player;
    usedLoadoutIndexes.add(loadout.loadoutIndex);
    return {
      ...player,
      loadoutIndex: loadout.loadoutIndex,
      subject: loadout.subject,
      initialSide: loadout.initialSide,
      sideSource: 'header-playerLoadouts-unique-agent',
    };
  });
}

function knownPlayerOpenSamplesFromDiagnostics(diagnostics) {
  const sources = [
    ...(diagnostics.frameSummary?.channelOpenSamples ?? []),
    ...(diagnostics.frameSummary?.classNetCacheSamples ?? []),
    ...(diagnostics.frameSummary?.valorantPayloadTransformSamples ?? []),
    ...(diagnostics.frameSummary?.compactChannelOpenSamples ?? []),
    ...(diagnostics.frameSummary?.compactClassNetCacheSamples ?? []),
    ...(diagnostics.frameSummary?.compactValorantPayloadTransformSamples ?? []),
  ];
  const byNetGuid = new Map();
  for (const sample of sources) {
    const archetypePath = sample.archetypePath ?? sample.actorPath ?? '';
    if (!/Default__[^/]+_PC_C$/i.test(archetypePath)) continue;
    if (/Ability|PostDeath/i.test(archetypePath)) continue;
    const netGuid = sample.actorNetGuid ?? sample.netGuid;
    if (!Number.isInteger(netGuid)) continue;
    const existing = byNetGuid.get(netGuid);
    const entry = {
      timeMs: sample.timeMs,
      chIndex: sample.chIndex,
      netGuid,
      archetypePath,
      agent: agentNameFromArchetype(archetypePath),
      location: sample.location ?? existing?.location ?? null,
      yaw: sample.rotation?.yaw ?? existing?.yaw ?? null,
    };
    if (
      !existing ||
      (Number.isFinite(entry.chIndex) && entry.chIndex < existing.chIndex) ||
      (!existing.archetypePath && entry.archetypePath)
    ) {
      byNetGuid.set(netGuid, entry);
    }
  }

  const sorted = [...byNetGuid.values()]
    .sort((a, b) => a.chIndex - b.chIndex || a.netGuid - b.netGuid)
    .map((sample, slotIndex) => ({ ...sample, slotIndex }));
  return sorted;
}

function adjustedSampleTimes(samples) {
  const groups = new Map();
  for (const sample of samples) {
    const key = `${sample.netGuid}|${sample.timeMs}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(sample);
  }

  const adjusted = [];
  for (const rows of groups.values()) {
    rows.sort(
      (a, b) =>
        (a.streamTimestamp ?? 0) - (b.streamTimestamp ?? 0) ||
        a.position.x - b.position.x ||
        a.position.y - b.position.y,
    );
    for (let index = 0; index < rows.length; index += 1) {
      const row = rows[index];
      adjusted.push({
        ...row,
        adjustedTimeMs: row.timeMs - (rows.length - index - 1) * 8,
      });
    }
  }
  return adjusted.sort(
    (a, b) =>
      a.adjustedTimeMs - b.adjustedTimeMs ||
      (a.streamTimestamp ?? 0) - (b.streamTimestamp ?? 0),
  );
}

function sampleSortKey(a, b) {
  return (
    a.timeMs - b.timeMs ||
    (a.streamTimestamp ?? 0) - (b.streamTimestamp ?? 0) ||
    a.position.x - b.position.x ||
    a.position.y - b.position.y
  );
}

function selectTrackSamples(samples, minIntervalMs) {
  if (!Number.isFinite(minIntervalMs) || minIntervalMs <= 0) {
    return samples.sort(sampleSortKey);
  }

  const byGuid = new Map();
  for (const sample of samples) {
    if (!Number.isInteger(sample.netGuid)) continue;
    if (!byGuid.has(sample.netGuid)) byGuid.set(sample.netGuid, []);
    byGuid.get(sample.netGuid).push(sample);
  }

  const selected = [];
  for (const rows of byGuid.values()) {
    rows.sort(sampleSortKey);
    let lastKeptTimeMs = -Infinity;
    for (let index = 0; index < rows.length; index += 1) {
      const row = rows[index];
      const previous = rows[index - 1];
      const next = rows[index + 1];
      const startsSegment = !previous || row.timeMs - previous.timeMs > minIntervalMs * 3;
      const endsSegment = !next || next.timeMs - row.timeMs > minIntervalMs * 3;
      if (
        startsSegment ||
        endsSegment ||
        row.timeMs - lastKeptTimeMs >= minIntervalMs
      ) {
        selected.push(row);
        lastKeptTimeMs = row.timeMs;
      }
    }
  }

  return selected.sort(sampleSortKey);
}

function timelineDeathEventsFromDiagnostics(diagnostics) {
  const events = Array.isArray(diagnostics.deathEvents) ? diagnostics.deathEvents : [];
  return events
    .map((event, index) => ({
      id: event.id ?? `death-${index}`,
      timeMs: Math.round(event.timeMs ?? 0),
      endMs: Number.isFinite(event.endMs) ? Math.round(event.endMs) : null,
      killerNetGuid: Number.isInteger(event.killerNetGuid) ? event.killerNetGuid : null,
      victimNetGuid: Number.isInteger(event.victimNetGuid) ? event.victimNetGuid : null,
      payloadVersion: event.payloadVersion ?? null,
      eventGroupLabel: event.eventGroupLabel ?? null,
      eventSeconds: event.eventSeconds ?? null,
      source: event.source ?? 'vrf-timeline-characterDeath-payload',
      confidence: event.confidence ?? 'proven-event-payload',
    }))
    .filter((event) => Number.isFinite(event.timeMs))
    .sort((a, b) => a.timeMs - b.timeMs || (a.victimNetGuid ?? 0) - (b.victimNetGuid ?? 0));
}

function timelineRoundStartEventsFromDiagnostics(diagnostics) {
  const events = Array.isArray(diagnostics.roundStartEvents) ? diagnostics.roundStartEvents : [];
  return events
    .map((event, index) => ({
      id: event.id ?? `round-start-${index}`,
      timeMs: Math.round(event.timeMs ?? 0),
      endMs: Number.isFinite(event.endMs) ? Math.round(event.endMs) : null,
      roundIndex: Number.isInteger(event.roundIndex) ? event.roundIndex : index,
      source: event.source ?? 'vrf-timeline-roundStarted',
      confidence: event.confidence ?? 'event-chunk',
    }))
    .filter((event) => Number.isFinite(event.timeMs))
    .sort((a, b) => a.timeMs - b.timeMs || (a.roundIndex ?? 999) - (b.roundIndex ?? 999));
}

function timelineSideSwitchEventsFromDiagnostics(diagnostics) {
  const events = Array.isArray(diagnostics.sideSwitchEvents) ? diagnostics.sideSwitchEvents : [];
  return events
    .map((event, index) => ({
      id: event.id ?? `side-switch-${index}`,
      timeMs: Math.round(event.timeMs ?? 0),
      endMs: Number.isFinite(event.endMs) ? Math.round(event.endMs) : null,
      source: event.source ?? 'vrf-timeline-switchTeams',
      confidence: event.confidence ?? 'event-chunk',
    }))
    .filter((event) => Number.isFinite(event.timeMs))
    .sort((a, b) => a.timeMs - b.timeMs);
}

function timelineUltimateEventsFromDiagnostics(diagnostics) {
  const events = Array.isArray(diagnostics.ultimateEvents)
    ? diagnostics.ultimateEvents
    : [];
  return events
    .map((event, index) => ({
      id: event.id ?? `ultimate-${index}`,
      timeMs: Math.round(event.timeMs ?? 0),
      endMs: Number.isFinite(event.endMs) ? Math.round(event.endMs) : null,
      playerNetGuid: Number.isInteger(event.playerNetGuid)
        ? event.playerNetGuid
        : null,
      payloadVersion: event.payloadVersion ?? null,
      eventGroupLabel: event.eventGroupLabel ?? null,
      eventSeconds: event.eventSeconds ?? null,
      phase: 'ultimate-use',
      source: event.source ?? 'vrf-timeline-characterUltimateUsed-payload',
      confidence: event.confidence ?? 'proven-event-payload',
    }))
    .filter((event) => Number.isFinite(event.timeMs))
    .sort((a, b) => a.timeMs - b.timeMs || (a.playerNetGuid ?? 0) - (b.playerNetGuid ?? 0));
}

function equippableNetGuidFromInputSample(sample) {
  if (![4, 8].includes(sample?.eventTypeValue)) return null;
  const buffer = Buffer.from(sample.serializedDataHex ?? '', 'hex');
  const bitLimit = Math.min(
    Number.isFinite(sample.serializedBitCount)
      ? sample.serializedBitCount
      : buffer.length * 8,
    buffer.length * 8,
  );
  if (bitLimit < 12) return null;
  const cursor = new BitCursor(buffer, bitLimit, 4);
  const netGuid = cursor.readIntPacked();
  return cursor.isError || !Number.isInteger(netGuid) ? null : netGuid;
}

function replayInputEventsFromDiagnostics(
  diagnostics,
  roundStartEvents = [],
  utilityActors = [],
  playerRefs = [],
) {
  const frameSummary = diagnostics.frameSummary ?? {};
  const samples = [
    ...(Array.isArray(frameSummary.nonMovementInputEventSamples)
      ? frameSummary.nonMovementInputEventSamples
      : []),
    ...(Array.isArray(frameSummary.compactNonMovementInputEventSamples)
      ? frameSummary.compactNonMovementInputEventSamples
      : []),
  ];
  const loadoutByIndex = new Map(
    headerPlayerLoadoutsFromDiagnostics(diagnostics).map((loadout) => [
      loadout.loadoutIndex,
      loadout,
    ]),
  );
  const seen = new Set();
  const events = [];
  const abilityEquippableByNetGuid = new Map(
    utilityActors
      .filter(
        (actor) =>
          Number.isInteger(actor.actorNetGuid) &&
          (!actor.ignoredAsAbility ||
            (actor.phase === 'cast-identity' &&
              actor.identitySource === 'static-direct-ability-asset')) &&
          (actor.sourceAbilitySlot ?? actor.abilitySlot) &&
          (actor.agent ?? actor.agentShippingName),
      )
      .map((actor) => [actor.actorNetGuid, actor]),
  );
  const playerBySubject = new Map(
    playerRefs
      .filter((player) => player.subject)
      .map((player) => [player.subject, player]),
  );
  for (const sample of samples) {
    if (!Number.isFinite(sample.timeMs)) continue;
    const key = [
      Math.round(sample.timeMs),
      sample.playerReplayId,
      sample.rawInputEventDataHex,
    ].join('|');
    if (seen.has(key)) continue;
    seen.add(key);
    const candidateLoadoutIndex = Number.isInteger(sample.candidateLoadoutIndex)
      ? sample.candidateLoadoutIndex
      : null;
    const loadout = candidateLoadoutIndex == null
      ? null
      : loadoutByIndex.get(candidateLoadoutIndex) ?? null;
    const playerIdMatchesLoadout =
      loadout != null &&
      sample.playerReplayId === 0x100 + loadout.loadoutIndex;
    const equippableNetGuid = equippableNetGuidFromInputSample(sample);
    const abilityEquippable = equippableNetGuid == null
      ? null
      : abilityEquippableByNetGuid.get(equippableNetGuid) ?? null;
    const playerAgent = playerIdMatchesLoadout ? loadout.agent : null;
    const abilityAgent =
      abilityEquippable?.agent ?? abilityEquippable?.agentShippingName ?? null;
    const exactAbilityIdentity =
      abilityEquippable != null &&
      (!playerAgent ||
        normalizedAgentName(playerAgent) === normalizedAgentName(abilityAgent));
    const abilitySlot = exactAbilityIdentity
      ? abilityEquippable.sourceAbilitySlot ?? abilityEquippable.abilitySlot
      : null;
    const playerRef = playerIdMatchesLoadout
      ? playerBySubject.get(loadout.subject) ?? null
      : null;
    events.push({
      ...sample,
      id: null,
      timeMs: Math.round(sample.timeMs),
      roundIndex: roundIndexForTime(roundStartEvents, sample.timeMs),
      playerLoadoutIndex: playerIdMatchesLoadout
        ? loadout.loadoutIndex
        : null,
      playerSubject: playerIdMatchesLoadout ? loadout.subject : null,
      playerNetGuid: playerRef?.netGuid ?? null,
      agent: playerAgent,
      playerIdentitySource: playerIdMatchesLoadout
        ? 'replay-player-id-0x100-plus-header-loadout-index'
        : null,
      equippableNetGuid,
      equippableActorId: exactAbilityIdentity ? abilityEquippable.id : null,
      abilitySlot,
      abilityIndex: exactAbilityIdentity
        ? abilityEquippable.abilityIndex ?? null
        : null,
      abilityName: exactAbilityIdentity
        ? abilityEquippable.sourceAbilityName ??
          abilityEquippable.abilityName ??
          null
        : null,
      canonicalAbilityId: exactAbilityIdentity
        ? canonicalAbilityId(abilityAgent, abilitySlot)
        : null,
      abilityIdentitySource: exactAbilityIdentity
        ? 'input-equippable-netguid+static-actor-identity'
        : null,
      abilityIdentityConfidence: exactAbilityIdentity
        ? 'replay-exact-netguid-static-identity'
        : null,
      confidence: 'decoded-input-capture-rpc',
    });
  }
  return events
    .sort(
      (a, b) =>
        a.timeMs - b.timeMs ||
        (a.playerReplayId ?? 0) - (b.playerReplayId ?? 0) ||
        String(a.rawInputEventDataHex).localeCompare(
          String(b.rawInputEventDataHex),
        ),
    )
    .map((event, index) => ({ ...event, id: `input-${index}` }));
}

function abilityStateNameFromPath(pathName) {
  return String(pathName ?? '')
    .split('/')
    .at(-1)
    .split('.')
    .at(-1)
    .replace(/^Default__/, '')
    .replace(/_C$/, '');
}

function abilityStateEventsFromDiagnostics(
  diagnostics,
  roundStartEvents = [],
  inputEvents = [],
) {
  const signals = abilitySignalsFromDiagnostics(diagnostics);
  const authStartWorldTimeByActorAndPacket = new Map();
  for (const sample of signals) {
    if (
      sample.fieldName !== 'AuthStartWorldTime' ||
      !Number.isInteger(sample.actorNetGuid) ||
      !Number.isFinite(sample.timeMs)
    ) {
      continue;
    }
    const buffer = Buffer.from(sample.payloadHex ?? '', 'hex');
    if (buffer.length < 4) continue;
    const value = buffer.readFloatLE(0);
    if (Number.isFinite(value)) {
      authStartWorldTimeByActorAndPacket.set(
        `${sample.actorNetGuid}|${Math.round(sample.timeMs)}`,
        value,
      );
    }
  }
  const ownerInputsByEquippable = new Map();
  for (const event of inputEvents) {
    if (
      !Number.isInteger(event.equippableNetGuid) ||
      !event.playerSubject ||
      !event.canonicalAbilityId
    ) {
      continue;
    }
    if (!ownerInputsByEquippable.has(event.equippableNetGuid)) {
      ownerInputsByEquippable.set(event.equippableNetGuid, []);
    }
    ownerInputsByEquippable.get(event.equippableNetGuid).push(event);
  }

  const seen = new Set();
  const events = [];
  for (const sample of signals) {
    if (sample.fieldName !== 'CurrentState') continue;
    if (!Number.isInteger(sample.actorNetGuid) || !Number.isFinite(sample.timeMs)) {
      continue;
    }
    const stateReference = (sample.netGuidReferences ?? []).find(
      (reference) => reference?.pathName,
    );
    if (!stateReference?.pathName) continue;
    const identity = abilitySignalMetadataFromActorPath(sample.actorPath);
    const abilitySlot = identity.sourceAbilitySlot ?? identity.abilitySlot;
    const agent = identity.agent ?? null;
    if (
      !agent ||
      !['Grenade', 'Ability1', 'Ability2', 'Ultimate', 'Passive'].includes(
        abilitySlot,
      ) ||
      !String(identity.identitySource ?? '').startsWith('static-')
    ) {
      continue;
    }
    const stateName = abilityStateNameFromPath(stateReference.pathName);
    if (!stateName) continue;
    const key = [
      Math.round(sample.timeMs),
      sample.actorNetGuid,
      stateReference.netGuid,
      stateReference.pathName,
    ].join('|');
    if (seen.has(key)) continue;
    seen.add(key);
    const ownerInputs = ownerInputsByEquippable.get(sample.actorNetGuid) ?? [];
    const ownerSubjects = new Set(
      ownerInputs.map((event) => event.playerSubject).filter(Boolean),
    );
    const ownerInput = ownerSubjects.size === 1 ? ownerInputs[0] : null;
    events.push({
      id: null,
      timeMs: Math.round(sample.timeMs),
      roundIndex: roundIndexForTime(roundStartEvents, sample.timeMs),
      equippableNetGuid: sample.actorNetGuid,
      stateNetGuid: stateReference.netGuid ?? null,
      statePath: stateReference.pathName,
      stateName,
      authStartWorldTimeSeconds:
        authStartWorldTimeByActorAndPacket.get(
          `${sample.actorNetGuid}|${Math.round(sample.timeMs)}`,
        ) ?? null,
      initialReplication: sample.timeMs <= 1000,
      agent,
      icarusAgentType: identity.icarusAgentType ?? null,
      abilitySlot,
      abilityIndex: identity.abilityIndex ?? null,
      abilityName: identity.sourceAbilityName ?? identity.abilityName ?? null,
      canonicalAbilityId: canonicalAbilityId(agent, abilitySlot),
      sourceAbilityAssetPath:
        identity.sourceAbilityAssetPath ?? identity.sourceAbilityClass ?? null,
      identitySource: identity.identitySource,
      identityConfidence: identity.identityConfidence ?? null,
      ownerPlayerNetGuid: ownerInput?.playerNetGuid ?? null,
      ownerSubject: ownerInput?.playerSubject ?? null,
      ownerSource: ownerInput
        ? 'exact-input-equippable-netguid-owner'
        : null,
      source: 'EquippableStateMachineComponent.CurrentState-NetGUID',
      evidence: 'observed',
    });
  }
  return events
    .sort(
      (a, b) =>
        a.timeMs - b.timeMs ||
        a.equippableNetGuid - b.equippableNetGuid ||
        a.stateName.localeCompare(b.stateName),
    )
    .map((event, index) => ({ ...event, id: `ability-state-${index}` }));
}

const ABILITY_LIFECYCLE_RPC_PHASES = new Map([
  ['MulticastStopProjectile', 'projectile-stop'],
  ['MulticastPlayContinuousEffect', 'continuous-effect-start'],
  ['MulticastStopContinuousEffect', 'continuous-effect-stop'],
  ['MulticastUpdateContinuousEffect', 'continuous-effect-update'],
  ['MulticastPlayOneShotEffect', 'one-shot-effect'],
  ['MulticastOnItemMovedToPersistentData', 'item-moved-to-persistent-data'],
  ['ClientResetStateMachine', 'state-machine-reset'],
]);

function abilityRpcEventsFromDiagnostics(diagnostics, inputEvents = []) {
  const ownerInputsByEquippable = new Map();
  for (const event of inputEvents) {
    if (
      !Number.isInteger(event.equippableNetGuid) ||
      !event.playerSubject ||
      !event.canonicalAbilityId
    ) {
      continue;
    }
    if (!ownerInputsByEquippable.has(event.equippableNetGuid)) {
      ownerInputsByEquippable.set(event.equippableNetGuid, []);
    }
    ownerInputsByEquippable.get(event.equippableNetGuid).push(event);
  }

  const events = [];
  for (const sample of abilitySignalsFromDiagnostics(diagnostics)) {
    const phaseType = ABILITY_LIFECYCLE_RPC_PHASES.get(sample.fieldName);
    if (!phaseType || !Number.isFinite(sample.timeMs)) continue;
    const identity = abilitySignalMetadataFromActorPath(sample.actorPath);
    const abilitySlot = identity.sourceAbilitySlot ?? identity.abilitySlot;
    const agent = identity.agent ?? null;
    if (
      !agent ||
      !abilitySlot ||
      !String(identity.identitySource ?? '').startsWith('static-')
    ) {
      continue;
    }
    const ownerInputs = ownerInputsByEquippable.get(sample.actorNetGuid) ?? [];
    const ownerSubjects = new Set(
      ownerInputs.map((event) => event.playerSubject).filter(Boolean),
    );
    const ownerInput = ownerSubjects.size === 1 ? ownerInputs[0] : null;
    events.push({
      id: null,
      timeMs: Math.round(sample.timeMs),
      actorNetGuid: Number.isInteger(sample.actorNetGuid)
        ? sample.actorNetGuid
        : null,
      actorPath: sample.actorPath ?? null,
      rpcName: sample.fieldName,
      phaseType,
      payloadBitCount: sample.numBits ?? sample.numPayloadBits ?? null,
      payloadPrefixHex: String(sample.payloadHex ?? '').slice(0, 128),
      payloadTruncated:
        sample.payloadHexTruncated === true ||
        String(sample.payloadHex ?? '').length > 128,
      agent,
      icarusAgentType: identity.icarusAgentType ?? null,
      abilitySlot,
      abilityIndex: identity.abilityIndex ?? null,
      abilityName: identity.sourceAbilityName ?? identity.abilityName ?? null,
      canonicalAbilityId: canonicalAbilityId(agent, abilitySlot),
      sourceAbilityAssetPath:
        identity.sourceAbilityAssetPath ?? identity.sourceAbilityClass ?? null,
      identitySource: identity.identitySource,
      identityConfidence: identity.identityConfidence ?? null,
      ownerPlayerNetGuid: ownerInput?.playerNetGuid ?? null,
      ownerSubject: ownerInput?.playerSubject ?? null,
      ownerSource: ownerInput
        ? 'exact-input-equippable-netguid-owner'
        : null,
      source: `classnet-rpc:${sample.fieldName}`,
      evidence: 'observed',
    });
  }
  return events
    .sort(
      (a, b) =>
        a.timeMs - b.timeMs ||
        (a.actorNetGuid ?? 0) - (b.actorNetGuid ?? 0) ||
        a.rpcName.localeCompare(b.rpcName),
    )
    .map((event, index) => ({ ...event, id: `ability-rpc-${index}` }));
}

function canonicalAbilityId(agent, abilitySlot) {
  const agentKey = normalizedAgentName(agent);
  const slotKey = String(abilitySlot ?? '')
    .trim()
    .toLowerCase();
  return agentKey && slotKey ? `valorant.${agentKey}.${slotKey}` : null;
}

function buildReplayAbilityActions(
  abilityCasts,
  utilityActors,
  ultimateEvents,
  inputEvents = [],
  abilityStateEvents = [],
  abilityRpcEvents = [],
) {
  const actions = [];
  const actionByCastId = new Map();
  const orphanActionByGroup = new Map();
  const inputEquipActionByNetGuidAndTime = new Map();
  const actionByUtilityActorNetGuid = new Map();

  function makeAction({
    id,
    agent,
    abilitySlot,
    abilityIndex,
    abilityName,
    sourceAbilityAssetPath,
    identitySource,
    ownerPlayerNetGuid = null,
    ownerSubject = null,
    ownerSource = null,
  }) {
    const action = {
      id,
      canonicalAbilityId: canonicalAbilityId(agent, abilitySlot),
      agent: agent ?? null,
      abilitySlot: abilitySlot ?? null,
      abilityIndex: Number.isInteger(abilityIndex) ? abilityIndex : null,
      abilityName: abilityName ?? null,
      sourceAbilityAssetPath: sourceAbilityAssetPath ?? null,
      identitySource: identitySource ?? null,
      ownerPlayerNetGuid: Number.isInteger(ownerPlayerNetGuid)
        ? ownerPlayerNetGuid
        : null,
      ownerSubject: ownerSubject ?? null,
      ownerSource: ownerSource ?? null,
      phases: [],
    };
    actions.push(action);
    return action;
  }

  for (const cast of abilityCasts ?? []) {
    const action = makeAction({
      id: `action-${cast.id}`,
      agent: cast.agent,
      abilitySlot: cast.abilitySlot,
      abilityIndex: cast.abilityIndex,
      abilityName: cast.abilityName,
      sourceAbilityAssetPath:
        cast.sourceAbilityAssetPath ?? cast.sourceAbilityClass,
      identitySource: cast.abilityIdentitySource,
      ownerPlayerNetGuid: cast.playerNetGuid,
      ownerSubject: cast.playerSubject,
      ownerSource: 'CharacterAbilityCastInfo-player',
    });
    action.sourceCastId = cast.id;
    action.phases.push({
      id: `${action.id}-cast`,
      type: 'cast',
      timeMs: cast.timeMs,
      roundIndex: cast.roundIndex ?? null,
      evidence: 'observed',
      evidenceSource: 'CharacterAbilityCastInfo-AbilityCastsThisRound',
      timeSource: cast.timeSource ?? null,
      position: cast.castLocation ?? null,
      effectLocations: cast.effectLocations ?? [],
      placementLocations: cast.placementLocations ?? [],
      destroyedCount: cast.destroyedCount ?? null,
      effects: cast.effects ?? [],
      sourceEventId: cast.id,
    });
    actionByCastId.set(cast.id, action);
  }

  for (const actor of utilityActors ?? []) {
    if (actor.ignoredAsAbility) continue;
    let action = actor.sourceCastId
      ? actionByCastId.get(actor.sourceCastId) ?? null
      : null;
    if (!action) {
      const groupKey =
        actor.phaseGroupId ??
        actor.parentUtilityActorId ??
        actor.id ??
        `actor-${actor.actorNetGuid ?? actor.chIndex}`;
      action = orphanActionByGroup.get(groupKey) ?? null;
      if (!action) {
        action = makeAction({
          id: `action-${groupKey}`,
          agent: actor.agent ?? actor.agentShippingName,
          abilitySlot: actor.sourceAbilitySlot ?? actor.abilitySlot,
          abilityIndex: actor.abilityIndex,
          abilityName: actor.sourceAbilityName ?? actor.abilityName,
          sourceAbilityAssetPath:
            actor.sourceAbilityAssetPath ?? actor.sourceAbilityClass,
          identitySource: actor.identitySource,
          ownerPlayerNetGuid: actor.ownerPlayerNetGuid,
          ownerSubject: actor.ownerSubject,
          ownerSource: actor.ownerSource,
        });
        action.orphanedFromCastLane = true;
        orphanActionByGroup.set(groupKey, action);
      }
    }
    action.sourceUtilityActorIds ??= [];
    action.sourceUtilityActorIds.push(actor.id);
    if (Number.isInteger(actor.actorNetGuid)) {
      actionByUtilityActorNetGuid.set(actor.actorNetGuid, action);
    }
    action.phases.push({
      id: `${action.id}-${actor.id}-open`,
      type: actor.phase ?? actor.contentKind ?? 'actor-open',
      timeMs: actor.observedStartMs ?? actor.timeMs,
      evidence: 'observed',
      evidenceSource: 'actor-channel-open',
      position: actor.position ?? null,
      velocity: actor.velocity ?? null,
      yawDegrees: actor.yawDegrees ?? null,
      actorNetGuid: actor.actorNetGuid ?? null,
      sourceEventId: actor.id,
      parentUtilityActorId: actor.parentUtilityActorId ?? null,
      sequenceIndex: actor.sequenceIndex ?? null,
      actionAssemblyEvidence: actor.sourceCastLinkEvidence ?? null,
      actionAssemblyConfidence: actor.sourceCastLinkConfidence ?? null,
    });

    const observedEndMs = actor.observedEndMs ?? actor.closedAtMs ?? null;
    const derivedEndMs = observedEndMs == null ? actor.effectiveEndMs ?? null : null;
    const endMs = observedEndMs ?? derivedEndMs;
    if (endMs != null) {
      action.phases.push({
        id: `${action.id}-${actor.id}-end`,
        type:
          actor.dormant === true
            ? 'dormant'
            : actor.endReason ?? 'actor-end',
        timeMs: endMs,
        evidence: observedEndMs != null ? 'observed' : 'derived',
        evidenceSource:
          observedEndMs != null
            ? 'actor-channel-close'
            : actor.durationSource ?? actor.endReasonEvidence ?? null,
        semanticEvidence: actor.endReasonEvidence ?? null,
        actorNetGuid: actor.actorNetGuid ?? null,
        sourceEventId: actor.id,
        closeReason: actor.closeReason ?? null,
        dormant: actor.dormant ?? null,
        terminal: true,
      });
    }
  }

  for (const event of ultimateEvents ?? []) {
    let action = event.linkedCastId
      ? actionByCastId.get(event.linkedCastId) ?? null
      : null;
    if (!action) {
      const groupKey = `ultimate-${event.id}`;
      const ultimateIdentity = abilityIdentityForSlot(event.agent, 'Ultimate');
      action = makeAction({
        id: `action-${groupKey}`,
        agent: event.agent,
        abilitySlot: 'Ultimate',
        abilityIndex: ultimateIdentity.abilityIndex,
        abilityName: ultimateIdentity.abilityName,
        identitySource: 'characterUltimateUsed+static-slot-catalog',
        ownerPlayerNetGuid: event.playerNetGuid,
        ownerSubject: event.playerSubject,
        ownerSource: 'characterUltimateUsed-player-netguid',
      });
      action.orphanedFromCastLane = true;
    }
    action.sourceUltimateEventIds ??= [];
    action.sourceUltimateEventIds.push(event.id);
    action.phases.push({
      id: `${action.id}-${event.id}`,
      type: 'ultimate-use',
      timeMs: event.timeMs,
      roundIndex: event.roundIndex ?? null,
      evidence: 'observed',
      evidenceSource: event.source,
      sourceEventId: event.id,
    });
  }

  for (const event of inputEvents ?? []) {
    if (
      event.eventType !== 'EquippableChange' ||
      !event.canonicalAbilityId ||
      !event.abilitySlot
    ) {
      continue;
    }
    const action = makeAction({
      id: `action-${event.id}-equip`,
      agent: event.agent,
      abilitySlot: event.abilitySlot,
      abilityIndex: event.abilityIndex,
      abilityName: event.abilityName,
      identitySource: event.abilityIdentitySource,
      ownerPlayerNetGuid: event.playerNetGuid,
      ownerSubject: event.playerSubject,
      ownerSource: 'input-capture-player+equippable-netguid',
    });
    action.sourceInputEventIds = [event.id];
    action.phases.push({
      id: `${action.id}-selected`,
      type: 'equip-selected',
      timeMs: event.timeMs,
      roundIndex: event.roundIndex ?? null,
      evidence: 'observed',
      evidenceSource:
        'ClientReplayReceiveInputEventProcessingCapture-EquippableChange+exact-equippable-NetGUID',
      actorNetGuid: event.equippableNetGuid,
      sourceEventId: event.id,
    });
    inputEquipActionByNetGuidAndTime.set(
      `${event.equippableNetGuid}|${event.timeMs}`,
      action,
    );
  }

  const openStateActionByEquippable = new Map();
  for (const event of abilityStateEvents ?? []) {
    if (event.initialReplication) continue;
    const isInactive = /^InactiveState$/i.test(event.stateName ?? '');
    let action = openStateActionByEquippable.get(event.equippableNetGuid) ?? null;
    if (!action && isInactive) continue;
    if (!action) {
      action = inputEquipActionByNetGuidAndTime.get(
        `${event.equippableNetGuid}|${event.timeMs}`,
      ) ?? null;
      if (!action) {
        action = makeAction({
          id: `action-state-${event.equippableNetGuid}-${event.id}`,
          agent: event.agent,
          abilitySlot: event.abilitySlot,
          abilityIndex: event.abilityIndex,
          abilityName: event.abilityName,
          sourceAbilityAssetPath: event.sourceAbilityAssetPath,
          identitySource: event.identitySource,
          ownerPlayerNetGuid: event.ownerPlayerNetGuid,
          ownerSubject: event.ownerSubject,
          ownerSource: event.ownerSource,
        });
      }
      action.sourceStateEventIds = [];
      openStateActionByEquippable.set(event.equippableNetGuid, action);
    }
    action.sourceStateEventIds.push(event.id);
    action.phases.push({
      id: `${action.id}-${event.id}`,
      type: `state-${String(event.stateName)
        .replace(/([a-z0-9])([A-Z])/g, '$1-$2')
        .replace(/[^a-z0-9]+/gi, '-')
        .replace(/^-|-$/g, '')
        .toLowerCase()}`,
      timeMs: event.timeMs,
      roundIndex: event.roundIndex ?? null,
      evidence: 'observed',
      evidenceSource: event.source,
      timeSource: 'CurrentState-replication-observation',
      actorNetGuid: event.equippableNetGuid,
      stateNetGuid: event.stateNetGuid,
      statePath: event.statePath,
      stateName: event.stateName,
      stateStartWorldTimeSeconds: event.authStartWorldTimeSeconds,
      sourceEventId: event.id,
      terminal: isInactive,
    });
    if (isInactive) openStateActionByEquippable.delete(event.equippableNetGuid);
  }

  for (const event of abilityRpcEvents ?? []) {
    const action = Number.isInteger(event.actorNetGuid)
      ? actionByUtilityActorNetGuid.get(event.actorNetGuid) ?? null
      : null;
    if (!action) continue;
    action.sourceRpcEventIds ??= [];
    action.sourceRpcEventIds.push(event.id);
    action.phases.push({
      id: `${action.id}-${event.id}`,
      type: `rpc-${event.phaseType}`,
      timeMs: event.timeMs,
      evidence: 'observed',
      evidenceSource: event.source,
      actorNetGuid: event.actorNetGuid,
      rpcName: event.rpcName,
      payloadBitCount: event.payloadBitCount,
      sourceEventId: event.id,
    });
  }

  return actions
    .map((action) => {
      action.phases.sort(
        (a, b) => a.timeMs - b.timeMs || a.id.localeCompare(b.id),
      );
      action.sourceUtilityActorIds = [
        ...new Set(action.sourceUtilityActorIds ?? []),
      ];
      action.sourceUltimateEventIds = [
        ...new Set(action.sourceUltimateEventIds ?? []),
      ];
      action.sourceInputEventIds = [
        ...new Set(action.sourceInputEventIds ?? []),
      ];
      action.sourceStateEventIds = [
        ...new Set(action.sourceStateEventIds ?? []),
      ];
      action.sourceRpcEventIds = [
        ...new Set(action.sourceRpcEventIds ?? []),
      ];
      const terminalPhases = action.phases.filter(
        (phase) => phase.terminal === true,
      );
      const observedTerminal = terminalPhases.some(
        (phase) => phase.evidence === 'observed',
      );
      const derivedTerminal = terminalPhases.some(
        (phase) => phase.evidence === 'derived',
      );
      const hasActorPhase = action.phases.some(
        (phase) => phase.actorNetGuid != null && !terminalPhases.includes(phase),
      );
      return {
        ...action,
        startTimeMs: action.phases[0]?.timeMs ?? null,
        endTimeMs: terminalPhases.at(-1)?.timeMs ?? null,
        terminationStatus: observedTerminal
          ? 'observed'
          : derivedTerminal
            ? 'derived'
            : hasActorPhase
              ? 'open-or-unknown'
              : 'event-only',
        rightCensored: terminalPhases.some(
          (phase) => phase.type === 'recording-censored',
        ) ||
          ((action.sourceStateEventIds ?? []).length > 0 &&
            terminalPhases.length === 0),
      };
    })
    .sort(
      (a, b) =>
        (a.startTimeMs ?? 0) - (b.startTimeMs ?? 0) ||
        a.id.localeCompare(b.id),
    );
}

function replayDurationMsFromDiagnostics(diagnostics) {
  const chunks = diagnostics.replayDataChunks ?? [];
  const lastChunkEnd = chunks.reduce((max, chunk) => Math.max(max, chunk.endMs ?? 0), 0);
  return lastChunkEnd > 0 ? lastChunkEnd : null;
}

function roundIndexForTime(roundStartEvents, timeMs) {
  let current = null;
  for (const event of roundStartEvents) {
    if (event.timeMs <= timeMs) current = event.roundIndex;
    else break;
  }
  return current;
}

function buildPlayerLifeState(netGuid, deathEvents, roundStartEvents, durationMs) {
  const playerDeaths = deathEvents
    .filter((event) => event.victimNetGuid === netGuid)
    .map((event) => ({
      ...event,
      roundIndex: roundIndexForTime(roundStartEvents, event.timeMs),
    }));
  const respawnEvents = roundStartEvents.map((event) => ({
    id: `respawn-${netGuid}-${event.roundIndex ?? event.timeMs}`,
    timeMs: event.timeMs,
    roundIndex: event.roundIndex,
    state: 'alive',
    source: 'vrf-timeline-roundStarted-reset',
    confidence: 'inferred-round-reset',
  }));
  const stateSamples = [
    ...respawnEvents,
    ...playerDeaths.map((event) => ({
      id: `dead-${netGuid}-${event.timeMs}`,
      timeMs: event.timeMs,
      roundIndex: event.roundIndex,
      state: 'dead',
      killerNetGuid: event.killerNetGuid,
      victimNetGuid: event.victimNetGuid,
      deathEventId: event.id,
      source: event.source,
      confidence: event.confidence,
    })),
  ].sort((a, b) => a.timeMs - b.timeMs || (a.state === 'dead' ? 1 : -1));

  const lifeSegments = [];
  if (roundStartEvents.length > 0) {
    for (let index = 0; index < roundStartEvents.length; index += 1) {
      const roundStart = roundStartEvents[index];
      const nextRoundStart = roundStartEvents[index + 1] ?? null;
      const roundEndMs = nextRoundStart?.timeMs ?? durationMs;
      const deathsThisRound = playerDeaths.filter(
        (event) =>
          event.timeMs >= roundStart.timeMs &&
          (roundEndMs == null || event.timeMs < roundEndMs),
      );
      const firstDeath = deathsThisRound[0] ?? null;
      lifeSegments.push({
        startMs: roundStart.timeMs,
        endMs: firstDeath?.timeMs ?? roundEndMs ?? null,
        roundIndex: roundStart.roundIndex,
        state: 'alive',
        source: firstDeath
          ? 'vrf-timeline-roundStarted+characterDeath'
          : 'vrf-timeline-roundStarted',
        confidence: firstDeath
          ? 'round-reset-inferred-death-proven'
          : 'inferred-round-reset-no-death-event',
      });
      if (firstDeath) {
        lifeSegments.push({
          startMs: firstDeath.timeMs,
          endMs: roundEndMs ?? null,
          roundIndex: roundStart.roundIndex,
          state: 'dead',
          deathEventId: firstDeath.id,
          killerNetGuid: firstDeath.killerNetGuid,
          source: 'vrf-timeline-characterDeath+next-roundStarted',
          confidence: 'death-proven-round-reset-inferred',
          additionalDeathEventCount: Math.max(0, deathsThisRound.length - 1),
        });
      }
    }
  }

  return {
    stateSamples,
    lifeSegments,
    deathEvents: playerDeaths,
    respawnEvents,
  };
}

function buildNativeReplayTrack(diagnostics, samples, positionValidation = null) {
  const openPlayerRefs = knownPlayerOpenSamplesFromDiagnostics(diagnostics);
  const deathEvents = timelineDeathEventsFromDiagnostics(diagnostics);
  const roundStartEvents = timelineRoundStartEventsFromDiagnostics(diagnostics);
  const sideSwitchEvents = timelineSideSwitchEventsFromDiagnostics(diagnostics);
  const rawUltimateEvents = timelineUltimateEventsFromDiagnostics(diagnostics);
  const durationMs = replayDurationMsFromDiagnostics(diagnostics);
  const decodedAbilityCasts = abilityCastsFromDiagnostics(
    diagnostics,
    openPlayerRefs.map((player) => ({
      diagnostic: {
        archetypePath: player.archetypePath,
        netGuid: player.netGuid,
      },
    })),
  );
  const rawUtilityActors = utilityActorsFromDiagnostics(diagnostics);
  const abilityCasts = resolveAbilityCastTimes(
    decodedAbilityCasts,
    rawUtilityActors,
    roundStartEvents,
  );
  const playerRefs = attachLoadoutSides(openPlayerRefs, diagnostics, abilityCasts);
  const playerByGuid = new Map(playerRefs.map((player) => [player.netGuid, player]));
  const inputEvents = replayInputEventsFromDiagnostics(
    diagnostics,
    roundStartEvents,
    rawUtilityActors,
    playerRefs,
  );
  const abilityStateEvents = abilityStateEventsFromDiagnostics(
    diagnostics,
    roundStartEvents,
    inputEvents,
  );
  const abilityRpcEvents = abilityRpcEventsFromDiagnostics(
    diagnostics,
    inputEvents,
  );
  const ultimateEvents = rawUltimateEvents.map((event) => {
    const player = playerByGuid.get(event.playerNetGuid) ?? null;
    const linkedCast = abilityCasts
      .filter(
        (cast) =>
          cast.abilitySlot === 'Ultimate' &&
          Number.isInteger(cast.playerNetGuid) &&
          cast.playerNetGuid === event.playerNetGuid &&
          Math.abs(cast.timeMs - event.timeMs) <= 1500,
      )
      .sort(
        (a, b) =>
          Math.abs(a.timeMs - event.timeMs) - Math.abs(b.timeMs - event.timeMs),
      )[0] ?? null;
    if (linkedCast) {
      linkedCast.linkedUltimateEventIds = [
        ...new Set([...(linkedCast.linkedUltimateEventIds ?? []), event.id]),
      ];
    }
    return {
      ...event,
      roundIndex: roundIndexForTime(roundStartEvents, event.timeMs),
      playerSubject: player?.subject ?? null,
      agent: player?.agent ?? null,
      linkedCastId: linkedCast?.id ?? null,
      castDeltaMs: linkedCast ? event.timeMs - linkedCast.timeMs : null,
      evidenceRoles: [
        'vrf-timeline-characterUltimateUsed-payload',
        linkedCast ? 'linked-to-AbilityCastsThisRound' : null,
      ].filter(Boolean),
    };
  });
  const restrictToKnownPlayers = playerByGuid.size > 0;
  const byGuid = new Map();
  const seen = new Set();

  for (const sample of samples) {
    if (!Number.isInteger(sample.netGuid)) continue;
    if (restrictToKnownPlayers && !playerByGuid.has(sample.netGuid)) continue;
    const key = [
      sample.netGuid,
      sample.timeMs,
      sample.streamTimestamp,
      sample.position?.x,
      sample.position?.y,
      sample.position?.z,
      sample.viewRotation?.yaw,
      sample.viewRotation?.pitch,
    ].join('|');
    if (seen.has(key)) continue;
    seen.add(key);
    if (!byGuid.has(sample.netGuid)) byGuid.set(sample.netGuid, []);
    byGuid.get(sample.netGuid).push(sample);
  }

  const players = [...byGuid.entries()]
    .sort((a, b) => {
      const playerA = playerByGuid.get(a[0]);
      const playerB = playerByGuid.get(b[0]);
      const slotA = playerA?.loadoutIndex ?? playerA?.slotIndex ?? 999;
      const slotB = playerB?.loadoutIndex ?? playerB?.slotIndex ?? 999;
      return slotA - slotB || a[0] - b[0];
    })
    .map(([netGuid, rows], index) => {
      const player = playerByGuid.get(netGuid);
      const agent = player?.agent ?? 'Unknown';
      const slotLabel = player?.slotIndex == null ? 'unknown-slot' : `slot${player.slotIndex}`;
      const ordered = adjustedSampleTimes(rows);
      const lifeState = buildPlayerLifeState(netGuid, deathEvents, roundStartEvents, durationMs);
      const teamColor =
        player?.initialSide === 'defender'
          ? DEFENDER_TEAM_COLOR
          : player?.initialSide === 'attacker'
            ? ATTACKER_TEAM_COLOR
            : TRACK_COLORS[index % TRACK_COLORS.length];
      return {
        id: `netguid-${netGuid}`,
        displayName: `${agent} g${netGuid}`,
        agent,
        initialSide: player?.initialSide ?? null,
        loadoutIndex: player?.loadoutIndex ?? null,
        subject: player?.subject ?? null,
        sideSource: player?.sideSource ?? null,
        teamColor,
        kind: 'player',
        sourceTag:
          '/Script/ShooterGame.ReplayPlayerController:ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous',
        confidence: 'confirmed-native-component-data-stream',
        diagnostic: {
          netGuid,
          chIndex: player?.chIndex ?? null,
          slotIndex: player?.slotIndex ?? null,
          loadoutIndex: player?.loadoutIndex ?? null,
          initialSide: player?.initialSide ?? null,
          sideSource: player?.sideSource ?? null,
          archetypePath: player?.archetypePath ?? null,
          sampleCount: ordered.length,
        },
        samples: ordered.map((sample) => ({
          timeMs: Math.max(0, Math.round(sample.adjustedTimeMs)),
          x: round(sample.position.x, 3),
          y: round(sample.position.y, 3),
          z: round(sample.position.z, 3),
          yawDegrees: round(sample.viewRotation?.yaw ?? 0, 3),
          pitchDegrees: round(sample.viewRotation?.pitch ?? 0, 3),
          streamTimestamp: sample.streamTimestamp,
          movementState: sample.diagnostics?.movementState ?? null,
          moveType: sample.diagnostics?.moveType ?? null,
        })),
        stateSamples: lifeState.stateSamples,
        lifeSegments: lifeState.lifeSegments,
        deathEvents: lifeState.deathEvents,
        respawnEvents: lifeState.respawnEvents,
        notes: `Decoded from native ComponentDataStream RemoteCharacterUpdates for ${slotLabel}.`,
      };
    });
  const movementUtilityActors = buildMovementUtilityActors(
    samples,
    playerByGuid,
    abilityCasts,
    diagnostics,
  );
  const focusProjectileReferences = focusProjectileReferencesFromDiagnostics(diagnostics);
  const utilityActors = linkUtilityActorsToAbilityCasts(
    rawUtilityActors,
    abilityCasts,
    focusProjectileReferences,
  );
  classifyUtilityActorCloses({
    utilityActors,
    abilitySignals: abilitySignalsFromDiagnostics(diagnostics),
    roundStartEvents,
    deathEvents,
  });
  const abilityActions = buildReplayAbilityActions(
    abilityCasts,
    utilityActors,
    ultimateEvents,
    inputEvents,
    abilityStateEvents,
    abilityRpcEvents,
  );
  decorateAbilityActionsWithLifecycle(abilityActions, utilityActors);

  return {
    abilitySchemaVersion: 3,
    sourceLabel: `VRF native ComponentDataStream: ${path.basename(diagnostics.inputPath ?? 'unknown replay')}`,
    coordinateSpace: 'game',
    mapId: diagnostics.header?.mapPath ?? null,
    durationMs,
    notes:
      `Decoded from Valorant replay-controller RemoteCharacterUpdates using the seeded payload transform for ${diagnostics.header?.branch ?? 'an unknown build'}.`,
    decoder: {
      targetRpc:
        '/Script/ShooterGame.ReplayPlayerController:ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous',
      branch: diagnostics.header?.branch ?? null,
      staticDecoderIndex: diagnostics.staticDecoderIndex ?? null,
      sampleShape:
        '{timeMs, x, y, z, yawDegrees, pitchDegrees, streamTimestamp, movementState, moveType}',
      lifeStateShape:
        '{stateSamples, lifeSegments, deathEvents, respawnEvents}; dead states are characterDeath payloads, alive resets are inferred from roundStarted events',
      abilityCastShape:
        '{playerSubject, abilitySlot, round, roundPhase, castTime, castLocation, effectLocations, destroyedCount, effects}; CharacterAbilityCastInfo decoded from AbilityCastsThisRound',
      candidateUtilityTrackCount: movementUtilityActors.length,
      candidateUtilityTrackNote:
        'Non-player ComponentDataStream tracks remain candidate evidence and are not promoted into app-facing utilityActors without a replay-native actor identity join.',
      inputEventShape:
        '{playerReplayId, playerLoadoutIndex, eventType, eventValueNibble, serializedBitCount, serializedDataHex, eventProcessingResult}; decoded from ClientReplayReceiveInputEventProcessingCapture',
      inputEventSummary:
        diagnostics.frameSummary?.nonMovementInputEventSummary ?? null,
      abilityStateEventShape:
        '{equippableNetGuid, stateNetGuid, statePath, stateName, canonicalAbilityId, owner}; exact CurrentState NetGUID path transitions',
      abilityRpcEventShape:
        '{actorNetGuid, rpcName, phaseType, canonicalAbilityId, payloadBitCount}; observed ability-actor lifecycle/effect RPC',
      abilitySignalCapture: {
        count:
          diagnostics.frameSummary?.abilitySignalSamples?.length ??
          diagnostics.frameSummary?.compactAbilitySignalSamples?.length ??
          0,
        sampleLimit:
          diagnostics.frameSummary?.abilitySignalSampleLimit ??
          diagnostics.frameSummary?.compactAbilitySignalSampleLimit ??
          null,
        overflowCount:
          diagnostics.frameSummary?.abilitySignalOverflowCount ??
          diagnostics.frameSummary?.compactAbilitySignalOverflowCount ??
          null,
      },
      abilityCapabilities: {
        characterAbilityCastInfo: true,
        castRoundPhaseAndTime: true,
        castLocationsAndEffects: true,
        actorChannelOpenClose: true,
        typedInputCapture: true,
        inputAbilitySlot: true,
        inputEquippableIdentity: true,
        equippableStateTransitions: true,
        abilityLifecycleRpcEvents: true,
        directActorOwner: false,
        semanticTerminationCause: false,
        canonicalAbilityActions: true,
      },
      positionValidation: positionValidation ?? {
        mode: 'unknown',
        mapKey: mapKeyFromPath(diagnostics.header?.mapPath),
      },
    },
    players,
    abilityCasts,
    abilityActions,
    utilityActors,
    candidateUtilityActors: movementUtilityActors,
    deathEvents,
    roundStartEvents,
    sideSwitchEvents,
    ultimateEvents,
    inputEvents,
    abilityStateEvents,
    abilityRpcEvents,
  };
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

function archetypeTokens(value) {
  return archetypeClassName(value)
    .split(/[^A-Za-z0-9]+/)
    .map((token) => token.toLowerCase())
    .filter(Boolean);
}

function playerAgentFromActorPath(actorPath) {
  const className = archetypeClassName(actorPath);
  const token = className.replace(/_PC$/i, '').toLowerCase();
  return VALORANT_AGENT_ARCHETYPE_TOKENS.get(token) ?? null;
}

function abilityNameFor(agent, abilityIndex) {
  if (!agent || !Number.isInteger(abilityIndex)) return null;
  return AGENT_ABILITY_NAMES.get(agent)?.[abilityIndex] ?? null;
}

let staticAgentAbilityCatalog = null;

function loadStaticAgentAbilityCatalog() {
  if (staticAgentAbilityCatalog) return staticAgentAbilityCatalog;
  staticAgentAbilityCatalog = new Map();
  let primaryIndex = readJsonIfExists(
    path.join(STATIC_DECODER_INDEX_DIR, 'agent_primary_index.json'),
  );
  if (
    !(primaryIndex?.agents ?? []).some(
      (agent) => Array.isArray(agent.abilities) && agent.abilities.length > 0,
    )
  ) {
    primaryIndex = readJsonIfExists(
      path.join(BUNDLED_DECODER_INDEX_DIR, 'agent_primary_index.json'),
    );
  }
  for (const agent of primaryIndex?.agents ?? []) {
    const abilities = new Map(
      (agent.abilities ?? [])
        .filter((ability) => ability?.abilitySlot)
        .map((ability) => [ability.abilitySlot, ability]),
    );
    const entry = { ...agent, abilities };
    if (agent.shippingName) {
      staticAgentAbilityCatalog.set(normalizedAgentName(agent.shippingName), entry);
    }
    if (agent.developerName) {
      staticAgentAbilityCatalog.set(normalizedAgentName(agent.developerName), entry);
    }
  }
  return staticAgentAbilityCatalog;
}

function staticAbilityForSlot(agent, abilitySlot) {
  if (!agent || !abilitySlot) return null;
  return (
    loadStaticAgentAbilityCatalog()
      .get(normalizedAgentName(agent))
      ?.abilities.get(abilitySlot) ?? null
  );
}

function defaultAbilityIndexForSlot(abilitySlot) {
  switch (abilitySlot) {
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

// Miks has four network slots and five Icarus visuals: M-pulse's healing and
// concuss modes use distinct icons while sharing the Grenade slot.
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

  const abilityIndex = defaultAbilityIndexForSlot(abilitySlot);
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

function readJsonIfExists(filePath) {
  try {
    if (!fs.existsSync(filePath)) return null;
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch {
    return null;
  }
}

function normalizeAssetClassName(value) {
  return archetypeClassName(value).toLowerCase();
}

let staticAbilityIdentityIndex = null;

function addStaticIdentityKey(map, key, identity) {
  const normalized = normalizeAssetClassName(key);
  if (normalized && !map.has(normalized)) map.set(normalized, identity);
}

function normalizeExactAssetPath(value) {
  const match = String(value ?? '').match(/\/Game\/[^'"\s]+/i);
  if (!match) return null;
  return match[0].split('.')[0].toLowerCase();
}

function loadStaticAbilityIdentityIndex() {
  if (staticAbilityIdentityIndex) return staticAbilityIdentityIndex;
  const byClassName = new Map();
  const byAssetPath = new Map();
  const abilityIdentityIndex = readJsonIfExists(
    path.join(STATIC_DECODER_INDEX_DIR, 'ability_identity_index.json'),
  );
  for (const [className, identity] of Object.entries(abilityIdentityIndex?.classes ?? {})) {
    addStaticIdentityKey(byClassName, className, identity);
  }
  for (const [assetPath, identity] of Object.entries(abilityIdentityIndex?.assets ?? {})) {
    byAssetPath.set(assetPath.toLowerCase(), identity);
  }
  staticAbilityIdentityIndex = { byClassName, byAssetPath };
  return staticAbilityIdentityIndex;
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

function abilitySignalMetadataFromActorPath(actorPath) {
  const staticIndex = loadStaticAbilityIdentityIndex();
  const exactAssetPath = normalizeExactAssetPath(actorPath);
  const identity =
    (exactAssetPath ? staticIndex.byAssetPath.get(exactAssetPath) : null) ??
    staticIndex.byClassName.get(normalizeAssetClassName(actorPath));
  const override = classAbilityOverride(actorPath);
  if (override && !identity) {
    return {
      ...override,
      sourceAbilityClass: identity?.sourceAbilityAsset ?? null,
      sourceAbilitySlot: override.abilitySlot,
      sourceAbilityName: override.abilityName,
      sourceAbilityAssetPath: identity?.sourceAbilityAsset ?? null,
      staticAbilitySlot: identity?.abilitySlot ?? null,
      staticAbilityName: identity?.abilityName ?? null,
      staticAssetPath: identity?.staticAssetPath ?? null,
      staticAssetKind: identity?.staticAssetKind ?? null,
      identitySource: 'class-name-override',
      identityConfidence: 'high',
    };
  }
  if (identity) {
    const slotIdentity = abilityIdentityForSlot(identity.agent, identity.abilitySlot, {
      className: archetypeClassName(actorPath),
      canonicalName: identity.abilityName,
    });
    const abilityIndex = slotIdentity.abilityIndex ??
      (Number.isInteger(identity.abilityIndex) ? identity.abilityIndex : null);
    return {
      agent: identity.agent ?? null,
      icarusAgentType:
        (identity.agent ? ICARUS_AGENT_TYPE_BY_AGENT.get(identity.agent) : null) ??
        identity.icarusAgentType ??
        null,
      abilitySlot: identity.abilitySlot ?? null,
      abilityIndex,
      abilityName: slotIdentity.abilityName ?? identity.abilityName,
      sourceAbilityClass: identity.sourceAbilityAsset ?? null,
      sourceAbilitySlot: identity.abilitySlot ?? null,
      sourceAbilityName:
        identity.abilityName ?? abilityNameFor(identity.agent, abilityIndex),
      sourceAbilityAssetPath: identity.sourceAbilityAsset ?? null,
      staticAbilitySlot: identity.abilitySlot ?? null,
      staticAbilityName: identity.abilityName ?? null,
      staticAssetPath: identity.staticAssetPath ?? null,
      staticAssetKind: identity.staticAssetKind ?? null,
      identitySource: `static-${identity.source ?? 'ability-identity'}`,
      identityConfidence: 'high',
    };
  }

  return inferAbilityIdentityFromLeafTokenFallback(actorPath);
}

function playerGuidByActorPath(players) {
  const result = new Map();
  for (const player of players ?? []) {
    const actorPath = player.diagnostic?.archetypePath;
    const netGuid = player.diagnostic?.netGuid;
    if (actorPath && Number.isInteger(netGuid) && !result.has(actorPath)) {
      result.set(actorPath, netGuid);
    }
  }
  return result;
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
    x: round(buffer.readDoubleLE(offset)),
    y: round(buffer.readDoubleLE(offset + 8)),
    z: round(buffer.readDoubleLE(offset + 16)),
  };
  return isPlausibleAbilityVector(vector) ? vector : null;
}

function decodeMapTargetingSingleClickVector(sample) {
  if (sample?.fieldName !== 'MulticastRespondToValidSingleMapClick') return null;
  if (!/MapTargetingStateComponent/i.test(sample.actorGroup ?? '')) return null;
  const payloadHex = sample.payloadHex ?? '';
  if (!payloadHex || sample.payloadHexTruncated) return null;

  const bitCount = sample.numBits ?? sample.numPayloadBits ?? payloadHex.length * 4;
  const cursor = new BitCursor(Buffer.from(payloadHex, 'hex'), bitCount);
  cursor.skipBits(1);
  const rawHandle = cursor.readIntPacked();
  if (rawHandle !== 1) return null;
  const vectorBits = cursor.readIntPacked();
  if (vectorBits !== 192 || !cursor.canRead(vectorBits)) return null;
  const vectorBuffer = copyBits(cursor.buffer, cursor.offset, vectorBits);
  if (cursor.isError) return null;
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
        if (
          placement.agent &&
          cast.agent &&
          normalizedAgentName(placement.agent) !== normalizedAgentName(cast.agent)
        ) return false;
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

function readFStringFromBitCursor(cursor) {
  if (!cursor.canRead(32)) return null;
  const rawLength = cursor.readUInt32();
  const length = rawLength > 0x7fffffff ? rawLength - 0x100000000 : rawLength;
  if (length === 0) return '';
  if (length > 0) {
    if (length > 1_000_000 || !cursor.canRead(length * 8)) return null;
    const bytes = cursor.readBytes(length);
    return bytes.subarray(0, Math.max(0, bytes.length - 1)).toString('utf8');
  }
  const charCount = -length;
  if (charCount > 500_000 || !cursor.canRead(charCount * 16)) return null;
  const bytes = cursor.readBytes(charCount * 2);
  return bytes.subarray(0, Math.max(0, bytes.length - 2)).toString('utf16le');
}

function parseStringTableTextPayload(buffer, bitCount) {
  const cursor = new BitCursor(buffer, bitCount);
  // FText's network serializer prefixes a one-bit presence/history flag. The
  // remaining StringTableEntry payload is ordinary byte data, even when the
  // containing user-defined struct field began at a non-byte bit offset.
  if (!cursor.canRead(1 + 32 + 8)) return null;
  const prefixBit = cursor.readBit() ? 1 : 0;
  const flags = cursor.readUInt32();
  const historyType = cursor.readByte();
  if (cursor.isError || historyType !== 5) {
    return { prefixBit, flags, historyType, tableId: null, key: null };
  }
  const tableId = readFStringFromBitCursor(cursor);
  if (tableId == null || !cursor.canRead(32)) {
    return { prefixBit, flags, historyType, tableId, key: null };
  }
  const tableIdNumber = cursor.readUInt32();
  const key = readFStringFromBitCursor(cursor);
  return {
    prefixBit,
    flags,
    historyType,
    tableId,
    tableIdNumber,
    key,
  };
}

function readUserStructFields(cursor) {
  const fields = new Map();
  while (!cursor.atEnd() && cursor.bitsLeft >= 8) {
    const handle = cursor.readIntPacked();
    if (cursor.isError) break;
    if (handle === 0) return { fields, terminated: true };
    const bitCount = cursor.readIntPacked();
    if (
      cursor.isError ||
      !Number.isInteger(bitCount) ||
      bitCount < 0 ||
      !cursor.canRead(bitCount)
    ) {
      return { fields, terminated: false, error: 'invalid-field-bit-count' };
    }
    const payload = copyBits(cursor.buffer, cursor.offset, bitCount);
    cursor.skipBits(bitCount);
    fields.set(handle, { handle, bitCount, payload });
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
  const cursor = new BitCursor(field.payload, field.bitCount);
  const count = cursor.readIntPacked();
  if (cursor.isError || count < 0 || count > 64) return [];
  const targets = [];
  for (let index = 0; index < count; index += 1) {
    const elementMarker = cursor.readIntPacked();
    if (cursor.isError || elementMarker !== 1) break;
    const parsed = readUserStructFields(cursor);
    const playerField = parsed.fields.get(20);
    const valueField = parsed.fields.get(21);
    let affectedPlayerNetGuid = null;
    if (playerField) {
      const playerCursor = new BitCursor(playerField.payload, playerField.bitCount);
      affectedPlayerNetGuid = playerCursor.readIntPacked();
      if (playerCursor.isError) affectedPlayerNetGuid = null;
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
  const cursor = new BitCursor(buffer, Math.min(bitCount, buffer.length * 8));
  const count = cursor.readIntPacked();
  if (cursor.isError || count < 0 || count > 64) return [];
  const effects = [];
  for (let index = 0; index < count; index += 1) {
    const elementMarker = cursor.readIntPacked();
    if (cursor.isError || elementMarker !== 1) break;
    const parsed = readUserStructFields(cursor);
    const statisticField = parsed.fields.get(15);
    const localizedField = parsed.fields.get(16);
    const statisticIndex = statisticField
      ? new BitCursor(statisticField.payload, statisticField.bitCount).readBitsUnsigned(
          statisticField.bitCount,
        )
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

function decodeAbilityCastEntriesFromSample(sample, playersByActorPath) {
  if (sample?.fieldName !== 'AbilityCastsThisRound') return [];
  const payloadHex = sample.payloadHex ?? '';
  if (!payloadHex || sample.payloadHexTruncated) return [];

  const buffer = Buffer.from(payloadHex, 'hex');
  const ascii = buffer.toString('latin1');
  const agentEntry = playerAgentFromActorPath(sample.actorPath);
  const playerNetGuid =
    Number.isInteger(sample.actorNetGuid)
      ? sample.actorNetGuid
      : playersByActorPath.get(sample.actorPath) ?? null;
  const entries = [];
  ABILITY_CAST_UUID_PATTERN.lastIndex = 0;
  let match;
  while ((match = ABILITY_CAST_UUID_PATTERN.exec(ascii))) {
    const uuidStart = match.index;
    const uuidEnd = uuidStart + match[0].length;
    if (buffer[uuidEnd] !== 0) continue;

    const afterNull = uuidEnd + 1;
    const slotEnumValue = buffer[afterNull + 2];
    const abilitySlot = ARES_ITEM_SLOT_TO_ABILITY_SLOT.get(slotEnumValue) ?? null;
    if (abilitySlot == null) continue;
    const slotIdentity = abilityIdentityForSlot(agentEntry?.agent, abilitySlot, {
      className: sample.actorPath,
    });
    const abilityIndex = slotIdentity.abilityIndex;
    const abilityName = slotIdentity.abilityName;

    const scalarFields = parseCharacterAbilityCastScalarFields(buffer, afterNull);
    if (scalarFields.castTimeSeconds == null) continue;

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
      playerNetGuid,
      playerSubject: match[0],
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
      linkedUtilityActorIds: [],
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

function abilityCastsFromDiagnostics(diagnostics, players) {
  const frameSummary = diagnostics.frameSummary ?? {};
  const rawSamples = Array.isArray(frameSummary.abilityCastSignalSamples)
    ? frameSummary.abilityCastSignalSamples
    : frameSummary.abilitySignalSamples;
  const compactSamples = Array.isArray(frameSummary.compactAbilityCastSignalSamples)
    ? frameSummary.compactAbilityCastSignalSamples
    : frameSummary.compactAbilitySignalSamples;
  const samples = [
    ...(Array.isArray(rawSamples) ? rawSamples : []),
    ...(Array.isArray(compactSamples) ? compactSamples : []),
  ];
  const placementSamples = [
    ...(Array.isArray(frameSummary.abilitySignalSamples) ? frameSummary.abilitySignalSamples : []),
    ...(Array.isArray(frameSummary.compactAbilitySignalSamples)
      ? frameSummary.compactAbilitySignalSamples
      : []),
  ];
  if (samples.length === 0) return [];

  const playersByActorPath = playerGuidByActorPath(players);
  const roundStartEvents = timelineRoundStartEventsFromDiagnostics(diagnostics);
  const casts = [];
  const seen = new Map();
  for (const sample of samples) {
    for (const decodedEntry of decodeAbilityCastEntriesFromSample(sample, playersByActorPath)) {
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
      const existingIndex = seen.get(key);
      if (existingIndex != null) {
        if (casts[existingIndex].replicationTimeMs > entry.replicationTimeMs) {
          casts[existingIndex] = entry;
        }
        continue;
      }
      seen.set(key, casts.length);
      casts.push(entry);
    }
  }

  casts.sort((a, b) => a.timeMs - b.timeMs || String(a.playerSubject).localeCompare(b.playerSubject));
  const sortedCasts = casts.map((cast, index) => ({ ...cast, id: `cast-${index}` }));
  return attachPlacementSignalsToAbilityCasts(
    sortedCasts,
    placementSignalsFromAbilitySignalSamples(placementSamples),
  );
}

function strictActorMatchesCast(actor, cast) {
  const actorAgent = actor.agent ?? actor.agentShippingName ?? null;
  const actorSlot = actor.sourceAbilitySlot ?? actor.abilitySlot ?? null;
  return Boolean(
    actorAgent &&
      cast.agent &&
      normalizedAgentName(actorAgent) === normalizedAgentName(cast.agent) &&
      actorSlot &&
      cast.abilitySlot &&
      actorSlot === cast.abilitySlot &&
      !actor.ignoredAsAbility &&
      actor.contentKind !== 'pickup-drop',
  );
}

function resolveAbilityCastTimes(casts, utilityActors, roundStartEvents) {
  const roundStartByIndex = new Map(
    (roundStartEvents ?? []).map((event) => [event.roundIndex, event]),
  );
  const resolved = (casts ?? []).map((cast) => {
    const replicationTimeMs = cast.replicationTimeMs ?? cast.timeMs;
    let timeMs = cast.timeMs;
    let timeSource = cast.timeSource ?? 'AbilityCastsThisRound-replication-observation';
    let phaseCandidateMs = null;

    if (
      cast.roundPhase === 'RoundStarting' &&
      Number.isFinite(cast.castTimeSeconds)
    ) {
      const roundStart = roundStartByIndex.get(cast.roundIndex);
      if (roundStart) {
        phaseCandidateMs = Math.round(
          roundStart.timeMs + cast.castTimeSeconds * 1000,
        );
        timeMs = phaseCandidateMs;
        timeSource = 'roundStarted+CharacterAbilityCastInfo-CastTime';
      }
    }

    const actorWindowMs = cast.roundPhase === 'RoundStarting' ? 750 : 250;
    const anchorMs = phaseCandidateMs ?? replicationTimeMs;
    const actorAnchor = (utilityActors ?? [])
      .filter(
        (actor) =>
          strictActorMatchesCast(actor, cast) &&
          Number.isFinite(actor.timeMs) &&
          Math.abs(actor.timeMs - anchorMs) <= actorWindowMs,
      )
      .sort(
        (a, b) =>
          Math.abs(a.timeMs - anchorMs) - Math.abs(b.timeMs - anchorMs),
      )[0];
    if (actorAnchor) {
      // The actor open corroborates the decoded agent/slot window, but it is
      // not a causal cast timestamp. Never replace CharacterAbilityCastInfo
      // time (or the observed replication time) with a proximity join.
    }

    const evidenceRoles = [...(cast.evidenceRoles ?? [])];
    if (!evidenceRoles.includes(timeSource)) evidenceRoles.push(timeSource);
    if (actorAnchor) {
      evidenceRoles.push('corroborated-by-matching-actor-channel-open');
    }
    return {
      ...cast,
      timeMs,
      timeSource,
      phaseTimeCandidateMs: phaseCandidateMs,
      timeAnchorUtilityActorId: actorAnchor?.id ?? null,
      evidenceRoles,
    };
  });

  resolved.sort(
    (a, b) =>
      a.timeMs - b.timeMs ||
      (a.replicationTimeMs ?? 0) - (b.replicationTimeMs ?? 0) ||
      String(a.playerSubject).localeCompare(String(b.playerSubject)),
  );
  return resolved.map((cast, index) => ({ ...cast, id: `cast-${index}` }));
}

function focusProjectileReferencesFromDiagnostics(diagnostics) {
  const references = [];
  for (const sample of abilitySignalsFromDiagnostics(diagnostics)) {
    if (!/FocusProjectiles/i.test(sample.fieldName ?? '')) continue;
    const agentEntry = playerAgentFromActorPath(sample.actorPath);
    for (const reference of sample.focusProjectileReferences ?? []) {
      if (!Number.isInteger(reference?.netGuid)) continue;
      references.push({
        actorNetGuid: reference.netGuid,
        timeMs: sample.timeMs,
        agent: agentEntry?.agent ?? null,
        playerNetGuid: sample.actorNetGuid ?? null,
        actorPath: sample.actorPath ?? null,
      });
    }
  }
  return references;
}

function nearestFocusProjectileReference(actor, focusProjectileReferences) {
  return focusProjectileReferences
    .filter((reference) => reference.actorNetGuid === actor.actorNetGuid)
    .sort((a, b) => Math.abs(actor.timeMs - a.timeMs) - Math.abs(actor.timeMs - b.timeMs))[0] ?? null;
}

function linkUtilityActorsToAbilityCasts(utilityActors, abilityCasts, focusProjectileReferences = []) {
  if (!Array.isArray(utilityActors) || !Array.isArray(abilityCasts) || abilityCasts.length === 0) {
    return utilityActors;
  }

  const linkedActorIdsByCast = new Map(abilityCasts.map((cast) => [cast.id, []]));
  const result = utilityActors.map((actor) => {
    if (actor.ignoredAsAbility || actor.contentKind === 'pickup-drop') return actor;
    const actorSlot = actor.sourceAbilitySlot ?? actor.abilitySlot;
    const actorAgent = actor.agent ?? actor.agentShippingName;
    const focusReference = nearestFocusProjectileReference(actor, focusProjectileReferences);
    let linkRole = 'linked-to-partial-cast';
    let candidates = [];
    if (focusReference) {
      linkRole = 'linked-to-focus-projectile-cast';
      candidates = abilityCasts
        .filter((cast) => {
          if (
            focusReference.agent &&
            cast.agent &&
            normalizedAgentName(focusReference.agent) !== normalizedAgentName(cast.agent)
          ) return false;
          if (
            actorAgent &&
            cast.agent &&
            normalizedAgentName(actorAgent) !== normalizedAgentName(cast.agent)
          ) return false;
          if (actorSlot && cast.abilitySlot && actorSlot !== cast.abilitySlot) return false;
          if (
            Number.isInteger(focusReference.playerNetGuid) &&
            Number.isInteger(cast.playerNetGuid) &&
            focusReference.playerNetGuid !== cast.playerNetGuid
          ) {
            return false;
          }
          return Math.abs(cast.timeMs - focusReference.timeMs) <= 500;
        })
        .sort((a, b) => Math.abs(a.timeMs - focusReference.timeMs) - Math.abs(b.timeMs - focusReference.timeMs));
    }
    if (!candidates.length) {
      candidates = abilityCasts
        .filter((cast) => {
          if (actorSlot && cast.abilitySlot && actorSlot !== cast.abilitySlot) return false;
          if (
            actorAgent &&
            cast.agent &&
            normalizedAgentName(actorAgent) !== normalizedAgentName(cast.agent)
          ) return false;
          return actor.timeMs >= cast.timeMs - 250 && actor.timeMs - cast.timeMs <= 3500;
        })
        .sort((a, b) => Math.abs(actor.timeMs - a.timeMs) - Math.abs(actor.timeMs - b.timeMs));
    }
    if (!candidates.length && actor.phase === 'submunition') {
      linkRole = 'linked-to-nearest-cast';
      candidates = abilityCasts
      .filter((cast) => {
        if (
          actorAgent &&
          cast.agent &&
          normalizedAgentName(actorAgent) !== normalizedAgentName(cast.agent)
        ) return false;
        if (actorSlot && cast.abilitySlot && actorSlot !== cast.abilitySlot) return false;
        return actor.timeMs >= cast.timeMs - 250 && actor.timeMs - cast.timeMs <= 3500;
      })
      .sort((a, b) => Math.abs(actor.timeMs - a.timeMs) - Math.abs(actor.timeMs - b.timeMs));
    }
    const cast = candidates[0] ?? null;
    if (!cast) return actor;
    if (linkRole !== 'linked-to-focus-projectile-cast') {
      return {
        ...actor,
        candidateSourceCastId: cast.id,
        candidateSourceCastEvidence: linkRole,
        candidateSourceCastConfidence:
          'derived-replay-agent-slot-time-window',
        evidenceRoles: [...new Set([...(actor.evidenceRoles ?? []), linkRole])],
      };
    }
    linkedActorIdsByCast.get(cast.id)?.push(
      actor.id ?? `actor-${actor.actorNetGuid ?? actor.chIndex}`,
    );
    return {
      ...actor,
      sourceCastId: cast.id,
      sourceCastLinkEvidence: linkRole,
      sourceCastLinkConfidence:
        linkRole === 'linked-to-focus-projectile-cast'
          ? 'derived-replay-netguid-and-time'
          : 'derived-replay-agent-slot-time-window',
      phaseGroupId: actor.phaseGroupId ?? cast.id,
      ownerPlayerNetGuid: cast.playerNetGuid ?? actor.ownerPlayerNetGuid ?? null,
      ownerSubject: cast.playerSubject ?? actor.ownerSubject ?? null,
      ownerSource: 'derived:strict-replay-cast-phase-join',
      ownerConfidence: 'derived-replay-cross-lane',
      evidenceRoles: [...new Set([...(actor.evidenceRoles ?? []), linkRole])],
    };
  });

  for (const cast of abilityCasts) {
    cast.linkedUtilityActorIds = linkedActorIdsByCast.get(cast.id) ?? [];
  }
  return result;
}

function abilitySignalsFromDiagnostics(diagnostics) {
  const frameSummary = diagnostics.frameSummary ?? {};
  const raw = Array.isArray(frameSummary.abilitySignalSamples)
    ? frameSummary.abilitySignalSamples
    : [];
  const compact = Array.isArray(frameSummary.compactAbilitySignalSamples)
    ? frameSummary.compactAbilitySignalSamples
    : [];
  return (raw.length > 0 ? raw : compact).filter(
    (sample) => sample.timeMs != null,
  );
}

function movementDistance2d(samples) {
  let maxDistanceSq = 0;
  for (let left = 0; left < samples.length; left += 1) {
    for (let right = left + 1; right < samples.length; right += 1) {
      const dx = samples[right].position.x - samples[left].position.x;
      const dy = samples[right].position.y - samples[left].position.y;
      maxDistanceSq = Math.max(maxDistanceSq, dx * dx + dy * dy);
    }
  }
  return Math.sqrt(maxDistanceSq);
}

function distance3d(a, b) {
  const dx = (a?.x ?? 0) - (b?.x ?? 0);
  const dy = (a?.y ?? 0) - (b?.y ?? 0);
  const dz = (a?.z ?? 0) - (b?.z ?? 0);
  return Math.sqrt(dx * dx + dy * dy + dz * dz);
}

function abilitySignalClassName(signal) {
  return archetypeClassName(signal?.actorPath);
}

function knownUtilityActorGuidsFromDiagnostics(diagnostics) {
  const frameSummary = diagnostics.frameSummary ?? {};
  const samples = [
    ...(Array.isArray(frameSummary.utilityActorOpenSamples)
      ? frameSummary.utilityActorOpenSamples
      : []),
    ...(Array.isArray(frameSummary.compactUtilityActorOpenSamples)
      ? frameSummary.compactUtilityActorOpenSamples
      : []),
  ];
  return new Set(
    samples
      .map((sample) => sample.actorNetGuid)
      .filter((actorNetGuid) => Number.isInteger(actorNetGuid)),
  );
}

function uniquePlayerForAgent(playerByGuid, agent) {
  if (!agent) return null;
  const matches = [...playerByGuid.values()].filter(
    (player) => normalizedAgentName(player.agent) === normalizedAgentName(agent),
  );
  return matches.length === 1 ? matches[0] : null;
}

function stationarySignalMetadata(signal) {
  const className = abilitySignalClassName(signal);
  if (!className) return null;
  const ability = abilitySignalMetadataFromActorPath(signal.actorPath);
  if (/Killjoy_E_Turret/i.test(className)) {
    return {
      ...ability,
      className,
      utilityKind: 'deployable',
      phase: 'deployable-pawn',
      staticAssetKind: 'deployable_pawn',
    };
  }
  if (/Killjoy_Q_Alarmbot/i.test(className)) {
    return {
      ...ability,
      className,
      utilityKind: 'deployable',
      phase: 'deployable-pawn',
      staticAssetKind: 'deployable_pawn',
    };
  }
  if (/Killjoy_4_RemoteBees|RemoteBees|Nanoswarm/i.test(className)) {
    return {
      ...ability,
      className,
      utilityKind: 'area-effect',
      phase: 'placed-object',
      staticAssetKind: 'ability',
    };
  }
  if (/Hunter_Q_RevealBolt|RevealBolt|Sonar/i.test(className)) {
    return {
      ...ability,
      className,
      utilityKind: 'reveal',
      phase: 'placed-object',
      staticAssetKind: 'ability',
    };
  }
  return null;
}

function nearestStationaryUtilitySignal(signals, first) {
  return signals
    .map((signal) => ({ signal, metadata: stationarySignalMetadata(signal) }))
    .filter(({ signal, metadata }) => {
      if (!metadata?.agent || !metadata.abilitySlot) return false;
      const deltaMs = first.adjustedTimeMs - signal.timeMs;
      return deltaMs >= -250 && deltaMs <= 900;
    })
    .sort(
      (a, b) =>
        Math.abs(first.adjustedTimeMs - a.signal.timeMs) -
        Math.abs(first.adjustedTimeMs - b.signal.timeMs),
    )[0] ?? null;
}

function nearestAbilitySignalForCast(signals, cast) {
  return signals
    .filter((signal) => {
      if (Math.abs(signal.timeMs - cast.timeMs) > 1600) return false;
      const metadata = abilitySignalMetadataFromActorPath(signal.actorPath);
      return (
        normalizedAgentName(metadata.agent) === normalizedAgentName(cast.agent) &&
        /^Ability_/i.test(abilitySignalClassName(signal))
      );
    })
    .sort((a, b) => Math.abs(a.timeMs - cast.timeMs) - Math.abs(b.timeMs - cast.timeMs))[0] ?? null;
}

function utilityKindFromAbilityClassName(className) {
  if (/Boomba|BoomBot/i.test(className)) return 'deployable';
  if (/ClusterGrenade|Grenade|Projectile|PaintShell/i.test(className)) return 'projectile';
  if (/Reveal|Bolt|Dart|Recon/i.test(className)) return 'reveal';
  return 'projectile';
}

function phaseFromAbilityClassName(className) {
  if (/Boomba|BoomBot/i.test(className)) return 'deployable-pawn';
  if (/ClusterGrenade|Grenade|Projectile|PaintShell/i.test(className)) return 'projectile-flight';
  if (/Reveal|Bolt|Dart|Recon/i.test(className)) return 'projectile-flight';
  return 'projectile-flight';
}

function buildMovementUtilityActors(samples, playerByGuid, abilityCasts, diagnostics) {
  if (!Array.isArray(samples) || !abilityCasts.length) return [];
  const abilitySignals = abilitySignalsFromDiagnostics(diagnostics);
  const knownUtilityActorGuids = knownUtilityActorGuidsFromDiagnostics(diagnostics);
  const byGuid = new Map();
  const seen = new Set();
  for (const sample of samples) {
    if (!Number.isInteger(sample.netGuid) || playerByGuid.has(sample.netGuid)) continue;
    if (!sample.position) continue;
    const key = [
      sample.netGuid,
      sample.timeMs,
      sample.streamTimestamp,
      sample.position.x,
      sample.position.y,
      sample.position.z,
    ].join('|');
    if (seen.has(key)) continue;
    seen.add(key);
    if (!byGuid.has(sample.netGuid)) byGuid.set(sample.netGuid, []);
    byGuid.get(sample.netGuid).push(sample);
  }

  const actors = [];
  for (const [netGuid, rows] of byGuid.entries()) {
    if (rows.length < 3) continue;
    const ordered = adjustedSampleTimes(rows);
    const first = ordered[0];
    const last = ordered.at(-1);
    if (!first?.position || !last?.position) continue;
    const durationMs = Math.round(last.adjustedTimeMs - first.adjustedTimeMs);
    if (durationMs < 300) continue;
    const travelDistance = movementDistance2d(ordered);
    if (travelDistance < 150) {
      if (knownUtilityActorGuids.has(netGuid) || durationMs < 900) continue;
      const signalMatch = nearestStationaryUtilitySignal(abilitySignals, first);
      if (!signalMatch) continue;
      const { signal, metadata } = signalMatch;
      const owner = uniquePlayerForAgent(playerByGuid, metadata.agent);
      actors.push({
        id: `movement-utility-${netGuid}`,
        timeMs: Math.max(0, Math.round(first.adjustedTimeMs)),
        closedAtMs: Math.max(0, Math.round(last.adjustedTimeMs)),
        lifetimeMs: Math.max(250, durationMs),
        observedLifetimeMs: durationMs,
        durationSource: 'native-component-stationary-track',
        chIndex: null,
        actorNetGuid: netGuid,
        archetypePath: signal.actorPath ?? null,
        className: metadata.className,
        agent: metadata.agent,
        icarusAgentType: metadata.icarusAgentType ?? null,
        abilitySlot: metadata.abilitySlot,
        abilityIndex: metadata.abilityIndex ?? null,
        abilityName: metadata.abilityName ?? null,
        utilityKind: metadata.utilityKind,
        contentKind: 'component-stationary-track',
        phase: metadata.phase,
        sourceAbilityClass: signal.actorPath ?? null,
        sourceAbilitySlot: metadata.abilitySlot,
        sourceAbilityName: metadata.abilityName ?? null,
        sourceAbilityAssetPath: metadata.sourceAbilityAssetPath ?? null,
        sourceCastId: null,
        phaseGroupId: `${signal.actorPath ?? metadata.className}:${Math.max(0, Math.round(first.adjustedTimeMs))}`,
        ownerPlayerNetGuid: owner?.netGuid ?? null,
        ownerSubject: null,
        ownerSource: owner ? 'unique-agent+nearby-ability-component-signal' : 'nearby-ability-component-signal',
        ownerConfidence: owner
          ? 'component-track-start-near-deployable-signal+unique-agent'
          : 'component-track-start-near-deployable-signal',
        sourceContentKind: 'ability-class',
        staticAbilitySlot: metadata.staticAbilitySlot ?? null,
        staticAbilityName: metadata.staticAbilityName ?? null,
        staticAssetPath: metadata.staticAssetPath ?? signal.actorPath ?? null,
        staticAssetKind: metadata.staticAssetKind,
        identitySource: metadata.identitySource ?? null,
        identityConfidence: metadata.identityConfidence ?? null,
        evidenceRoles: [
          'native-component-movement-track',
          'stationary-component-track',
          'nearby-ability-component-signal',
        ],
        confidence: 'inferred-stationary-utility-from-component-track',
        position: {
          x: round(first.position.x, 3),
          y: round(first.position.y, 3),
          z: round(first.position.z, 3),
        },
        yawDegrees: round(first.viewRotation?.yaw ?? 0, 3),
        rotation: {
          pitchDegrees: round(first.viewRotation?.pitch ?? 0, 3),
          yawDegrees: round(first.viewRotation?.yaw ?? 0, 3),
          rollDegrees: round(first.viewRotation?.roll ?? 0, 3),
        },
        samples: ordered.map((sample) => ({
          timeMs: Math.max(0, Math.round(sample.adjustedTimeMs)),
          position: {
            x: round(sample.position.x, 3),
            y: round(sample.position.y, 3),
            z: round(sample.position.z, 3),
          },
          yawDegrees: round(sample.viewRotation?.yaw ?? 0, 3),
          pitchDegrees: round(sample.viewRotation?.pitch ?? 0, 3),
          streamTimestamp: sample.streamTimestamp,
          movementState: sample.diagnostics?.movementState ?? null,
          moveType: sample.diagnostics?.moveType ?? null,
        })),
        raw: {
          correlatedSignal: {
            timeMs: signal.timeMs,
            actorNetGuid: signal.actorNetGuid ?? null,
            actorPath: signal.actorPath ?? null,
            actorGroup: signal.actorGroup ?? null,
            repObject: signal.repObject ?? null,
            repObjectPath: signal.repObjectPath ?? null,
            fieldName: signal.fieldName ?? null,
            numBits: signal.numBits ?? null,
            payloadHex: signal.payloadHex ?? null,
          },
          travelDistance: round(travelDistance, 3),
        },
      });
      continue;
    }

    const cast = abilityCasts
      .filter((candidate) => {
        const deltaMs = first.adjustedTimeMs - candidate.timeMs;
        if (deltaMs < -250 || deltaMs > 1500) return false;
        if (!candidate.castLocation) return false;
        return distance3d(first.position, candidate.castLocation) <= 650;
      })
      .sort(
        (a, b) =>
          Math.abs(first.adjustedTimeMs - a.timeMs) - Math.abs(first.adjustedTimeMs - b.timeMs),
      )[0] ?? null;
    if (!cast) continue;

    const signal = nearestAbilitySignalForCast(abilitySignals, cast);
    const className =
      abilitySignalClassName(signal) || `MovementUtility_${cast.agent ?? 'Unknown'}_${cast.abilitySlot ?? 'Ability'}`;
    const signalMetadata = signal ? abilitySignalMetadataFromActorPath(signal.actorPath) : null;
    const utilityKind = utilityKindFromAbilityClassName(className);
    const phase = phaseFromAbilityClassName(className);
    const actorAgent = signalMetadata?.agent ?? cast.agent ?? null;
    const actorAbilitySlot = signalMetadata?.abilitySlot ?? cast.abilitySlot ?? null;
    const actorAbilityIndex = signalMetadata?.abilityIndex ?? cast.abilityIndex ?? null;
    const actorAbilityName = signalMetadata?.abilityName ?? cast.abilityName ?? null;
    actors.push({
      id: `movement-utility-${netGuid}`,
      timeMs: Math.max(0, Math.round(first.adjustedTimeMs)),
      closedAtMs: Math.max(0, Math.round(last.adjustedTimeMs)),
      lifetimeMs: Math.max(250, durationMs),
      observedLifetimeMs: durationMs,
      durationSource: 'native-component-movement-track',
      chIndex: null,
      actorNetGuid: netGuid,
      archetypePath: signal?.actorPath ?? null,
      className,
      agent: actorAgent,
      icarusAgentType: signalMetadata?.icarusAgentType ?? cast.icarusAgentType ?? null,
      abilitySlot: actorAbilitySlot,
      abilityIndex: actorAbilityIndex,
      abilityName: actorAbilityName,
      utilityKind,
      contentKind: 'component-movement-track',
      phase,
      sourceAbilityClass: signalMetadata?.sourceAbilityClass ?? signal?.actorPath ?? null,
      sourceAbilitySlot: signalMetadata?.sourceAbilitySlot ?? actorAbilitySlot,
      sourceAbilityName: signalMetadata?.sourceAbilityName ?? actorAbilityName,
      sourceAbilityAssetPath: signalMetadata?.sourceAbilityAssetPath ?? null,
      sourceCastId: cast.id,
      phaseGroupId: cast.id,
      ownerPlayerNetGuid: cast.playerNetGuid ?? null,
      ownerSubject: cast.playerSubject ?? null,
      ownerSource: 'nearest-cast-by-time-and-start-position',
      ownerConfidence: 'component-track-start-near-cast',
      staticAbilitySlot: signalMetadata?.staticAbilitySlot ?? null,
      staticAbilityName: signalMetadata?.staticAbilityName ?? null,
      staticAssetPath: signalMetadata?.staticAssetPath ?? null,
      staticAssetKind: signalMetadata?.staticAssetKind ?? null,
      identitySource: signalMetadata?.identitySource ?? null,
      identityConfidence: signalMetadata?.identityConfidence ?? null,
      evidenceRoles: [
        'native-component-movement-track',
        'linked-to-partial-cast',
        signal ? 'nearby-ability-component-signal' : null,
      ].filter(Boolean),
      confidence: 'inferred-moving-utility-from-component-track',
      position: {
        x: round(first.position.x, 3),
        y: round(first.position.y, 3),
        z: round(first.position.z, 3),
      },
      yawDegrees: round(first.viewRotation?.yaw ?? 0, 3),
      rotation: {
        pitchDegrees: round(first.viewRotation?.pitch ?? 0, 3),
        yawDegrees: round(first.viewRotation?.yaw ?? 0, 3),
        rollDegrees: round(first.viewRotation?.roll ?? 0, 3),
      },
      samples: ordered.map((sample) => ({
        timeMs: Math.max(0, Math.round(sample.adjustedTimeMs)),
        position: {
          x: round(sample.position.x, 3),
          y: round(sample.position.y, 3),
          z: round(sample.position.z, 3),
        },
        yawDegrees: round(sample.viewRotation?.yaw ?? 0, 3),
        pitchDegrees: round(sample.viewRotation?.pitch ?? 0, 3),
        streamTimestamp: sample.streamTimestamp,
        movementState: sample.diagnostics?.movementState ?? null,
        moveType: sample.diagnostics?.moveType ?? null,
      })),
    });
  }
  return actors.sort((a, b) => a.timeMs - b.timeMs || (a.actorNetGuid ?? 0) - (b.actorNetGuid ?? 0));
}

function utilityActorsFromDiagnostics(diagnostics) {
  const frameSummary = diagnostics.frameSummary ?? {};
  const rawSamples = frameSummary.utilityActorOpenSamples;
  const compactSamples = frameSummary.compactUtilityActorOpenSamples;
  const samples = Array.isArray(rawSamples) && rawSamples.length
    ? rawSamples
    : compactSamples;
  if (!Array.isArray(samples)) return [];
  return samples.map((sample) => ({
    id: sample.id ?? `actor-${sample.actorNetGuid ?? sample.chIndex}`,
    timeMs: sample.timeMs,
    closedAtMs: sample.closedAtMs ?? null,
    lifetimeMs: sample.lifetimeMs ?? null,
    observedLifetimeMs: sample.observedLifetimeMs ?? null,
    observedStartMs: sample.observedStartMs ?? sample.timeMs,
    observedEndMs: sample.observedEndMs ?? sample.closedAtMs ?? null,
    fallbackLifetimeMs: sample.fallbackLifetimeMs ?? null,
    fallbackEndMs: sample.fallbackEndMs ?? null,
    effectiveEndMs: sample.effectiveEndMs ?? sample.observedEndMs ?? sample.closedAtMs ?? null,
    lifecycleEvidence: sample.lifecycleEvidence ?? null,
    closeReason: sample.closeReason ?? null,
    dormant: sample.dormant ?? null,
    endReason: sample.endReason ?? null,
    endReasonEvidence: sample.endReasonEvidence ?? null,
    roundTeardownAtMs: sample.roundTeardownAtMs ?? null,
    roundTeardownEventId: sample.roundTeardownEventId ?? null,
    censoredAtMs: sample.censoredAtMs ?? null,
    lifecyclePolicy: sample.lifecyclePolicy ?? null,
    lifecyclePolicySource: sample.lifecyclePolicySource ?? null,
    verifiedAbilityId: sample.verifiedAbilityId ?? null,
    fallbackDurationSource: sample.fallbackDurationSource ?? null,
    durationSource: sample.durationSource ?? null,
    ignoredAsAbility: sample.ignoredAsAbility || undefined,
    chIndex: sample.chIndex ?? null,
    actorNetGuid: sample.actorNetGuid ?? null,
    archetypePath: sample.archetypePath ?? null,
    className: sample.className ?? null,
    agent: sample.agent ?? null,
    icarusAgentType: sample.icarusAgentType ?? null,
    abilitySlot: sample.abilitySlot ?? null,
    abilityIndex: sample.abilityIndex ?? null,
    abilityName: sample.abilityName ?? null,
    utilityKind: sample.utilityKind ?? null,
    contentKind: sample.contentKind ?? null,
    phase: sample.phase ?? null,
    sourceAbilityClass: sample.sourceAbilityClass ?? null,
    sourceAbilitySlot: sample.sourceAbilitySlot ?? null,
    sourceAbilityName: sample.sourceAbilityName ?? null,
    sourceAbilityAssetPath: sample.sourceAbilityAssetPath ?? null,
    sourceContentKind: sample.sourceContentKind ?? null,
    sourceCastId: sample.sourceCastId ?? null,
    parentActorNetGuid: sample.parentActorNetGuid ?? null,
    parentUtilityActorId: sample.parentUtilityActorId ?? null,
    phaseGroupId: sample.phaseGroupId ?? null,
    sequenceIndex: sample.sequenceIndex ?? null,
    ownerPlayerNetGuid: sample.ownerPlayerNetGuid ?? null,
    ownerSubject: sample.ownerSubject ?? null,
    ownerSource: sample.ownerSource ?? null,
    ownerConfidence: sample.ownerConfidence ?? null,
    staticAbilitySlot: sample.staticAbilitySlot ?? null,
    staticAbilityName: sample.staticAbilityName ?? null,
    staticAssetPath: sample.staticAssetPath ?? null,
    staticAssetKind: sample.staticAssetKind ?? null,
    identitySource: sample.identitySource ?? null,
    identityConfidence: sample.identityConfidence ?? null,
    agentUuid: sample.agentUuid ?? null,
    characterId: sample.characterId ?? null,
    agentDeveloperName: sample.agentDeveloperName ?? null,
    agentShippingName: sample.agentShippingName ?? null,
    evidenceRoles: sample.evidenceRoles ?? null,
    confidence: sample.confidence ?? null,
    position: sample.position ?? null,
    velocity: sample.velocity ?? null,
    yawDegrees: sample.yawDegrees ?? sample.rotation?.yawDegrees ?? null,
    rotation: sample.rotation ?? null,
    samples: Array.isArray(sample.samples) ? sample.samples : [],
  }));
}

class BitCursor {
  constructor(buffer, bitLimit = buffer.length * 8, bitOffset = 0) {
    this.buffer = buffer;
    this.bitLimit = bitLimit;
    this.offset = bitOffset;
    this.isError = false;
  }

  get bitsLeft() {
    return this.bitLimit - this.offset;
  }

  atEnd() {
    return this.offset >= this.bitLimit;
  }

  canRead(bitCount) {
    return this.offset + bitCount <= this.bitLimit;
  }

  cloneAt(bitOffset = this.offset, bitLimit = this.bitLimit) {
    return new BitCursor(this.buffer, bitLimit, bitOffset);
  }

  fork(bitCount) {
    if (!this.canRead(bitCount)) {
      this.isError = true;
      return new BitCursor(Buffer.from([]), 0);
    }
    return new BitCursor(copyBits(this.buffer, this.offset, bitCount), bitCount);
  }

  readBit() {
    if (!this.canRead(1)) {
      this.isError = true;
      return 0;
    }
    const value = readBit(this.buffer, this.offset);
    this.offset += 1;
    return value;
  }

  readBitsUnsigned(bitCount) {
    let value = 0;
    let bitValue = 1;
    for (let bit = 0; bit < bitCount; bit += 1) {
      if (this.readBit()) value += bitValue;
      bitValue *= 2;
    }
    return value;
  }

  readBitsSigned(bitCount) {
    const value = this.readBitsUnsigned(bitCount);
    const signBit = 2 ** (bitCount - 1);
    return (value ^ signBit) - signBit;
  }

  readByte() {
    return this.readBitsUnsigned(8);
  }

  readBytes(byteCount) {
    if (!this.canRead(byteCount * 8)) {
      this.isError = true;
      return Buffer.from([]);
    }
    const result = Buffer.alloc(byteCount);
    for (let index = 0; index < byteCount; index += 1) result[index] = this.readByte();
    return result;
  }

  readUInt16() {
    return this.readByte() | (this.readByte() << 8);
  }

  readUInt32() {
    return (
      this.readByte() |
      (this.readByte() << 8) |
      (this.readByte() << 16) |
      (this.readByte() << 24)
    ) >>> 0;
  }

  readIntPacked() {
    let value = 0;
    let shift = 1;
    for (let index = 0; index < 5; index += 1) {
      if (!this.canRead(8)) {
        this.isError = true;
        return value;
      }
      const currentByte = this.readByte();
      value += (currentByte >> 1) * shift;
      if ((currentByte & 1) === 0) return value;
      shift *= 128;
    }
    this.isError = true;
    return value;
  }

  readSerializedInt(maxValue) {
    let value = 0;
    for (let mask = 1; value + mask < maxValue; mask *= 2) {
      if (this.readBit()) value |= mask;
    }
    return value;
  }

  readVlqUInt32() {
    let value = 0;
    let shift = 0;
    for (let index = 0; index < 5; index += 1) {
      if (!this.canRead(8)) {
        this.isError = true;
        return null;
      }
      const currentByte = this.readByte();
      value += ((currentByte >> 1) & 0x7f) * 2 ** shift;
      if ((currentByte & 1) === 0) return value >>> 0;
      shift += 7;
    }
    this.isError = true;
    return null;
  }

  skipBits(bitCount) {
    if (!this.canRead(bitCount)) {
      this.isError = true;
      this.offset = this.bitLimit;
      return;
    }
    this.offset += bitCount;
  }
}

function mapKeyFromPath(mapPath) {
  const lowered = String(mapPath ?? '').toLowerCase();
  for (const [token, key] of MAP_PATH_TOKENS) {
    if (lowered.includes(token)) return key;
  }
  return null;
}

function mapBoundsFromPath(mapPath) {
  const mapKey = mapKeyFromPath(mapPath);
  const bounds = MAP_VECTOR_BOUNDS.get(mapKey);
  if (!bounds) {
    throw new Error(
      `Unsupported VALORANT map path: ${mapPath ?? 'unknown'}. ` +
      'Add its verified projection constants before decoding movement.',
    );
  }
  return bounds;
}

function projectMapPosition(position, mapPath) {
  const bounds = mapBoundsFromPath(mapPath);
  return {
    u: position.y * bounds.xMultiplier + bounds.xScalarToAdd,
    v: position.x * bounds.yMultiplier + bounds.yScalarToAdd,
  };
}

function isPlausibleMapPosition(position, mapPath) {
  const bounds = mapBoundsFromPath(mapPath);
  const percent = projectMapPosition(position, mapPath);
  return (
    percent.u >= bounds.minPercent &&
    percent.u <= bounds.maxPercent &&
    percent.v >= bounds.minPercent &&
    percent.v <= bounds.maxPercent &&
    position.z >= bounds.minZ &&
    position.z <= bounds.maxZ &&
    (Math.abs(position.x) >= 50 || Math.abs(position.y) >= 50)
  );
}

function readFixedVector(cursor) {
  const x = cursor.readSerializedInt(0x10000);
  const y = cursor.readSerializedInt(0x10000);
  const z = cursor.readSerializedInt(0x10000);
  return {
    x: (x - 0x8000) / 65536,
    y: (y - 0x8000) / 65536,
    z: (z - 0x8000) / 65536,
    componentBits: 16,
    scaleFactor: 65536,
  };
}

function readQuantizedVector(cursor, scaleFactor) {
  const bitsAndInfo = cursor.readSerializedInt(1 << 7);
  const componentBits = bitsAndInfo & 63;
  const extraInfo = bitsAndInfo >> 6;
  if (componentBits <= 0 || componentBits > 30 || !cursor.canRead(componentBits * 3)) {
    return null;
  }

  const raw = {
    x: cursor.readBitsSigned(componentBits),
    y: cursor.readBitsSigned(componentBits),
    z: cursor.readBitsSigned(componentBits),
  };
  return {
    bitsAndInfo,
    componentBits,
    extraInfo,
    scaleFactor,
    raw,
    x: extraInfo ? raw.x / scaleFactor : raw.x,
    y: extraInfo ? raw.y / scaleFactor : raw.y,
    z: extraInfo ? raw.z / scaleFactor : raw.z,
  };
}

function nextMarker(marker) {
  const next = (marker + 1) & 7;
  return next < 2 ? 1 : next;
}

function parseMovementMove(cursor, marker) {
  const startBit = cursor.offset;
  const moveType = cursor.readBit();
  const rotationYawMultiplier = ((cursor.readByte() + 128) & 0xff) - 128;
  const movementState = cursor.readByte();
  const unusedByte = cursor.readByte();
  const rotationInput = readFixedVector(cursor);
  const timestamp = cursor.readVlqUInt32();
  const positionBitOffset = cursor.offset;
  const position = readQuantizedVector(cursor, 100);
  if (!position) {
    return { ok: false, error: 'missing-position-vector', startBit, positionBitOffset };
  }

  const hasOptionalMovementValue = cursor.readBit();
  const optionalMovementRawByte = hasOptionalMovementValue ? cursor.readByte() : null;
  const flag48 = cursor.readBit();
  const packedAngles = cursor.readUInt32();
  const rawPitch = packedAngles & 0xffff;
  const rawYaw = packedAngles >>> 16;

  let velocity = null;
  let variant0PackedAngles = null;
  if (moveType) {
    const variant1Flag = cursor.readBit();
    velocity = readQuantizedVector(cursor, 10);
    if (!velocity) {
      return {
        ok: false,
        error: 'missing-variant1-vector',
        startBit,
        positionBitOffset,
        variant1Flag,
      };
    }
  } else {
    const hasExternalCharacterRef = cursor.readBit();
    if (hasExternalCharacterRef) {
      return {
        ok: false,
        error: 'variant0-external-character-ref',
        startBit,
        positionBitOffset,
        position,
      };
    }
    variant0PackedAngles = cursor.readUInt32();
  }

  const errorSentinel = cursor.readBit();
  if (errorSentinel) {
    return {
      ok: false,
      error: 'movement-error-sentinel',
      startBit,
      positionBitOffset,
      position,
    };
  }

  return {
    ok: true,
    startBit,
    endBit: cursor.offset,
    marker,
    moveType,
    rotationYawMultiplier,
    movementState,
    unusedByte,
    rotationInput,
    timestamp,
    positionBitOffset,
    position,
    hasOptionalMovementValue: Boolean(hasOptionalMovementValue),
    optionalMovementRawByte,
    flag48: Boolean(flag48),
    packedAngles,
    rawYaw,
    rawPitch,
    yaw: rawYaw * 360 / 65536,
    pitch: rawPitch * 360 / 65536,
    velocity,
    variant0PackedAngles,
  };
}

function parseMovementSection(cursor) {
  const startBit = cursor.offset;
  const magic = cursor.readByte();
  if (magic !== MOVEMENT_MAGIC) return { ok: false, error: 'invalid-movement-magic', magic, startBit };

  let marker = cursor.readBitsUnsigned(3);
  let expectedMarker = 1;
  const moves = [];
  while (marker !== 0 && !cursor.isError) {
    if (marker !== expectedMarker) {
      return {
        ok: false,
        error: 'movement-marker-mismatch',
        marker,
        expectedMarker,
        moves,
        startBit,
      };
    }

    const move = parseMovementMove(cursor, marker);
    if (!move.ok) return { ok: false, error: move.error, move, moves, startBit };
    moves.push(move);

    if (cursor.bitsLeft <= MAX_MOVEMENT_PADDING_BITS) {
      return { ok: true, moves, startBit, trailingBits: cursor.bitsLeft };
    }

    expectedMarker = nextMarker(expectedMarker);
    marker = cursor.readBitsUnsigned(3);
  }

  return { ok: !cursor.isError, moves, startBit, trailingBits: cursor.bitsLeft };
}

function parseComponentPayload(cursor) {
  if (!cursor.canRead(16)) return { ok: false, error: 'component-payload-too-short' };
  const startBit = cursor.offset;
  const movementBitCount = cursor.readUInt16();
  if (movementBitCount === 0) {
    return {
      mode: 'zero-bitcount-prefix',
      movementBitCount,
      ...parseMovementSection(cursor),
    };
  }

  if (movementBitCount > cursor.bitsLeft) {
    cursor.offset = startBit;
    return {
      mode: 'raw-movement-fallback',
      movementBitCount,
      ...parseMovementSection(cursor),
    };
  }

  const movementCursor = cursor.cloneAt(cursor.offset, cursor.offset + movementBitCount);
  const parsed = parseMovementSection(movementCursor);
  cursor.offset += movementBitCount;
  return {
    mode: 'bounded-movement-section',
    movementBitCount,
    ...parsed,
  };
}

function parseComponentDataStream(cursor) {
  const attempts = [];

  const payloadBytesCursor = cursor.cloneAt();
  if (payloadBytesCursor.canRead(16)) {
    const byteCount = payloadBytesCursor.readUInt16();
    if (byteCount > 0 && payloadBytesCursor.canRead(byteCount * 8)) {
      const payloadBytes = payloadBytesCursor.readBytes(byteCount);
      attempts.push({
        outerMode: 'payload-byte-array',
        byteCount,
        ...parseComponentPayload(new BitCursor(payloadBytes, byteCount * 8)),
      });
    }
  }

  attempts.push({
    outerMode: 'component-payload',
    ...parseComponentPayload(cursor.cloneAt()),
  });
  attempts.push({
    outerMode: 'movement-direct',
    ...parseMovementSection(cursor.cloneAt()),
  });

  return attempts.sort((a, b) => {
    if (Boolean(a.ok) !== Boolean(b.ok)) return Number(b.ok) - Number(a.ok);
    return (b.moves?.length ?? 0) - (a.moves?.length ?? 0);
  })[0];
}

function parseRemoteCharacterUpdateArray(cursor) {
  const arraySize = cursor.readIntPacked();
  if (!Number.isInteger(arraySize) || arraySize < 0 || arraySize > 32) {
    return {
      ok: false,
      error: 'implausible-array-size',
      arraySize,
      elements: [],
      remainingBits: cursor.bitsLeft,
    };
  }

  const elements = [];
  while (!cursor.atEnd() && !cursor.isError) {
    const rawIndex = cursor.readIntPacked();
    if (rawIndex === 0) {
      if (cursor.bitsLeft === 8) {
        const terminator = cursor.readIntPacked();
        if (terminator !== 0) {
          return {
            ok: false,
            error: 'bad-array-terminator',
            arraySize,
            terminator,
            elements,
            remainingBits: cursor.bitsLeft,
          };
        }
      }
      return { ok: true, arraySize, elements, remainingBits: cursor.bitsLeft };
    }

    const index = rawIndex - 1;
    if (index < 0 || index >= arraySize) {
      return {
        ok: false,
        error: 'array-index-out-of-range',
        arraySize,
        index,
        rawIndex,
        elements,
        remainingBits: cursor.bitsLeft,
      };
    }

    const element = { index, fields: [], netGuid: null, componentDataStream: null };
    while (!cursor.atEnd() && !cursor.isError) {
      const rawHandle = cursor.readIntPacked();
      if (rawHandle === 0) break;

      const handle = rawHandle - 1;
      const fieldName = TARGET_RPC_FIELDS.get(handle) ?? `handle_${handle}`;
      const numBits = cursor.readIntPacked();
      if (numBits < 0 || numBits > cursor.bitsLeft) {
        return {
          ok: false,
          error: 'array-field-bitcount-out-of-range',
          arraySize,
          handle,
          rawHandle,
          numBits,
          elements,
          remainingBits: cursor.bitsLeft,
        };
      }

      const fieldCursor = cursor.fork(numBits);
      cursor.skipBits(numBits);
      const field = {
        handle,
        fieldName,
        numBits,
        value: null,
        remainingBits: null,
        readerError: false,
      };
      if (fieldName === 'ShooterCharacterNetGuidValue') {
        field.value = fieldCursor.canRead(32) ? fieldCursor.readUInt32() : null;
        element.netGuid = field.value;
      } else if (fieldName === 'ComponentDataStream') {
        field.value = parseComponentDataStream(fieldCursor);
        element.componentDataStream = field.value;
      } else if (fieldName === 'bIsReplayFastForwardImportant') {
        field.value = fieldCursor.canRead(1) ? Boolean(fieldCursor.readBit()) : null;
      }
      field.remainingBits = fieldCursor.bitsLeft;
      field.readerError = fieldCursor.isError;
      element.fields.push(field);
    }

    elements.push(element);
  }

  return {
    ok: !cursor.isError,
    error: cursor.isError ? 'array-reader-error' : null,
    arraySize,
    elements,
    remainingBits: cursor.bitsLeft,
  };
}

function parseTargetRpcReceiveProperties(cursor, { skipChecksumBit }) {
  const checksumBit = skipChecksumBit && cursor.canRead(1) ? cursor.readBit() : null;
  const properties = [];
  while (!cursor.atEnd() && !cursor.isError) {
    const rawHandle = cursor.readIntPacked();
    if (rawHandle === 0) {
      return {
        ok: true,
        checksumBit,
        properties,
        remainingBits: cursor.bitsLeft,
      };
    }

    const handle = rawHandle - 1;
    const fieldName = TARGET_RPC_FIELDS.get(handle) ?? `handle_${handle}`;
    if (!TARGET_RPC_FIELDS.has(handle)) {
      return {
        ok: false,
        error: 'rpc-handle-out-of-range',
        checksumBit,
        handle,
        rawHandle,
        properties,
        remainingBits: cursor.bitsLeft,
      };
    }

    const numBits = cursor.readIntPacked();
    if (numBits < 0 || numBits > cursor.bitsLeft) {
      return {
        ok: false,
        error: 'rpc-field-bitcount-out-of-range',
        checksumBit,
        handle,
        rawHandle,
        fieldName,
        numBits,
        properties,
        remainingBits: cursor.bitsLeft,
      };
    }

    const fieldCursor = cursor.fork(numBits);
    cursor.skipBits(numBits);
    const property = {
      handle,
      fieldName,
      numBits,
      value: null,
      remainingBits: null,
      readerError: false,
    };
    if (fieldName === 'RemoteCharacterUpdates') {
      property.value = parseRemoteCharacterUpdateArray(fieldCursor);
    } else if (fieldName === 'ShooterCharacterNetGuidValue') {
      property.value = fieldCursor.canRead(32) ? fieldCursor.readUInt32() : null;
    } else if (fieldName === 'ComponentDataStream') {
      property.value = parseComponentDataStream(fieldCursor);
    } else if (fieldName === 'bIsReplayFastForwardImportant') {
      property.value = fieldCursor.canRead(1) ? Boolean(fieldCursor.readBit()) : null;
    }
    property.remainingBits = fieldCursor.bitsLeft;
    property.readerError = fieldCursor.isError;
    properties.push(property);
  }

  return {
    ok: !cursor.isError,
    error: cursor.isError ? 'rpc-reader-error' : null,
    checksumBit,
    properties,
    remainingBits: cursor.bitsLeft,
  };
}

function candidateSources(diagnostics, options = {}) {
  const frameSummary = diagnostics.frameSummary ?? {};
  const rows = [];
  const add = (sourceKind, sample) => {
    if (!sample?.payloadHex || !Number.isInteger(sample.numPayloadBits)) return;
    const functionName = sample.fieldName ?? sample.functionName ?? '';
    const isNamedTarget = functionName.includes(TARGET_FUNCTION_NAME);
    const fieldHandle = sample.fieldHandle ?? sample.functionHandle ?? null;
    const isUnknownReplayControllerField =
      options.includeUnknownReplayControllerFields &&
      !functionName &&
      /BaseReplayController_C_ClassNetCache$/i.test(sample.classNetCache ?? '') &&
      sample.numPayloadBits >= options.minUnknownReplayControllerPayloadBits &&
      (!options.unknownReplayControllerFieldHandles ||
        options.unknownReplayControllerFieldHandles.has(fieldHandle));
    if (!isNamedTarget && !isUnknownReplayControllerField) return;
    if (sample.payloadHexTruncated) return;
    const bitCount = sample.numPayloadBits;
    const buffer = Buffer.from(normalizeHexToFullBytes(sample.payloadHex), 'hex');
    if (buffer.length * 8 < bitCount) return;
    rows.push({
      sourceKind,
      timeMs: sample.timeMs,
      chIndex: sample.chIndex ?? null,
      actorNetGuid: sample.actorNetGuid ?? null,
      fieldHandle,
      functionName,
      bitCount,
      payloadHex: sample.payloadHex,
      buffer,
    });
  };

  for (const sample of frameSummary.replayControllerCandidateFieldSamples ?? []) {
    add('replayControllerCandidateFieldSamples', sample);
  }
  for (const sample of frameSummary.rpcCandidateSamples ?? []) add('rpcCandidateSamples', sample);
  for (const sample of frameSummary.compactRpcCandidateSamples ?? []) {
    add('compactRpcCandidateSamples', sample);
  }

  const seen = new Set();
  return rows.filter((row) => {
    const key = `${row.sourceKind}|${row.timeMs}|${row.bitCount}|${row.payloadHex}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function movementRejectionReasons(move, options) {
  const reasons = [];
  if (!move?.position) reasons.push('missing-position');
  else {
    if (move.position.componentBits < options.minPositionComponentBits) {
      reasons.push('low-position-component-bits');
    }
    if (options.requireMapPlausiblePosition && !isPlausibleMapPosition(move.position, options.mapPath)) {
      reasons.push('off-map-position');
    }
  }
  if (move?.timestamp == null) reasons.push('missing-stream-timestamp');
  return reasons;
}

function summarizeComponent(component, options) {
  const moves = component?.moves ?? [];
  const acceptedMoves = [];
  const rejectedMoves = [];
  for (const move of moves) {
    const rejectionReasons = movementRejectionReasons(move, options);
    const summary = {
      marker: move.marker,
      timestamp: move.timestamp,
      positionBitOffset: move.positionBitOffset,
      componentBits: move.position?.componentBits ?? null,
      extraInfo: move.position?.extraInfo ?? null,
      position: move.position
        ? {
            x: round(move.position.x),
            y: round(move.position.y),
            z: round(move.position.z),
          }
        : null,
      yaw: round(move.yaw),
      pitch: round(move.pitch),
      rejectionReasons,
    };
    if (rejectionReasons.length === 0) acceptedMoves.push(summary);
    else rejectedMoves.push(summary);
  }

  return {
    ok: Boolean(component?.ok),
    outerMode: component?.outerMode ?? null,
    mode: component?.mode ?? null,
    error: component?.error ?? null,
    movementBitCount: component?.movementBitCount ?? null,
    moveCount: moves.length,
    acceptedMoveCount: acceptedMoves.length,
    acceptedMoves,
    rejectedMoves: rejectedMoves.slice(0, 4),
  };
}

function collectParsedComponents(parsedRpc, options) {
  const components = [];
  for (const property of parsedRpc.properties ?? []) {
    if (property.fieldName === 'ComponentDataStream') {
      components.push({
        source: 'top-level',
        netGuid: null,
        component: property.value,
        numBits: property.numBits,
      });
    }
    if (property.fieldName !== 'RemoteCharacterUpdates') continue;
    for (const element of property.value?.elements ?? []) {
      for (const field of element.fields ?? []) {
        if (field.fieldName !== 'ComponentDataStream') continue;
        components.push({
          source: 'remote-array',
          elementIndex: element.index,
          netGuid: element.netGuid,
          component: field.value,
          numBits: field.numBits,
        });
      }
    }
  }

  return components.map((entry) => ({
    ...entry,
    summary: summarizeComponent(entry.component, options),
  }));
}

function trackSamplesFromComponent(row, componentEntry, options) {
  const samples = [];
  const moves = componentEntry.component?.moves ?? [];
  for (const move of moves) {
    if (movementRejectionReasons(move, options).length > 0) continue;
    samples.push({
      timeMs: row.timeMs,
      netGuid: componentEntry.netGuid,
      sourceKind: row.sourceKind,
      componentSource: componentEntry.source,
      elementIndex: componentEntry.elementIndex ?? null,
      streamTimestamp: move.timestamp,
      position: {
        x: round(move.position.x),
        y: round(move.position.y),
        z: round(move.position.z),
      },
      viewRotation: {
        pitch: round(move.pitch),
        yaw: round(move.yaw),
        roll: 0,
      },
      diagnostics: {
        positionBitOffset: move.positionBitOffset,
        componentBits: move.position.componentBits,
        extraInfo: move.position.extraInfo,
        movementState: move.movementState,
        moveType: move.moveType,
      },
    });
  }
  return samples;
}

function looksLikeComponentStart(row, bitOffset) {
  if (readBitsUnsignedAt(row.buffer, row.bitCount, bitOffset, 8) === MOVEMENT_MAGIC) {
    return true;
  }
  if (readBitsUnsignedAt(row.buffer, row.bitCount, bitOffset + 16, 8) === MOVEMENT_MAGIC) {
    return true;
  }

  const byteCount = readBitsUnsignedAt(row.buffer, row.bitCount, bitOffset, 16);
  if (byteCount == null || byteCount <= 0) return false;
  const payloadStart = bitOffset + 16;
  if (payloadStart + byteCount * 8 > row.bitCount) return false;
  return (
    readBitsUnsignedAt(row.buffer, row.bitCount, payloadStart, 8) === MOVEMENT_MAGIC ||
    readBitsUnsignedAt(row.buffer, row.bitCount, payloadStart + 16, 8) === MOVEMENT_MAGIC
  );
}

function scanComponentDataStreamOffsets(row, options) {
  const hits = [];
  const errorCounts = new Map();
  for (let bitOffset = 0; bitOffset < row.bitCount && hits.length < 12; bitOffset += 1) {
    if (!looksLikeComponentStart(row, bitOffset)) continue;
    const component = parseComponentDataStream(new BitCursor(row.buffer, row.bitCount, bitOffset));
    if (!component?.ok || (component.moves?.length ?? 0) === 0) {
      increment(errorCounts, component?.error ?? 'unknown-component-scan-error');
      continue;
    }

    const summary = summarizeComponent(component, options);
    hits.push({
      bitOffset,
      outerMode: summary.outerMode,
      mode: summary.mode,
      movementBitCount: summary.movementBitCount,
      moveCount: summary.moveCount,
      acceptedMoveCount: summary.acceptedMoveCount,
      firstAcceptedMove: summary.acceptedMoves[0] ?? null,
      firstRejectedMove: summary.rejectedMoves[0] ?? null,
      prefixHex: bitsToHex(row.buffer, bitOffset, Math.min(128, row.bitCount - bitOffset)),
    });
  }

  return {
    hitCount: hits.length,
    hits,
    errorCounts: topCounts(errorCounts, 8),
  };
}

function compactPropertySummary(property) {
  const base = {
    handle: property.handle,
    fieldName: property.fieldName,
    numBits: property.numBits,
    remainingBits: property.remainingBits,
    readerError: property.readerError,
  };
  if (property.fieldName === 'RemoteCharacterUpdates') {
    return {
      ...base,
      arraySize: property.value?.arraySize ?? null,
      elementCount: property.value?.elements?.length ?? 0,
      arrayError: property.value?.error ?? null,
      arrayRemainingBits: property.value?.remainingBits ?? null,
      elements: (property.value?.elements ?? []).slice(0, 6).map((element) => ({
        index: element.index,
        netGuid: element.netGuid,
        fields: element.fields.map((field) => ({
          handle: field.handle,
          fieldName: field.fieldName,
          numBits: field.numBits,
          component: field.fieldName === 'ComponentDataStream'
            ? summarizeComponent(field.value, {
                minPositionComponentBits: 7,
                requireMapPlausiblePosition: false,
              })
            : undefined,
        })),
      })),
    };
  }
  if (property.fieldName === 'ComponentDataStream') {
    return {
      ...base,
      component: summarizeComponent(property.value, {
        minPositionComponentBits: 7,
        requireMapPlausiblePosition: false,
      }),
    };
  }
  return { ...base, value: property.value ?? null };
}

function analyze(diagnostics, options) {
  options = {
    ...options,
    mapPath: options.mapPath ?? diagnostics.header?.mapPath ?? null,
  };
  const sources = candidateSources(diagnostics, options);
  const parseErrorCounts = new Map();
  const sourceCounts = new Map();
  const componentErrorCounts = new Map();
  const movementRejectionCounts = new Map();
  const examples = [];
  const movementSamples = [];

  let attemptedParses = 0;
  let successfulRpcParses = 0;
  let strictRpcParses = 0;
  let remoteUpdateElements = 0;
  let componentParseOkCount = 0;
  let acceptedComponentCount = 0;
  let directComponentScanHitCount = 0;
  let directComponentScanAcceptedMoveCount = 0;
  const directComponentScanErrorCounts = new Map();
  const directComponentScanExamples = [];

  for (const row of sources.slice(0, options.maxSamples)) {
    increment(sourceCounts, row.sourceKind);
    const directScan = scanComponentDataStreamOffsets(row, options);
    directComponentScanHitCount += directScan.hitCount;
    for (const entry of directScan.errorCounts) {
      increment(directComponentScanErrorCounts, entry.key, entry.count);
    }
    for (const hit of directScan.hits) {
      directComponentScanAcceptedMoveCount += hit.acceptedMoveCount;
      if (directComponentScanExamples.length < options.maxExamples) {
        directComponentScanExamples.push({
          sourceKind: row.sourceKind,
          timeMs: row.timeMs,
          bitCount: row.bitCount,
          ...hit,
        });
      }
    }
    for (const skipChecksumBit of [true, false]) {
      attemptedParses += 1;
      const parsed = parseTargetRpcReceiveProperties(
        new BitCursor(row.buffer, row.bitCount),
        { skipChecksumBit },
      );
      const components = collectParsedComponents(parsed, options);
      const acceptedSamples = components.flatMap((entry) =>
        trackSamplesFromComponent(row, entry, options),
      );

      if (parsed.ok) successfulRpcParses += 1;
      if (parsed.ok && parsed.properties.length > 0 && parsed.remainingBits === 0) {
        strictRpcParses += 1;
      }
      if (!parsed.ok) increment(parseErrorCounts, parsed.error ?? 'unknown-parse-error');

      for (const property of parsed.properties ?? []) {
        if (property.fieldName === 'RemoteCharacterUpdates') {
          remoteUpdateElements += property.value?.elements?.length ?? 0;
          if (property.value?.error) increment(parseErrorCounts, `array:${property.value.error}`);
        }
      }

      for (const component of components) {
        if (component.component?.ok) componentParseOkCount += 1;
        else increment(componentErrorCounts, component.component?.error ?? 'unknown-component-error');
        if (component.summary.acceptedMoveCount > 0) acceptedComponentCount += 1;
        for (const move of component.summary.rejectedMoves ?? []) {
          for (const reason of move.rejectionReasons ?? []) increment(movementRejectionCounts, reason);
        }
      }

      movementSamples.push(...acceptedSamples);

      const shouldKeepExample =
        examples.length < options.maxExamples &&
        (acceptedSamples.length > 0 ||
          components.some((entry) => entry.component?.ok) ||
          (parsed.ok && parsed.properties.length > 0) ||
          (!parsed.ok && examples.length < Math.ceil(options.maxExamples / 2)));
      if (shouldKeepExample) {
        examples.push({
          sourceKind: row.sourceKind,
          timeMs: row.timeMs,
          bitCount: row.bitCount,
          skipChecksumBit,
          ok: parsed.ok,
          strict: parsed.ok && parsed.properties.length > 0 && parsed.remainingBits === 0,
          error: parsed.error ?? null,
          handle: parsed.handle ?? null,
          rawHandle: parsed.rawHandle ?? null,
          numBits: parsed.numBits ?? null,
          remainingBits: parsed.remainingBits,
          propertyCount: parsed.properties?.length ?? 0,
          componentCount: components.length,
          acceptedSampleCount: acceptedSamples.length,
          properties: (parsed.properties ?? []).slice(0, 4).map(compactPropertySummary),
          componentSummaries: components.slice(0, 4).map((entry) => ({
            source: entry.source,
            elementIndex: entry.elementIndex ?? null,
            netGuid: entry.netGuid,
            numBits: entry.numBits,
            ...entry.summary,
          })),
          payloadPrefixHex: bitsToHex(row.buffer, 0, Math.min(row.bitCount, 160)),
        });
      }
    }
  }

  const emittedSamples = selectTrackSamples(
    movementSamples,
    options.trackMinSampleIntervalMs,
  );

  const conclusions = [
    `Scanned ${sources.length} captured target-RPC payloads (${attemptedParses} checksum variants).`,
    `${strictRpcParses} parses consumed a non-empty target RPC cleanly; ${componentParseOkCount} ComponentDataStream fields matched the native movement parser.`,
    `${directComponentScanHitCount} direct bit-offset scans found a native movement section inside target payload bytes.`,
    `${movementSamples.length} movement samples passed the strict NetGUID + plausible-position gate.`,
    `${emittedSamples.length} app track samples remain after the ${options.trackMinSampleIntervalMs}ms real-sample export cadence.`,
  ];
  if (movementSamples.length === 0) {
    conclusions.push(
      'No app-ready movement samples were emitted; current diagnostics still appear misframed or captured above/below the native ComponentDataStream layer.',
    );
  }
  if (componentParseOkCount > 0 && movementSamples.length === 0) {
    conclusions.push(
      'Native-looking movement sections were seen, but their positions failed strict movement plausibility checks.',
    );
  }

  return {
    input: {
      minPositionComponentBits: options.minPositionComponentBits,
      requireMapPlausiblePosition: options.requireMapPlausiblePosition,
      mapPath: options.mapPath,
      mapKey: mapKeyFromPath(options.mapPath),
      maxSamples: options.maxSamples,
      trackMinSampleIntervalMs: options.trackMinSampleIntervalMs,
    },
    notes: [
      'This ports the ValorantReplayParserPlayground ComponentDataStream model into a diagnostics verifier.',
      'The target RPC shape is ReceiveProperties -> RemoteCharacterUpdates dynamic array -> ShooterCharacterNetGuidValue + ComponentDataStream.',
      'Samples are emitted only when a ComponentDataStream movement record has a decoded NetGUID and a plausible map-specific world position.',
    ],
    source: {
      candidatePayloadCount: sources.length,
      sourceCounts: topCounts(sourceCounts, 12),
      firstPayloads: sources.slice(0, 8).map((row) => ({
        sourceKind: row.sourceKind,
        timeMs: row.timeMs,
        bitCount: row.bitCount,
        payloadPrefixHex: bitsToHex(row.buffer, 0, Math.min(row.bitCount, 96)),
      })),
    },
    attemptedParses,
    successfulRpcParseCount: successfulRpcParses,
    strictRpcParseCount: strictRpcParses,
    remoteUpdateElementCount: remoteUpdateElements,
    componentParseOkCount,
    acceptedComponentCount,
    directComponentScan: {
      hitCount: directComponentScanHitCount,
      acceptedMoveCount: directComponentScanAcceptedMoveCount,
      errors: topCounts(directComponentScanErrorCounts, 16),
      examples: directComponentScanExamples,
    },
    movementSampleCount: movementSamples.length,
    emittedMovementSampleCount: emittedSamples.length,
    parseErrors: topCounts(parseErrorCounts, 16),
    componentErrors: topCounts(componentErrorCounts, 16),
    movementRejections: topCounts(movementRejectionCounts, 16),
    examples,
    samples: emittedSamples,
    conclusions,
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  if (!diagnosticsPath) {
    console.error(
      'usage: node analyze_component_data_stream_native.mjs --diagnostics replay.diagnostics.json --out component_data_stream_native.report.json [--samples-out samples.json] [--track-out track.json]',
    );
    process.exitCode = 1;
    return;
  }

  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const report = analyze(diagnostics, options);
  report.input = {
    ...report.input,
    diagnostics: diagnosticsPath,
  };

  const outPath = resolveUserPath(options.out);
  if (outPath) {
    writeJson(
      outPath,
      options.includeSamplesInReport
        ? report
        : {
            ...report,
            samples: [],
          },
    );
  }
  else process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);

  const samplesOutPath = resolveUserPath(options.samplesOut);
  if (samplesOutPath) writeJson(samplesOutPath, report.samples);

  const trackOutPath = resolveUserPath(options.trackOut);
  if (trackOutPath) {
    writeJson(
      trackOutPath,
      buildNativeReplayTrack(diagnostics, report.samples, {
        mode: report.input.requireMapPlausiblePosition
          ? 'strict-map-bounds'
          : 'disabled-diagnostic-only',
        mapKey: report.input.mapKey,
      }),
    );
  }

  console.error(
    `native ComponentDataStream scan: targetPayloads=${report.source.candidatePayloadCount}; strictRpc=${report.strictRpcParseCount}; componentOk=${report.componentParseOkCount}; samples=${report.movementSampleCount}`,
  );
}

const invokedAsScript =
  process.argv[1] != null &&
  path.resolve(process.argv[1]).toLowerCase() ===
    path.resolve(fileURLToPath(import.meta.url)).toLowerCase();

if (invokedAsScript) main();

export {
  abilitySignalMetadataFromActorPath,
  abilityRpcEventsFromDiagnostics,
  abilityStateEventsFromDiagnostics,
  buildNativeReplayTrack,
  buildReplayAbilityActions,
  equippableNetGuidFromInputSample,
  linkUtilityActorsToAbilityCasts,
  parseCharacterAbilityCastScalarFields,
  parseCharacterAbilityEffects,
  replayInputEventsFromDiagnostics,
  resolveAbilityCastTimes,
};
