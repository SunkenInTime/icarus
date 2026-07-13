#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const TOOL_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_AGENT_INDEX = path.join(
  TOOL_DIR,
  'static_decoder_indexes',
  'agent_primary_index.json',
);
const DEFAULT_IDENTITY_INDEX = path.join(
  TOOL_DIR,
  'static_decoder_indexes',
  'ability_identity_index.json',
);

function parseArgs(argv) {
  const options = {
    tracks: [],
    dirs: [],
    agentIndex: DEFAULT_AGENT_INDEX,
    identityIndex: DEFAULT_IDENTITY_INDEX,
    out: null,
    markdown: null,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--track') options.tracks.push(argv[++index]);
    else if (arg === '--dir') options.dirs.push(argv[++index]);
    else if (arg === '--agent-index') options.agentIndex = argv[++index];
    else if (arg === '--identity-index') options.identityIndex = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--markdown') options.markdown = argv[++index];
    else if (arg === '--help' || arg === '-h') options.help = true;
    else if (arg?.startsWith('-')) throw new Error(`Unknown argument: ${arg}`);
    else options.tracks.push(arg);
  }
  return options;
}

function usage() {
  return [
    'Usage: node audit_replay_ability_corpus.mjs --track <track.json> [...]',
    '       node audit_replay_ability_corpus.mjs --dir <track-directory>',
    '       [--out report.json] [--markdown report.md]',
  ].join('\n');
}

function resolveUserPath(value) {
  if (!value) return null;
  return path.isAbsolute(value)
    ? value
    : path.resolve(process.env.INIT_CWD ?? process.cwd(), value);
}

function walkTrackFiles(directory) {
  const result = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const filePath = path.join(directory, entry.name);
    if (entry.isDirectory()) result.push(...walkTrackFiles(filePath));
    else if (/\.native(?:_component)?\.track\.json$/i.test(entry.name)) {
      result.push(filePath);
    }
  }
  return result;
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function writeFile(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, value);
}

function normalizeAgent(value) {
  return String(value ?? '')
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]/g, '');
}

function canonicalAbilityId(agent, abilitySlot) {
  const agentKey = normalizeAgent(agent);
  const slotKey = String(abilitySlot ?? '').trim().toLowerCase();
  return agentKey && slotKey ? `valorant.${agentKey}.${slotKey}` : null;
}

function classNameFrom(value) {
  return String(value ?? '')
    .split('/')
    .at(-1)
    .split('.')
    .at(-1)
    .replace(/^Default__/, '')
    .replace(/_C$/, '');
}

function normalizedIdentityMap(identityIndex) {
  return new Map(
    Object.entries(identityIndex.classes ?? {}).map(([className, identity]) => [
      className.toLowerCase(),
      identity,
    ]),
  );
}

function sameAbilityName(actual, expected) {
  if (actual == null || expected == null) return actual === expected;
  if (String(actual).trim().toLowerCase() === String(expected).trim().toLowerCase()) {
    return true;
  }
  return (
    String(expected).trim().toLowerCase() === 'm-pulse' &&
    /^m-pulse (?:concuss|healing)$/i.test(String(actual).trim())
  );
}

function lifecycleBucket(actor) {
  if (actor.lifecycleEvidence) return actor.lifecycleEvidence;
  if (actor.observedEndMs != null || actor.closedAtMs != null) return 'observed';
  if (/^derived:/i.test(actor.durationSource ?? '')) return 'derived';
  if (
    actor.fallbackEndMs != null ||
    actor.fallbackLifetimeMs != null ||
    /fallback|wiki|default|kind-duration/i.test(actor.durationSource ?? '')
  ) {
    return 'fallback';
  }
  return 'absent';
}

function appFacingFallback(actor) {
  if (actor.observedEndMs != null || actor.closedAtMs != null) return false;
  if (/fallback|wiki|default|kind-duration/i.test(actor.durationSource ?? '')) {
    return true;
  }
  return (
    actor.fallbackEndMs != null &&
    actor.effectiveEndMs != null &&
    actor.fallbackEndMs === actor.effectiveEndMs
  );
}

function issue(issues, severity, code, trackFile, details) {
  issues.push({ severity, code, trackFile: path.basename(trackFile), ...details });
}

