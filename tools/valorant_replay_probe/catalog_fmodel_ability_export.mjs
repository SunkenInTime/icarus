#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

function firstExistingPath(candidates) {
  return candidates.find((candidate) => candidate && fs.existsSync(candidate)) ?? candidates.find(Boolean);
}

const DEFAULT_EXPORT_ROOT = firstExistingPath([
  process.env.VALORANT_FMODEL_CHARACTERS_ROOT,
  process.env.VALORANT_FMODEL_EXPORT_ROOT
    ? path.join(process.env.VALORANT_FMODEL_EXPORT_ROOT, 'Content', 'Characters')
    : null,
  'D:\\Downloads\\Output\\Exports\\ShooterGame\\Content\\Characters',
  path.join(
    process.env.USERPROFILE ?? 'C:\\Users\\shawn',
    'Downloads',
    'Output',
    'Exports',
    'ShooterGame',
    'Content',
    'Characters',
  ),
]);

const AGENT_TOKENS = new Map([
  ['AggroBot', { agent: 'Gekko', icarusAgentType: 'gekko' }],
  ['Astra', { agent: 'Astra', icarusAgentType: 'astra' }],
  ['BountyHunter', { agent: 'Fade', icarusAgentType: 'fade' }],
  ['Breach', { agent: 'Breach', icarusAgentType: 'breach' }],
  ['Cable', { agent: 'Deadlock', icarusAgentType: 'deadlock' }],
  ['Cashew', { agent: 'Tejo', icarusAgentType: 'tejo' }],
  ['Clay', { agent: 'Raze', icarusAgentType: 'raze' }],
  ['Deadeye', { agent: 'Chamber', icarusAgentType: 'chamber' }],
  ['Grenadier', { agent: 'KAY/O', icarusAgentType: 'kayo' }],
  ['Guide', { agent: 'Skye', icarusAgentType: 'skye' }],
  ['Gumshoe', { agent: 'Cypher', icarusAgentType: 'cypher' }],
  ['Harbor', { agent: 'Harbor', icarusAgentType: 'harbor' }],
  ['Hunter', { agent: 'Sova', icarusAgentType: 'sova' }],
  ['Iris', { agent: 'Miks', icarusAgentType: 'miks' }],
  ['Jett', { agent: 'Jett', icarusAgentType: 'jett' }],
  ['Killjoy', { agent: 'Killjoy', icarusAgentType: 'killjoy' }],
  ['Mage', { agent: 'Harbor', icarusAgentType: 'harbor' }],
  ['Miks', { agent: 'Miks', icarusAgentType: 'miks' }],
  ['Nox', { agent: 'Vyse', icarusAgentType: 'vyse' }],
  ['Pandemic', { agent: 'Viper', icarusAgentType: 'viper' }],
  ['Phoenix', { agent: 'Phoenix', icarusAgentType: 'pheonix' }],
  ['Pine', { agent: 'Veto', icarusAgentType: 'veto' }],
  ['Raze', { agent: 'Raze', icarusAgentType: 'raze' }],
  ['Rift', { agent: 'Astra', icarusAgentType: 'astra' }],
  ['Sage', { agent: 'Sage', icarusAgentType: 'sage' }],
  ['Sarge', { agent: 'Brimstone', icarusAgentType: 'brimstone' }],
  ['Sequoia', { agent: 'Iso', icarusAgentType: 'iso' }],
  ['Smonk', { agent: 'Clove', icarusAgentType: 'clove' }],
  ['Sprinter', { agent: 'Neon', icarusAgentType: 'neon' }],
  ['Stealth', { agent: 'Yoru', icarusAgentType: 'yoru' }],
  ['Terra', { agent: 'Waylay', icarusAgentType: 'waylay' }],
  ['Thorne', { agent: 'Sage', icarusAgentType: 'sage' }],
  ['Vampire', { agent: 'Reyna', icarusAgentType: 'reyna' }],
  ['Viper', { agent: 'Viper', icarusAgentType: 'viper' }],
  ['Wraith', { agent: 'Omen', icarusAgentType: 'omen' }],
  ['Wushu', { agent: 'Jett', icarusAgentType: 'jett' }],
  ['Yoru', { agent: 'Yoru', icarusAgentType: 'yoru' }],
]);

