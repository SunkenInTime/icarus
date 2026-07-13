import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const harnessDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(harnessDir, '..', '..');

const mapsSource = fs.readFileSync(path.join(repoRoot, 'lib/const/maps.dart'), 'utf8');
const transformsSource = fs.readFileSync(
  path.join(repoRoot, 'lib/replay/valorant_map_transform.dart'),
  'utf8',
);
const agentsSource = fs.readFileSync(path.join(repoRoot, 'lib/const/agents.dart'), 'utf8');

function blockBetween(source, start, end) {
  const startIndex = source.indexOf(start);
  if (startIndex < 0) throw new Error(`Missing source block: ${start}`);
  const endIndex = source.indexOf(end, startIndex + start.length);
  if (endIndex < 0) throw new Error(`Missing source block terminator: ${end}`);
  return source.slice(startIndex + start.length, endIndex);
}

function parseMapPairs(block, valuePattern, mapValue) {
  const output = {};
  const regex = new RegExp(`MapValue\\.(\\w+)\\s*:\\s*${valuePattern}`, 'g');
  for (const match of block.matchAll(regex)) output[match[1]] = mapValue(match);
  return output;
}

const names = parseMapPairs(
  blockBetween(mapsSource, 'static Map<MapValue, String> mapNames = {', '};'),
  "['\"]([^'\"]+)['\"]",
  (match) => match[2],
);
const scales = parseMapPairs(
  blockBetween(mapsSource, 'static Map<MapValue, double> mapScale = {', '};'),
  '([0-9.]+)',
  (match) => Number(match[2]),
);
const viewBoxes = parseMapPairs(
  blockBetween(mapsSource, 'static const Map<MapValue, Size> mapViewBox = {', '};'),
  'Size\\(([0-9.]+),\\s*([0-9.]+)\\)',
  (match) => ({ width: Number(match[2]), height: Number(match[3]) }),
);
const paddings = parseMapPairs(
  blockBetween(
    mapsSource,
    'static const Map<MapValue, EdgeInsets> valorantDisplayIconPaddingVb = {',
    '};',
  ),
  'EdgeInsets\\.fromLTRB\\(([0-9.]+),\\s*([0-9.]+),\\s*([0-9.]+),\\s*([0-9.]+)\\)',
  (match) => ({
    left: Number(match[2]),
    top: Number(match[3]),
    right: Number(match[4]),
    bottom: Number(match[5]),
  }),
);

const transformBlock = blockBetween(
  transformsSource,
  'static const Map<MapValue, ValorantMapTransform> mapTransforms = {',
  '};',
);
const transforms = {};
for (const match of transformBlock.matchAll(
  /MapValue\.(\w+)\s*:\s*ValorantMapTransform\(\s*xMultiplier:\s*([0-9.-]+),\s*yMultiplier:\s*([0-9.-]+),\s*xScalarToAdd:\s*([0-9.-]+),\s*yScalarToAdd:\s*([0-9.-]+),\s*\)/g,
)) {
  transforms[match[1]] = {
    xMultiplier: Number(match[2]),
    yMultiplier: Number(match[3]),
    xScalarToAdd: Number(match[4]),
    yScalarToAdd: Number(match[5]),
  };
}

const turnBlock = blockBetween(
  transformsSource,
  'static const Map<MapValue, int> importCwQuarterTurns = {',
  '};',
);
const turns = {};
for (const match of turnBlock.matchAll(/MapValue\.(\w+)\s*:\s*(\d+)/g)) {
  turns[match[1]] = Number(match[2]);
}

const riotIds = {};
for (const match of transformsSource.matchAll(/['"]([^'"]+)['"]\s*:\s*MapValue\.(\w+)/g)) {
  if (match[1].startsWith('/Game/Maps/')) riotIds[match[1]] = match[2];
}

const maps = {};
for (const [key, name] of Object.entries(names)) {
  maps[key] = {
    key,
    name,
    asset: `../../assets/maps/${name}_map.svg`,
    calloutsAsset: `../../assets/maps/${name}_call_outs.svg`,
    scale: scales[key] ?? 1,
    viewBox: viewBoxes[key],
    padding: paddings[key] ?? null,
    transform: transforms[key],
    importCwQuarterTurns: turns[key] ?? 0,
  };
}

const agentAssetsDir = path.join(repoRoot, 'assets/agents');
const assetAgentNames = fs
  .readdirSync(agentAssetsDir, { withFileTypes: true })
  .filter((entry) => entry.isDirectory())
  .map((entry) => entry.name);

const parsedAgents = new Map();
for (const match of agentsSource.matchAll(
  /AgentData\(\s*type:\s*AgentType\.(\w+),[\s\S]{0,500}?name:\s*["']([^"']+)["'],[\s\S]{0,500}?abilityNames:\s*const\s*\[([\s\S]*?)\]/g,
)) {
  const abilityNames = [...match[3].matchAll(/["']([^"']+)["']/g)].map((nameMatch) => nameMatch[1]);
  parsedAgents.set(match[2].toLowerCase(), {
    type: match[1],
    name: match[2],
    abilityNames,
  });
}

const miksNames = [
  'M-pulse Concuss',
  'M-pulse Healing',
  'Harmonize',
  'Waveform',
  'Bassquake',
];
const agents = {};
if (process.env.DEBUG_CATALOG) {
  console.log(`Parsed Dart agents: ${[...parsedAgents.keys()].join(', ')}`);
}
for (const assetName of assetAgentNames.sort((a, b) => a.localeCompare(b))) {
  const parsed = parsedAgents.get(assetName.toLowerCase());
  const abilityFiles = fs
    .readdirSync(path.join(agentAssetsDir, assetName))
    .filter((file) => /^\d+\.webp$/i.test(file))
    .sort((a, b) => Number.parseInt(a, 10) - Number.parseInt(b, 10));
  if (assetName === 'Astra' && fs.existsSync(path.join(agentAssetsDir, assetName, 'star.webp'))) {
    abilityFiles.push('star.webp');
  }
  const abilityNames = assetName === 'Miks' ? miksNames : parsed?.abilityNames ?? [];
  if (assetName === 'Astra') abilityNames.push('Astra Star');
  const visualAssets = fs
    .readdirSync(path.join(agentAssetsDir, assetName))
    .filter((file) => file.endsWith('.webp') && file !== 'icon.webp' && !abilityFiles.includes(file))
    .map((file) => `../../assets/agents/${assetName}/${file}`);
  agents[assetName.toLowerCase()] = {
    key: parsed?.type ?? assetName.toLowerCase(),
    name: assetName,
    icon: `../../assets/agents/${assetName}/icon.webp`,
    visualAssets,
    abilities: abilityFiles.map((file, index) => ({
      index,
      name: abilityNames[index] ?? `Ability ${index + 1}`,
      icon: `../../assets/agents/${assetName}/${file}`,
    })),
  };
}

const generated = `// Generated by generate_catalog.mjs. Do not edit by hand.\n` +
  `export const MAPS = ${JSON.stringify(maps, null, 2)};\n\n` +
  `export const RIOT_MAP_IDS = ${JSON.stringify(riotIds, null, 2)};\n\n` +
  `export const AGENTS = ${JSON.stringify(agents, null, 2)};\n`;

fs.writeFileSync(path.join(harnessDir, 'catalog.generated.js'), generated);
console.log(`Generated ${Object.keys(maps).length} maps and ${Object.keys(agents).length} agents.`);
