#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const TOOL_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(TOOL_DIR, '..', '..');

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
const DEFAULT_OUT_DIR = path.resolve(
  REPO_ROOT,
  'tmp',
  'valorant_export_research',
  'indexes',
);
const DEFAULT_RUNTIME_OUT_DIR = path.join(TOOL_DIR, 'static_decoder_indexes');

function parseArgs(argv) {
  const args = {
    exportRoot: DEFAULT_EXPORT_ROOT,
    outDir: DEFAULT_OUT_DIR,
    runtimeOutDir: DEFAULT_RUNTIME_OUT_DIR,
    contentVersion: process.env.VALORANT_FMODEL_CONTENT_VERSION ?? null,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--export-root') {
      args.exportRoot = argv[++i];
    } else if (arg === '--out-dir') {
      args.outDir = argv[++i];
    } else if (arg === '--content-version') {
      args.contentVersion = argv[++i];
    } else if (arg === '--runtime-out-dir') {
      args.runtimeOutDir = argv[++i];
    } else if (arg === '--no-runtime-bundle') {
      args.runtimeOutDir = null;
    } else if (arg === '--help' || arg === '-h') {
      console.log(`Usage: node build_valorant_static_decoder_indexes.mjs [--export-root <path>] [--out-dir <path>] [--runtime-out-dir <path>] [--content-version <version>]

Builds small static indexes from a VALORANT FModel JSON export:
  - agent_primary_index.json
  - ability_actor_index.json
  - ability_spawn_graph_edges.jsonl`);
      process.exit(0);
    }
  }

  args.exportRoot = path.resolve(args.exportRoot);
  args.outDir = path.resolve(args.outDir);
  if (args.runtimeOutDir) args.runtimeOutDir = path.resolve(args.runtimeOutDir);
  return args;
}

function walkJsonFiles(root, visit) {
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
      if (entry.isDirectory()) {
        stack.push(fullPath);
      } else if (entry.isFile() && entry.name.endsWith('.json')) {
        visit(fullPath);
      }
    }
  }
}

function readJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch {
    return null;
  }
}

function readText(filePath) {
  try {
    return fs.readFileSync(filePath, 'utf8');
  } catch {
    return '';
  }
}

function rel(exportRoot, filePath) {
  return path.relative(exportRoot, filePath).replace(/\\/g, '/');
}

function firstObject(data) {
  if (!Array.isArray(data)) return null;
  return data.find((entry) => entry && typeof entry === 'object') ?? null;
}

function defaultObject(data, preferredObjectBase = null) {
  if (!Array.isArray(data)) return null;
  if (preferredObjectBase) {
    const wanted = `Default__${preferredObjectBase}_C`;
    const preferred = data.find((entry) => entry?.Name === wanted);
    if (preferred) return preferred;
  }
  return (
    data.find(
      (entry) =>
        entry &&
        typeof entry.Name === 'string' &&
        entry.Name.startsWith('Default__'),
    ) ?? firstObject(data)
  );
}

function propsOf(object) {
  return object?.Properties && typeof object.Properties === 'object'
    ? object.Properties
    : {};
}

function assetPathName(value) {
  if (typeof value === 'string') return value;
  if (value && typeof value === 'object') {
    if (typeof value.AssetPathName === 'string') return value.AssetPathName;
    if (typeof value.ObjectPath === 'string') return value.ObjectPath;
    if (typeof value.ObjectName === 'string') return value.ObjectName;
  }
  return null;
}

