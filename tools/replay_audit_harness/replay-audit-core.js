import { AGENTS, MAPS, RIOT_MAP_IDS } from './catalog.generated.js';

export const WORLD_HEIGHT = 1000;
export const WORLD_WIDTH = WORLD_HEIGHT * (16 / 9);
export const MAP_WIDTH = WORLD_HEIGHT * 1.24;
export const MAP_PADDING_X = (WORLD_WIDTH - MAP_WIDTH) / 2;
export const MAX_PLAYER_INTERPOLATION_GAP_MS = 250;
export const MAX_UTILITY_INTERPOLATION_GAP_MS = 1200;

const clamp = (value, min, max) => Math.min(max, Math.max(min, value));
const number = (value, fallback = 0) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
};

export function mapKeyFromTrack(track) {
  const candidate = String(track?.mapId ?? track?.mapName ?? track?.map ?? '').trim();
  if (RIOT_MAP_IDS[candidate]) return RIOT_MAP_IDS[candidate];
  const normalized = candidate.toLowerCase();
  return Object.keys(MAPS).find((key) => key === normalized || MAPS[key].name === normalized) ?? null;
}

export function rotateUvCw(u, v, turns) {
  const normalized = ((turns % 4) + 4) % 4;
  if (normalized === 0) return { u, v };
  if (normalized === 1) return { u: 1 - v, v: u };
  if (normalized === 2) return { u: 1 - u, v: 1 - v };
  return { u: v, v: 1 - u };
}

export function percentToWorld(u, v) {
  return {
    x: MAP_PADDING_X + clamp(number(u), 0, 1) * MAP_WIDTH,
    y: clamp(number(v), 0, 1) * WORLD_HEIGHT,
  };
}

export function paddedPercentToWorld(mapKey, u, v) {
  const map = MAPS[mapKey];
  if (!map?.viewBox || !map?.padding) return percentToWorld(u, v);
  const { width, height } = map.viewBox;
  const { left, top, right, bottom } = map.padding;
  const paddedWidth = width + left + right;
  const paddedHeight = height + top + bottom;
  const svgX = clamp(number(u) * paddedWidth - left, 0, width);
  const svgY = clamp(number(v) * paddedHeight - top, 0, height);
  const scale = Math.min(MAP_WIDTH / width, WORLD_HEIGHT / height);
  const renderedWidth = width * scale;
  const renderedHeight = height * scale;
  return {
    x: MAP_PADDING_X + (MAP_WIDTH - renderedWidth) / 2 + svgX * scale,
    y: (WORLD_HEIGHT - renderedHeight) / 2 + svgY * scale,
  };
}

export function gameToWorld(mapKey, gameX, gameY) {
  const map = MAPS[mapKey];
  if (!map?.transform) return { x: number(gameX), y: number(gameY) };
  const transform = map.transform;
  const rawU = number(gameY) * transform.xMultiplier + transform.xScalarToAdd;
  const rawV = number(gameX) * transform.yMultiplier + transform.yScalarToAdd;
  const rotated = rotateUvCw(rawU, rawV, map.importCwQuarterTurns ?? 0);
  return paddedPercentToWorld(mapKey, rotated.u, rotated.v);
}

export function replayPositionToWorld(track, position) {
  const coordinateSpace = String(track?.coordinateSpace ?? 'game').toLowerCase();
  if (coordinateSpace === 'percent') return percentToWorld(position?.x, position?.y);
  if (coordinateSpace === 'icarus') return { x: number(position?.x), y: number(position?.y) };
  return gameToWorld(mapKeyFromTrack(track), position?.x, position?.y);
}

export function worldToPercent(position) {
  return {
    left: (number(position?.x) / WORLD_WIDTH) * 100,
    top: (number(position?.y) / WORLD_HEIGHT) * 100,
  };
}

function binaryBeforeAfter(samples, timeMs) {
  let low = 0;
  let high = samples.length - 1;
  while (low <= high) {
    const mid = (low + high) >> 1;
    const sampleTime = number(samples[mid]?.timeMs);
    if (sampleTime === timeMs) return { exact: samples[mid] };
    if (sampleTime < timeMs) low = mid + 1;
    else high = mid - 1;
  }
  return { before: samples[high], after: samples[low] };
}

function lerpPosition(before, after, t) {
  return {
    x: number(before?.x) + (number(after?.x) - number(before?.x)) * t,
    y: number(before?.y) + (number(after?.y) - number(before?.y)) * t,
    z: before?.z == null || after?.z == null
      ? before?.z ?? after?.z
      : number(before.z) + (number(after.z) - number(before.z)) * t,
  };
}

