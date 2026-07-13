#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

function firstExistingPath(candidates) {
  return candidates.find((candidate) => candidate && fs.existsSync(candidate)) ?? candidates.find(Boolean);
}

const DEFAULT_EXPORT_ROOT = firstExistingPath([
  process.env.VALORANT_FMODEL_EXPORT_ROOT,
  'D:\\Downloads\\Output\\Exports\\ShooterGame',
  path.join(
    process.env.USERPROFILE ?? 'C:\\Users\\shawn',
    'Downloads',
    'Output',
    'Exports',
    'ShooterGame',
  ),
]);

const DEFAULT_OUT_DIR = path.resolve('tmp/valorant_export_research/indexes');

const KEYWORDS = [
  ['replay', /Replay/i],
  ['client_replay_input_capture', /ClientReplayReceiveInputEventProcessingCapture/i],
  ['remote_character_updates', /RemoteCharacterUpdates/i],
  ['component_data_stream', /ComponentDataStream/i],
  ['ability_statistics', /AbilityStatistics|CharacterAbilityStatistics|ECharacterAbilityStatisticList/i],
  ['ability_system', /AresAbilitySystem|AbilitySystem|AbilityTracking/i],
  ['ability_cast', /AbilityCast|CastInfo|CharacterAbilityCastInfo/i],
  ['character_ability', /CharacterAbility|ECharacterAbilitySlot/i],
  ['input_state', /AresInputState|InputEvent|AbilityInputs|ActivationInput|EquippableInput/i],
  ['inventory', /AresInventory|CurrentEquippable|EquippableState|EquipmentCharge/i],
  ['equippable', /Equippable/i],
  ['projectile', /Projectile/i],
  ['game_object', /GameObject/i],
  ['patch', /Patch_/i],
  ['statistic', /Statistic/i],
  ['damage', /Damage|DmgSource|Health|Armor/i],
  ['death', /Death|Killed|Killfeed/i],
  ['round', /Round|RoundPhase|Spike|Bomb|Defuse|Plant/i],
  ['map', /Minimap|MapDisplay|Callout|TacticalMap/i],
  ['uuid', /"Uuid"|"UUID"|Uuid/i],
  ['guid', /Guid|NetGUID|NetGuid|ActorNetGuid/i],
  ['replication', /Replicated|Replication|RepLayout|RepNotify|Replicator/i],
  ['net', /ClassNetCache|NetField|NetSerialize|Network/i],
  ['movement', /Movement|Velocity|Location|Rotation|View|Aim/i],
];

const REPLAY_SIGNAL_KEYWORDS = new Set([
  'replay',
  'client_replay_input_capture',
  'remote_character_updates',
  'component_data_stream',
  'ability_statistics',
  'ability_system',
  'ability_cast',
  'input_state',
  'inventory',
  'replication',
  'net',
  'guid',
]);

function parseArgs(argv) {
  const args = {
    exportRoot: DEFAULT_EXPORT_ROOT,
    outDir: DEFAULT_OUT_DIR,
    sampleLimit: 300,
    parseSizeLimitMb: 80,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--export-root') args.exportRoot = argv[++index];
    else if (arg.startsWith('--export-root=')) args.exportRoot = arg.slice('--export-root='.length);
    else if (arg === '--out-dir') args.outDir = argv[++index];
    else if (arg.startsWith('--out-dir=')) args.outDir = arg.slice('--out-dir='.length);
    else if (arg === '--sample-limit') args.sampleLimit = Number(argv[++index]);
    else if (arg.startsWith('--sample-limit=')) args.sampleLimit = Number(arg.slice('--sample-limit='.length));
    else if (arg === '--parse-size-limit-mb') args.parseSizeLimitMb = Number(argv[++index]);
    else if (arg.startsWith('--parse-size-limit-mb=')) args.parseSizeLimitMb = Number(arg.slice('--parse-size-limit-mb='.length));
    else if (arg === '--help' || arg === '-h') args.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }

  args.exportRoot = path.resolve(args.exportRoot);
  args.outDir = path.resolve(args.outDir);
  return args;
}

function usage() {
  return [
    'usage: node build_fmodel_export_index.mjs [--export-root <dir>] [--out-dir <dir>]',
    '',
    'Builds compact JSON/JSONL indexes from a full FModel package-property export.',
  ].join('\n');
}

function* walkFiles(root) {
  const stack = [root];
  while (stack.length > 0) {
    const current = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(current, { withFileTypes: true });
    } catch {
      continue;
    }
    entries.sort((left, right) => right.name.localeCompare(left.name));
    for (const entry of entries) {
      const fullPath = path.join(current, entry.name);
      if (entry.isDirectory()) stack.push(fullPath);
      else if (entry.isFile() && entry.name.endsWith('.json')) yield fullPath;
    }
  }
}

