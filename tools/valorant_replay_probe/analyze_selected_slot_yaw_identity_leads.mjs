#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const DEFAULT_BIT_WIDTHS = [8, 10, 12, 13, 14, 15, 16, 18, 20, 24];
const YAW_TRANSFORMS = ['as-read', 'negated', 'plus-90', 'minus-90', 'plus-180'];
const YAW_ENCODINGS = ['unsigned360', 'signed360'];
const PACKED_VECTOR_HEADER_BITS = 7;

function parseArgs(argv) {
  const options = {
    diagnostics: null,
    decoderReport: null,
    yawSamples: null,
    out: null,
    bitWidths: DEFAULT_BIT_WIDTHS,
    maxYawDeltaMs: 64,
    minSamples: 40,
    minUniqueValues: 12,
    minHandle122Matches: 12,
    minHandle122ComparedRate: 0.35,
    minHandle122Within15Rate: 0.45,
    maxHandle122P90AngleDeltaDegrees: 35,
    maxP90YawStepDegrees: 75,
    maxP90AngularSpeedDps: 900,
    maxCandidatesPerFamily: 50,
    maxLanesPerCandidate: 8,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--decoder-report') options.decoderReport = argv[++index];
    else if (arg === '--yaw-samples') options.yawSamples = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--bit-widths') {
      options.bitWidths = argv[++index].split(',').map(Number).filter(Number.isFinite);
    } else if (arg === '--max-yaw-delta-ms') {
      options.maxYawDeltaMs = Number(argv[++index]);
    } else if (arg === '--min-samples') {
      options.minSamples = Number(argv[++index]);
    } else if (arg === '--min-unique-values') {
      options.minUniqueValues = Number(argv[++index]);
    } else if (arg === '--min-handle122-matches') {
      options.minHandle122Matches = Number(argv[++index]);
    } else if (arg === '--min-handle122-compared-rate') {
      options.minHandle122ComparedRate = Number(argv[++index]);
    } else if (arg === '--min-handle122-within15-rate') {
      options.minHandle122Within15Rate = Number(argv[++index]);
    } else if (arg === '--max-handle122-p90-angle-delta-degrees') {
      options.maxHandle122P90AngleDeltaDegrees = Number(argv[++index]);
    } else if (arg === '--max-p90-yaw-step-degrees') {
      options.maxP90YawStepDegrees = Number(argv[++index]);
    } else if (arg === '--max-p90-angular-speed-dps') {
      options.maxP90AngularSpeedDps = Number(argv[++index]);
    } else if (arg === '--max-candidates-per-family') {
      options.maxCandidatesPerFamily = Number(argv[++index]);
    } else if (arg === '--max-lanes-per-candidate') {
      options.maxLanesPerCandidate = Number(argv[++index]);
    }
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

function round(value, digits = 3) {
  if (value == null || !Number.isFinite(value)) return null;
  return Number(value.toFixed(digits));
}

function percentile(values, fraction) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.max(0, Math.floor(sorted.length * fraction)));
  return sorted[index];
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
    .filter((sample) => sample.hasFullPayload)
    .sort((a, b) => a.timeMs - b.timeMs || a.sampleIndex - b.sampleIndex);
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
    .filter((sample) => Number.isInteger(sample.netGuid))
    .sort((a, b) => a.chIndex - b.chIndex || a.netGuid - b.netGuid);
}

function selectedFamilyEntries(decoderReport) {
  return (decoderReport.familyReports ?? [])
    .map((entry) => {
      const family = entry.family;
      if (!family) return null;
      return {
        fieldHandle: family.fieldHandle,
        payloadBitCount: family.payloadBitCount,
        prefixHex: family.prefixHex,
        slotIndex: family.slotIndex,
        slotNetGuid: family.slotNetGuid,
        slotChIndex: family.slotChIndex,
        headerBits: family.headerBits,
        recordBits: family.recordBits,
        relativeOffset: family.relativeOffset,
        absoluteOffset: family.absoluteOffset,
        scaleFactor: family.scaleFactor,
        componentBits: family.componentBits,
        extraInfo: family.extraInfo,
        identityLeads: entry.identity?.targetSlotSameIdentityHits ?? [],
      };
    })
    .filter(Boolean);
}