export function playerSampleAt(player, timeMs) {
  const samples = player?.samples ?? [];
  if (!samples.length) return null;
  if (timeMs <= number(samples[0].timeMs)) return samples[0];
  if (timeMs >= number(samples.at(-1).timeMs)) return samples.at(-1);
  const result = binaryBeforeAfter(samples, timeMs);
  if (result.exact) return result.exact;
  const span = number(result.after.timeMs) - number(result.before.timeMs);
  if (span <= 0 || span > MAX_PLAYER_INTERPOLATION_GAP_MS) return result.before;
  const t = (timeMs - number(result.before.timeMs)) / span;
  return {
    ...lerpPosition(result.before, result.after, t),
    timeMs,
    yawDegrees: number(result.before.yawDegrees) +
      (number(result.after.yawDegrees) - number(result.before.yawDegrees)) * t,
  };
}

export function utilityPositionAt(actor, timeMs) {
  const samples = actor?.samples ?? [];
  const initial = actor?.position ?? { x: 0, y: 0 };
  if (!samples.length || timeMs < number(samples[0]?.timeMs)) return initial;
  if (timeMs === number(samples[0]?.timeMs)) return samples[0].position ?? samples[0];
  if (timeMs >= number(samples.at(-1)?.timeMs)) return samples.at(-1).position ?? samples.at(-1);
  const normalized = samples.map((sample) => ({ ...sample, ...(sample.position ?? {}) }));
  const result = binaryBeforeAfter(normalized, timeMs);
  if (result.exact) return result.exact;
  const span = number(result.after.timeMs) - number(result.before.timeMs);
  if (span <= 0 || span > MAX_UTILITY_INTERPOLATION_GAP_MS) return result.before;
  return lerpPosition(result.before, result.after, (timeMs - number(result.before.timeMs)) / span);
}

export function abilityIndex(event) {
  if (Number.isInteger(event?.abilityIndex) && event.abilityIndex >= 0) return event.abilityIndex;
  const slot = String(event?.abilitySlot ?? event?.sourceAbilitySlot ?? '').trim().toLowerCase();
  if (['c', 'grenade', 'ability0'].includes(slot)) return 0;
  if (['q', 'ability1'].includes(slot)) return 1;
  if (['e', 'ability2', 'signature'].includes(slot)) return 2;
  if (['x', 'ultimate', 'ability3'].includes(slot)) return 3;
  return null;
}

export function agentForEvent(event, track) {
  const direct = String(event?.icarusAgentType ?? event?.agent ?? '').trim().toLowerCase();
  if (AGENTS[direct]) return AGENTS[direct];
  const normalized = direct.replace(/[^a-z]/g, '');
  const match = Object.values(AGENTS).find((agent) =>
    agent.key.toLowerCase() === normalized || agent.name.toLowerCase().replace(/[^a-z]/g, '') === normalized,
  );
  if (match) return match;
  const ownerGuid = event?.ownerPlayerNetGuid ?? event?.playerNetGuid;
  const owner = (track?.players ?? []).find((player) =>
    player.id === `netguid-${ownerGuid}` || player.diagnostic?.netGuid === ownerGuid,
  );
  return owner?.agent ? AGENTS[String(owner.agent).toLowerCase()] ?? null : null;
}

export function abilityForEvent(event, track) {
  const agent = agentForEvent(event, track);
  const index = abilityIndex(event);
  return index == null ? null : agent?.abilities?.[index] ?? null;
}

function observedStart(actor) {
  return number(actor?.observedStartMs ?? actor?.timeMs);
}

function observedEnd(actor) {
  if (actor?.observedEndMs != null) return number(actor.observedEndMs);
  if (actor?.closedAtMs != null) return number(actor.closedAtMs);
  if (actor?.observedLifetimeMs != null) return observedStart(actor) + number(actor.observedLifetimeMs);
  return null;
}

export function utilityEnd(actor) {
  const observed = observedEnd(actor);
  if (observed != null) return observed;
  if (actor?.lifecycleEvidence === 'derived' && actor?.effectiveEndMs != null) {
    return number(actor.effectiveEndMs);
  }
  return null;
}