const SLOT_DIRS = new Map([
  ['Ability_4', { slot: 'Grenade', abilityIndex: 0, key: 'GrenadeAbility' }],
  ['Ability_C', { slot: 'Grenade', abilityIndex: 0, key: 'GrenadeAbility' }],
  ['Ability_Q', { slot: 'Ability1', abilityIndex: 1, key: 'Ability1' }],
  ['Ability_E', { slot: 'Ability2', abilityIndex: 2, key: 'Ability2' }],
  ['Ability_X', { slot: 'Ultimate', abilityIndex: 3, key: 'Ultimate' }],
]);

const KIND_RULES = [
  { pattern: /^Ability_/i, kind: 'ability-class' },
  { pattern: /^Projectile_/i, kind: 'projectile-class' },
  { pattern: /^GameObject_/i, kind: 'game-object-class' },
  { pattern: /^Patch_/i, kind: 'area-patch-class' },
  { pattern: /^Equippable_/i, kind: 'equippable-class' },
  { pattern: /^Gun_/i, kind: 'equippable-class' },
  { pattern: /^ForceModule_/i, kind: 'movement-force-module' },
  { pattern: /^Comp_Ability/i, kind: 'ability-component' },
  { pattern: /^StateComponent_/i, kind: 'state-component' },
  { pattern: /^FXC_/i, kind: 'fx-class' },
  { pattern: /PrimaryAsset$/i, kind: 'primary-data-asset' },
  { pattern: /UIData$/i, kind: 'ui-data' },
];

function parseArgs(argv) {
  const args = {
    exportRoot: DEFAULT_EXPORT_ROOT,
    out: path.resolve('tools/valorant_replay_probe/tmp/valorant_12_11_fmodel_ability_catalog.json'),
    includeFxAssets: false,
    maxAbilityAssets: 15000,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--export-root') args.exportRoot = argv[++index];
    else if (arg.startsWith('--export-root=')) args.exportRoot = arg.slice('--export-root='.length);
    else if (arg === '--out') args.out = argv[++index];
    else if (arg.startsWith('--out=')) args.out = arg.slice('--out='.length);
    else if (arg === '--include-fx-assets') args.includeFxAssets = true;
    else if (arg === '--max-ability-assets') args.maxAbilityAssets = Number(argv[++index]);
    else if (arg.startsWith('--max-ability-assets=')) args.maxAbilityAssets = Number(arg.slice('--max-ability-assets='.length));
    else if (arg === '--help' || arg === '-h') args.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }

  args.exportRoot = path.resolve(args.exportRoot);
  args.out = path.resolve(args.out);
  return args;
}

function usage() {
  return [
    'usage: node tools/valorant_replay_probe/catalog_fmodel_ability_export.mjs [--export-root <dir>] [--out <json>]',
    '',
    'Builds an ability/slot/UUID catalog from FModel exported package-property JSON.',
    'Default export root uses VALORANT_FMODEL_CHARACTERS_ROOT, VALORANT_FMODEL_EXPORT_ROOT, or a discovered Downloads/Output export.',
  ].join('\n');
}

function* walkFiles(root, predicate = () => true) {
  const stack = [root];
  while (stack.length > 0) {
    const current = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(current, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const fullPath = path.join(current, entry.name);
      if (entry.isDirectory()) stack.push(fullPath);
      else if (entry.isFile() && predicate(fullPath, entry.name)) yield fullPath;
    }
  }
}

function readJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (error) {
    return { parseError: String(error) };
  }
}

function firstDefaultExport(exports) {
  if (!Array.isArray(exports)) return null;
  return exports.find((entry) => typeof entry?.Name === 'string' && entry.Name.startsWith('Default__')) ?? null;
}