function samplesForFamily(samples, family) {
  return samples.filter(
    (sample) =>
      sample.fieldHandle === family.fieldHandle &&
      sample.bitCount === family.payloadBitCount &&
      bitsToHex(sample.buffer, 0, Math.min(32, sample.bitCount)) === family.prefixHex,
  );
}

function loadYawLanes(yawSamplesPath) {
  if (!yawSamplesPath) return [];
  const yawReport = JSON.parse(fs.readFileSync(yawSamplesPath, 'utf8'));
  return (yawReport.lanes ?? [])
    .map((lane) => ({
      prefixHex: lane.prefixHex,
      fieldHandle: lane.fieldHandle ?? 122,
      payloadBitCount: lane.payloadBitCount ?? 92,
      candidateIdentity: lane.candidateIdentity ?? null,
      samples: (lane.samples ?? [])
        .map((sample) => {
          const yawDegrees =
            sample.viewRotation?.yawDegrees360 ?? sample.viewRotation?.yawDegrees ?? null;
          if (!Number.isFinite(yawDegrees)) return null;
          return {
            timeMs: sample.timeMs,
            yawDegrees360: normalizeDegrees360(yawDegrees),
            yawDegrees: normalizeDegrees180(yawDegrees),
          };
        })
        .filter(Boolean)
        .sort((a, b) => a.timeMs - b.timeMs),
    }))
    .filter((lane) => lane.samples.length > 0);
}

function nearestByTime(rows, targetTimeMs) {
  if (!rows?.length) return null;
  let low = 0;
  let high = rows.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (rows[middle].timeMs < targetTimeMs) low = middle + 1;
    else high = middle;
  }
  let best = null;
  for (const index of [low - 1, low]) {
    if (index < 0 || index >= rows.length) continue;
    const deltaMs = Math.abs(rows[index].timeMs - targetTimeMs);
    if (!best || deltaMs < best.deltaMs) best = { row: rows[index], deltaMs };
  }
  return best;
}

function decodeRawYawDegrees(sample, absoluteOffset, bitWidth, encoding) {
  if (absoluteOffset + bitWidth > sample.bitCount) return null;
  if (encoding === 'unsigned360') {
    return (readBitsUnsigned(sample.buffer, absoluteOffset, bitWidth) * 360) / 2 ** bitWidth;
  }
  if (encoding === 'signed360') {
    return (readBitsSigned(sample.buffer, absoluteOffset, bitWidth) * 360) / 2 ** bitWidth;
  }
  throw new Error(`unknown yaw encoding: ${encoding}`);
}

function buildYawRows(groupSamples, recordStart, relativeOffset, bitWidth, encoding, transform) {
  return groupSamples
    .map((sample) => {
      const absoluteOffset = recordStart + relativeOffset;
      const rawYawDegrees = decodeRawYawDegrees(sample, absoluteOffset, bitWidth, encoding);
      if (!Number.isFinite(rawYawDegrees)) return null;
      const yawDegrees = normalizeDegrees360(transformYaw(rawYawDegrees, transform));
      const rawUnsigned = readBitsUnsigned(sample.buffer, absoluteOffset, bitWidth);
      const rawSigned = readBitsSigned(sample.buffer, absoluteOffset, bitWidth);
      return {
        timeMs: sample.timeMs,
        sampleIndex: sample.sampleIndex,
        rawUnsigned,
        rawSigned,
        yawDegrees360: yawDegrees,
        yawDegrees: normalizeDegrees180(yawDegrees),
      };
    })
    .filter(Boolean)
    .sort((a, b) => a.timeMs - b.timeMs || a.sampleIndex - b.sampleIndex);
}

