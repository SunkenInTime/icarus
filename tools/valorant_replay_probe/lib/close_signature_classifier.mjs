import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
export const CLOSE_SIGNATURE_RULES_PATH = path.join(
  MODULE_DIR,
  '..',
  'static_decoder_indexes',
  'close_signature_rules.json',
);

let cachedRules = null;

export function loadCloseSignatureRules(rulesPath = CLOSE_SIGNATURE_RULES_PATH) {
  if (rulesPath === CLOSE_SIGNATURE_RULES_PATH && cachedRules) return cachedRules;
  const parsed = JSON.parse(fs.readFileSync(rulesPath, 'utf8'));
  if (parsed?.schema !== 'icarus-close-signature-rules-v3') {
    throw new Error(`Unsupported close-signature rules schema in ${rulesPath}`);
  }
  if (rulesPath === CLOSE_SIGNATURE_RULES_PATH) cachedRules = parsed;
  return parsed;
}

function normalized(value) {
  return String(value ?? '').trim().toLowerCase().replace(/[^a-z0-9]/g, '');
}

function actorId(actor) {
  return actor.id ?? `actor-${actor.actorNetGuid ?? actor.chIndex ?? actor.timeMs}`;
}

function actorStartMs(actor) {
  return actor.observedStartMs ?? actor.timeMs ?? null;
}

function actorCloseMs(actor) {
  return actor.observedEndMs ?? actor.closedAtMs ?? null;
}

function actorLifetimeMs(actor) {
  if (Number.isFinite(actor.observedLifetimeMs)) return actor.observedLifetimeMs;
  const startMs = actorStartMs(actor);
  const closeMs = actorCloseMs(actor);
  return Number.isFinite(startMs) && Number.isFinite(closeMs)
    ? closeMs - startMs
    : null;
}

function actorClass(actor) {
  return String(actor.className ?? actor.archetypePath ?? '')
    .split('/')
    .at(-1)
    .split('.')
    .at(-1)
    .replace(/^Default__/, '')
    .replace(/_C$/, '');
}

function sameAbility(left, right) {
  const leftAgent = normalized(left.agent ?? left.agentShippingName);
  const rightAgent = normalized(right.agent ?? right.agentShippingName);
  const leftSlot = normalized(left.sourceAbilitySlot ?? left.abilitySlot);
  const rightSlot = normalized(right.sourceAbilitySlot ?? right.abilitySlot);
  if (leftAgent && rightAgent && leftAgent !== rightAgent) return false;
  if (leftSlot && rightSlot && leftSlot !== rightSlot) return false;
  const leftName = normalized(left.sourceAbilityName ?? left.abilityName);
  const rightName = normalized(right.sourceAbilityName ?? right.abilityName);
  return !(leftName && rightName && leftName !== rightName);
}

function roundIndexForTime(roundStartEvents, timeMs) {
  let result = null;
  for (let index = 0; index < roundStartEvents.length; index += 1) {
    if (roundStartEvents[index].timeMs <= timeMs) result = index;
    else break;
  }
  return result;
}

function distance2d(left, right) {
  if (!left || !right || !Number.isFinite(left.x) || !Number.isFinite(left.y) ||
      !Number.isFinite(right.x) || !Number.isFinite(right.y)) {
    return null;
  }
  return Math.hypot(left.x - right.x, left.y - right.y);
}

function compile(pattern, flags = '') {
  return new RegExp(pattern, flags);
}

function signalStateNames(signal) {
  return (signal.netGuidReferences ?? [])
    .map((reference) => reference.pathName)
    .filter(Boolean);
}

function matchingSignals(actor, signature, abilitySignals) {
  const closeMs = actorCloseMs(actor);
  if (!Number.isFinite(closeMs) || !signature.signal) return [];
  const field = compile(signature.signal.fieldPattern, 'i');
  const state = signature.signal.statePattern
    ? compile(signature.signal.statePattern, 'i')
    : null;
  const actorPath = signature.signal.actorPathPattern
    ? compile(signature.signal.actorPathPattern, 'i')
    : null;
  return abilitySignals.filter((signal) => {
    const offsetMs = signal.timeMs - closeMs;
    if (offsetMs < signature.signal.fromMs || offsetMs > signature.signal.toMs) return false;
    if (!field.test(signal.fieldName ?? '')) return false;
    if (state && !signalStateNames(signal).some((name) => state.test(name))) return false;
    if (actorPath && !actorPath.test(signal.actorPath ?? '')) return false;
    if (signature.signal.sameActor && signal.actorNetGuid !== actor.actorNetGuid) return false;
    if (Number.isFinite(signature.signal.minimumPayloadBits) &&
        (signal.numBits ?? signal.numPayloadBits ?? 0) < signature.signal.minimumPayloadBits) {
      return false;
    }
    return true;
  });
}

