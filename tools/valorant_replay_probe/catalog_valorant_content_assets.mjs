#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const DEFAULT_FMODEL_SETTINGS = path.join(
  process.env.APPDATA ?? '',
  'FModel',
  'AppSettings.json',
);

const AGENT_TOKENS = new Map([
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

const SLOT_TOKENS = new Map([
  ['c', { abilitySlot: 'Grenade', abilityIndex: 0 }],
  ['4', { abilitySlot: 'Grenade', abilityIndex: 0 }],
  ['q', { abilitySlot: 'Ability1', abilityIndex: 1 }],
  ['1', { abilitySlot: 'Ability1', abilityIndex: 1 }],
  ['e', { abilitySlot: 'Ability2', abilityIndex: 2 }],
  ['2', { abilitySlot: 'Ability2', abilityIndex: 2 }],
  ['x', { abilitySlot: 'Ultimate', abilityIndex: 3 }],
  ['ultimate', { abilitySlot: 'Ultimate', abilityIndex: 3 }],
]);

const CONTENT_KIND_RULES = [
  { pattern: /^Ability_/i, kind: 'ability-class' },
  { pattern: /^Projectile_/i, kind: 'projectile-class' },
  { pattern: /^GameObject_/i, kind: 'game-object-class' },
  { pattern: /^Patch_/i, kind: 'area-patch-class' },
  { pattern: /^FXC_/i, kind: 'fx-class' },
  { pattern: /^Equippable_/i, kind: 'equippable-class' },
  { pattern: /^Comp_Ability/i, kind: 'ability-component' },
  { pattern: /^CharacterAbility/i, kind: 'character-ability-schema' },
  { pattern: /^ECharacterAbility/i, kind: 'character-ability-enum' },
  { pattern: /^Activate_Ability/i, kind: 'ability-input-action' },
  { pattern: /^Activate_Grenade/i, kind: 'ability-input-action' },
  { pattern: /^UseAgentAbility/i, kind: 'ability-input-action' },
  { pattern: /^Enum_AbilityInputs/i, kind: 'ability-input-enum' },
  { pattern: /^DmgSource_Ability/i, kind: 'damage-source' },
  { pattern: /Ability/i, kind: 'ability-named-asset' },
];

const DEFAULT_ASSET_FILTER = [
  /^Ability_/i,
  /^Projectile_/i,
  /^GameObject_/i,
  /^Patch_/i,
  /^Equippable_/i,
  /^Comp_Ability/i,
  /^CharacterAbility/i,
  /^ECharacterAbility/i,
  /^Activate_Ability/i,
  /^Activate_Grenade/i,
  /^UseAgentAbility/i,
  /^Enum_AbilityInputs/i,
  /^DmgSource_Ability/i,
];

function parseArgs(argv) {
  const args = {
    paks: null,
    track: null,
    out: null,
    includeFxAssets: false,
    includeBroadAbilityNames: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--paks') args.paks = argv[++i];
    else if (arg.startsWith('--paks=')) args.paks = arg.slice('--paks='.length);
    else if (arg === '--track') args.track = argv[++i];
    else if (arg.startsWith('--track=')) args.track = arg.slice('--track='.length);
    else if (arg === '--out') args.out = argv[++i];
    else if (arg.startsWith('--out=')) args.out = arg.slice('--out='.length);
    else if (arg === '--include-fx-assets') args.includeFxAssets = true;
    else if (arg === '--include-broad-ability-names') args.includeBroadAbilityNames = true;
    else if (arg === '--help' || arg === '-h') args.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  return args;
}

function readFModelGameDirectory() {
  if (!DEFAULT_FMODEL_SETTINGS || !fs.existsSync(DEFAULT_FMODEL_SETTINGS)) return null;
  try {
    const settings = JSON.parse(fs.readFileSync(DEFAULT_FMODEL_SETTINGS, 'utf8'));
    return settings?.GameDirectory || null;
  } catch {
    return null;
  }
}

function usage() {
  return [
    'usage: node tools/valorant_replay_probe/catalog_valorant_content_assets.mjs [--paks <dir>] [--track track.json] --out out.json',
    '',
    'Scans VALORANT .utoc package indexes for ability-shaped content asset names.',
    'If --paks is omitted, the FModel GameDirectory setting is used.',
    'Use --include-fx-assets to include the much noisier FXC_* visual-effect assets.',
  ].join('\n');
}

function resolveCliPath(value) {
  if (!value) return value;
  if (path.isAbsolute(value)) return value;
  return path.resolve(process.env.INIT_CWD ?? process.cwd(), value);
}

function isAsciiNameByte(byte) {
  return (
    (byte >= 48 && byte <= 57) ||
    (byte >= 65 && byte <= 90) ||
    (byte >= 97 && byte <= 122) ||
    byte === 95 ||
    byte === 45 ||
    byte === 46
  );
}

function extractAsciiTokens(buffer) {
  const tokens = [];
  let start = null;
  for (let index = 0; index <= buffer.length; index += 1) {
    const byte = buffer[index];
    if (index < buffer.length && isAsciiNameByte(byte)) {
      if (start == null) start = index;
      continue;
    }
    if (start != null && index - start >= 3) {
      tokens.push(buffer.subarray(start, index).toString('ascii'));
    }
    start = null;
  }
  return tokens;
}

function stripAssetExtension(value) {
  return value.replace(/\.(?:uasset|uexp|ubulk|umap)$/i, '');
}

function classifyContentKind(assetName) {
  return CONTENT_KIND_RULES.find((rule) => rule.pattern.test(assetName))?.kind ?? 'other';
}

function shouldIncludeAssetName(assetName, includeFxAssets, includeBroadAbilityNames) {
  if (DEFAULT_ASSET_FILTER.some((pattern) => pattern.test(assetName))) return true;
  if (includeFxAssets && /^FXC_/i.test(assetName)) return true;
  return includeBroadAbilityNames && /Ability/i.test(assetName);
}

function assetTokens(assetName) {
  return assetName
    .split(/[^A-Za-z0-9]+/)
    .map((token) => token.toLowerCase())
    .filter(Boolean);
}

function inferMetadata(assetName) {
  const tokens = assetTokens(assetName);
  const agentEntry = tokens.map((token) => AGENT_TOKENS.get(token)).find(Boolean) ?? null;
  const slotEntry = tokens.map((token) => SLOT_TOKENS.get(token)).find(Boolean) ?? null;
  return {
    agent: agentEntry?.agent ?? null,
    icarusAgentType: agentEntry?.icarusAgentType ?? null,
    abilitySlot: slotEntry?.abilitySlot ?? null,
    abilityIndex: slotEntry?.abilityIndex ?? null,
    contentKind: classifyContentKind(assetName),
  };
}

function addCount(counts, key) {
  const normalized = key ?? 'unknown';
  counts.set(normalized, (counts.get(normalized) ?? 0) + 1);
}

function sortCounts(counts) {
  return [...counts.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .map(([key, count]) => ({ key, count }));
}

function uniqueTrackClassNames(track) {
  const names = new Set();
  for (const event of track?.abilityEvents ?? []) {
    if (event?.className) names.add(event.className);
  }
  for (const event of track?.utilityActors ?? []) {
    if (event?.className) names.add(event.className);
  }
  for (const sample of track?.diagnostics?.abilitySignalSamples ?? []) {
    const pathNames = [
      sample?.actorPath,
      sample?.actorGroup,
      sample?.repObjectPath,
      sample?.archetypePath,
    ];
    for (const pathName of pathNames) {
      const match = String(pathName ?? '').match(/([^/.]+?)(?:_C)?(?:\.[^/.]+)?$/);
      if (match?.[1]) names.add(match[1].replace(/^Default__/, '').replace(/_C$/i, ''));
    }
  }
  return [...names].sort((a, b) => a.localeCompare(b));
}

function buildReplayJoin(trackPath, assetsByName) {
  if (!trackPath) return null;
  const track = JSON.parse(fs.readFileSync(trackPath, 'utf8'));
  const names = uniqueTrackClassNames(track);
  const matched = [];
  const unmatched = [];
  for (const className of names) {
    const normalized = stripAssetExtension(className).replace(/_C$/i, '');
    const asset = assetsByName.get(normalized);
    if (asset) matched.push({ className, assetName: asset.assetName, ...inferMetadata(asset.assetName) });
    else unmatched.push({ className });
  }
  return {
    trackPath,
    classNameCount: names.length,
    matchedCount: matched.length,
    unmatchedCount: unmatched.length,
    matched,
    unmatched,
  };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    process.stdout.write(`${usage()}\n`);
    return;
  }

  const pakDirectory = resolveCliPath(args.paks) ?? readFModelGameDirectory();
  const trackPath = resolveCliPath(args.track);
  const outPath = resolveCliPath(args.out);
  if (!pakDirectory) throw new Error('No pak directory provided and FModel GameDirectory was not available.');
  if (!outPath) throw new Error('--out is required');

  const utocFiles = fs
    .readdirSync(pakDirectory, { withFileTypes: true })
    .filter((entry) => entry.isFile() && /\.utoc$/i.test(entry.name))
    .map((entry) => path.join(pakDirectory, entry.name))
    .sort((a, b) => a.localeCompare(b));

  const assetsByName = new Map();
  const countsBySource = new Map();
  for (const filePath of utocFiles) {
    const sourceUtoc = path.basename(filePath);
    const buffer = fs.readFileSync(filePath);
    const tokens = extractAsciiTokens(buffer);
    for (const token of tokens) {
      if (!/\.(?:uasset|uexp|ubulk|umap)$/i.test(token)) continue;
      const assetName = stripAssetExtension(path.basename(token));
      if (!shouldIncludeAssetName(assetName, args.includeFxAssets, args.includeBroadAbilityNames)) continue;
      const existing = assetsByName.get(assetName);
      if (existing) {
        existing.sourceUtocs.push(sourceUtoc);
        continue;
      }
      const asset = {
        assetName,
        ...inferMetadata(assetName),
        sourceUtocs: [sourceUtoc],
      };
      assetsByName.set(assetName, asset);
      addCount(countsBySource, sourceUtoc);
    }
  }

  const assets = [...assetsByName.values()].sort((a, b) => a.assetName.localeCompare(b.assetName));
  const countsByKind = new Map();
  const countsByAgent = new Map();
  const countsBySlot = new Map();
  for (const asset of assets) {
    addCount(countsByKind, asset.contentKind);
    addCount(countsByAgent, asset.icarusAgentType);
    addCount(countsBySlot, asset.abilitySlot);
  }

  const result = {
    generatedAt: new Date().toISOString(),
    source: {
      pakDirectory,
      utocCount: utocFiles.length,
      fmodelSettingsPath: fs.existsSync(DEFAULT_FMODEL_SETTINGS) ? DEFAULT_FMODEL_SETTINGS : null,
    },
    counts: {
      assetCount: assets.length,
      byKind: sortCounts(countsByKind),
      byAgent: sortCounts(countsByAgent),
      bySlot: sortCounts(countsBySlot),
      bySourceUtoc: sortCounts(countsBySource),
    },
    assets,
    replayJoin: buildReplayJoin(trackPath, assetsByName),
  };

  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, `${JSON.stringify(result, null, 2)}\n`);
  process.stdout.write(
    [
      `cataloged ${assets.length} ability-shaped assets from ${utocFiles.length} .utoc files`,
      trackPath && result.replayJoin
        ? `replay class names: ${result.replayJoin.matchedCount}/${result.replayJoin.classNameCount} matched`
        : null,
      `wrote ${outPath}`,
    ]
      .filter(Boolean)
      .join('\n') + '\n',
  );
}

main();