function summarizeYawRows(rows, slotOpenSample) {
  const ordered = [...rows].sort((a, b) => a.timeMs - b.timeMs || a.sampleIndex - b.sampleIndex);
  const uniqueRawValues = new Set(ordered.map((row) => row.rawUnsigned));
  const uniqueYawValues = new Set(ordered.map((row) => Math.round(row.yawDegrees360 * 10)));
  const dts = [];
  const yawSteps = [];
  const angularSpeeds = [];
  let sameTimeConflictCount = 0;
  const byTime = new Map();

  for (const row of ordered) {
    const yawKey = Math.round(row.yawDegrees360 * 1000);
    if (byTime.has(row.timeMs) && byTime.get(row.timeMs) !== yawKey) sameTimeConflictCount += 1;
    byTime.set(row.timeMs, yawKey);
  }

  for (let index = 1; index < ordered.length; index += 1) {
    const previous = ordered[index - 1];
    const current = ordered[index];
    const dtMs = current.timeMs - previous.timeMs;
    if (dtMs <= 0) continue;
    dts.push(dtMs);
    if (dtMs <= 250) {
      const step = circularDegreesDelta(current.yawDegrees360, previous.yawDegrees360);
      yawSteps.push(step);
      angularSpeeds.push(step / (dtMs / 1000));
    }
  }

  const first = ordered[0] ?? null;
  const openYawDelta =
    first && Number.isFinite(slotOpenSample?.yaw)
      ? circularDegreesDelta(first.yawDegrees360, slotOpenSample.yaw)
      : null;

  return {
    count: ordered.length,
    firstTimeMs: first?.timeMs ?? null,
    lastTimeMs: ordered.at(-1)?.timeMs ?? null,
    activeSpanMs: ordered.length ? ordered.at(-1).timeMs - first.timeMs : 0,
    uniqueRawValueCount: uniqueRawValues.size,
    uniqueYawValueCount: uniqueYawValues.size,
    sameTimeConflictCount,
    openYawDeltaDegrees: round(openYawDelta),
    openYaw:
      Number.isFinite(slotOpenSample?.yaw)
        ? {
            netGuid: slotOpenSample.netGuid,
            chIndex: slotOpenSample.chIndex,
            yaw: round(slotOpenSample.yaw),
          }
        : null,
    medianDtMs: round(percentile(dts, 0.5), 0),
    p90DtMs: round(percentile(dts, 0.9), 0),
    adjacentStepCount: yawSteps.length,
    medianYawStepDegrees: round(percentile(yawSteps, 0.5)),
    p90YawStepDegrees: round(percentile(yawSteps, 0.9)),
    maxYawStepDegrees: round(yawSteps.length ? Math.max(...yawSteps) : null),
    medianAngularSpeedDps: round(percentile(angularSpeeds, 0.5)),
    p90AngularSpeedDps: round(percentile(angularSpeeds, 0.9)),
    maxAngularSpeedDps: round(angularSpeeds.length ? Math.max(...angularSpeeds) : null),
    samples: ordered.slice(0, 6).map((row) => ({
      timeMs: row.timeMs,
      rawUnsigned: row.rawUnsigned,
      rawSigned: row.rawSigned,
      yawDegrees: round(row.yawDegrees),
      yawDegrees360: round(row.yawDegrees360),
    })),
  };
}