function auditTrack(trackFile, catalog, identityByClass) {
  const track = readJson(trackFile);
  const casts = Array.isArray(track.abilityCasts) ? track.abilityCasts : [];
  const actions = Array.isArray(track.abilityActions)
    ? track.abilityActions
    : [];
  const actors = Array.isArray(track.utilityActors) ? track.utilityActors : [];
  const candidates = Array.isArray(track.candidateUtilityActors)
    ? track.candidateUtilityActors
    : [];
  const inputEvents = Array.isArray(track.inputEvents) ? track.inputEvents : [];
  const ultimateEvents = Array.isArray(track.ultimateEvents)
    ? track.ultimateEvents
    : [];
  const abilityStateEvents = Array.isArray(track.abilityStateEvents)
    ? track.abilityStateEvents
    : [];
  const abilityRpcEvents = Array.isArray(track.abilityRpcEvents)
    ? track.abilityRpcEvents
    : [];
  const issues = [];
  const castSlots = new Set();
  const actorSlots = new Set();
  const inputAbilitySlots = new Set();
  const abilityStateSlots = new Set();
  const abilityStateNames = new Map();
  const abilityStatesBySlot = new Map();
  const abilityRpcSlots = new Set();
  const abilityRpcNames = new Map();
  const rosterAgents = new Set();
  const phases = new Map();
  const lifecycle = { observed: 0, derived: 0, fallback: 0, absent: 0 };
  let decodedEffectCount = 0;
  let placementCount = 0;
  let ownerObservedCount = 0;
  let ownerDerivedCount = 0;
  let candidateSourceCastLinkCount = 0;

  if ((track.abilitySchemaVersion ?? 0) < 2) {
    issue(issues, 'error', 'ability-schema-missing-or-legacy', trackFile, {
      abilitySchemaVersion: track.abilitySchemaVersion ?? null,
    });
  }
  for (const capability of [
    'characterAbilityCastInfo',
    'actorChannelOpenClose',
    'equippableStateTransitions',
    'abilityLifecycleRpcEvents',
    'canonicalAbilityActions',
  ]) {
    if (track.decoder?.abilityCapabilities?.[capability] !== true) {
      issue(issues, 'error', 'required-ability-capability-missing', trackFile, {
        capability,
      });
    }
  }
  const positionValidation = track.decoder?.positionValidation ?? null;
  if (positionValidation?.mode === 'disabled-diagnostic-only') {
    issue(issues, 'warning', 'position-validation-disabled-diagnostic-only', trackFile, {
      mapId: track.mapId ?? null,
      mapKey: positionValidation.mapKey ?? null,
    });
  } else if (positionValidation?.mode !== 'strict-map-bounds') {
    issue(issues, 'error', 'position-validation-provenance-missing', trackFile, {
      mode: positionValidation?.mode ?? null,
      mapId: track.mapId ?? null,
    });
  }

  for (const player of track.players ?? []) {
    if (player.agent) rosterAgents.add(normalizeAgent(player.agent));
  }

  for (const cast of casts) {
    const agentKey = normalizeAgent(cast.agent);
    if (!catalog.agentsByKey.has(agentKey) || !catalog.slots.has(cast.abilitySlot)) {
      issue(issues, 'error', 'cast-identity-missing', trackFile, {
        id: cast.id ?? null,
        agent: cast.agent ?? null,
        abilitySlot: cast.abilitySlot ?? null,
      });
    } else {
      castSlots.add(`${agentKey}|${cast.abilitySlot}`);
    }
    decodedEffectCount += Array.isArray(cast.effects) ? cast.effects.length : 0;
    placementCount += Array.isArray(cast.placementLocations)
      ? cast.placementLocations.length
      : 0;
    if (
      cast.displayLifetimeMs != null &&
      cast.endTimeMs == null &&
      /fallback|wiki|default|inferred/i.test(cast.displayLifetimeSource ?? '')
    ) {
      issue(issues, 'error', 'cast-overlay-inferred-end', trackFile, {
        id: cast.id ?? null,
        displayLifetimeMs: cast.displayLifetimeMs,
        displayLifetimeSource: cast.displayLifetimeSource ?? null,
      });
    }
  }

  const castById = new Map(casts.map((cast) => [cast.id, cast]));
  for (const actor of actors) {
    const className = actor.className ?? classNameFrom(actor.archetypePath);
    const identity = identityByClass.get(String(className).toLowerCase()) ?? null;
    const actualAgent = actor.agent ?? actor.agentShippingName ?? null;
    const actualSlot = actor.sourceAbilitySlot ?? actor.abilitySlot ?? null;
    if (!actor.ignoredAsAbility && (!actualAgent || !actualSlot)) {
      issue(issues, 'error', 'utility-identity-missing', trackFile, {
        id: actor.id ?? null,
        className,
        agent: actualAgent,
        abilitySlot: actualSlot,
      });
    }
    if (identity && !actor.ignoredAsAbility) {
      const mismatches = [];
      if (normalizeAgent(actualAgent) !== normalizeAgent(identity.agent)) {
        mismatches.push({ field: 'agent', actual: actualAgent, expected: identity.agent });
      }
      if (actualSlot !== identity.abilitySlot) {
        mismatches.push({ field: 'abilitySlot', actual: actualSlot, expected: identity.abilitySlot });
      }
      if (!sameAbilityName(actor.abilityName, identity.abilityName)) {
        mismatches.push({ field: 'abilityName', actual: actor.abilityName, expected: identity.abilityName });
      }
      if (mismatches.length) {
        issue(issues, 'error', 'utility-static-identity-mismatch', trackFile, {
          id: actor.id ?? null,
          className,
          mismatches,
        });
      }
    }
    if (actor.ignoredAsAbility) continue;
    if (actualAgent && actualSlot) {
      const slotKey = `${normalizeAgent(actualAgent)}|${actualSlot}`;
      actorSlots.add(slotKey);
      if (!phases.has(slotKey)) phases.set(slotKey, new Set());
      phases.get(slotKey).add(actor.phase ?? actor.contentKind ?? 'unknown');
    }
    const bucket = lifecycleBucket(actor);
    lifecycle[bucket] = (lifecycle[bucket] ?? 0) + 1;
    if (appFacingFallback(actor)) {
      issue(issues, 'error', 'utility-app-facing-fallback-end', trackFile, {
        id: actor.id ?? null,
        className,
        effectiveEndMs: actor.effectiveEndMs ?? null,
        fallbackEndMs: actor.fallbackEndMs ?? null,
        durationSource: actor.durationSource ?? null,
      });
    }
    if (actor.observedStartMs == null) {
      issue(issues, 'error', 'utility-observed-start-missing', trackFile, {
        id: actor.id ?? null,
        className,
      });
    }
    if (/inferred-component|nearest-cast/i.test(actor.confidence ?? actor.sourceTag ?? '')) {
      issue(issues, 'error', 'inferred-motion-promoted-to-utility', trackFile, {
        id: actor.id ?? null,
        className,
        confidence: actor.confidence ?? null,
      });
    }
    if (actor.ownerSource === 'actor-channel-owner-netguid') ownerObservedCount += 1;
    else if (actor.ownerId || actor.ownerPlayerNetGuid) ownerDerivedCount += 1;
    if (actor.candidateSourceCastId) candidateSourceCastLinkCount += 1;

    if (
      actor.sourceCastId &&
      actor.sourceCastLinkConfidence !== 'derived-replay-netguid-and-time'
    ) {
      issue(issues, 'error', 'weak-cast-link-promoted-to-causal', trackFile, {
        actorId: actor.id ?? null,
        castId: actor.sourceCastId,
        linkEvidence: actor.sourceCastLinkEvidence ?? null,
        linkConfidence: actor.sourceCastLinkConfidence ?? null,
      });
    }

    const sourceCast = actor.sourceCastId ? castById.get(actor.sourceCastId) : null;
    if (sourceCast) {
      if (
        normalizeAgent(actualAgent) !== normalizeAgent(sourceCast.agent) ||
        (actualSlot && sourceCast.abilitySlot && actualSlot !== sourceCast.abilitySlot)
      ) {
        issue(issues, 'error', 'cast-actor-link-identity-mismatch', trackFile, {
          actorId: actor.id ?? null,
          castId: sourceCast.id ?? null,
          actorAgent: actualAgent,
          actorSlot: actualSlot,
          castAgent: sourceCast.agent ?? null,
          castSlot: sourceCast.abilitySlot ?? null,
        });
      }
    }
  }

  for (const action of actions) {
    if (!action.canonicalAbilityId || !action.agent || !action.abilitySlot) {
      issue(issues, 'error', 'canonical-action-identity-missing', trackFile, {
        id: action.id ?? null,
        canonicalAbilityId: action.canonicalAbilityId ?? null,
        agent: action.agent ?? null,
        abilitySlot: action.abilitySlot ?? null,
      });
    }
    if (!Array.isArray(action.phases) || action.phases.length === 0) {
      issue(issues, 'error', 'canonical-action-has-no-phases', trackFile, {
        id: action.id ?? null,
      });
      continue;
    }
    for (const phase of action.phases) {
      if (!['observed', 'derived', 'absent'].includes(phase.evidence)) {
        issue(issues, 'error', 'canonical-phase-invalid-evidence', trackFile, {
          id: action.id ?? null,
          phaseId: phase.id ?? null,
          evidence: phase.evidence ?? null,
        });
      }
      if (phase.evidence === 'fallback') {
        issue(issues, 'error', 'canonical-phase-fallback', trackFile, {
          id: action.id ?? null,
          phaseId: phase.id ?? null,
        });
      }
      if (
        String(phase.type ?? '').startsWith('state-') &&
        (!phase.stateName ||
          !phase.statePath ||
          !Number.isInteger(phase.stateNetGuid))
      ) {
        issue(issues, 'error', 'canonical-state-phase-invalid', trackFile, {
          id: action.id ?? null,
          phaseId: phase.id ?? null,
          stateName: phase.stateName ?? null,
          statePath: phase.statePath ?? null,
          stateNetGuid: phase.stateNetGuid ?? null,
        });
      }
      if (
        String(phase.type ?? '').startsWith('rpc-') &&
        (!phase.rpcName || !Number.isInteger(phase.actorNetGuid))
      ) {
        issue(issues, 'error', 'canonical-rpc-phase-invalid', trackFile, {
          id: action.id ?? null,
          phaseId: phase.id ?? null,
          rpcName: phase.rpcName ?? null,
          actorNetGuid: phase.actorNetGuid ?? null,
        });
      }
    }
    if (
      (action.sourceStateEventIds ?? []).length > 0 &&
      !action.phases.some((phase) => phase.terminal === true) &&
      action.rightCensored !== true
    ) {
      issue(issues, 'error', 'open-state-action-not-censored', trackFile, {
        id: action.id ?? null,
      });
    }
  }

  for (const event of inputEvents) {
    if (event.playerLoadoutIndex == null || !event.playerSubject || !event.agent) {
      issue(issues, 'warning', 'input-player-unmapped', trackFile, {
        id: event.id ?? null,
        playerReplayId: event.playerReplayId ?? null,
      });
    }
    if (event.canonicalAbilityId) {
      const expectedCanonicalId = canonicalAbilityId(event.agent, event.abilitySlot);
      if (
        event.eventType !== 'EquippableChange' ||
        !event.equippableNetGuid ||
        !event.abilitySlot ||
        event.canonicalAbilityId !== expectedCanonicalId
      ) {
        issue(issues, 'error', 'input-ability-identity-invalid', trackFile, {
          id: event.id ?? null,
          eventType: event.eventType ?? null,
          equippableNetGuid: event.equippableNetGuid ?? null,
          canonicalAbilityId: event.canonicalAbilityId,
          expectedCanonicalId,
        });
      } else {
        inputAbilitySlots.add(`${normalizeAgent(event.agent)}|${event.abilitySlot}`);
      }
    }
  }

  for (const event of abilityStateEvents) {
    const expectedCanonicalId = canonicalAbilityId(event.agent, event.abilitySlot);
    if (
      !Number.isInteger(event.equippableNetGuid) ||
      !Number.isInteger(event.stateNetGuid) ||
      !event.statePath ||
      !event.stateName ||
      event.evidence !== 'observed' ||
      event.canonicalAbilityId !== expectedCanonicalId
    ) {
      issue(issues, 'error', 'ability-state-event-invalid', trackFile, {
        id: event.id ?? null,
        equippableNetGuid: event.equippableNetGuid ?? null,
        stateNetGuid: event.stateNetGuid ?? null,
        statePath: event.statePath ?? null,
        evidence: event.evidence ?? null,
        canonicalAbilityId: event.canonicalAbilityId ?? null,
        expectedCanonicalId,
      });
      continue;
    }
    if (
      catalog.slots.has(event.abilitySlot) &&
      !event.initialReplication &&
      !/^InactiveState$/i.test(event.stateName)
    ) {
      const slotKey = `${normalizeAgent(event.agent)}|${event.abilitySlot}`;
      abilityStateSlots.add(slotKey);
      if (!abilityStatesBySlot.has(slotKey)) abilityStatesBySlot.set(slotKey, new Set());
      abilityStatesBySlot.get(slotKey).add(event.stateName);
    }
    abilityStateNames.set(
      event.stateName,
      (abilityStateNames.get(event.stateName) ?? 0) + 1,
    );
  }

  for (const event of abilityRpcEvents) {
    const expectedCanonicalId = canonicalAbilityId(event.agent, event.abilitySlot);
    if (
      !event.rpcName ||
      !event.phaseType ||
      event.evidence !== 'observed' ||
      event.canonicalAbilityId !== expectedCanonicalId
    ) {
      issue(issues, 'error', 'ability-rpc-event-invalid', trackFile, {
        id: event.id ?? null,
        rpcName: event.rpcName ?? null,
        phaseType: event.phaseType ?? null,
        evidence: event.evidence ?? null,
        canonicalAbilityId: event.canonicalAbilityId ?? null,
        expectedCanonicalId,
      });
      continue;
    }
    if (catalog.slots.has(event.abilitySlot)) {
      abilityRpcSlots.add(`${normalizeAgent(event.agent)}|${event.abilitySlot}`);
    }
    abilityRpcNames.set(
      event.rpcName,
      (abilityRpcNames.get(event.rpcName) ?? 0) + 1,
    );
  }

  const inputSummary = track.decoder?.inputEventSummary ?? null;
  if ((inputSummary?.overflowCount ?? 0) > 0) {
    issue(issues, 'warning', 'input-event-lane-capped', trackFile, {
      overflowCount: inputSummary.overflowCount,
      sampleLimit: inputSummary.sampleLimit ?? null,
    });
  }
  const abilitySignalCapture = track.decoder?.abilitySignalCapture ?? null;
  if (
    (abilitySignalCapture?.overflowCount ?? 0) > 0 ||
    (abilitySignalCapture?.overflowCount == null &&
      Number.isFinite(abilitySignalCapture?.sampleLimit) &&
      abilitySignalCapture.count >= abilitySignalCapture.sampleLimit)
  ) {
    issue(issues, 'error', 'ability-signal-lane-capped', trackFile, {
      count: abilitySignalCapture?.count ?? null,
      overflowCount: abilitySignalCapture?.overflowCount ?? null,
      sampleLimit: abilitySignalCapture?.sampleLimit ?? null,
    });
  }
  const indexVersion = track.decoder?.staticDecoderIndex?.contentVersion ?? null;
  if (indexVersion && /release-13\.00/i.test(track.decoder?.branch ?? '') && indexVersion !== '13.00') {
    issue(issues, 'warning', 'static-index-version-mismatch', trackFile, {
      replayBranch: track.decoder.branch,
      staticContentVersion: indexVersion,
    });
  }

  const summary = {
    file: trackFile,
    sourceLabel: track.sourceLabel ?? null,
    mapId: track.mapId ?? null,
    positionValidation,
    durationMs: track.durationMs ?? null,
    playerCount: Array.isArray(track.players) ? track.players.length : 0,
    rosterAgents: [...rosterAgents].sort(),
    castCount: casts.length,
    abilityActionCount: actions.length,
    abilityStateActionCount: actions.filter(
      (action) => (action.sourceStateEventIds ?? []).length > 0,
    ).length,
    abilityStateActionTermination: Object.entries(
      actions
        .filter((action) => (action.sourceStateEventIds ?? []).length > 0)
        .reduce((counts, action) => {
          const key = action.terminationStatus ?? 'unknown';
          counts[key] = (counts[key] ?? 0) + 1;
          return counts;
        }, {}),
    )
      .map(([key, count]) => ({ key, count }))
      .sort((a, b) => b.count - a.count),
    abilityActionTermination: Object.entries(
      actions.reduce((counts, action) => {
        const key = action.terminationStatus ?? 'unknown';
        counts[key] = (counts[key] ?? 0) + 1;
        return counts;
      }, {}),
    )
      .map(([key, count]) => ({ key, count }))
      .sort((a, b) => b.count - a.count),
    castSlots: [...castSlots].sort(),
    decodedEffectCount,
    placementCount,
    utilityActorCount: actors.filter((actor) => !actor.ignoredAsAbility).length,
    ignoredUtilityActorCount: actors.filter((actor) => actor.ignoredAsAbility).length,
    utilityActorSlots: [...actorSlots].sort(),
    inputAbilitySlots: [...inputAbilitySlots].sort(),
    abilityStateSlots: [...abilityStateSlots].sort(),
    abilityRpcSlots: [...abilityRpcSlots].sort(),
    candidateUtilityActorCount: candidates.length,
    lifecycle,
    ownerObservedCount,
    ownerDerivedCount,
    candidateSourceCastLinkCount,
    abilitySignalCapture,
    inputEventCount: inputEvents.length,
    abilityStateEventCount: abilityStateEvents.length,
    activeAbilityStateEventCount: abilityStateEvents.filter(
      (event) =>
        !event.initialReplication &&
        !/^InactiveState$/i.test(event.stateName ?? ''),
    ).length,
    ownedAbilityStateEventCount: abilityStateEvents.filter(
      (event) => event.ownerSubject || event.ownerPlayerNetGuid,
    ).length,
    abilityRpcEventCount: abilityRpcEvents.length,
    abilityRpcNames: [...abilityRpcNames.entries()]
      .map(([key, count]) => ({ key, count }))
      .sort((a, b) => b.count - a.count || a.key.localeCompare(b.key)),
    abilityStateNames: [...abilityStateNames.entries()]
      .map(([key, count]) => ({ key, count }))
      .sort((a, b) => b.count - a.count || a.key.localeCompare(b.key)),
    abilityStatesBySlot: Object.fromEntries(
      [...abilityStatesBySlot.entries()].map(([key, values]) => [
        key,
        [...values].sort(),
      ]),
    ),
    inputEventTypes: Object.entries(
      inputEvents.reduce((counts, event) => {
        counts[event.eventType ?? 'Unknown'] =
          (counts[event.eventType ?? 'Unknown'] ?? 0) + 1;
        return counts;
      }, {}),
    )
      .map(([key, count]) => ({ key, count }))
      .sort((a, b) => b.count - a.count),
    ultimateEventCount: ultimateEvents.length,
    phases: Object.fromEntries(
      [...phases.entries()].map(([key, values]) => [key, [...values].sort()]),
    ),
    issues,
  };
  return summary;
}

