import assert from 'node:assert/strict';
import {
  AGENTS,
  MAPS,
  abilityIndex,
  gameToWorld,
  groupAbilityEvents,
  identityWarnings,
  mapKeyFromTrack,
  normalizeAbilityEvents,
  rotateUvCw,
  spectatorKey,
  trackDuration,
} from './replay-audit-core.js';

assert.equal(Object.keys(MAPS).length, 12, 'all supported Icarus maps are catalogued');
assert.ok(Object.keys(AGENTS).length >= 29, 'all current agent asset directories are catalogued');
for (const map of Object.values(MAPS)) {
  assert.ok(map.asset.endsWith('_map.svg'));
  assert.ok(map.viewBox?.width > 0 && map.viewBox?.height > 0);
  assert.ok(map.transform?.xMultiplier);
}

assert.deepEqual(rotateUvCw(.2, .3, 1), { u: .7, v: .2 });
assert.equal(mapKeyFromTrack({ mapId: '/Game/Maps/Ascent/Ascent' }), 'ascent');
assert.equal(mapKeyFromTrack({ mapName: 'Lotus' }), 'lotus');
assert.equal(abilityIndex({ abilitySlot: 'Ability2' }), 2);
assert.equal(abilityIndex({ abilityIndex: 4, abilitySlot: 'Ability3' }), 4);
assert.equal(spectatorKey({ initialSide: 'defender', loadoutIndex: 0 }), '1');
assert.equal(spectatorKey({ initialSide: 'attacker', loadoutIndex: 4 }), '0');

const ascentOrigin = gameToWorld('ascent', 0, 0);
assert.ok(ascentOrigin.x > 0 && ascentOrigin.x < 1778);
assert.ok(ascentOrigin.y > 0 && ascentOrigin.y < 1000);

const track = {
  mapId: '/Game/Maps/Ascent/Ascent',
  coordinateSpace: 'game',
  players: [{ samples: [{ timeMs: 1000 }, { timeMs: 8000 }] }],
  abilityCasts: [{ id: 'cast-a', timeMs: 2000, agent: 'Omen', abilitySlot: 'Ability2' }],
  utilityActors: [{
    id: 'actor-a',
    timeMs: 2500,
    observedEndMs: 5500,
    position: { x: 1, y: 2 },
    agent: 'Omen',
    abilitySlot: 'Ability2',
    phase: 'placed',
    sourceCastId: 'cast-a',
  }],
};
assert.equal(trackDuration(track), 8000);
const normalizedEvents = normalizeAbilityEvents(track);
assert.deepEqual(normalizedEvents.map((event) => event.id), ['cast-a', 'actor-a']);
assert.equal(groupAbilityEvents(normalizedEvents).length, 1);
assert.deepEqual(
  identityWarnings({ source: { abilityName: 'Shock Bolt', className: 'GameObject_Hunter_Q_SonarBolt' } }, track),
  ['Class/lifecycle evidence looks like Recon Bolt, not “Shock Bolt”.'],
);

console.log('Replay audit core tests passed.');