function outcomeEvidenceTier(rule, observedRuleIds) {
  return observedRuleIds.has(rule.id) ? 'observed' : 'derived';
}

function publicOutcome(rule, observedRuleIds, signatureIds = [rule.id]) {
  return {
    type: rule.outcome,
    confidence: rule.confidence,
    evidence: outcomeEvidenceTier(rule, observedRuleIds),
    ruleId: rule.id,
    signatureIds,
  };
}

function buildChainLinks(utilityActors, roundStartEvents, rules) {
  const links = [];
  const usedSuccessors = new Set();
  const ordered = [...utilityActors].sort(
    (left, right) =>
      (actorStartMs(left) ?? 0) - (actorStartMs(right) ?? 0) ||
      actorId(left).localeCompare(actorId(right)),
  );
  for (const fromActor of ordered) {
    const closeMs = actorCloseMs(fromActor);
    if (!Number.isFinite(closeMs)) continue;
    const fromClass = actorClass(fromActor);
    for (const rule of rules.chainHandoffs ?? []) {
      if (!compile(rule.fromPattern).test(fromClass)) continue;
      const fromRound = roundIndexForTime(roundStartEvents, closeMs);
      const candidates = ordered
        .filter((toActor) => {
          if (toActor === fromActor || usedSuccessors.has(actorId(toActor))) return false;
          if (!compile(rule.toPattern).test(actorClass(toActor))) return false;
          if (!sameAbility(fromActor, toActor)) return false;
          const openMs = actorStartMs(toActor);
          const gapMs = openMs - closeMs;
          if (gapMs < rule.minGapMs || gapMs > rule.maxGapMs) return false;
          if (roundIndexForTime(roundStartEvents, openMs) !== fromRound) return false;
          const distance = distance2d(fromActor.position, toActor.position);
          return rule.sameLocationTolerance == null || distance == null ||
            distance <= rule.sameLocationTolerance;
        })
        .map((toActor) => ({
          toActor,
          gapMs: actorStartMs(toActor) - closeMs,
          distanceUnits: distance2d(fromActor.position, toActor.position),
        }))
        .sort((left, right) =>
          Math.abs(left.gapMs) - Math.abs(right.gapMs) ||
          (left.distanceUnits ?? 0) - (right.distanceUnits ?? 0));
      const candidate = candidates[0];
      if (!candidate) continue;
      usedSuccessors.add(actorId(candidate.toActor));
      links.push({
        rule,
        fromActor,
        toActor: candidate.toActor,
        gapMs: candidate.gapMs,
        distanceUnits: candidate.distanceUnits,
      });
      break;
    }
  }
  return links;
}

function assignChainMetadata(utilityActors, links) {
  const predecessorById = new Map();
  const successorById = new Map();
  for (const link of links) {
    predecessorById.set(actorId(link.toActor), link.fromActor);
    successorById.set(actorId(link.fromActor), link.toActor);
  }
  const visited = new Set();
  for (const actor of utilityActors) {
    if (visited.has(actorId(actor))) continue;
    let first = actor;
    while (predecessorById.has(actorId(first))) {
      first = predecessorById.get(actorId(first));
    }
    const stages = [];
    let current = first;
    while (current && !stages.includes(current)) {
      stages.push(current);
      current = successorById.get(actorId(current)) ?? null;
    }
    if (stages.length < 2) continue;
    const chainGroupId = `chain-${actorId(first)}`;
    for (let index = 0; index < stages.length; index += 1) {
      const stage = stages[index];
      visited.add(actorId(stage));
      stage.chainGroupId = chainGroupId;
      stage.chainStageIndex = index;
      stage.predecessorActorId = index > 0 ? actorId(stages[index - 1]) : null;
      stage.successorActorId = index + 1 < stages.length
        ? actorId(stages[index + 1])
        : null;
    }
  }
}

function simultaneousCloseCount(utilityActors, closeMs) {
  return utilityActors.filter((actor) => actorCloseMs(actor) === closeMs).length;
}