function localizedText(value) {
  if (value == null || typeof value !== 'object') return null;
  return value.LocalizedString ?? value.SourceString ?? null;
}

function assetPathName(value) {
  if (value == null || typeof value !== 'object') return null;
  return value.AssetPathName ?? value.ObjectPath ?? value.ObjectName ?? null;
}

function inferAgentFromPath(filePath, exportRoot) {
  const relative = path.relative(exportRoot, filePath);
  const token = relative.split(path.sep)[0];
  return {
    token,
    ...(AGENT_TOKENS.get(token) ?? { agent: token, icarusAgentType: token.toLowerCase() }),
  };
}

function inferSlotFromPath(filePath) {
  for (const segment of filePath.split(path.sep)) {
    if (SLOT_DIRS.has(segment)) return { dir: segment, ...SLOT_DIRS.get(segment) };
  }
  return null;
}

function classifyAssetName(name) {
  return KIND_RULES.find((rule) => rule.pattern.test(name))?.kind ?? 'other';
}

function addCount(map, key) {
  const normalized = key ?? 'unknown';
  map.set(normalized, (map.get(normalized) ?? 0) + 1);
}

function sortedCounts(map) {
  return [...map.entries()]
    .sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0]))
    .map(([key, count]) => ({ key, count }));
}

function findStrings(value, predicate, hits = new Set()) {
  if (typeof value === 'string') {
    if (predicate(value)) hits.add(value);
    return hits;
  }
  if (Array.isArray(value)) {
    for (const item of value) findStrings(item, predicate, hits);
    return hits;
  }
  if (value && typeof value === 'object') {
    for (const item of Object.values(value)) findStrings(item, predicate, hits);
  }
  return hits;
}

function extractRegexStrings(text, regex) {
  const hits = new Set();
  for (const match of text.matchAll(regex)) hits.add(match[0]);
  return [...hits].sort();
}

function scanUuidObjects(value, context, hits = []) {
  if (Array.isArray(value)) {
    for (const item of value) scanUuidObjects(item, context, hits);
    return hits;
  }
  if (!value || typeof value !== 'object') return hits;
  if (typeof value.Uuid === 'string') {
    hits.push({
      uuid: value.Uuid,
      package: context.package,
      exportName: context.exportName,
      exportType: context.exportType,
    });
  }
  for (const item of Object.values(value)) scanUuidObjects(item, context, hits);
  return hits;
}