function compareRowsToYawLane(rows, lane, options) {
  const angleDeltas = [];
  const timeDeltas = [];
  for (const row of rows) {
    const nearest = nearestByTime(lane.samples, row.timeMs);
    if (!nearest || nearest.deltaMs > options.maxYawDeltaMs) continue;
    timeDeltas.push(nearest.deltaMs);
    angleDeltas.push(circularDegreesDelta(row.yawDegrees360, nearest.row.yawDegrees360));
  }
  const comparedCount = angleDeltas.length;
  return {
    prefixHex: lane.prefixHex,
    candidateIdentity: lane.candidateIdentity,
    comparedCount,
    comparedRate: rows.length ? round(comparedCount / rows.length) : 0,
    within5Count: angleDeltas.filter((value) => value <= 5).length,
    within10Count: angleDeltas.filter((value) => value <= 10).length,
    within15Count: angleDeltas.filter((value) => value <= 15).length,
    within30Count: angleDeltas.filter((value) => value <= 30).length,
    within5Rate: comparedCount
      ? round(angleDeltas.filter((value) => value <= 5).length / comparedCount)
      : 0,
    within10Rate: comparedCount
      ? round(angleDeltas.filter((value) => value <= 10).length / comparedCount)
      : 0,
    within15Rate: comparedCount
      ? round(angleDeltas.filter((value) => value <= 15).length / comparedCount)
      : 0,
    within30Rate: comparedCount
      ? round(angleDeltas.filter((value) => value <= 30).length / comparedCount)
      : 0,
    angleDeltaDegrees: angleDeltas.length
      ? {
          median: round(percentile(angleDeltas, 0.5)),
          p90: round(percentile(angleDeltas, 0.9)),
          max: round(Math.max(...angleDeltas)),
        }
      : null,
    timeDeltaMs: timeDeltas.length
      ? {
          median: round(percentile(timeDeltas, 0.5), 0),
          p90: round(percentile(timeDeltas, 0.9), 0),
          max: round(Math.max(...timeDeltas), 0),
        }
      : null,
  };
}

function compareRowsToYawLanes(rows, family, yawLanes, options) {
  const laneComparisons = yawLanes
    .map((lane) => ({
      ...compareRowsToYawLane(rows, lane, options),
      sameNetGuid: lane.candidateIdentity?.netGuid === family.slotNetGuid,
      sameChIndex: lane.candidateIdentity?.chIndex === family.slotChIndex,
    }))
    .filter((entry) => entry.comparedCount > 0);
  const sortLane = (a, b) =>
    Number(b.sameNetGuid) - Number(a.sameNetGuid) ||
    b.within15Rate - a.within15Rate ||
    b.within5Rate - a.within5Rate ||
    b.comparedCount - a.comparedCount ||
    (a.angleDeltaDegrees?.median ?? Infinity) - (b.angleDeltaDegrees?.median ?? Infinity);
  const sameNetGuid = laneComparisons
    .filter((entry) => entry.sameNetGuid)
    .sort(sortLane);
  const anyNetGuid = [...laneComparisons].sort(sortLane);
  const bestSame = sameNetGuid[0] ?? null;
  const bestAny = anyNetGuid[0] ?? null;
  const bestScore = bestSame?.within15Rate ?? 0;
  const ambiguousComparableLaneCount = laneComparisons.filter(
    (entry) =>
      entry.comparedCount >= options.minHandle122Matches &&
      entry.within15Rate >= Math.max(0, bestScore - 0.05),
  ).length;
  return {
    bestSameNetGuidLane: bestSame,
    bestAnyLane: bestAny,
    sameNetGuidLaneCount: sameNetGuid.length,
    comparedLaneCount: laneComparisons.length,
    ambiguousComparableLaneCount,
    topLanes: anyNetGuid.slice(0, options.maxLanesPerCandidate),
  };
}

function selectedVectorRange(family) {
  return {
    start: family.relativeOffset,
    end: family.relativeOffset + PACKED_VECTOR_HEADER_BITS + family.componentBits * 3,
  };
}

function offsetRole(relativeOffset, bitWidth, family) {
  const range = selectedVectorRange(family);
  const end = relativeOffset + bitWidth;
  if (end <= range.start) return 'before-selected-vector';
  if (relativeOffset >= range.end) return 'after-selected-vector';
  return 'overlaps-selected-vector';
}