export function isUtilityCandidate(actor) {
  if (!actor || actor.ignoredAsAbility) return false;
  const source = String(actor.durationSource ?? '').toLowerCase();
  if (source.startsWith('ignored-')) return false;
  const name = `${actor.className ?? ''} ${actor.archetypePath ?? ''}`;
  if (/EquippablePickupProjectile/i.test(name)) return false;
  if (actor.contentKind === 'pickup-drop' || actor.phase === 'pickup-drop') return false;
  const spatial = actor.position && Number.isFinite(Number(actor.position.x)) && Number.isFinite(Number(actor.position.y));
  const abilityMention = Boolean(
    actor.agent || actor.icarusAgentType || actor.abilitySlot || actor.abilityName ||
    Number.isInteger(actor.abilityIndex) || /ability|projectile|gameobject|patch|pawn/i.test(name),
  );
  const end = utilityEnd(actor);
  return spatial && abilityMention && end != null && end >= observedStart(actor);
}

export function isUtilityActive(actor, timeMs) {
  if (!isUtilityCandidate(actor)) return false;
  const start = observedStart(actor);
  const end = utilityEnd(actor);
  return timeMs >= start && timeMs <= end;
}

export function castLocations(cast) {
  return cast?.placementLocations ?? cast?.displayLocations ?? cast?.visualLocations ?? [];
}

export function isCastActive(cast, timeMs) {
  if (!castLocations(cast).length || timeMs < number(cast?.timeMs)) return false;
  const explicitEnd = cast?.endTimeMs ?? cast?.endMs;
  const explicitLifetime = cast?.displayLifetimeMs ?? cast?.lifetimeMs;
  const end = explicitEnd ??
    (explicitLifetime == null ? null : number(cast?.timeMs) + number(explicitLifetime));
  if (end == null) return false;
  return timeMs <= number(end);
}

export function eventLabel(event, track) {
  const agent = agentForEvent(event, track);
  const ability = abilityForEvent(event, track);
  const fallback = event?.abilityName ?? event?.sourceAbilityName ?? event?.abilitySlot ??
    event?.className ?? event?.archetypePath ?? 'Ability event';
  return [agent?.name, ability?.name ?? fallback].filter(Boolean).join(' · ');
}

export function normalizeAbilityEvents(track) {
  const events = [];
  for (const cast of track?.abilityCasts ?? []) {
    events.push({
      kind: 'abilityCast',
      id: cast.id ?? `cast-${cast.timeMs}-${events.length}`,
      groupId: `cast:${cast.id ?? `cast-${cast.timeMs}-${events.length}`}`,
      timeMs: number(cast.timeMs),
      endTimeMs:
        cast.endTimeMs ?? cast.endMs ??
        (cast.displayLifetimeMs == null
          ? null
          : number(cast.timeMs) + number(cast.displayLifetimeMs)),
      source: cast,
      label: eventLabel(cast, track),
    });
  }
  for (const actor of track?.utilityActors ?? []) {
    if (!isUtilityCandidate(actor)) continue;
    const id = actor.id ?? `actor-${actor.actorNetGuid ?? actor.chIndex ?? actor.timeMs}`;
    const groupId = actor.sourceCastId
      ? `cast:${actor.sourceCastId}`
      : actor.phaseGroupId
        ? `phase:${actor.phaseGroupId}`
        : `event:${id}`;
    events.push({
      kind: 'utilityActor',
      id,
      groupId,
      timeMs: observedStart(actor),
      endTimeMs: utilityEnd(actor),
      source: actor,
      label: eventLabel(actor, track),
    });
  }
  return events.sort((a, b) => a.timeMs - b.timeMs || a.label.localeCompare(b.label));
}

function representativeScore(event) {
  const phase = String(event?.source?.phase ?? '').toLowerCase();
  if (/placed|area|patch|active/.test(phase)) return 5;
  if (/deployable|movement/.test(phase)) return 4;
  if (/projectile|flight/.test(phase)) return 3;
  if (/cast-identity/.test(phase)) return 1;
  return event?.kind === 'abilityCast' ? 2 : 0;
}

export function groupAbilityEvents(events) {
  const byId = new Map();
  for (const event of events) {
    const id = event.groupId ?? `event:${event.id}`;
    const group = byId.get(id) ?? {
      id,
      label: event.label,
      timeMs: event.timeMs,
      endTimeMs: event.endTimeMs,
      events: [],
      representative: event,
    };
    group.events.push(event);
    group.timeMs = Math.min(group.timeMs, event.timeMs);
    group.endTimeMs = Math.max(group.endTimeMs ?? event.endTimeMs, event.endTimeMs ?? group.endTimeMs);
    if (representativeScore(event) > representativeScore(group.representative)) group.representative = event;
    byId.set(id, group);
  }
  return [...byId.values()].sort((a, b) => a.timeMs - b.timeMs || a.label.localeCompare(b.label));
}

