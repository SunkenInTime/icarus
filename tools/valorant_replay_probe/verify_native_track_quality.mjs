#!/usr/bin/env node

import assert from 'node:assert/strict';

import { validateNativeExtractionQuality } from './extract_native_track.mjs';

function fixture() {
  const loadouts = [
    {
      index: 0,
      subject: '00000000-0000-0000-0000-000000000001',
      agent: 'Jett',
      initialSide: 'defender',
    },
    {
      index: 1,
      subject: '00000000-0000-0000-0000-000000000002',
      agent: 'Sova',
      initialSide: 'attacker',
    },
  ];
  const roundStartEvents = [{ timeMs: 100 }, { timeMs: 60_000 }];
  const deathEvents = [{ timeMs: 118_000 }];
  return {
    diagnostics: {
      header: {
        mapPath: '/Game/Maps/Ascent/Ascent',
        branch: '++Ares-Core+release-13.00',
        playerCount: 2,
        headerPlayerLoadouts: loadouts,
      },
      replayDataChunks: [{ startMs: 0, endMs: 120_000 }],
      roundStartEvents,
      deathEvents,
      frameSummary: {
        rawPacketsScanned: 80_000,
        rawPacketScanLimit: 1_000_000,
        rawPacketScanLimitReached: false,
        rawPacketScanSkipped: false,
        rawPacketTimeFromMs: 0,
        rawPacketTimeToMs: null,
      },
    },
    report: {
      input: {
        mapKey: 'ascent',
        requireMapPlausiblePosition: true,
      },
      movementSampleCount: 8,
      emittedMovementSampleCount: 8,
    },
    track: {
      mapId: '/Game/Maps/Ascent/Ascent',
      roundStartEvents,
      deathEvents,
      players: loadouts.map((loadout, index) => ({
        id: `netguid-${100 + index}`,
        agent: loadout.agent,
        initialSide: loadout.initialSide,
        loadoutIndex: loadout.index,
        subject: loadout.subject,
        sideSource: 'ability-cast-subject-netguid',
        diagnostic: { netGuid: 100 + index },
        samples: [
          { timeMs: 500, x: index * 100, y: 0, z: 100 },
          { timeMs: 60_500, x: index * 100 + 50, y: 25, z: 100 },
          { timeMs: 119_500, x: index * 100 + 100, y: 50, z: 100 },
        ],
      })),
    },
  };
}

function expectFailure(update, pattern) {
  const value = fixture();
  update(value);
  assert.throws(() => validateNativeExtractionQuality(value), pattern);
}

const summary = validateNativeExtractionQuality(fixture());
assert.equal(summary.mapKey, 'ascent');
assert.equal(summary.players, 2);
assert.equal(summary.totalSamples, 6);
assert.ok(summary.replayCoverage > 0.99);

for (const [mapPath, mapKey] of [
  ['/Game/Maps/Bonsai/Bonsai', 'split'],
  ['/Game/Maps/Duality/Duality', 'bind'],
]) {
  const value = fixture();
  value.diagnostics.header.mapPath = mapPath;
  value.track.mapId = mapPath;
  value.report.input.mapKey = mapKey;
  assert.equal(validateNativeExtractionQuality(value).mapKey, mapKey);
}

expectFailure((value) => {
  value.diagnostics.frameSummary.rawPacketsScanned = 1_000_000;
  value.diagnostics.frameSummary.rawPacketScanLimitReached = true;
}, /raw packet scan reached[\s\S]+--raw-packet-limit 2000000/i);

expectFailure((value) => {
  value.track.players[1].subject = value.track.players[0].subject;
}, /player identities are incomplete[\s\S]+subject does not match header/i);

expectFailure((value) => {
  value.track.players.pop();
}, /emitted 1\/2 expected players/i);

expectFailure((value) => {
  value.track.mapId = '/Game/Maps/Unknown/Unknown';
  value.diagnostics.header.mapPath = value.track.mapId;
}, /Unsupported replay map/i);

expectFailure((value) => {
  value.report.input.requireMapPlausiblePosition = false;
}, /did not enforce map-plausible positions/i);

expectFailure((value) => {
  value.track.players[0].samples.pop();
}, /Player movement lanes do not cover[\s\S]+netguid-100/i);

expectFailure((value) => {
  for (const player of value.track.players) player.samples = player.samples.slice(0, 1);
}, /Movement covers only[\s\S]+decoded event timeline/i);

expectFailure((value) => {
  for (const player of value.track.players) player.samples = [];
  value.report.movementSampleCount = 0;
  value.report.emittedMovementSampleCount = 0;
}, /no accepted movement samples/i);

expectFailure((value) => {
  value.diagnostics.frameSummary.rawPacketTimeToMs = 60_000;
}, /raw scan stops at 60000ms/i);

console.log('Native track quality verification passed.');