function parseUiData(filePath, exportRoot) {
  const exports = readJson(filePath);
  if (!Array.isArray(exports)) return null;
  const defaultExport = firstDefaultExport(exports);
  const properties = defaultExport?.Properties;
  if (!properties?.Abilities) return null;

  const childByName = new Map(
    exports
      .filter((entry) => entry?.Type === 'CharacterAbilityUIData')
      .map((entry) => [entry.Name, entry]),
  );

  const slotEntries = [];
  for (const item of properties.Abilities) {
    const slot = item?.Key?.replace('ECharacterAbilitySlot::', '') ?? null;
    const childName = item?.Value?.ObjectName?.match(/:(CharacterAbilityUIData_\d+)'?$/)?.[1] ?? null;
    const child = childByName.get(childName);
    slotEntries.push({
      slot,
      uiObject: childName,
      displayName: localizedText(child?.Properties?.DisplayName),
      description: localizedText(child?.Properties?.Description),
      displayIcon: assetPathName(child?.Properties?.DisplayIcon),
    });
  }

  return {
    file: filePath,
    package: defaultExport.Package,
    ...inferAgentFromPath(filePath, exportRoot),
    characterDisplayName: localizedText(properties.DisplayName),
    characterDescription: localizedText(properties.Description),
    slots: slotEntries,
  };
}

function parsePrimaryAsset(filePath, exportRoot) {
  const exports = readJson(filePath);
  if (!Array.isArray(exports)) return null;
  const defaultExport = firstDefaultExport(exports);
  const properties = defaultExport?.Properties;
  if (!properties?.Uuid) return null;

  const inferredAgent = inferAgentFromPath(filePath, exportRoot);
  const inferredSlot = inferSlotFromPath(filePath);
  return {
    file: filePath,
    package: defaultExport.Package,
    exportName: defaultExport.Name,
    exportType: defaultExport.Type,
    ...inferredAgent,
    slot: inferredSlot?.slot ?? null,
    abilityIndex: inferredSlot?.abilityIndex ?? null,
    slotDir: inferredSlot?.dir ?? null,
    characterId: properties.CharacterID ?? null,
    developerName: properties.DeveloperName ?? null,
    uuid: properties.Uuid,
    characterPath: assetPathName(properties.Character),
    equippablePath: assetPathName(properties.Equippable),
    uiDataPath: assetPathName(properties.UIData),
    rolePath: assetPathName(properties.Role),
    isPlayableCharacter: properties.bIsPlayableCharacter ?? null,
  };
}

function parseAbilityAsset(filePath, exportRoot) {
  const basename = path.basename(filePath, '.json');
  if (!basename.match(/^(Ability_|Projectile_|GameObject_|Patch_|Equippable_|Gun_|ForceModule_|Comp_Ability|StateComponent_|FXC_)/i)) {
    return null;
  }
  const kind = classifyAssetName(basename);
  const slot = inferSlotFromPath(filePath);
  if (!slot && kind !== 'ability-component') return null;

  const text = fs.readFileSync(filePath, 'utf8');
  let exports = null;
  try {
    exports = JSON.parse(text);
  } catch {
    exports = null;
  }
  const defaultExport = firstDefaultExport(exports);
  const searchRoot = defaultExport?.Properties ?? exports;
  const statisticStrings = extractRegexStrings(text, /ECharacterAbilityStatisticList::[A-Za-z0-9_]+/g);
  const inputStrings = extractRegexStrings(text, /Enum_AbilityInputs::[A-Za-z0-9_]+/g);
  const overrideSlots = [
    ...new Set([
      ...findStrings(searchRoot, (value) => value.startsWith('EAresItemSlot::')),
      ...extractRegexStrings(text, /EAresItemSlot::[A-Za-z0-9_]+/g),
    ]),
  ].sort();
  const uuidHits = scanUuidObjects(searchRoot, {
    package: defaultExport?.Package ?? null,
    exportName: defaultExport?.Name ?? null,
    exportType: defaultExport?.Type ?? null,
  });

  return {
    file: filePath,
    package: defaultExport?.Package ?? null,
    exportName: defaultExport?.Name ?? null,
    exportType: defaultExport?.Type ?? null,
    assetName: basename,
    kind,
    ...inferAgentFromPath(filePath, exportRoot),
    slot: slot?.slot ?? null,
    abilityIndex: slot?.abilityIndex ?? null,
    slotDir: slot?.dir ?? null,
    template: defaultExport?.Template?.ObjectName ?? null,
    statisticStrings,
    inputStrings,
    overrideSlots,
    uuidHits,
  };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    return;
  }
  if (!fs.existsSync(args.exportRoot)) {
    throw new Error(`FModel export root does not exist: ${args.exportRoot}`);
  }

  const agents = [];
  const uiData = [];
  const primaryAssets = [];
  const abilityAssets = [];
  const uuidHits = [];
  const kindCounts = new Map();
  const slotCounts = new Map();
  const statisticCounts = new Map();
  const inputCounts = new Map();
  const overrideSlotCounts = new Map();

  for (const filePath of walkFiles(args.exportRoot, (file, name) => name.endsWith('.json') && !file.includes(`${path.sep}WwiseAudio${path.sep}`))) {
    const basename = path.basename(filePath);
    if (basename.endsWith('_UIData.json')) {
      const item = parseUiData(filePath, args.exportRoot);
      if (item) uiData.push(item);
    }

    if (basename.endsWith('_PrimaryAsset.json') || basename.endsWith('_PrimaryDataAsset.json')) {
      const item = parsePrimaryAsset(filePath, args.exportRoot);
      if (item) {
        primaryAssets.push(item);
        uuidHits.push({
          uuid: item.uuid,
          package: item.package,
          exportName: item.exportName,
          exportType: item.exportType,
        });
      }
    }

    if (abilityAssets.length < args.maxAbilityAssets) {
      const item = parseAbilityAsset(filePath, args.exportRoot);
      if (item && (args.includeFxAssets || item.kind !== 'fx-class')) {
        abilityAssets.push(item);
        addCount(kindCounts, item.kind);
        addCount(slotCounts, item.slot);
        for (const statistic of item.statisticStrings) addCount(statisticCounts, statistic);
        for (const input of item.inputStrings) addCount(inputCounts, input);
        for (const slot of item.overrideSlots) addCount(overrideSlotCounts, slot);
        uuidHits.push(...item.uuidHits);
      }
    }
  }

  const agentByToken = new Map();
  for (const item of primaryAssets.filter((asset) => asset.developerName || asset.characterId)) {
    agentByToken.set(item.token, item);
    agents.push(item);
  }

  const uiByToken = new Map(uiData.map((item) => [item.token, item]));
  const equippablePrimaryAssets = primaryAssets.filter((asset) => asset.equippablePath);
  const equippablesByTokenSlot = new Map();
  for (const asset of equippablePrimaryAssets) {
    if (!asset.slot) continue;
    const key = `${asset.token}:${asset.slot}`;
    if (!equippablesByTokenSlot.has(key)) equippablesByTokenSlot.set(key, []);
    equippablesByTokenSlot.get(key).push(asset);
  }

  const slotCatalog = [];
  for (const [token, agentPrimary] of agentByToken.entries()) {
    const ui = uiByToken.get(token);
    for (const slot of ui?.slots ?? []) {
      const equippables = equippablesByTokenSlot.get(`${token}:${slot.slot}`) ?? [];
      slotCatalog.push({
        token,
        agent: agentPrimary.agent,
        icarusAgentType: agentPrimary.icarusAgentType,
        characterUuid: agentPrimary.uuid,
        characterId: agentPrimary.characterId,
        slot: slot.slot,
        displayName: slot.displayName,
        description: slot.description,
        displayIcon: slot.displayIcon,
        equippablePrimaryAssets: equippables.map((asset) => ({
          uuid: asset.uuid,
          package: asset.package,
          exportName: asset.exportName,
          equippablePath: asset.equippablePath,
          uiDataPath: asset.uiDataPath,
        })),
      });
    }
  }

  const uniqueUuidHits = [...new Map(uuidHits.map((hit) => [`${hit.uuid}:${hit.package}:${hit.exportName}`, hit])).values()]
    .sort((left, right) => String(left.package).localeCompare(String(right.package)) || String(left.exportName).localeCompare(String(right.exportName)));

  const output = {
    generatedAt: new Date().toISOString(),
    exportRoot: args.exportRoot,
    summary: {
      agents: agents.length,
      uiDataFiles: uiData.length,
      slotCatalogEntries: slotCatalog.length,
      primaryAssetsWithUuid: primaryAssets.length,
      equippablePrimaryAssetsWithUuid: equippablePrimaryAssets.length,
      abilityAssets: abilityAssets.length,
      uuidHits: uniqueUuidHits.length,
      kindCounts: sortedCounts(kindCounts),
      slotCounts: sortedCounts(slotCounts),
      statisticCounts: sortedCounts(statisticCounts),
      inputCounts: sortedCounts(inputCounts),
      overrideSlotCounts: sortedCounts(overrideSlotCounts),
    },
    agents,
    slotCatalog,
    equippablePrimaryAssets,
    abilityAssets,
    uuidHits: uniqueUuidHits,
  };

  fs.mkdirSync(path.dirname(args.out), { recursive: true });
  fs.writeFileSync(args.out, `${JSON.stringify(output, null, 2)}\n`);
  console.log(JSON.stringify(output.summary, null, 2));
  console.log(`Wrote ${args.out}`);
}

main();
