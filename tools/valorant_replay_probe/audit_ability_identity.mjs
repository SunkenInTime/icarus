#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const TOOL_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(TOOL_DIR, '..', '..');
const GENERATED_INDEX = path.join(
  REPO_ROOT,
  'tmp',
  'valorant_export_research',
  'indexes',
  'ability_identity_index.json',
);
const BUNDLED_INDEX = path.join(
  TOOL_DIR,
  'static_decoder_indexes',
  'ability_identity_index.json',
);
const DEFAULT_INDEX = fs.existsSync(GENERATED_INDEX) ? GENERATED_INDEX : BUNDLED_INDEX;

const EXPECTED_CLASSES = new Map([
  ['GameObject_Deadeye_E_Trap', { agent: 'Chamber', abilitySlot: 'Grenade', abilityName: 'Trademark' }],
  ['GameObject_Deadeye_E_Teleporter_Tether', { agent: 'Chamber', abilitySlot: 'Ability2', abilityName: 'Rendezvous' }],
  ['Projectile_Wraith_4_Smoke', { agent: 'Omen', abilitySlot: 'Ability2', abilityName: 'Dark Cover' }],
  ['Projectile_Wraith_Q_NearsightMissile', { agent: 'Omen', abilitySlot: 'Ability1', abilityName: 'Paranoia' }],
  ['Projectile_Hunter_4_ExplosiveBolt', { agent: 'Sova', abilitySlot: 'Ability1', abilityName: 'Shock Bolt' }],
  ['Pawn_Hunter_E_Drone', { agent: 'Sova', abilitySlot: 'Grenade', abilityName: 'Owl Drone' }],
  ['Projectile_Sprinter_4_GroundStrike', { agent: 'Neon', abilitySlot: 'Ability1', abilityName: 'Relay Bolt' }],
  ['Projectile_Neon_C_Tunnel', { agent: 'Neon', abilitySlot: 'Grenade', abilityName: 'Fast Lane' }],
]);

function parseArgs(argv) {
  const args = {
    track: null,
    index: DEFAULT_INDEX,
    out: null,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--track') args.track = argv[++i];
    else if (arg === '--index') args.index = argv[++i];
    else if (arg === '--out') args.out = argv[++i];
    else if (arg === '--help' || arg === '-h') {
      console.log('Usage: node audit_ability_identity.mjs --track <track.json> [--index <ability_identity_index.json>] [--out <report.json>]');
      process.exit(0);
    }
  }
  if (!args.track) throw new Error('--track is required');
  const baseCwd = process.env.INIT_CWD || process.cwd();
  args.track = path.resolve(baseCwd, args.track);
  args.index = path.resolve(baseCwd, args.index);
  args.out = args.out ? path.resolve(baseCwd, args.out) : null;
  return args;
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
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

function staticIdentityFor(index, className) {
  if (!className) return null;
  if (index.classes?.[className]) return index.classes[className];
  const lower = className.toLowerCase();
  const match = Object.entries(index.classes ?? {}).find(
    ([key]) => key.toLowerCase() === lower,
  );
  return match?.[1] ?? null;
}

function mismatch(field, actual, expected) {
  if (expected == null || actual == null || actual === expected) return null;
  if (
    field.toLowerCase().includes('name') &&
    (
      String(actual).trim().toLowerCase() === String(expected).trim().toLowerCase() ||
      (
        String(expected).trim().toLowerCase() === 'm-pulse' &&
        /^m-pulse (?:concuss|healing)$/i.test(String(actual).trim())
      )
    )
  ) {
    return null;
  }
  return { field, actual, expected };
}

function auditTrack(track, index) {
  const findings = [];
  const utilityActors = Array.isArray(track.utilityActors) ? track.utilityActors : [];

  for (const actor of utilityActors) {
    const className = actor.className ?? classNameFrom(actor.archetypePath);
    const identity = staticIdentityFor(index, className);
    const mismatches = [];
    if (identity) {
      for (const item of [
        mismatch('agent', actor.agent, identity.agent),
        mismatch('abilitySlot', actor.abilitySlot, identity.abilitySlot),
        mismatch('abilityName', actor.abilityName, identity.abilityName),
        mismatch('sourceAbilitySlot', actor.sourceAbilitySlot, identity.abilitySlot),
      ]) {
        if (item) mismatches.push(item);
      }
      if (
        actor.identityConfidence &&
        actor.identityConfidence !== 'high' &&
        actor.identitySource?.startsWith('static-')
      ) {
        mismatches.push({
          field: 'identityConfidence',
          actual: actor.identityConfidence,
          expected: 'high',
        });
      }
    }

    if (/chamber-trademark/i.test(actor.durationSource ?? '') && actor.abilityName !== 'Trademark') {
      mismatches.push({
        field: 'durationSource/abilityName',
        actual: `${actor.durationSource} / ${actor.abilityName}`,
        expected: 'chamber-trademark / Trademark',
      });
    }
    if (actor.sourceAbilitySlot && actor.abilitySlot && actor.sourceAbilitySlot !== actor.abilitySlot) {
      mismatches.push({
        field: 'sourceAbilitySlot/abilitySlot',
        actual: `${actor.sourceAbilitySlot} / ${actor.abilitySlot}`,
        expected: actor.sourceAbilitySlot,
      });
    }

    if (mismatches.length) {
      findings.push({
        type: 'utility-actor-static-identity-mismatch',
        id: actor.id ?? null,
        timeMs: actor.timeMs ?? null,
        className,
        staticIdentity: identity,
        mismatches,
      });
    }
  }

  for (const [className, expected] of EXPECTED_CLASSES.entries()) {
    const identity = staticIdentityFor(index, className);
    const mismatches = [
      mismatch('agent', identity?.agent, expected.agent),
      mismatch('abilitySlot', identity?.abilitySlot, expected.abilitySlot),
      mismatch('abilityName', identity?.abilityName, expected.abilityName),
    ].filter(Boolean);
    if (!identity || mismatches.length) {
      findings.push({
        type: 'known-class-static-index-mismatch',
        className,
        staticIdentity: identity,
        expected,
        mismatches,
      });
    }
  }

  return {
    utilityActorCount: utilityActors.length,
    findingCount: findings.length,
    findings,
  };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const track = readJson(args.track);
  const index = readJson(args.index);
  const report = auditTrack(track, index);
  const output = JSON.stringify(report, null, 2);
  if (args.out) {
    fs.mkdirSync(path.dirname(args.out), { recursive: true });
    fs.writeFileSync(args.out, `${output}\n`);
  }
  console.log(output);
  if (report.findingCount > 0) process.exitCode = 1;
}

main();