function yawLeadRejectionReasons(candidate, options) {
  const reasons = [];
  const bestSame = candidate.handle122.bestSameNetGuidLane;
  if (candidate.role === 'overlaps-selected-vector') {
    reasons.push('overlaps-selected-packed-vector');
  }
  if (candidate.summary.count < options.minSamples) reasons.push('too-few-samples');
  if (candidate.summary.uniqueRawValueCount < options.minUniqueValues) {
    reasons.push('too-few-unique-values');
  }
  if (candidate.summary.sameTimeConflictCount > 0) reasons.push('same-time-yaw-conflicts');
  if (
    candidate.summary.p90YawStepDegrees == null ||
    candidate.summary.p90YawStepDegrees > options.maxP90YawStepDegrees
  ) {
    reasons.push('jumpy-or-missing-p90-yaw-step');
  }
  if (
    candidate.summary.p90AngularSpeedDps == null ||
    candidate.summary.p90AngularSpeedDps > options.maxP90AngularSpeedDps
  ) {
    reasons.push('high-or-missing-p90-angular-speed');
  }
  if (!bestSame || bestSame.comparedCount < options.minHandle122Matches) {
    reasons.push('too-few-same-netguid-handle122-matches');
  } else if (bestSame.comparedRate < options.minHandle122ComparedRate) {
    reasons.push('low-same-netguid-handle122-temporal-coverage');
  } else if (bestSame.within15Rate < options.minHandle122Within15Rate) {
    reasons.push('low-same-netguid-handle122-yaw-agreement');
  } else if (
    bestSame.angleDeltaDegrees?.p90 == null ||
    bestSame.angleDeltaDegrees.p90 > options.maxHandle122P90AngleDeltaDegrees
  ) {
    reasons.push('high-or-missing-same-netguid-handle122-p90-angle-delta');
  }
  if (
    candidate.handle122.bestAnyLane &&
    bestSame &&
    candidate.handle122.bestAnyLane.candidateIdentity?.netGuid !== bestSame.candidateIdentity?.netGuid &&
    candidate.handle122.bestAnyLane.within15Rate > bestSame.within15Rate + 0.05
  ) {
    reasons.push('better-handle122-match-belongs-to-different-netguid');
  }
  return reasons;
}

function promotionRejectionReasons(candidate) {
  const reasons = [];
  if (!candidate.passesYawLeadGate) reasons.push('yaw-lead-gate-failed');
  reasons.push('handle122-identity-is-open-yaw-inferred');
  reasons.push('position-transform-is-still-diagnostic-integration-lead');
  return reasons;
}

function analyzeCandidate(groupSamples, family, yawLanes, slotOpenSample, spec, options) {
  const recordStart = family.headerBits + family.slotIndex * family.recordBits;
  const rows = buildYawRows(
    groupSamples,
    recordStart,
    spec.relativeOffset,
    spec.bitWidth,
    spec.encoding,
    spec.transform,
  );
  const summary = summarizeYawRows(rows, slotOpenSample);
  if (summary.uniqueRawValueCount < options.minUniqueValues) return null;
  const handle122 = compareRowsToYawLanes(rows, family, yawLanes, options);
  const candidate = {
    relativeOffset: spec.relativeOffset,
    absoluteOffset: recordStart + spec.relativeOffset,
    bitWidth: spec.bitWidth,
    encoding: spec.encoding,
    transform: spec.transform,
    role: offsetRole(spec.relativeOffset, spec.bitWidth, family),
    summary,
    handle122,
  };
  const rejectionReasons = yawLeadRejectionReasons(candidate, options);
  candidate.passesYawLeadGate = rejectionReasons.length === 0;
  candidate.rejectionReasons = rejectionReasons;
  candidate.passesReplayTrackPromotionGate = false;
  candidate.promotionRejectionReasons = promotionRejectionReasons(candidate);
  return candidate;
}