function buildCatalog(agentIndex) {
  const agents = (agentIndex.agents ?? []).filter((agent) => agent.shippingName);
  const agentsByKey = new Map(
    agents.map((agent) => [normalizeAgent(agent.shippingName), agent]),
  );
  const slots = new Set(['Grenade', 'Ability1', 'Ability2', 'Ultimate']);
  const expectedSlots = new Set();
  for (const agent of agents) {
    for (const ability of agent.abilities ?? []) {
      if (slots.has(ability.abilitySlot)) {
        expectedSlots.add(`${normalizeAgent(agent.shippingName)}|${ability.abilitySlot}`);
      }
    }
  }
  return { agents, agentsByKey, slots, expectedSlots };
}

function corpusReport(trackSummaries, catalog, identityIndex, trackFiles) {
  const catalogSlots = (values) =>
    new Set(values.filter((slotKey) => catalog.expectedSlots.has(slotKey)));
  const rawCastSlots = new Set(
    trackSummaries.flatMap((track) => track.castSlots),
  );
  const rawActorSlots = new Set(
    trackSummaries.flatMap((track) => track.utilityActorSlots),
  );
  const rawInputAbilitySlots = new Set(
    trackSummaries.flatMap((track) => track.inputAbilitySlots),
  );
  const rawAbilityStateSlots = new Set(
    trackSummaries.flatMap((track) => track.abilityStateSlots),
  );
  const rawAbilityRpcSlots = new Set(
    trackSummaries.flatMap((track) => track.abilityRpcSlots),
  );
  const castSlots = catalogSlots([...rawCastSlots]);
  const actorSlots = catalogSlots([...rawActorSlots]);
  const inputAbilitySlots = catalogSlots([...rawInputAbilitySlots]);
  const abilityStateSlots = catalogSlots([...rawAbilityStateSlots]);
  const abilityRpcSlots = catalogSlots([...rawAbilityRpcSlots]);
  const nonCatalogObservedSlots = new Set(
    [
      ...rawCastSlots,
      ...rawActorSlots,
      ...rawInputAbilitySlots,
      ...rawAbilityStateSlots,
      ...rawAbilityRpcSlots,
    ].filter((slotKey) => !catalog.expectedSlots.has(slotKey)),
  );
  const observedEvidenceSlots = new Set([
    ...castSlots,
    ...actorSlots,
    ...inputAbilitySlots,
    ...abilityStateSlots,
    ...abilityRpcSlots,
  ]);
  const rosterAgents = new Set(
    trackSummaries.flatMap((track) => track.rosterAgents),
  );
  const issues = trackSummaries.flatMap((track) => track.issues);
  const errors = issues.filter((entry) => entry.severity === 'error');
  const warnings = issues.filter((entry) => entry.severity === 'warning');
  const abilityStateNameCounts = new Map();
  const abilityRpcNameCounts = new Map();
  for (const track of trackSummaries) {
    for (const entry of track.abilityStateNames ?? []) {
      abilityStateNameCounts.set(
        entry.key,
        (abilityStateNameCounts.get(entry.key) ?? 0) + entry.count,
      );
    }
    for (const entry of track.abilityRpcNames ?? []) {
      abilityRpcNameCounts.set(
        entry.key,
        (abilityRpcNameCounts.get(entry.key) ?? 0) + entry.count,
      );
    }
  }
  const agentCoverage = catalog.agents.map((agent) => {
    const agentKey = normalizeAgent(agent.shippingName);
    const abilities = (agent.abilities ?? []).filter((ability) =>
      catalog.slots.has(ability.abilitySlot),
    );
    return {
      agent: agent.shippingName,
      presentInRoster: rosterAgents.has(agentKey),
      castSlots: abilities
        .filter((ability) => castSlots.has(`${agentKey}|${ability.abilitySlot}`))
        .map((ability) => ability.abilitySlot),
      actorSlots: abilities
        .filter((ability) => actorSlots.has(`${agentKey}|${ability.abilitySlot}`))
        .map((ability) => ability.abilitySlot),
      inputAbilitySlots: abilities
        .filter((ability) =>
          inputAbilitySlots.has(`${agentKey}|${ability.abilitySlot}`),
        )
        .map((ability) => ability.abilitySlot),
      abilityStateSlots: abilities
        .filter((ability) =>
          abilityStateSlots.has(`${agentKey}|${ability.abilitySlot}`),
        )
        .map((ability) => ability.abilitySlot),
      abilityRpcSlots: abilities
        .filter((ability) =>
          abilityRpcSlots.has(`${agentKey}|${ability.abilitySlot}`),
        )
        .map((ability) => ability.abilitySlot),
      observedEvidenceSlots: abilities
        .filter((ability) =>
          observedEvidenceSlots.has(`${agentKey}|${ability.abilitySlot}`),
        )
        .map((ability) => ability.abilitySlot),
      missingCastSlots: abilities
        .filter((ability) => !castSlots.has(`${agentKey}|${ability.abilitySlot}`))
        .map((ability) => ability.abilitySlot),
    };
  });
  const lifecycle = trackSummaries.reduce(
    (sum, track) => {
      for (const key of Object.keys(sum)) sum[key] += track.lifecycle[key] ?? 0;
      return sum;
    },
    { observed: 0, derived: 0, fallback: 0, absent: 0 },
  );
  return {
    generatedAt: new Date().toISOString(),
    status: errors.length === 0 ? 'pass' : 'fail',
    trackCount: trackSummaries.length,
    trackFiles,
    staticCatalog: {
      agentCount: catalog.agents.length,
      expectedSlotCount: catalog.expectedSlots.size,
      identityClassCount: identityIndex.count ?? Object.keys(identityIndex.classes ?? {}).length,
      identityAssetCount: identityIndex.assetCount ?? Object.keys(identityIndex.assets ?? {}).length,
      ambiguousClassAliasCount: identityIndex.ambiguousClassAliasCount ?? null,
      contentVersion: identityIndex.contentVersion ?? null,
    },
    coverage: {
      rosterAgentCount: rosterAgents.size,
      castSlotCount: castSlots.size,
      actorSlotCount: actorSlots.size,
      inputAbilitySlotCount: inputAbilitySlots.size,
      abilityStateSlotCount: abilityStateSlots.size,
      abilityRpcSlotCount: abilityRpcSlots.size,
      abilityStateNameCount: abilityStateNameCounts.size,
      abilityRpcNameCount: abilityRpcNameCounts.size,
      observedEvidenceSlotCount: observedEvidenceSlots.size,
      nonCatalogObservedSlotCount: nonCatalogObservedSlots.size,
      missingCastSlotCount: Math.max(0, catalog.expectedSlots.size - castSlots.size),
      castCount: trackSummaries.reduce((sum, track) => sum + track.castCount, 0),
      abilityActionCount: trackSummaries.reduce(
        (sum, track) => sum + track.abilityActionCount,
        0,
      ),
      abilityStateActionCount: trackSummaries.reduce(
        (sum, track) => sum + track.abilityStateActionCount,
        0,
      ),
      utilityActorCount: trackSummaries.reduce(
        (sum, track) => sum + track.utilityActorCount,
        0,
      ),
      ignoredUtilityActorCount: trackSummaries.reduce(
        (sum, track) => sum + track.ignoredUtilityActorCount,
        0,
      ),
      candidateUtilityActorCount: trackSummaries.reduce(
        (sum, track) => sum + track.candidateUtilityActorCount,
        0,
      ),
      decodedEffectCount: trackSummaries.reduce(
        (sum, track) => sum + track.decodedEffectCount,
        0,
      ),
      placementCount: trackSummaries.reduce(
        (sum, track) => sum + track.placementCount,
        0,
      ),
      inputEventCount: trackSummaries.reduce(
        (sum, track) => sum + track.inputEventCount,
        0,
      ),
      abilityStateEventCount: trackSummaries.reduce(
        (sum, track) => sum + track.abilityStateEventCount,
        0,
      ),
      activeAbilityStateEventCount: trackSummaries.reduce(
        (sum, track) => sum + track.activeAbilityStateEventCount,
        0,
      ),
      ownedAbilityStateEventCount: trackSummaries.reduce(
        (sum, track) => sum + track.ownedAbilityStateEventCount,
        0,
      ),
      abilityRpcEventCount: trackSummaries.reduce(
        (sum, track) => sum + track.abilityRpcEventCount,
        0,
      ),
      ultimateEventCount: trackSummaries.reduce(
        (sum, track) => sum + track.ultimateEventCount,
        0,
      ),
      lifecycle,
      diagnosticOffMapTrackCount: trackSummaries.filter(
        (track) => track.positionValidation?.mode === 'disabled-diagnostic-only',
      ).length,
    },
    agentCoverage,
    abilityStateNames: [...abilityStateNameCounts.entries()]
      .map(([key, count]) => ({ key, count }))
      .sort((a, b) => b.count - a.count || a.key.localeCompare(b.key)),
    abilityRpcNames: [...abilityRpcNameCounts.entries()]
      .map(([key, count]) => ({ key, count }))
      .sort((a, b) => b.count - a.count || a.key.localeCompare(b.key)),
    nonCatalogObservedSlots: [...nonCatalogObservedSlots].sort(),
    issueCount: issues.length,
    errorCount: errors.length,
    warningCount: warnings.length,
    issues,
    tracks: trackSummaries,
  };
}