function addCount(map, key, amount = 1) {
  const normalized = key || 'unknown';
  map.set(normalized, (map.get(normalized) ?? 0) + amount);
}

function addSample(index, key, sample, limit) {
  const normalized = key || 'unknown';
  let entry = index.get(normalized);
  if (!entry) {
    entry = { count: 0, samples: [] };
    index.set(normalized, entry);
  }
  entry.count += 1;
  if (entry.samples.length < limit) entry.samples.push(sample);
}

function sortedCountMap(map, limit = null) {
  const rows = [...map.entries()]
    .sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0]))
    .map(([key, count]) => ({ key, count }));
  return limit == null ? rows : rows.slice(0, limit);
}

function sortedSampleIndex(index) {
  return Object.fromEntries(
    [...index.entries()]
      .sort((left, right) => right[1].count - left[1].count || left[0].localeCompare(right[0]))
      .map(([key, value]) => [key, value]),
  );
}

function contentFamilyFromRelative(relativePath) {
  const parts = relativePath.split('/');
  if (parts[0] === 'Content') return parts[1] ?? 'Content';
  return parts[0] ?? 'unknown';
}

function pathPrefix(relativePath, depth) {
  return relativePath.split('/').slice(0, depth).join('/') || 'root';
}

function uniqueStrings(values, limit = 20) {
  return [...new Set(values.filter(Boolean))].slice(0, limit);
}

function defaultExports(exports) {
  if (!Array.isArray(exports)) return [];
  return exports.filter((entry) => typeof entry?.Name === 'string' && entry.Name.startsWith('Default__'));
}

function propertyKeys(exports) {
  const keys = [];
  for (const entry of defaultExports(exports)) {
    if (entry?.Properties && typeof entry.Properties === 'object' && !Array.isArray(entry.Properties)) {
      keys.push(...Object.keys(entry.Properties));
    }
  }
  return uniqueStrings(keys, 120);
}

function exportTypes(exports) {
  if (!Array.isArray(exports)) return [];
  return uniqueStrings(exports.map((entry) => entry?.Type), 40);
}

function exportNames(exports) {
  if (!Array.isArray(exports)) return [];
  return uniqueStrings(exports.map((entry) => entry?.Name), 12);
}

function packageNames(exports) {
  if (!Array.isArray(exports)) return [];
  return uniqueStrings(exports.map((entry) => entry?.Package), 8);
}

function matchUuids(text) {
  return uniqueStrings(
    [...text.matchAll(/[0-9A-F]{8}-[0-9A-F]{8}-[0-9A-F]{8}-[0-9A-F]{8}/gi)].map((match) =>
      match[0].toUpperCase(),
    ),
    20,
  );
}

function matchPathRefs(text) {
  return uniqueStrings(
    [...text.matchAll(/\/(?:Game|Script)\/[A-Za-z0-9_./:-]+/g)].map((match) =>
      match[0].replace(/[.)]+$/g, ''),
    ),
    80,
  );
}