function candidateSort(a, b) {
  const aSame = a.handle122.bestSameNetGuidLane;
  const bSame = b.handle122.bestSameNetGuidLane;
  const aAny = a.handle122.bestAnyLane;
  const bAny = b.handle122.bestAnyLane;
  return (
    Number(b.passesReplayTrackPromotionGate) - Number(a.passesReplayTrackPromotionGate) ||
    Number(b.passesYawLeadGate) - Number(a.passesYawLeadGate) ||
    Number(a.role === 'overlaps-selected-vector') - Number(b.role === 'overlaps-selected-vector') ||
    (bSame?.comparedRate ?? 0) - (aSame?.comparedRate ?? 0) ||
    (bSame?.within15Rate ?? 0) - (aSame?.within15Rate ?? 0) ||
    (bSame?.within5Rate ?? 0) - (aSame?.within5Rate ?? 0) ||
    (bSame?.comparedCount ?? 0) - (aSame?.comparedCount ?? 0) ||
    (bAny?.within15Rate ?? 0) - (aAny?.within15Rate ?? 0) ||
    (a.summary.p90YawStepDegrees ?? Infinity) - (b.summary.p90YawStepDegrees ?? Infinity) ||
    (a.summary.p90AngularSpeedDps ?? Infinity) - (b.summary.p90AngularSpeedDps ?? Infinity) ||
    a.relativeOffset - b.relativeOffset ||
    a.bitWidth - b.bitWidth
  );
}

function analyzeFamily(family, samples, players, yawLanes, options) {
  const groupSamples = samplesForFamily(samples, family);
  const slotOpenSample = players[family.slotIndex] ?? null;
  const specs = [];
  for (const bitWidth of options.bitWidths) {
    for (let relativeOffset = 0; relativeOffset + bitWidth <= family.recordBits; relativeOffset += 1) {
      for (const encoding of YAW_ENCODINGS) {
        for (const transform of YAW_TRANSFORMS) {
          specs.push({ relativeOffset, bitWidth, encoding, transform });
        }
      }
    }
  }
  const candidates = specs
    .map((spec) => analyzeCandidate(groupSamples, family, yawLanes, slotOpenSample, spec, options))
    .filter(Boolean)
    .sort(candidateSort);
  const yawLeads = candidates.filter((candidate) => candidate.passesYawLeadGate);
  const promotable = candidates.filter((candidate) => candidate.passesReplayTrackPromotionGate);
  return {
    family,
    groupSampleCount: groupSamples.length,
    slotOpenSample,
    identityLeads: family.identityLeads.slice(0, 8),
    status:
      promotable.length > 0
        ? 'selected slot record has replay-track promotable yaw/identity candidates'
        : yawLeads.length > 0
          ? 'selected slot record has yaw-shaped same-NetGUID handle122 leads, but none are promotable'
          : 'selected slot record has no scalar yaw field passing same-NetGUID handle122 gates',
    yawLeadCount: yawLeads.length,
    replayTrackPromotableCount: promotable.length,
    yawLeads: yawLeads.slice(0, options.maxCandidatesPerFamily),
    promotableCandidates: promotable.slice(0, options.maxCandidatesPerFamily),
    bestRejectedCandidates: candidates
      .filter((candidate) => !candidate.passesYawLeadGate)
      .slice(0, options.maxCandidatesPerFamily),
  };
}