function nextRoundStartAfter(roundStartEvents, timeMs) {
  return roundStartEvents.find((event) => event.timeMs > timeMs)?.timeMs ?? null;
}

function classifyActor(actor, context) {
  const {
    utilityActors,
    abilitySignals,
    roundStartEvents,
    deathEvents,
    rules,
    observedRuleIds,
    outgoingLink,
  } = context;
  const closeMs = actorCloseMs(actor);
  if (!Number.isFinite(closeMs)) return { outcome: null, matchingSignal: null, rule: null };
  const className = actorClass(actor);
  const classRule = (id) => (rules.classOutcomeRules ?? []).find(
    (rule) => rule.id === id,
  );

  if (actor.endReason === 'round-teardown') {
    const rule = classRule('observed-round-teardown');
    return {
      outcome: publicOutcome(rule, observedRuleIds),
      matchingSignal: null,
      rule,
    };
  }

  for (const signature of rules.outcomeSignatures ?? []) {
    if (!compile(signature.classPattern).test(className)) continue;
    const signals = matchingSignals(actor, signature, abilitySignals);
    if (!signals.length) continue;
    return {
      outcome: publicOutcome(signature, observedRuleIds),
      matchingSignal: signals.at(-1),
      rule: signature,
    };
  }

  if (outgoingLink) {
    let chainRule = {
      id: outgoingLink.rule.outcomeRuleId,
      outcome: 'phase-transition',
      confidence: outgoingLink.rule.confidence,
    };
    if (/^Pawn_Aggrobot_SeekerNade$/.test(className)) {
      const conditionalRuleId = /PlantSuccessful/.test(actorClass(outgoingLink.toActor))
        ? 'gekko-wingman-plant-completed'
        : actorLifetimeMs(actor) <= 2500
          ? 'gekko-wingman-short-run-to-reclaim'
          : 'gekko-wingman-course-completed';
      chainRule = classRule(conditionalRuleId);
    }
    return {
      outcome: publicOutcome(chainRule, observedRuleIds, [outgoingLink.rule.id]),
      matchingSignal: null,
      rule: chainRule,
    };
  }

  const lifetimeMs = actorLifetimeMs(actor);
  for (const timer of rules.fixedTimerExpiry ?? []) {
    if (!compile(timer.classPattern).test(className) ||
        !Number.isFinite(lifetimeMs) ||
        Math.abs(lifetimeMs - timer.timerMs) > timer.toleranceMs) {
      continue;
    }
    const timerRule = {
      ...timer,
      outcome: timer.id === 'deadlock-fissure-linger-ended'
        ? 'phase-transition'
        : 'expired',
    };
    return {
      outcome: publicOutcome(timerRule, observedRuleIds),
      matchingSignal: null,
      rule: timerRule,
    };
  }

  const roundRule = rules.roundEndWindow;
  const nextRoundStartMs = nextRoundStartAfter(roundStartEvents, closeMs);
  const closeToNextRoundStartMs = Number.isFinite(nextRoundStartMs)
    ? nextRoundStartMs - closeMs
    : null;
  if (simultaneousCloseCount(utilityActors, closeMs) >= roundRule.minimumSimultaneousCloses &&
      Number.isFinite(closeToNextRoundStartMs) &&
      closeToNextRoundStartMs >= roundRule.minimumMsBeforeNextRound &&
      closeToNextRoundStartMs <= roundRule.maximumMsBeforeNextRound) {
    return {
      outcome: publicOutcome(roundRule, observedRuleIds),
      matchingSignal: null,
      rule: roundRule,
    };
  }

  for (const id of [
    'killjoy-alarmbot-no-trigger-signature',
    'cypher-spycam-dart-non-round-close',
    'killjoy-turret-non-recall-close',
  ]) {
    const rule = classRule(id);
    if (rule?.classPattern && compile(rule.classPattern).test(className)) {
      return {
        outcome: publicOutcome(rule, observedRuleIds),
        matchingSignal: null,
        rule,
      };
    }
  }

  if (Number.isInteger(actor.ownerPlayerNetGuid)) {
    const deathRule = rules.ownerDeathWindow;
    const death = deathEvents.find((event) => {
      const offsetMs = closeMs - event.timeMs;
      return event.victimNetGuid === actor.ownerPlayerNetGuid &&
        offsetMs >= deathRule.minimumOffsetMs &&
        offsetMs <= deathRule.maximumOffsetMs;
    });
    if (death) {
      return {
        outcome: publicOutcome(deathRule, observedRuleIds),
        matchingSignal: null,
        rule: deathRule,
      };
    }
  }

  if (/^Projectile_/.test(className)) {
    const stopSignal = abilitySignals.find((signal) =>
      signal.actorNetGuid === actor.actorNetGuid &&
      /MulticastStopProjectile/i.test(signal.fieldName ?? '') &&
      signal.timeMs - closeMs >= -1500 && signal.timeMs - closeMs <= 20);
    if (stopSignal) {
      const rule = classRule('generic-projectile-stop');
      return {
        outcome: publicOutcome(rule, observedRuleIds),
        matchingSignal: stopSignal,
        rule,
      };
    }
  }

  if (/^Patch_/.test(className) && Number.isFinite(lifetimeMs) && lifetimeMs >= 500) {
    const rule = classRule('area-patch-natural-duration-ended');
    return {
      outcome: publicOutcome(rule, observedRuleIds),
      matchingSignal: null,
      rule,
    };
  }

  return {
    outcome: {
      type: 'unknown',
      confidence: 'low',
      evidence: 'derived',
      ruleId: 'insufficient-discriminating-evidence',
      signatureIds: [],
    },
    matchingSignal: null,
    rule: null,
  };
}