export function trackDuration(track) {
  const explicit = track?.durationMs ?? track?.recordedDurationMs;
  if (Number.isFinite(Number(explicit))) return number(explicit);
  let duration = 0;
  for (const player of track?.players ?? []) duration = Math.max(duration, number(player.samples?.at(-1)?.timeMs));
  for (const event of track?.roundStartEvents ?? []) duration = Math.max(duration, number(event.timeMs));
  for (const event of track?.deathEvents ?? []) duration = Math.max(duration, number(event.timeMs));
  for (const cast of track?.abilityCasts ?? []) duration = Math.max(duration, number(cast.endTimeMs ?? cast.timeMs));
  for (const actor of track?.utilityActors ?? []) duration = Math.max(duration, utilityEnd(actor) ?? number(actor.timeMs));
  return duration;
}

export function playerNetGuid(player) {
  const idMatch = String(player?.id ?? '').match(/netguid-(\d+)/i);
  return number(player?.diagnostic?.netGuid ?? idMatch?.[1], null);
}

export function ownerPlayer(event, track) {
  const source = event?.source ?? event;
  const guid = source?.ownerPlayerNetGuid ?? source?.playerNetGuid;
  const subject = source?.ownerSubject ?? source?.playerSubject;
  const direct = (track?.players ?? []).find((player) =>
    (guid != null && playerNetGuid(player) === number(guid)) ||
    (subject && (player.subject === subject || player.playerSubject === subject)),
  );
  if (direct) return direct;
  if (source?.sourceCastId) {
    const cast = (track?.abilityCasts ?? []).find((candidate) => candidate.id === source.sourceCastId);
    if (cast) {
      const linked = ownerPlayer(cast, track);
      if (linked) return linked;
    }
  }
  const agent = agentForEvent(source, track);
  if (!agent) return null;
  const matches = (track?.players ?? []).filter((player) =>
    String(player.agent ?? '').toLowerCase() === agent.name.toLowerCase(),
  );
  return matches.length === 1 ? matches[0] : null;
}

function normalizedIdentity(value) {
  return String(value ?? '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}

export function identityWarnings(event, track) {
  const warnings = [];
  const source = event?.source ?? event ?? {};
  const rendered = abilityForEvent(source, track)?.name ?? source.abilityName;
  const evidence = [
    source.sourceAbilityName,
    source.staticAbilityName,
    source.verifiedAbilityId,
  ].filter(Boolean);
  const renderedIdentity = normalizedIdentity(rendered);
  for (const value of evidence) {
    const evidenceIdentity = normalizedIdentity(value);
    if (renderedIdentity && evidenceIdentity &&
        !evidenceIdentity.includes(renderedIdentity) && !renderedIdentity.includes(evidenceIdentity)) {
      warnings.push(`Rendered “${rendered}” conflicts with evidence “${value}”.`);
    }
  }
  const classEvidence = normalizedIdentity(`${source.className ?? ''} ${source.archetypePath ?? ''} ${source.durationSource ?? ''}`);
  if (/sonar|recon bolt/.test(classEvidence) && renderedIdentity && !renderedIdentity.includes('recon bolt')) {
    warnings.push(`Class/lifecycle evidence looks like Recon Bolt, not “${rendered}”.`);
  }
  return [...new Set(warnings)];
}

export function spectatorKey(player, track = null) {
  if (!player) return null;
  let loadoutIndex = number(player.loadoutIndex ?? player.diagnostic?.loadoutIndex, -1);
  const side = String(player.initialSide ?? player.side ?? '').toLowerCase();
  if ((loadoutIndex < 0 || loadoutIndex > 4) && track && side) {
    loadoutIndex = (track.players ?? [])
      .filter((candidate) => String(candidate.initialSide ?? candidate.side ?? '').toLowerCase() === side)
      .indexOf(player);
  }
  if (loadoutIndex < 0 || loadoutIndex > 4) return null;
  if (side === 'defender') return String(loadoutIndex + 1);
  if (side === 'attacker') return loadoutIndex === 4 ? '0' : String(loadoutIndex + 6);
  return null;
}

export function formatTime(timeMs) {
  const totalSeconds = Math.max(0, Math.floor(number(timeMs) / 1000));
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  const millis = Math.floor(number(timeMs) % 1000);
  return `${minutes}:${String(seconds).padStart(2, '0')}.${String(millis).padStart(3, '0')}`;
}

export { AGENTS, MAPS, RIOT_MAP_IDS };