function keywordHits(text) {
  const hits = [];
  for (const [name, pattern] of KEYWORDS) {
    if (pattern.test(text)) hits.push(name);
  }
  return hits;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    return;
  }

  if (!fs.existsSync(args.exportRoot)) {
    throw new Error(`Export root does not exist: ${args.exportRoot}`);
  }

  fs.mkdirSync(args.outDir, { recursive: true });
  const manifestPath = path.join(args.outDir, 'asset_manifest.jsonl');
  const uuidPath = path.join(args.outDir, 'uuid_assets.jsonl');
  const replaySignalPath = path.join(args.outDir, 'replay_signal_files.jsonl');
  const referencePath = path.join(args.outDir, 'selected_references.jsonl');

  const manifest = fs.createWriteStream(manifestPath, { encoding: 'utf8' });
  const uuidAssets = fs.createWriteStream(uuidPath, { encoding: 'utf8' });
  const replaySignals = fs.createWriteStream(replaySignalPath, { encoding: 'utf8' });
  const references = fs.createWriteStream(referencePath, { encoding: 'utf8' });

  const countsByFamily = new Map();
  const countsByPath2 = new Map();
  const countsByType = new Map();
  const countsByPropertyKey = new Map();
  const keywordIndex = new Map();
  const parseErrors = [];
  const largestFiles = [];
  const parseSizeLimit = args.parseSizeLimitMb * 1024 * 1024;
  let fileCount = 0;
  let totalBytes = 0;
  let parsedCount = 0;
  let skippedLargeCount = 0;
  let uuidFileCount = 0;
  let replaySignalFileCount = 0;
  let selectedReferenceCount = 0;

  const startedAt = Date.now();
  for (const filePath of walkFiles(args.exportRoot)) {
    fileCount += 1;
    const stat = fs.statSync(filePath);
    totalBytes += stat.size;
    const relativePath = path.relative(args.exportRoot, filePath).replaceAll(path.sep, '/');
    const family = contentFamilyFromRelative(relativePath);
    addCount(countsByFamily, family);
    addCount(countsByPath2, pathPrefix(relativePath, 2));

    largestFiles.push({ relativePath, bytes: stat.size });
    largestFiles.sort((left, right) => right.bytes - left.bytes);
    if (largestFiles.length > 50) largestFiles.pop();

    let text = '';
    let hits = [];
    let uuids = [];
    let selectedRefs = [];
    if (stat.size <= parseSizeLimit) {
      text = fs.readFileSync(filePath, 'utf8');
      hits = keywordHits(text);
      uuids = matchUuids(text);
      selectedRefs = matchPathRefs(text).filter((ref) =>
        /Replay|Ability|Equippable|Input|Inventory|Projectile|GameObject|Patch|Damage|Death|Round|Spike|Bomb|Movement|Character|Ares|Net/i.test(
          ref,
        ),
      );
    } else {
      skippedLargeCount += 1;
    }
    for (const hit of hits) addSample(keywordIndex, hit, relativePath, args.sampleLimit);

    const hasReplaySignal = hits.some((hit) => REPLAY_SIGNAL_KEYWORDS.has(hit));
    let exports = null;
    let parsed = false;
    if (stat.size <= parseSizeLimit) {
      try {
        exports = JSON.parse(text);
        parsed = true;
        parsedCount += 1;
      } catch (error) {
        if (parseErrors.length < 200) {
          parseErrors.push({ relativePath, error: String(error) });
        }
      }
    }

    const types = parsed ? exportTypes(exports) : [];
    const names = parsed ? exportNames(exports) : [];
    const packages = parsed ? packageNames(exports) : [];
    const keys = parsed ? propertyKeys(exports) : [];

    for (const type of types) addCount(countsByType, type);
    for (const key of keys) addCount(countsByPropertyKey, key);

    const row = {
      relativePath,
      bytes: stat.size,
      family,
      path2: pathPrefix(relativePath, 2),
      exportCount: Array.isArray(exports) ? exports.length : null,
      types,
      names,
      packages,
      propertyKeys: keys,
      uuids,
      keywords: hits,
    };
    manifest.write(`${JSON.stringify(row)}\n`);

    if (uuids.length) {
      uuidFileCount += 1;
      uuidAssets.write(`${JSON.stringify(row)}\n`);
    }
    if (hasReplaySignal) {
      replaySignalFileCount += 1;
      replaySignals.write(`${JSON.stringify(row)}\n`);
    }

    for (const ref of selectedRefs.slice(0, 40)) {
      selectedReferenceCount += 1;
      references.write(`${JSON.stringify({ source: relativePath, ref })}\n`);
    }

    if (fileCount % 25000 === 0) {
      process.stderr.write(`indexed ${fileCount} files...\n`);
    }
  }

  manifest.end();
  uuidAssets.end();
  replaySignals.end();
  references.end();

  const summary = {
    generatedAt: new Date().toISOString(),
    exportRoot: args.exportRoot,
    outDir: args.outDir,
    elapsedMs: Date.now() - startedAt,
    fileCount,
    parsedCount,
    skippedLargeCount,
    totalBytes,
    totalMiB: Number((totalBytes / 1024 / 1024).toFixed(2)),
    uuidFileCount,
    replaySignalFileCount,
    selectedReferenceCount,
    countsByFamily: sortedCountMap(countsByFamily),
    countsByPath2: sortedCountMap(countsByPath2, 200),
    topTypes: sortedCountMap(countsByType, 200),
    topPropertyKeys: sortedCountMap(countsByPropertyKey, 300),
    largestFiles,
    parseErrors,
    outputs: {
      manifestPath,
      uuidPath,
      replaySignalPath,
      referencePath,
      keywordHitsPath: path.join(args.outDir, 'keyword_hits.json'),
      typeIndexPath: path.join(args.outDir, 'type_index.json'),
      propertyKeyIndexPath: path.join(args.outDir, 'property_key_index.json'),
    },
  };

  fs.writeFileSync(path.join(args.outDir, 'summary.json'), `${JSON.stringify(summary, null, 2)}\n`);
  fs.writeFileSync(
    path.join(args.outDir, 'keyword_hits.json'),
    `${JSON.stringify(sortedSampleIndex(keywordIndex), null, 2)}\n`,
  );
  fs.writeFileSync(
    path.join(args.outDir, 'type_index.json'),
    `${JSON.stringify(sortedCountMap(countsByType), null, 2)}\n`,
  );
  fs.writeFileSync(
    path.join(args.outDir, 'property_key_index.json'),
    `${JSON.stringify(sortedCountMap(countsByPropertyKey), null, 2)}\n`,
  );

  console.log(JSON.stringify(summary, null, 2));
}

main();