function applyCloseLag(actor, classification, outgoingLink, rules) {
  const closeMs = actorCloseMs(actor);
  if (!Number.isFinite(closeMs) || !classification.outcome) return;
  if (classification.outcome.type === 'unknown') {
    actor.rawCloseMs = Math.round(closeMs);
    actor.triggerTimeMs = null;
    actor.closeLagMs = null;
    return;
  }
  let triggerTimeMs = closeMs;
  let closeLagMs = 0;
  if (outgoingLink && classification.outcome.type === 'phase-transition') {
    triggerTimeMs = actorStartMs(outgoingLink.toActor);
    closeLagMs = closeMs - triggerTimeMs;
  }
  const lagRule = (rules.closeLag ?? []).find((candidate) =>
    candidate.outcomeRuleId === classification.outcome.ruleId &&
    compile(candidate.classPattern).test(actorClass(actor)));
  if (lagRule) {
    if (lagRule.marker === 'actor-open') {
      triggerTimeMs = actorStartMs(actor);
    } else if (lagRule.marker === 'matching-signal' && classification.matchingSignal) {
      triggerTimeMs = classification.matchingSignal.timeMs;
    } else if (lagRule.marker === 'successor-open' && outgoingLink) {
      triggerTimeMs = actorStartMs(outgoingLink.toActor);
    } else {
      triggerTimeMs = closeMs - lagRule.lingerMs;
    }
    closeLagMs = closeMs - triggerTimeMs;
  }
  actor.triggerTimeMs = Math.round(triggerTimeMs);
  actor.rawCloseMs = Math.round(closeMs);
  actor.closeLagMs = Math.round(closeLagMs);
}

export function classifyUtilityActorCloses({
  utilityActors = [],
  abilitySignals = [],
  roundStartEvents = [],
  deathEvents = [],
  rules = loadCloseSignatureRules(),
} = {}) {
  const observedRuleIds = new Set(rules.evidencePolicy?.observedRuleIds ?? []);
  for (const actor of utilityActors) {
    actor.outcome = null;
    actor.chainGroupId = null;
    actor.chainStageIndex = null;
    actor.predecessorActorId = null;
    actor.successorActorId = null;
    actor.triggerTimeMs = null;
    actor.rawCloseMs = actorCloseMs(actor);
    actor.closeLagMs = null;
  }

  const links = buildChainLinks(utilityActors, roundStartEvents, rules);
  assignChainMetadata(utilityActors, links);
  const outgoingByActorId = new Map(
    links.map((link) => [actorId(link.fromActor), link]),
  );
  const filteredPatterns = (rules.filteredChildren ?? []).map((rule) => ({
    rule,
    pattern: compile(rule.classPattern),
  }));
  for (const actor of utilityActors) {
    const outgoingLink = outgoingByActorId.get(actorId(actor)) ?? null;
    const classification = classifyActor(actor, {
      utilityActors,
      abilitySignals,
      roundStartEvents,
      deathEvents,
      rules,
      observedRuleIds,
      outgoingLink,
    });
    actor.outcome = classification.outcome;
    applyCloseLag(actor, classification, outgoingLink, rules);
    const filtered = filteredPatterns.find(({ pattern }) => pattern.test(actorClass(actor)));
    if (filtered && actor.outcome?.type === 'unknown') {
      actor.outcome = {
        ...actor.outcome,
        ruleId: filtered.rule.id,
        signatureIds: [filtered.rule.id],
      };
    }
  }
  return { utilityActors, links, rules };
}