function splitObjectPath(objectPath) {
  if (typeof objectPath !== 'string') return null;
  const match = objectPath.match(/^(\/Game\/[^.:'"]+)(?:\.([^:'"]+))?/);
  if (!match) return null;
  return {
    packagePath: match[1],
    objectName: match[2] ?? path.posix.basename(match[1]),
  };
}

function fileForGamePath(exportRoot, objectPath) {
  const split = splitObjectPath(objectPath);
  if (!split) return null;
  const contentPath = split.packagePath.replace(/^\/Game\//, 'Content/');
  return path.join(exportRoot, `${contentPath}.json`);
}

function normalizeGamePath(objectPath) {
  const split = splitObjectPath(objectPath);
  return split?.packagePath ?? null;
}

function displayValue(value) {
  if (typeof value === 'string') return value;
  if (value && typeof value === 'object') {
    if (typeof value.SourceString === 'string') return value.SourceString;
    if (value.LocalizedString) return displayValue(value.LocalizedString);
    if (typeof value.Key === 'string') return value.Key;
    if (typeof value.Namespace === 'string' && typeof value.Key === 'string') {
      return `${value.Namespace}:${value.Key}`;
    }
  }
  return null;
}

function basenameFromGamePath(objectPath) {
  const normalized = normalizeGamePath(objectPath) ?? objectPath;
  if (!normalized || typeof normalized !== 'string') return '';
  return normalized.split('/').pop()?.replace(/_C$/, '') ?? '';
}

function classifyName(name, normalizedPath = '') {
  const base = basenameFromGamePath(name) || basenameFromGamePath(normalizedPath);
  const lowerPath = `${normalizedPath}/${base}`.toLowerCase();

  if (/^ability_/i.test(base)) return 'ability';
  if (/^projectile_/i.test(base)) return 'projectile';
  if (/^gameobject_/i.test(base)) return 'game_object';
  if (/^patch_/i.test(base)) return 'patch';
  if (/^(ai)?pawn_/i.test(base)) return 'deployable_pawn';
  if (/^forcemodule_/i.test(base)) return 'force_module';
  if (/^dmg(source|type)_/i.test(base)) return 'damage_metadata';
  if (/^buff_/i.test(base)) return 'buff';
  if (/^fxc_/i.test(base) || lowerPath.includes('/fxc_')) return 'fx';
  if (/^comp_ability/i.test(base)) return 'ability_component';
  if (/pickup|groundpickup|equippablepickup/i.test(base)) return 'pickup_drop';
  if (/equippable/i.test(base) || lowerPath.includes('/equippables/')) {
    return 'equippable';
  }
  if (/state(component|machine)?/i.test(base)) return 'state';
  return 'other';
}

function inferAgentAndSlotFromPath(gamePathOrRelPath) {
  const asPosix = gamePathOrRelPath.replace(/\\/g, '/');
  const parts = asPosix.split('/');
  const charactersIndex = parts.findIndex((part) => part === 'Characters');
  const agent = charactersIndex >= 0 ? parts[charactersIndex + 1] ?? null : null;
  const slotPart =
    parts.find((part) => /^Ability[12]$/i.test(part)) ??
    parts.find((part) => /^[QEXCP4]$/i.test(part)) ??
    parts.find((part) => /Ultimate|Passive|Grenade/i.test(part)) ??
    null;

  let inferredSlot = null;
  if (slotPart) {
    if (/^Ability1$/i.test(slotPart) || /^Q$/i.test(slotPart)) {
      inferredSlot = 'Ability1';
    } else if (/^Ability2$/i.test(slotPart) || /^E$/i.test(slotPart)) {
      inferredSlot = 'Ability2';
    } else if (/^Grenade$/i.test(slotPart) || /^[C4]$/i.test(slotPart)) {
      inferredSlot = 'Grenade';
    } else if (/^Ultimate$/i.test(slotPart) || /^X$/i.test(slotPart)) {
      inferredSlot = 'Ultimate';
    } else if (/^Passive$/i.test(slotPart) || /^P$/i.test(slotPart)) {
      inferredSlot = 'Passive';
    }
  }

  return { agent, inferredSlot };
}

function collectAssetPathReferences(text) {
  const refs = new Set();
  const regex = /\/Game\/[A-Za-z0-9_./-]+/g;
  let match;
  while ((match = regex.exec(text)) !== null) {
    const raw = match[0].replace(/[.,);}\]"']+$/g, '');
    const normalized = normalizeGamePath(raw);
    if (normalized) refs.add(normalized);
  }
  return [...refs].sort();
}

function collectPropertyReferenceContext(value, pathParts = [], out = []) {
  if (!value || typeof value !== 'object') {
    return out;
  }

  if (Array.isArray(value)) {
    value.forEach((item, index) => {
      collectPropertyReferenceContext(item, [...pathParts, String(index)], out);
    });
    return out;
  }

  const direct = assetPathName(value);
  if (direct) {
    const normalized = normalizeGamePath(direct);
    if (normalized) {
      out.push({ propertyPath: pathParts.join('.'), assetPath: normalized });
    }
  }

  for (const [key, item] of Object.entries(value)) {
    collectPropertyReferenceContext(item, [...pathParts, key], out);
  }

  return out;
}

function unwrapEnum(value) {
  if (typeof value === 'string') return value;
  if (value && typeof value === 'object') {
    if (typeof value.Value === 'string') return value.Value;
    if (typeof value.Name === 'string') return value.Name;
  }
  return null;
}

function normalizeAbilitySlot(value) {
  const raw = unwrapEnum(value);
  if (!raw) return null;
  const token = String(raw).split('::').pop();
  switch (token) {
    case 'Grenade':
    case 'GrenadeAbility':
      return 'Grenade';
    case 'Ability1':
      return 'Ability1';
    case 'Ability2':
    case 'SignatureAbility':
      return 'Ability2';
    case 'Ultimate':
    case 'UltimateAbility':
      return 'Ultimate';
    case 'Passive':
      return 'Passive';
    default:
      return null;
  }
}

function abilityIndexForSlot(slot) {
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

function classNameFromAssetPath(value) {
  return basenameFromGamePath(value).replace(/^Default__/, '').replace(/_C$/, '');
}

function addClassAlias(aliases, value) {
  const className = classNameFromAssetPath(value);
  if (className) aliases.add(className);
}

function loadUiSlots(exportRoot, uiDataPath) {
  if (!uiDataPath || !fs.existsSync(uiDataPath)) return {};
  const data = readJson(uiDataPath);
  const def = defaultObject(data, path.basename(uiDataPath, '.json'));
  const props = propsOf(def);
  const slots = {};
  const abilityEntries = Array.isArray(props.Abilities) ? props.Abilities : [];
  const uiObjectsByName = new Map();

  if (Array.isArray(data)) {
    for (const entry of data) {
      if (entry?.Name) uiObjectsByName.set(entry.Name, entry);
      const objectPath = assetPathName(entry?.Outer);
      if (entry?.Name && objectPath) {
        uiObjectsByName.set(`${objectPath}:${entry.Name}`, entry);
      }
    }
  }

  for (const abilityEntry of abilityEntries) {
    const slot =
      unwrapEnum(abilityEntry?.Key) ??
      unwrapEnum(abilityEntry?.Slot) ??
      unwrapEnum(abilityEntry?.AbilitySlot) ??
      unwrapEnum(abilityEntry?.AbilityType);
    const uiRef =
      abilityEntry?.Value ??
      abilityEntry?.AbilityUIData ??
      abilityEntry?.UIData ??
      abilityEntry?.CharacterAbilityUIData;
    const uiName = (() => {
      if (typeof uiRef === 'string') return uiRef;
      if (typeof uiRef?.ObjectName === 'string') {
        const quoted = uiRef.ObjectName.match(/:([^']+)'?$/);
        if (quoted) return quoted[1];
        return uiRef.ObjectName.split('.').pop();
      }
      return null;
    })();
    const uiObject = uiName ? uiObjectsByName.get(uiName) : null;
    const templatePath = assetPathName(uiObject?.Template);
    const templateFile = templatePath ? fileForGamePath(exportRoot, templatePath) : null;
    const templateData =
      templateFile && fs.existsSync(templateFile) ? readJson(templateFile) : null;
    const templateDef = templateData
      ? defaultObject(templateData, path.basename(templateFile, '.json'))
      : null;
    const uiProps = {
      ...propsOf(uiObject),
      ...propsOf(templateDef),
    };
    const key = slot ?? `Unknown_${Object.keys(slots).length}`;

    slots[key] = {
      uiObjectName: uiName,
      uiDataAsset: normalizeGamePath(templatePath),
      displayName:
        displayValue(uiProps.DisplayName) ??
        displayValue(uiProps.AbilityName) ??
        displayValue(uiProps.Name),
      description:
        displayValue(uiProps.Description) ??
        displayValue(uiProps.AbilityDescription),
      icon: normalizeGamePath(assetPathName(uiProps.Icon ?? uiProps.DisplayIcon)),
      rawSlot: slot,
    };
  }

  return slots;
}

function buildAgentPrimaryIndex(exportRoot) {
  const characterRoot = path.join(exportRoot, 'Content', 'Characters');
  const agents = [];

  walkJsonFiles(characterRoot, (filePath) => {
    if (!/PrimaryAsset\.json$/i.test(filePath)) return;
    const data = readJson(filePath);
    const def = defaultObject(data);
    const props = propsOf(def);
    if (!props.CharacterID || !props.Uuid) return;
    if (props.bIsPlayableCharacter === false) return;

    const characterPath = assetPathName(props.Character);
    const uiDataPathName = assetPathName(props.UIData);
    const characterFile = characterPath
      ? fileForGamePath(exportRoot, characterPath)
      : null;
    const uiDataFile = uiDataPathName
      ? fileForGamePath(exportRoot, uiDataPathName)
      : null;
    const characterData =
      characterFile && fs.existsSync(characterFile) ? readJson(characterFile) : null;
    const characterDef =
      characterFile && characterData
        ? defaultObject(characterData, path.basename(characterFile, '.json'))
        : null;
    const characterProps = propsOf(characterDef);
    const startingEquippableClasses = Array.isArray(
      characterProps.StartingEquippableClasses,
    )
      ? characterProps.StartingEquippableClasses
          .map(assetPathName)
          .map(normalizeGamePath)
          .filter(Boolean)
      : [];

    const abilityClasses = startingEquippableClasses.filter((entry) =>
      /\/Ability_/i.test(entry),
    );

    const uiSlots = loadUiSlots(exportRoot, uiDataFile);
    const pathInfo = inferAgentAndSlotFromPath(rel(exportRoot, filePath));

    agents.push({
      characterId: props.CharacterID,
      developerName: props.DeveloperName ?? pathInfo.agent,
      shippingName:
        displayValue(props.ShippingName) ??
        displayValue(props.DisplayName) ??
        props.DeveloperName ??
        pathInfo.agent,
      uuid: props.Uuid,
      role:
        normalizeGamePath(assetPathName(props.Role)) ??
        assetPathName(props.Role) ??
        null,
      primaryAssetPath: rel(exportRoot, filePath),
      primaryAssetGamePath: normalizeGamePath(
        `/Game/${rel(exportRoot, filePath)
          .replace(/^Content\//, '')
          .replace(/\.json$/i, '')}`,
      ),
      characterClass: normalizeGamePath(characterPath),
      characterFile: characterFile && fs.existsSync(characterFile)
        ? rel(exportRoot, characterFile)
        : null,
      uiData: normalizeGamePath(uiDataPathName),
      uiDataFile: uiDataFile && fs.existsSync(uiDataFile)
        ? rel(exportRoot, uiDataFile)
        : null,
      startingEquippableClasses,
      abilityClasses,
      uiSlots,
      components: Object.entries(characterProps)
        .filter(([, value]) => assetPathName(value))
        .map(([name, value]) => ({
          name,
          assetPath: normalizeGamePath(assetPathName(value)),
        }))
        .filter((entry) => entry.assetPath),
    });
  });

  agents.sort((a, b) => a.developerName.localeCompare(b.developerName));
  return agents;
}

function buildAbilityActorIndex(exportRoot, agents) {
  const characterRoot = path.join(exportRoot, 'Content', 'Characters');
  const records = [];
  const edges = [];
  const abilityToAgentSlot = new Map();

  for (const agent of agents) {
    for (const abilityPath of agent.abilityClasses) {
      abilityToAgentSlot.set(abilityPath, {
        agent: agent.developerName,
        characterId: agent.characterId,
        uuid: agent.uuid,
      });
    }
  }

  const interestingPrefix =
    /(^|\/)(Ability_|Projectile_|GameObject_|Patch_|AIPawn_|Pawn_|ForceModule_|DmgSource_|DmgType_|Buff_|FXC_|Comp_Ability|StateComponent|EquippablePickup|EquippableGroundPickup)/i;

  walkJsonFiles(characterRoot, (filePath) => {
    const relativePath = rel(exportRoot, filePath);
    const base = path.basename(filePath, '.json');
    if (!interestingPrefix.test(base) && !interestingPrefix.test(relativePath)) {
      return;
    }

    const text = readText(filePath);
    if (!text.trim().startsWith('[')) return;
    const data = readJson(filePath);
    if (!data) return;

    const first = firstObject(data);
    const def = defaultObject(data, path.basename(filePath, '.json'));
    const props = propsOf(def);
    const gamePath = normalizeGamePath(
      `/Game/${relativePath.replace(/^Content\//, '').replace(/\.json$/i, '')}`,
    );
    const kind = classifyName(base, gamePath);
    const pathInfo = inferAgentAndSlotFromPath(relativePath);
    const staticAgent =
      abilityToAgentSlot.get(gamePath) ??
      (pathInfo.agent
        ? { agent: pathInfo.agent, characterId: null, uuid: null }
        : null);
    const refs = collectAssetPathReferences(text)
      .filter((ref) => ref !== gamePath)
      .map((assetPath) => ({
        assetPath,
        kind: classifyName(assetPath, assetPath),
      }));
    const propertyRefs = collectPropertyReferenceContext(props)
      .filter((ref) => ref.assetPath !== gamePath)
      .slice(0, 400);
    const refCountsByKind = refs.reduce((acc, ref) => {
      acc[ref.kind] = (acc[ref.kind] ?? 0) + 1;
      return acc;
    }, {});

    const record = {
      assetPath: gamePath,
      file: relativePath,
      name: first?.Name ?? base,
      type: first?.Type ?? null,
      class: first?.Class ?? null,
      super:
        normalizeGamePath(assetPathName(first?.SuperStruct)) ??
        normalizeGamePath(assetPathName(first?.Super)) ??
        null,
      template:
        normalizeGamePath(assetPathName(first?.Template)) ??
        normalizeGamePath(assetPathName(first?.ObjectTemplate)) ??
        null,
      kind,
      inferredAgent: staticAgent?.agent ?? null,
      inferredCharacterId: staticAgent?.characterId ?? null,
      inferredAgentUuid: staticAgent?.uuid ?? null,
      inferredSlotFromPath: pathInfo.inferredSlot,
      rawEquippableSlot: unwrapEnum(props.EquippableSlot),
      inferredSlotFromEquippableSlot: normalizeAbilitySlot(props.EquippableSlot),
      propertyKeys: Object.keys(props).sort(),
      refCountsByKind,
      references: refs.slice(0, 300),
      propertyReferences: propertyRefs,
    };
    records.push(record);

    for (const ref of propertyRefs) {
      const targetKind = classifyName(ref.assetPath, ref.assetPath);
      if (
        kind === 'ability' &&
        [
          'projectile',
          'game_object',
          'patch',
          'deployable_pawn',
          'force_module',
          'damage_metadata',
          'buff',
          'ability_component',
          'state',
        ].includes(targetKind)
      ) {
        edges.push({
          source: gamePath,
          sourceKind: kind,
          target: ref.assetPath,
          targetKind,
          propertyPath: ref.propertyPath,
          inferredAgent: record.inferredAgent,
          inferredSlotFromPath: record.inferredSlotFromPath,
        });
      }
    }

    if (kind === 'ability') {
      for (const ref of refs) {
        if (
          ![
            'projectile',
            'game_object',
            'patch',
            'deployable_pawn',
            'force_module',
            'damage_metadata',
            'buff',
          ].includes(ref.kind)
        ) {
          continue;
        }
        edges.push({
          source: gamePath,
          sourceKind: kind,
          target: ref.assetPath,
          targetKind: ref.kind,
          propertyPath: 'textReference',
          inferredAgent: record.inferredAgent,
          inferredSlotFromPath: record.inferredSlotFromPath,
        });
      }
    }
  });

  records.sort((a, b) => a.assetPath.localeCompare(b.assetPath));
  edges.sort(
    (a, b) =>
      a.source.localeCompare(b.source) ||
      a.target.localeCompare(b.target) ||
      a.propertyPath.localeCompare(b.propertyPath),
  );

  return { records, edges };
}

function buildAbilityIdentityIndex(agents, records, edges) {
  const agentsByDeveloperName = new Map();
  const recordsByAssetPath = new Map(records.map((record) => [record.assetPath, record]));
  const primaryAbilityAssetPaths = new Set(
    agents.flatMap((agent) =>
      (agent.abilityClasses ?? []).filter(
        (abilityPath) =>
          /\/Ability_/i.test(abilityPath) &&
          !/\/Ability_Melee_Base$/i.test(abilityPath),
      ),
    ),
  );
  const abilityIdentityByAssetPath = new Map();
  const abilitySlotByAssetPathFromAgentOrder = new Map();
  const abilitySlotResolutionByAssetPath = new Map();

  function abilityDirectoryKey(assetPath) {
    return String(assetPath ?? '').match(
      /^(\/Game\/Characters\/[^/]+\/S\d+\/Ability_[^/]+)/i,
    )?.[1]?.toLowerCase() ?? null;
  }

  function inheritedAbilitySlot(record, visited = new Set()) {
    if (!record || visited.has(record.assetPath)) return null;
    visited.add(record.assetPath);

    if (record.inferredSlotFromEquippableSlot) {
      return record.inferredSlotFromEquippableSlot;
    }

    // Unreal omits properties that are inherited unchanged from a parent CDO.
    // Ability_Grenade_Base owns the Grenade slot default, so a child whose CDO
    // does not repeat EquippableSlot is still unambiguously the C ability.
    const hierarchyPaths = [record.template, record.super].filter(Boolean);
    if (hierarchyPaths.some((value) => /(?:^|\/)Ability_Grenade_Base$/i.test(value))) {
      return 'Grenade';
    }

    for (const hierarchyPath of hierarchyPaths) {
      const inherited = inheritedAbilitySlot(recordsByAssetPath.get(hierarchyPath), visited);
      if (inherited) return inherited;
    }
    return null;
  }

  function matchingUiIconSlot(agent, record) {
    const referencedAssets = new Set([
      ...(record.references ?? []).map((entry) => entry.assetPath),
      ...(record.propertyReferences ?? []).map((entry) => entry.assetPath),
    ]);
    if (referencedAssets.size === 0) return null;
    const matchingSlots = Object.values(agent.uiSlots ?? {})
      .filter((entry) => entry.icon && referencedAssets.has(entry.icon))
      .map((entry) => normalizeAbilitySlot(entry.rawSlot))
      .filter(Boolean);
    return new Set(matchingSlots).size === 1 ? matchingSlots[0] : null;
  }

  for (const agent of agents) {
    if (agent.developerName) {
      agentsByDeveloperName.set(agent.developerName.toLowerCase(), agent);
    }
    const orderedAbilities = (agent.abilityClasses ?? []).filter(
      (abilityPath) =>
        /\/Ability_/i.test(abilityPath) &&
        !/\/Ability_Melee_Base$/i.test(abilityPath),
    );
    const knownSlots = new Set();
    const missingAbilities = [];
    for (const abilityPath of orderedAbilities) {
      const record = recordsByAssetPath.get(abilityPath);
      const resolvedSlot =
        record?.inferredSlotFromEquippableSlot ??
        matchingUiIconSlot(agent, record ?? {}) ??
        inheritedAbilitySlot(record);
      if (resolvedSlot) {
        knownSlots.add(resolvedSlot);
        abilitySlotByAssetPathFromAgentOrder.set(abilityPath, resolvedSlot);
        abilitySlotResolutionByAssetPath.set(
          abilityPath,
          record?.inferredSlotFromEquippableSlot
            ? 'equippable-slot'
            : matchingUiIconSlot(agent, record ?? {})
              ? 'ui-icon-match'
              : 'inherited-equippable-slot',
        );
      } else {
        missingAbilities.push(abilityPath);
      }
    }
    const availableSlots = Object.values(agent.uiSlots ?? {})
      .map((slotEntry) => normalizeAbilitySlot(slotEntry.rawSlot))
      .filter((slot) => slot && slot !== 'Passive' && !knownSlots.has(slot));
    // A single remaining ability/slot pair is mathematically unambiguous.
    // Never zip two ordered lists here: StartingEquippableClasses and UIData
    // use different orders for agents such as Gekko and Vyse.
    if (missingAbilities.length === 1 && availableSlots.length === 1) {
      const abilityPath = missingAbilities[0];
      abilitySlotByAssetPathFromAgentOrder.set(abilityPath, availableSlots[0]);
      abilitySlotResolutionByAssetPath.set(abilityPath, 'remaining-unambiguous-slot');
    }
  }

  for (const record of records) {
    // Only character-primary equippables are identity roots. Many auxiliary
    // console/reactivation assets also inherit an EquippableSlot, but that
    // slot belongs to the temporary UI equippable rather than the character
    // ability (Clove's smoke and Pick-me-up consoles are concrete examples).
    // Those assets inherit identity from a proven primary via the spawn graph,
    // ability directory, or class hierarchy below.
    if (
      record.kind !== 'ability' ||
      !primaryAbilityAssetPaths.has(record.assetPath)
    ) {
      continue;
    }
    const agent = agentsByDeveloperName.get(record.inferredAgent?.toLowerCase());
    if (!agent) continue;
    const abilitySlot =
      record.inferredSlotFromEquippableSlot ??
      abilitySlotByAssetPathFromAgentOrder.get(record.assetPath);
    if (!abilitySlot) continue;
    const abilityIndex = abilityIndexForSlot(abilitySlot);
    const slotCatalog = Object.values(agent.uiSlots ?? {}).find(
      (slot) => normalizeAbilitySlot(slot.rawSlot) === abilitySlot,
    );
    abilityIdentityByAssetPath.set(record.assetPath, {
      agent: agent.shippingName,
      icarusAgentType: agent.shippingName?.toLowerCase().replace(/[^a-z0-9]+/g, '_') ?? null,
      agentDeveloperName: agent.developerName,
      agentUuid: agent.uuid,
      characterId: agent.characterId,
      abilitySlot,
      abilityIndex,
      abilityName: slotCatalog?.displayName ?? null,
      sourceAbilityAsset: record.assetPath,
      sourceAbilityClassName: classNameFromAssetPath(record.assetPath),
      sourceAbilityRawEquippableSlot: record.rawEquippableSlot ?? null,
      sourceAbilitySlotResolution:
        abilitySlotResolutionByAssetPath.get(record.assetPath) ??
        (record.inferredSlotFromEquippableSlot ? 'equippable-slot' : null),
      slotCatalogRawSlot: slotCatalog?.rawSlot ?? null,
      slotCatalogDisplayName: slotCatalog?.displayName ?? null,
      source: 'ability-asset',
      confidence: 'static-source-ability',
    });
  }

  const abilityIdentitiesByDirectory = new Map();
  for (const identity of abilityIdentityByAssetPath.values()) {
    const directoryKey = abilityDirectoryKey(identity.sourceAbilityAsset);
    if (!directoryKey) continue;
    if (!abilityIdentitiesByDirectory.has(directoryKey)) {
      abilityIdentitiesByDirectory.set(directoryKey, []);
    }
    abilityIdentitiesByDirectory.get(directoryKey).push(identity);
  }

  const classes = {};
  const assets = {};
  const ambiguousClassAliases = new Set();

  function identityKey(identity) {
    return [
      identity?.agent,
      identity?.abilitySlot,
      identity?.sourceAbilityAsset,
    ].join('|');
  }

  function shouldReplaceIdentity(existing, candidate, record) {
    if (!existing) return true;
    if (existing.staticAssetPath === candidate.staticAssetPath) {
      const inferredAgent = record.inferredAgent?.toLowerCase() ?? null;
      const existingMatchesAgent =
        inferredAgent != null &&
        existing.agentDeveloperName?.toLowerCase() === inferredAgent;
      const candidateMatchesAgent =
        inferredAgent != null &&
        candidate.agentDeveloperName?.toLowerCase() === inferredAgent;
      if (candidateMatchesAgent !== existingMatchesAgent) {
        return candidateMatchesAgent;
      }
      return false;
    }
    return existing.source !== 'spawn-graph' && candidate.source === 'spawn-graph';
  }

  function addIdentityForRecord(record, identity, source, confidence) {
    if (!record || !identity?.abilitySlot || !identity.agent) return;
    const classAliases = new Set();
    addClassAlias(classAliases, record.assetPath);
    addClassAlias(classAliases, record.name);
    addClassAlias(classAliases, record.type);
    addClassAlias(classAliases, record.class);
    addClassAlias(classAliases, record.template);

    const entry = {
      agent: identity.agent,
      icarusAgentType: identity.icarusAgentType,
      abilitySlot: identity.abilitySlot,
      abilityIndex: identity.abilityIndex,
      abilityName: identity.abilityName,
      sourceAbilityAsset: identity.sourceAbilityAsset,
      sourceAbilityClassName: identity.sourceAbilityClassName,
      sourceAbilityRawEquippableSlot: identity.sourceAbilityRawEquippableSlot,
      sourceAbilitySlotResolution: identity.sourceAbilitySlotResolution ?? null,
      agentDeveloperName: identity.agentDeveloperName,
      agentUuid: identity.agentUuid,
      characterId: identity.characterId,
      staticAssetPath: record.assetPath,
      staticAssetKind: record.kind,
      source,
      confidence,
    };

    if (shouldReplaceIdentity(assets[record.assetPath], entry, record)) {
      assets[record.assetPath] = entry;
    }
    for (const alias of classAliases) {
      if (!alias) continue;
      if (ambiguousClassAliases.has(alias)) continue;
      const existing = classes[alias];
      if (existing && identityKey(existing) !== identityKey(entry)) {
        delete classes[alias];
        ambiguousClassAliases.add(alias);
        continue;
      }
      if (shouldReplaceIdentity(existing, entry, record)) {
        classes[alias] = entry;
      }
    }
  }

  for (const record of records) {
    const directIdentity = abilityIdentityByAssetPath.get(record.assetPath);
    if (directIdentity) {
      addIdentityForRecord(record, directIdentity, 'direct-ability-asset', 'high');
    }
  }

  for (const edge of edges) {
    const identity = abilityIdentityByAssetPath.get(edge.source);
    const targetRecord = recordsByAssetPath.get(edge.target);
    if (!identity || !targetRecord) continue;
    addIdentityForRecord(targetRecord, identity, 'spawn-graph', 'high');
  }

  // Some lifecycle actors point back to their source ability instead of being
  // spawned through an exported ability reference. Gekko reclaim globules are
  // the important example: their CDO's "Reclaim Equippable" property is an
  // explicit, unambiguous source-ability edge.
  for (const record of records) {
    const reclaimAbilityPaths = (record.propertyReferences ?? [])
      .filter((reference) => /(?:^|\.)Reclaim Equippable$/i.test(reference.propertyPath ?? ''))
      .map((reference) => reference.assetPath);
    const identities = reclaimAbilityPaths
      .map((abilityPath) => abilityIdentityByAssetPath.get(abilityPath))
      .filter(Boolean);
    const uniqueIdentityKeys = new Set(
      identities.map(
        (identity) => `${identity.agent}|${identity.abilitySlot}|${identity.sourceAbilityAsset}`,
      ),
    );
    if (uniqueIdentityKeys.size === 1) {
      addIdentityForRecord(
        record,
        identities[0],
        'source-ability-property',
        'high',
      );
    }
  }


  // Cooked agent content is partitioned by one ability directory. When a
  // projectile/patch/placed actor has no direct export edge, a directory with
  // exactly one agent+slot identity still provides an unambiguous static join.
  // This recovers secondary grenades, landed patches, wall segments, and
  // tracking darts without replay-time name heuristics.
  for (const record of records) {
    if (assets[record.assetPath]) continue;
    const directoryKey = abilityDirectoryKey(record.assetPath);
    const candidates = directoryKey
      ? abilityIdentitiesByDirectory.get(directoryKey) ?? []
      : [];
    const uniqueSlotKeys = new Set(
      candidates.map((identity) => `${identity.agent}|${identity.abilitySlot}`),
    );
    if (uniqueSlotKeys.size !== 1) continue;
    const identity = [...candidates].sort((a, b) => {
      const penalty = (value) =>
        /Unpossess|Dart|Internal|Secondary|Passive/i.test(
          value.sourceAbilityAsset ?? '',
        )
          ? 1
          : 0;
      return (
        penalty(a) - penalty(b) ||
        String(a.sourceAbilityAsset).length - String(b.sourceAbilityAsset).length
      );
    })[0];
    if (identity) {
      addIdentityForRecord(record, identity, 'ability-directory', 'high');
    }
  }

  // Propagate a specific parent's proven identity to generated subclasses.
  // Do not propagate from generic shared parents with no identity.
  let inheritedIdentityAdded = true;
  while (inheritedIdentityAdded) {
    inheritedIdentityAdded = false;
    for (const record of records) {
      if (assets[record.assetPath]) continue;
      const inheritedEntries = [record.super, record.template]
        .filter(Boolean)
        .map((parentPath) => assets[parentPath])
        .filter(Boolean);
      const uniqueIdentityKeys = new Set(
        inheritedEntries.map(
          (identity) => `${identity.agent}|${identity.abilitySlot}|${identity.sourceAbilityAsset}`,
        ),
      );
      if (uniqueIdentityKeys.size !== 1) continue;
      addIdentityForRecord(
        record,
        inheritedEntries[0],
        'inherited-source-ability',
        'high',
      );
      inheritedIdentityAdded = true;
    }
  }

  for (const record of records) {
    if (assets[record.assetPath]) continue;
    const agent = agentsByDeveloperName.get(record.inferredAgent?.toLowerCase());
    const slot = record.inferredSlotFromEquippableSlot;
    if (!agent || !slot) continue;
    const abilityIndex = abilityIndexForSlot(slot);
    const slotCatalog = Object.values(agent.uiSlots ?? {}).find(
      (slotEntry) => normalizeAbilitySlot(slotEntry.rawSlot) === slot,
    );
    addIdentityForRecord(
      record,
      {
        agent: agent.shippingName,
        icarusAgentType: agent.shippingName?.toLowerCase().replace(/[^a-z0-9]+/g, '_') ?? null,
        agentDeveloperName: agent.developerName,
        agentUuid: agent.uuid,
        characterId: agent.characterId,
        abilitySlot: slot,
        abilityIndex,
        abilityName: slotCatalog?.displayName ?? null,
        sourceAbilityAsset: record.assetPath,
        sourceAbilityClassName: classNameFromAssetPath(record.assetPath),
        sourceAbilityRawEquippableSlot: record.rawEquippableSlot ?? null,
      },
      'direct-static-actor',
      'medium',
    );
  }

  return {
    generatedAt: new Date().toISOString(),
    count: Object.keys(classes).length,
    assetCount: Object.keys(assets).length,
    ambiguousClassAliasCount: ambiguousClassAliases.size,
    ambiguousClassAliases: [...ambiguousClassAliases].sort(),
    classes,
    assets,
  };
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function writeJsonl(filePath, values) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${values.map((value) => JSON.stringify(value)).join('\n')}\n`);
}

function writeCompactJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value)}\n`);
}

function writeRuntimeDecoderBundle(
  outDir,
  { agents, records, edges, abilityIdentityIndex, contentVersion },
) {
  const generatedAt = new Date().toISOString();
  const runtimeAgents = agents.map((agent) => ({
    characterId: agent.characterId ?? null,
    developerName: agent.developerName ?? null,
    shippingName: agent.shippingName ?? null,
    uuid: agent.uuid ?? null,
    // Keep the authoritative UIData slot catalog in the runtime bundle. This
    // lets replay casts resolve agent + EAresItemSlot without duplicating a
    // hand-maintained list in each decoder, and automatically covers agents
    // that were not present in the replay corpus used during development.
    abilities: Object.values(agent.uiSlots ?? {})
      .map((slot) => {
        const abilitySlot = normalizeAbilitySlot(slot.rawSlot);
        const sourceIdentity = Object.values(abilityIdentityIndex.assets ?? {}).find(
          (identity) =>
            identity?.agent === agent.shippingName &&
            identity?.abilitySlot === abilitySlot &&
            identity?.staticAssetKind === 'ability' &&
            identity?.source === 'direct-ability-asset',
        );
        return {
          abilitySlot,
          abilityIndex: abilityIndexForSlot(abilitySlot),
          abilityName: slot.displayName ?? null,
          rawSlot: slot.rawSlot ?? null,
          sourceAbilityAsset: sourceIdentity?.sourceAbilityAsset ?? null,
        };
      })
      .filter(
        (ability) =>
          ability.abilitySlot &&
          ability.abilitySlot !== 'Passive' &&
          Number.isInteger(ability.abilityIndex),
      )
      .sort((a, b) => a.abilityIndex - b.abilityIndex),
  }));
  const runtimeRecords = records.map((record) => ({
    assetPath: record.assetPath ?? null,
    name: record.name ?? null,
    type: record.type ?? null,
    class: record.class ?? null,
    kind: record.kind ?? null,
    inferredAgent: record.inferredAgent ?? null,
    inferredCharacterId: record.inferredCharacterId ?? null,
    inferredAgentUuid: record.inferredAgentUuid ?? null,
  }));
  const runtimeIdentity = {
    ...abilityIdentityIndex,
    generatedAt,
    contentVersion,
  };
  const summary = {
    schemaVersion: 1,
    generatedAt,
    contentVersion,
    agentCount: runtimeAgents.length,
    abilityActorCount: runtimeRecords.length,
    spawnGraphEdgeCount: edges.length,
    abilityIdentityClassCount: abilityIdentityIndex.count,
    abilityIdentityAssetCount: abilityIdentityIndex.assetCount,
    ambiguousClassAliasCount:
      abilityIdentityIndex.ambiguousClassAliasCount ?? 0,
  };

  writeCompactJson(path.join(outDir, 'agent_primary_index.json'), {
    ...summary,
    agents: runtimeAgents,
  });
  writeCompactJson(path.join(outDir, 'ability_actor_index.json'), {
    ...summary,
    records: runtimeRecords,
  });
  writeJsonl(path.join(outDir, 'ability_spawn_graph_edges.jsonl'), edges);
  writeCompactJson(path.join(outDir, 'ability_identity_index.json'), runtimeIdentity);
  writeJson(path.join(outDir, 'static_decoder_index_summary.json'), summary);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!fs.existsSync(args.exportRoot)) {
    throw new Error(`Export root does not exist: ${args.exportRoot}`);
  }

  const agents = buildAgentPrimaryIndex(args.exportRoot);
  const { records, edges } = buildAbilityActorIndex(args.exportRoot, agents);
  const abilityIdentityIndex = buildAbilityIdentityIndex(agents, records, edges);

  writeJson(path.join(args.outDir, 'agent_primary_index.json'), {
    generatedAt: new Date().toISOString(),
    exportRoot: args.exportRoot,
    count: agents.length,
    agents,
  });
  writeJson(path.join(args.outDir, 'ability_actor_index.json'), {
    generatedAt: new Date().toISOString(),
    exportRoot: args.exportRoot,
    count: records.length,
    countsByKind: records.reduce((acc, record) => {
      acc[record.kind] = (acc[record.kind] ?? 0) + 1;
      return acc;
    }, {}),
    records,
  });
  writeJsonl(path.join(args.outDir, 'ability_spawn_graph_edges.jsonl'), edges);
  writeJson(path.join(args.outDir, 'ability_identity_index.json'), abilityIdentityIndex);
  writeJson(path.join(args.outDir, 'static_decoder_index_summary.json'), {
    generatedAt: new Date().toISOString(),
    exportRoot: args.exportRoot,
    contentVersion: args.contentVersion,
    agentCount: agents.length,
    abilityActorCount: records.length,
    spawnGraphEdgeCount: edges.length,
    abilityIdentityClassCount: abilityIdentityIndex.count,
    abilityIdentityAssetCount: abilityIdentityIndex.assetCount,
    countsByKind: records.reduce((acc, record) => {
      acc[record.kind] = (acc[record.kind] ?? 0) + 1;
      return acc;
    }, {}),
  });
  if (args.runtimeOutDir) {
    writeRuntimeDecoderBundle(args.runtimeOutDir, {
      agents,
      records,
      edges,
      abilityIdentityIndex,
      contentVersion: args.contentVersion,
    });
  }

  console.log(
    JSON.stringify(
      {
        agentCount: agents.length,
        abilityActorCount: records.length,
        spawnGraphEdgeCount: edges.length,
        abilityIdentityClassCount: abilityIdentityIndex.count,
        abilityIdentityAssetCount: abilityIdentityIndex.assetCount,
        outDir: args.outDir,
        runtimeOutDir: args.runtimeOutDir,
      },
      null,
      2,
    ),
  );
}

main();
