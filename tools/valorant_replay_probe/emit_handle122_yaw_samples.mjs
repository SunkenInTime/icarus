#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const FIELD_HANDLE = 122;
const PAYLOAD_BITS = 92;
const YAW_BIT_OFFSET = 50;
const YAW_BIT_COUNT = 18;

function parseArgs(argv) {
  const options = {
    diagnostics: null,
    out: null,
    mapId: '/Game/Maps/Ascent/Ascent',
    minSamples: 20,
    maxLanes: 20,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--out') options.out = argv[++index];
    else if (arg === '--map-id') options.mapId = argv[++index];
    else if (arg === '--min-samples') options.minSamples = Number(argv[++index]);
    else if (arg === '--max-lanes') options.maxLanes = Number(argv[++index]);
    else if (!options.diagnostics) options.diagnostics = arg;
  }
  return options;
}

function resolveUserPath(value) {
  if (!value) return null;
  if (path.isAbsolute(value)) return value;
  return path.resolve(process.env.INIT_CWD ?? process.cwd(), value);
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function normalizeHexToFullBytes(hex) {
  if (typeof hex !== 'string') return '';
  return hex.length % 2 === 0 ? hex : `${hex}0`;
}

function readBit(buffer, bitOffset) {
  return (buffer[bitOffset >> 3] >> (bitOffset & 7)) & 1;
}

function readBitsUnsigned(buffer, bitOffset, bitCount) {
  let value = 0;
  let bitValue = 1;
  for (let bit = 0; bit < bitCount; bit += 1) {
    if (readBit(buffer, bitOffset + bit)) value += bitValue;
    bitValue *= 2;
  }
  return value;
}

function readBitsSigned(buffer, bitOffset, bitCount) {
  const value = readBitsUnsigned(buffer, bitOffset, bitCount);
  const signBit = 2 ** (bitCount - 1);
  return (value ^ signBit) - signBit;
}

function copyBits(buffer, sourceBitOffset, bitCount) {
  const result = Buffer.alloc(Math.ceil(bitCount / 8));
  for (let bit = 0; bit < bitCount; bit += 1) {
    if (readBit(buffer, sourceBitOffset + bit)) result[bit >> 3] |= 1 << (bit & 7);
  }
  return result;
}

function bitsToHex(buffer, bitOffset, bitCount) {
  if (bitCount <= 0) return '';
  return copyBits(buffer, bitOffset, bitCount).toString('hex');
}

function round(value, digits = 3) {
  if (value == null || !Number.isFinite(value)) return null;
  return Number(value.toFixed(digits));
}

function normalizeDegrees360(value) {
  const normalized = value % 360;
  return normalized < 0 ? normalized + 360 : normalized;
}

function normalizeDegrees180(value) {
  const normalized = normalizeDegrees360(value);
  return normalized >= 180 ? normalized - 360 : normalized;
}

function circularDegreesDelta(a, b) {
  const delta = Math.abs(normalizeDegrees360(a) - normalizeDegrees360(b)) % 360;
  return delta > 180 ? 360 - delta : delta;
}

function transformYaw(rawYawDegrees, transform) {
  if (transform === 'as-read') return rawYawDegrees;
  if (transform === 'negated') return -rawYawDegrees;
  if (transform === 'plus-90') return rawYawDegrees + 90;
  if (transform === 'minus-90') return rawYawDegrees - 90;
  if (transform === 'plus-180') return rawYawDegrees + 180;
  throw new Error(`unknown yaw transform: ${transform}`);
}

function parseCandidateFieldSamples(diagnostics) {
  return (diagnostics.frameSummary?.replayControllerCandidateFieldSamples ?? [])
    .filter((sample) => sample.payloadHex != null && Number.isInteger(sample.numPayloadBits))
    .map((sample, sampleIndex) => {
      const bitCount = sample.numPayloadBits;
      const payloadHex = normalizeHexToFullBytes(sample.payloadHex);
      const buffer = Buffer.from(payloadHex, 'hex');
      return {
        ...sample,
        sampleIndex,
        bitCount,
        payloadHex,
        buffer,
        hasFullPayload: !sample.payloadHexTruncated && buffer.length * 8 >= bitCount,
      };
    })
    .sort(
      (a, b) =>
        a.timeMs - b.timeMs ||
        a.sampleIndex - b.sampleIndex ||
        a.fieldHandle - b.fieldHandle,
    );
}

function knownPlayerOpenSamplesFromDiagnostics(diagnostics) {
  return (diagnostics.frameSummary?.channelOpenSamples ?? [])
    .filter((sample) => /Default__[^/]+_PC_C$/i.test(sample.archetypePath ?? ''))
    .filter((sample) => !/Ability|PostDeath/i.test(sample.archetypePath ?? ''))
    .map((sample) => ({
      timeMs: sample.timeMs,
      chIndex: sample.chIndex,
      netGuid: sample.actorNetGuid,
      archetypePath: sample.archetypePath ?? null,
      location: sample.location ?? null,
      yaw: sample.rotation?.yaw ?? null,
    }))
    .filter((sample) => Number.isInteger(sample.netGuid) && Number.isFinite(sample.yaw))
    .sort((a, b) => a.netGuid - b.netGuid);
}

function yawSampleFromEntry(entry, transform, prefixHex, netGuid) {
  const signedValue = readBitsSigned(entry.buffer, YAW_BIT_OFFSET, YAW_BIT_COUNT);
  const rawYawDegrees = (signedValue * 360) / 2 ** YAW_BIT_COUNT;
  const transformedYawDegrees = transformYaw(rawYawDegrees, transform);
  return {
    timeMs: entry.timeMs,
    netGuid,
    position: null,
    viewRotation: {
      yawDegrees: round(normalizeDegrees180(transformedYawDegrees)),
      yawDegrees360: round(normalizeDegrees360(transformedYawDegrees)),
      pitchDegrees: null,
      rollDegrees: null,
    },
    source: {
      fieldHandle: FIELD_HANDLE,
      prefixHex,
      yawTransform: transform,
      rawYawDegrees: round(rawYawDegrees),
      rawSignedValue: signedValue,
      payloadHex: entry.payloadHex,
    },
  };
}

function summarizeYawSeries(samples) {
  const deltas = [];
  const dts = [];
  const angularSpeeds = [];
  for (let index = 1; index < samples.length; index += 1) {
    const previous = samples[index - 1];
    const current = samples[index];
    const dtSeconds = (current.timeMs - previous.timeMs) / 1000;
    if (dtSeconds <= 0) continue;
    const delta = circularDegreesDelta(
      current.viewRotation.yawDegrees360,
      previous.viewRotation.yawDegrees360,
    );
    deltas.push(delta);
    dts.push(current.timeMs - previous.timeMs);
    angularSpeeds.push(delta / dtSeconds);
  }
  const sorted = (values) => [...values].sort((a, b) => a - b);
  const percentile = (values, fraction) => {
    if (!values.length) return null;
    const ordered = sorted(values);
    return ordered[Math.min(ordered.length - 1, Math.floor(ordered.length * fraction))];
  };

  return {
    firstTimeMs: samples[0]?.timeMs ?? null,
    lastTimeMs: samples.at(-1)?.timeMs ?? null,
    medianDtMs: round(percentile(dts, 0.5), 0),
    p90DtMs: round(percentile(dts, 0.9), 0),
    medianYawDeltaDegrees: round(percentile(deltas, 0.5)),
    p90YawDeltaDegrees: round(percentile(deltas, 0.9)),
    medianAngularSpeedDps: round(percentile(angularSpeeds, 0.5)),
    p90AngularSpeedDps: round(percentile(angularSpeeds, 0.9)),
  };
}

function openYawAlignmentForLane(firstRawYawDegrees, playerOpenSamples) {
  const transforms = ['as-read', 'negated', 'plus-90', 'minus-90', 'plus-180'];
  const transformMatches = transforms.map((transform) => {
    const transformedYaw = normalizeDegrees360(transformYaw(firstRawYawDegrees, transform));
    const bestMatches = playerOpenSamples
      .map((player) => ({
        netGuid: player.netGuid,
        archetypePath: player.archetypePath,
        openTimeMs: player.timeMs,
        openYaw: round(player.yaw),
        deltaDegrees: round(circularDegreesDelta(transformedYaw, player.yaw)),
      }))
      .sort((a, b) => a.deltaDegrees - b.deltaDegrees || a.netGuid - b.netGuid)
      .slice(0, 3);
    return {
      transform,
      transformedYawDegrees: round(normalizeDegrees180(transformedYaw)),
      transformedYawDegrees360: round(transformedYaw),
      bestMatches,
    };
  });
  const bestTransformMatch = [...transformMatches].sort(
    (a, b) =>
      (a.bestMatches[0]?.deltaDegrees ?? Infinity) -
      (b.bestMatches[0]?.deltaDegrees ?? Infinity),
  )[0];
  return { bestTransformMatch, transformMatches };
}

function buildHandle122YawSamples(diagnostics, options) {
  const samples = parseCandidateFieldSamples(diagnostics);
  const knownPlayerOpenSamples = knownPlayerOpenSamplesFromDiagnostics(diagnostics);
  const laneMap = new Map();
  let rawHandle122SampleCount = 0;
  let fullPayloadSampleCount = 0;

  for (const sample of samples) {
    if (sample.fieldHandle !== FIELD_HANDLE) continue;
    rawHandle122SampleCount += 1;
    if (!sample.hasFullPayload || sample.bitCount !== PAYLOAD_BITS) continue;
    fullPayloadSampleCount += 1;
    const prefixHex = bitsToHex(sample.buffer, 0, 32);
    if (!laneMap.has(prefixHex)) laneMap.set(prefixHex, []);
    laneMap.get(prefixHex).push(sample);
  }

  const lanes = [...laneMap.entries()]
    .map(([prefixHex, rawEntries]) => {
      const deduped = new Map();
      for (const entry of rawEntries) deduped.set(`${entry.timeMs}:${entry.payloadHex}`, entry);
      const entries = [...deduped.values()].sort(
        (a, b) => a.timeMs - b.timeMs || a.sampleIndex - b.sampleIndex,
      );
      const firstEntry = entries[0];
      const firstRawYawDegrees =
        firstEntry == null
          ? null
          : (readBitsSigned(firstEntry.buffer, YAW_BIT_OFFSET, YAW_BIT_COUNT) * 360) /
            2 ** YAW_BIT_COUNT;
      const alignment =
        firstRawYawDegrees == null
          ? { bestTransformMatch: null, transformMatches: [] }
          : openYawAlignmentForLane(firstRawYawDegrees, knownPlayerOpenSamples);
      const transform = alignment.bestTransformMatch?.transform ?? 'as-read';
      const mappedPlayer = alignment.bestTransformMatch?.bestMatches[0] ?? null;
      const yawSamples = entries.map((entry) =>
        yawSampleFromEntry(entry, transform, prefixHex, mappedPlayer?.netGuid ?? null),
      );

      return {
        prefixHex,
        fieldHandle: FIELD_HANDLE,
        payloadBitCount: PAYLOAD_BITS,
        yawEncoding: {
          bitOffset: YAW_BIT_OFFSET,
          bitCount: YAW_BIT_COUNT,
          signedScale: 'degrees = signed * 360 / 2^18',
        },
        captureCounts: {
          rawSampleCount: rawEntries.length,
          dedupedSampleCount: entries.length,
        },
        candidateIdentity: mappedPlayer
          ? {
              netGuid: mappedPlayer.netGuid,
              archetypePath: mappedPlayer.archetypePath,
              openTimeMs: mappedPlayer.openTimeMs,
              openYaw: mappedPlayer.openYaw,
              deltaDegrees: mappedPlayer.deltaDegrees,
              transform,
              confidence: mappedPlayer.deltaDegrees <= 3 ? 'open-yaw-close-match' : 'open-yaw-loose-match',
            }
          : null,
        ambiguity: {
          status:
            'Candidate identity is inferred only by comparing the first decoded yaw to channel-open yaw. Position samples are not decoded here.',
          bestOpenYawMatches: alignment.bestTransformMatch?.bestMatches ?? [],
          transformMatches: alignment.transformMatches,
        },
        seriesSummary: summarizeYawSeries(yawSamples),
        samples: yawSamples,
      };
    })
    .filter((lane) => lane.captureCounts.dedupedSampleCount >= options.minSamples)
    .sort(
      (a, b) =>
        b.captureCounts.dedupedSampleCount - a.captureCounts.dedupedSampleCount ||
        a.prefixHex.localeCompare(b.prefixHex),
    )
    .slice(0, options.maxLanes);

  const identityCounts = new Map();
  for (const lane of lanes) {
    const netGuid = lane.candidateIdentity?.netGuid;
    if (!Number.isInteger(netGuid)) continue;
    identityCounts.set(netGuid, (identityCounts.get(netGuid) ?? 0) + 1);
  }
  for (const lane of lanes) {
    const netGuid = lane.candidateIdentity?.netGuid;
    if (Number.isInteger(netGuid) && identityCounts.get(netGuid) > 1) {
      lane.candidateIdentity.confidence = 'ambiguous-open-yaw-match';
      lane.ambiguity.status =
        'Multiple handle-122 prefixes currently map to this NetGUID under first-sample open-yaw matching.';
    }
  }

  return {
    sourceLabel: 'VRF handle 122 ReplayController yaw candidates',
    kind: 'candidate-handle122-view-yaw-samples',
    coordinateSpace: 'view-rotation-only',
    mapId: options.mapId,
    notes:
      'Diagnostic extraction of high-frequency ReplayController handle 122. Samples contain decoded view yaw only; no world position or confirmed player identity is emitted.',
    decoder: {
      fieldHandle: FIELD_HANDLE,
      payloadBitCount: PAYLOAD_BITS,
      laneKey: 'first 32 payload bits',
      yawEncoding: {
        bitOffset: YAW_BIT_OFFSET,
        bitCount: YAW_BIT_COUNT,
        signedScale: 'degrees = signed * 360 / 2^18',
      },
      sampleShape:
        '{timeMs, netGuid, position:null, viewRotation:{yawDegrees,yawDegrees360,pitchDegrees:null,rollDegrees:null}}',
      dedupeKey: 'timeMs:payloadHex',
    },
    source: {
      rawPacketsScanned: diagnostics.frameSummary?.rawPacketsScanned ?? null,
      movementRpcHitCount: diagnostics.frameSummary?.movementRpcHitCount ?? null,
      replayControllerCandidateFieldSampleCount:
        diagnostics.frameSummary?.replayControllerCandidateFieldSamples?.length ?? null,
      rawHandle122SampleCount,
      fullPayloadSampleCount,
      knownPlayerOpenSampleCount: knownPlayerOpenSamples.length,
    },
    lanes,
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  if (!diagnosticsPath) {
    console.error(
      'usage: node emit_handle122_yaw_samples.mjs replay.diagnostics.json --out handle122_yaw.samples.json [--min-samples 20] [--max-lanes 20]',
    );
    process.exitCode = 1;
    return;
  }
  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const output = buildHandle122YawSamples(diagnostics, options);
  output.input = { diagnostics: diagnosticsPath };

  const outPath =
    resolveUserPath(options.out) ??
    path.resolve(
      process.env.INIT_CWD ?? process.cwd(),
      `${path.basename(diagnosticsPath, '.json')}.handle122_yaw.samples.json`,
    );
  writeJson(outPath, output);
  const sampleCount = output.lanes.reduce(
    (sum, lane) => sum + lane.captureCounts.dedupedSampleCount,
    0,
  );
  console.log(`wrote ${outPath} (${output.lanes.length} lanes, ${sampleCount} yaw samples)`);
}

main();