function lifecycleLink(actor, nextActor = null) {
  const startMs = actorStartMs(actor);
  const endMs = actor.triggerTimeMs ?? actorCloseMs(actor);
  const nextStartMs = nextActor == null ? null : actorStartMs(nextActor);
  return {
    utilityActorId: actorId(actor),
    className: actorClass(actor),
    phaseType: actor.phase ?? actor.contentKind ?? 'actor',
    startMs: Number.isFinite(startMs) ? Math.round(startMs) : null,
    endMs: Number.isFinite(endMs) ? Math.round(endMs) : null,
    handoffGapMs: Number.isFinite(endMs) && Number.isFinite(nextStartMs)
      ? Math.round(nextStartMs - endMs)
      : null,
  };
}

export function decorateAbilityActionsWithLifecycle(
  abilityActions = [],
  utilityActors = [],
) {
  const actorById = new Map(utilityActors.map((actor) => [actorId(actor), actor]));
  const actionByActorId = new Map();
  for (const action of abilityActions) {
    action.lifecycleChain = null;
    action.outcome = null;
    for (const id of action.sourceUtilityActorIds ?? []) {
      if (!actionByActorId.has(id)) actionByActorId.set(id, action);
    }
  }

  const chains = new Map();
  for (const actor of utilityActors) {
    if (!actor.chainGroupId) continue;
    if (!chains.has(actor.chainGroupId)) chains.set(actor.chainGroupId, []);
    chains.get(actor.chainGroupId).push(actor);
  }
  for (const actors of chains.values()) {
    actors.sort((left, right) => left.chainStageIndex - right.chainStageIndex);
    const action = actors.map((actor) => actionByActorId.get(actorId(actor))).find(Boolean);
    if (!action) continue;
    action.lifecycleChain = actors.map((actor, index) =>
      lifecycleLink(actor, actors[index + 1] ?? null));
  }

  for (const actor of utilityActors) {
    if (!actor.outcome || !Number.isFinite(actor.triggerTimeMs)) continue;
    const action = actionByActorId.get(actorId(actor));
    if (!action) continue;
    const isIntermediateHandoff = actor.outcome.type === 'phase-transition' &&
      actor.successorActorId != null;
    const phase = {
      id: `${action.id}-${actorId(actor)}-lifecycle-${actor.outcome.type}`,
      type: isIntermediateHandoff
        ? 'lifecycle-chain-handoff'
        : `lifecycle-${actor.outcome.type}`,
      timeMs: actor.triggerTimeMs,
      evidence: actor.outcome.evidence,
      evidenceSource: `close-signature-rule:${actor.outcome.ruleId}`,
      semanticEvidence: actor.outcome.evidence,
      timeSource: actor.closeLagMs > 0
        ? 'lag-corrected-gameplay-trigger'
        : 'raw-actor-close',
      actorNetGuid: actor.actorNetGuid ?? null,
      sourceEventId: actorId(actor),
      ruleId: actor.outcome.ruleId,
      signatureIds: actor.outcome.signatureIds,
      terminal: !isIntermediateHandoff,
    };
    if (!(action.phases ?? []).some((candidate) => candidate.id === phase.id)) {
      action.phases.push(phase);
      action.phases.sort((left, right) =>
        left.timeMs - right.timeMs || left.id.localeCompare(right.id));
    }
    if (!isIntermediateHandoff &&
        (action.outcome == null ||
          actor.triggerTimeMs >= (action.__outcomeTimeMs ?? Number.NEGATIVE_INFINITY))) {
      action.outcome = actor.outcome;
      Object.defineProperty(action, '__outcomeTimeMs', {
        value: actor.triggerTimeMs,
        writable: true,
        enumerable: false,
      });
    }
  }
  return abilityActions;
}

// Corpus studies keep their rich evidence objects. This seam lets the study and
// emitter share rule loading/orchestration while preserving the frozen v2 row
// shape used by the 4,963-close regression artifact.
export function classifyCorpusCloseCluster(
  cluster,
  context,
  corpusCompatibilityClassifier,
) {
  loadCloseSignatureRules();
  return corpusCompatibilityClassifier(cluster, context);
}