function buildConclusions(familyReports) {
  const conclusions = [];
  const yawLeadCount = familyReports.reduce((sum, report) => sum + report.yawLeadCount, 0);
  const promotableCount = familyReports.reduce(
    (sum, report) => sum + report.replayTrackPromotableCount,
    0,
  );
  conclusions.push(
    yawLeadCount > 0
      ? `${yawLeadCount} scalar yaw candidates passed same-NetGUID handle-122 agreement gates, but ${promotableCount} are replay-track promotable.`
      : 'No selected h24/h100 target-slot scalar yaw field passed the same-NetGUID handle-122 agreement gates.',
  );
  for (const report of familyReports) {
    const best = report.yawLeads[0] ?? report.bestRejectedCandidates[0];
    if (!best) continue;
    const same = best.handle122.bestSameNetGuidLane;
    conclusions.push(
      `${report.family.fieldHandle}/${report.family.prefixHex} best ${best.passesYawLeadGate ? 'lead' : 'rejected'} rel=${best.relativeOffset} width=${best.bitWidth} ${best.encoding}/${best.transform} role=${best.role} same-NetGUID within15=${same?.within15Rate ?? 0} compared=${same?.comparedCount ?? 0} p90Step=${best.summary.p90YawStepDegrees}.`,
    );
  }
  conclusions.push(
    'The decoder still needs a native, non-ambiguous yaw/identity association before selected-slot position integrations can be emitted as replay tracks.',
  );
  return conclusions;
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  const decoderReportPath = resolveUserPath(options.decoderReport);
  const yawSamplesPath = resolveUserPath(options.yawSamples);
  if (!diagnosticsPath || !decoderReportPath) {
    console.error(
      'usage: node analyze_selected_slot_yaw_identity_leads.mjs --diagnostics replay.diagnostics.json --decoder-report decoder_leads.report.json [--yaw-samples handle122_yaw.samples.json] --out yaw_identity_leads.report.json',
    );
    process.exitCode = 1;
    return;
  }

  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const decoderReport = JSON.parse(fs.readFileSync(decoderReportPath, 'utf8'));
  const samples = parseCandidateFieldSamples(diagnostics);
  const players = knownPlayerOpenSamplesFromDiagnostics(diagnostics);
  const families = selectedFamilyEntries(decoderReport);
  const yawLanes = loadYawLanes(yawSamplesPath);
  const familyReports = families.map((family) =>
    analyzeFamily(family, samples, players, yawLanes, options),
  );
  const yawLeadCount = familyReports.reduce((sum, report) => sum + report.yawLeadCount, 0);
  const replayTrackPromotableCount = familyReports.reduce(
    (sum, report) => sum + report.replayTrackPromotableCount,
    0,
  );

  const report = {
    generatedAt: new Date().toISOString(),
    input: {
      diagnostics: diagnosticsPath,
      decoderReport: decoderReportPath,
      yawSamples: yawSamplesPath,
    },
    options: {
      bitWidths: options.bitWidths,
      yawEncodings: YAW_ENCODINGS,
      yawTransforms: YAW_TRANSFORMS,
      maxYawDeltaMs: options.maxYawDeltaMs,
      minSamples: options.minSamples,
      minUniqueValues: options.minUniqueValues,
      minHandle122Matches: options.minHandle122Matches,
      minHandle122ComparedRate: options.minHandle122ComparedRate,
      minHandle122Within15Rate: options.minHandle122Within15Rate,
      maxHandle122P90AngleDeltaDegrees: options.maxHandle122P90AngleDeltaDegrees,
      maxP90YawStepDegrees: options.maxP90YawStepDegrees,
      maxP90AngularSpeedDps: options.maxP90AngularSpeedDps,
      maxCandidatesPerFamily: options.maxCandidatesPerFamily,
      maxLanesPerCandidate: options.maxLanesPerCandidate,
    },
    notes: [
      'This scans scalar bit fields inside the selected h24/h100 target slot records for yaw-like encodings.',
      'Candidates are scored against nearby handle-122 yaw lanes, but handle-122 lane identity is still open-yaw inferred and can be ambiguous.',
      'A yaw lead is not replay-track promotable until position integration, NetGUID identity, and view-yaw identity are all native and non-ambiguous.',
    ],
    source: {
      candidateFieldSampleCount: samples.length,
      selectedFamilyCount: families.length,
      playerReferenceCount: players.length,
      yawLaneCount: yawLanes.length,
      players,
      yawLanes: yawLanes.map((lane) => ({
        prefixHex: lane.prefixHex,
        sampleCount: lane.samples.length,
        candidateIdentity: lane.candidateIdentity,
      })),
    },
    status:
      replayTrackPromotableCount > 0
        ? 'selected slot records include replay-track promotable yaw/identity candidates; inspect before emission'
        : yawLeadCount > 0
          ? 'selected slot records include scalar yaw leads, but none are replay-track promotable'
          : 'selected slot records have no scalar yaw field passing same-NetGUID handle122 agreement gates',
    yawLeadCount,
    replayTrackPromotableCount,
    conclusions: buildConclusions(familyReports),
    familyReports,
  };

  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);

  console.error(
    `analyzed ${familyReports.length} selected families; yawLeads=${yawLeadCount}; promotable=${replayTrackPromotableCount}`,
  );
}

main();