function markdownReport(report) {
  const lines = [
    '# Valorant replay ability corpus audit',
    '',
    `Status: **${report.status.toUpperCase()}** — ${report.errorCount} errors, ${report.warningCount} warnings across ${report.trackCount} tracks.`,
    '',
    `Observed ${report.coverage.castSlotCount}/${report.staticCatalog.expectedSlotCount} cast slots, ${report.coverage.actorSlotCount}/${report.staticCatalog.expectedSlotCount} actor-phase slots, ${report.coverage.inputAbilitySlotCount}/${report.staticCatalog.expectedSlotCount} exact input/equip slots, ${report.coverage.abilityStateSlotCount}/${report.staticCatalog.expectedSlotCount} active state-machine slots, and ${report.coverage.abilityRpcSlotCount}/${report.staticCatalog.expectedSlotCount} named ability-RPC slots across ${report.coverage.rosterAgentCount}/${report.staticCatalog.agentCount} roster agents.`,
    '',
    `Lifecycle endings: ${report.coverage.lifecycle.observed} observed, ${report.coverage.lifecycle.derived} derived, ${report.coverage.lifecycle.fallback} fallback, ${report.coverage.lifecycle.absent} absent.`,
    `Diagnostic tracks with map-position validation disabled: ${report.coverage.diagnosticOffMapTrackCount}.`,
    `Observed non-catalog slots (excluded from the 116-slot denominator): ${report.nonCatalogObservedSlots.join(', ') || 'none'}.`,
    '',
    '| Agent | Roster | Cast slots | Actor slots | Exact equip slots | Active state slots | RPC slots | Missing cast slots |',
    '| --- | --- | --- | --- | --- | --- | --- | --- |',
  ];
  for (const agent of report.agentCoverage) {
    lines.push(
      `| ${agent.agent} | ${agent.presentInRoster ? 'yes' : 'no'} | ${agent.castSlots.join(', ') || '—'} | ${agent.actorSlots.join(', ') || '—'} | ${agent.inputAbilitySlots.join(', ') || '—'} | ${agent.abilityStateSlots.join(', ') || '—'} | ${agent.abilityRpcSlots.join(', ') || '—'} | ${agent.missingCastSlots.join(', ') || '—'} |`,
    );
  }
  lines.push('', '## Findings', '');
  if (report.issues.length === 0) lines.push('No audit violations.');
  else {
    for (const finding of report.issues.slice(0, 500)) {
      lines.push(
        `- **${finding.severity} / ${finding.code}** (${finding.trackFile})${finding.id ? `: ${finding.id}` : ''}`,
      );
    }
    if (report.issues.length > 500) {
      lines.push(`- … ${report.issues.length - 500} additional findings are in the JSON report.`);
    }
  }
  lines.push('');
  return `${lines.join('\n')}\n`;
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    console.log(usage());
    return;
  }
  const trackFiles = [
    ...options.tracks.map(resolveUserPath),
    ...options.dirs.flatMap((directory) => walkTrackFiles(resolveUserPath(directory))),
  ];
  const uniqueTrackFiles = [...new Set(trackFiles)].sort();
  if (uniqueTrackFiles.length === 0) throw new Error('At least one --track or --dir is required.');
  for (const trackFile of uniqueTrackFiles) {
    if (!fs.existsSync(trackFile)) throw new Error(`Track does not exist: ${trackFile}`);
  }
  const agentIndex = readJson(resolveUserPath(options.agentIndex));
  const identityIndex = readJson(resolveUserPath(options.identityIndex));
  const catalog = buildCatalog(agentIndex);
  const identityByClass = normalizedIdentityMap(identityIndex);
  const tracks = uniqueTrackFiles.map((trackFile) =>
    auditTrack(trackFile, catalog, identityByClass),
  );
  const report = corpusReport(tracks, catalog, identityIndex, uniqueTrackFiles);
  const json = `${JSON.stringify(report, null, 2)}\n`;
  if (options.out) writeFile(resolveUserPath(options.out), json);
  if (options.markdown) {
    writeFile(resolveUserPath(options.markdown), markdownReport(report));
  }
  process.stdout.write(json);
  if (report.errorCount > 0) process.exitCode = 1;
}

main();
