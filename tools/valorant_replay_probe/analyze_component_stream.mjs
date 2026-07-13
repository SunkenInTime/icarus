#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const ASCENT_TRANSFORM = {
  xMultiplier: 0.00007,
  yMultiplier: -0.00007,
  xScalarToAdd: 0.813895,
  yScalarToAdd: 0.573242,
  minPercent: -0.08,
  maxPercent: 1.08,
  minZ: -500,
  maxZ: 900,
};

class BitReader {
  constructor(buffer, bitCount = buffer.length * 8, bitOffset = 0) {
    this.buffer = buffer;
    this.offset = bitOffset;
    this.lastBit = bitCount;
    this.isError = false;
  }

  canRead(bitCount) {
    return this.offset + bitCount <= this.lastBit;
  }

  readBit() {
    if (!this.canRead(1)) {
      this.isError = true;
      return false;
    }
    const value = (this.buffer[Math.floor(this.offset / 8)] >> (this.offset & 7)) & 1;
    this.offset += 1;
    return value === 1;
  }

  readBits(count) {
    if (count < 0 || !this.canRead(count)) {
      this.isError = true;
      return Buffer.from([]);
    }
    const result = Buffer.alloc(Math.ceil(count / 8));
    for (let i = 0; i < count; i += 1) {
      if (this.readBit()) result[Math.floor(i / 8)] |= 1 << (i & 7);
    }
    return result;
  }

  readBitsToUnsignedInt(count) {
    let value = 0;
    let currentBit = 1;
    for (let i = 0; i < count; i += 1) {
      if (this.readBit()) value |= currentBit;
      currentBit *= 2;
    }
    return value;
  }

  readSerializedInt(maxValue) {
    let value = 0;
    for (let mask = 1; value + mask < maxValue; mask *= 2) {
      if (this.readBit()) value |= mask;
    }
    return value;
  }

  readIntPacked() {
    let remaining = true;
    let value = 0;
    let index = 0;
    while (remaining && index < 5) {
      const currentByte = this.readBitsToUnsignedInt(8);
      remaining = (currentByte & 1) === 1;
      value += (currentByte >> 1) << (7 * index);
      index += 1;
    }
    if (remaining) this.isError = true;
    return value;
  }

  readPackedVector(scaleFactor) {
    const bitsAndInfo = this.readSerializedInt(1 << 7);
    const componentBits = bitsAndInfo & 63;
    const extraInfo = bitsAndInfo >> 6;
    if (componentBits <= 0 || componentBits >= 31) return null;
    const x = this.readBitsToUnsignedInt(componentBits);
    const y = this.readBitsToUnsignedInt(componentBits);
    const z = this.readBitsToUnsignedInt(componentBits);
    const signBit = 1 << (componentBits - 1);
    const vector = {
      x: (x ^ signBit) - signBit,
      y: (y ^ signBit) - signBit,
      z: (z ^ signBit) - signBit,
      componentBits,
      extraInfo,
    };
    return extraInfo
      ? {
          ...vector,
          x: vector.x / scaleFactor,
          y: vector.y / scaleFactor,
          z: vector.z / scaleFactor,
        }
      : vector;
  }
}

function parseArgs(argv) {
  const options = {
    diagnostics: null,
    assemblies: null,
    usmapSchema: null,
    out: null,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--assemblies') options.assemblies = argv[++index];
    else if (arg === '--usmap-schema') options.usmapSchema = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
  }
  return options;
}

function resolveUserPath(value) {
  if (!value) return null;
  if (path.isAbsolute(value)) return value;
  return path.resolve(process.env.INIT_CWD ?? process.cwd(), value);
}

function projectAscent(vector) {
  return {
    u: vector.y * ASCENT_TRANSFORM.xMultiplier + ASCENT_TRANSFORM.xScalarToAdd,
    v: vector.x * ASCENT_TRANSFORM.yMultiplier + ASCENT_TRANSFORM.yScalarToAdd,
  };
}

function isPlausibleAscentVector(vector) {
  const percent = projectAscent(vector);
  return (
    percent.u >= ASCENT_TRANSFORM.minPercent &&
    percent.u <= ASCENT_TRANSFORM.maxPercent &&
    percent.v >= ASCENT_TRANSFORM.minPercent &&
    percent.v <= ASCENT_TRANSFORM.maxPercent &&
    vector.z >= ASCENT_TRANSFORM.minZ &&
    vector.z <= ASCENT_TRANSFORM.maxZ &&
    (Math.abs(vector.x) >= 50 || Math.abs(vector.y) >= 50)
  );
}

function parseReplayPropertyFieldsAt(buffer, bitCount, bitOffset, skipLeadingBit) {
  const reader = new BitReader(buffer, bitCount, bitOffset);
  if (skipLeadingBit) reader.readBit();
  const fields = [];
  for (let index = 0; index < 10 && !reader.isError && reader.offset < bitCount; index += 1) {
    const rawHandle = reader.readIntPacked();
    if (rawHandle === 0) {
      fields.push({ terminator: true, rawHandle });
      break;
    }
    const handle = rawHandle - 1;
    const numBits = reader.readIntPacked();
    if (numBits < 0 || numBits > bitCount - reader.offset) {
      fields.push({ handle, rawHandle, numBits, bad: true });
      break;
    }
    fields.push({
      handle,
      rawHandle,
      numBits,
      payload: reader.readBits(numBits),
    });
  }
  return fields;
}

function findPackedVectors(payload, bitCount, maxVectors = 8) {
  const vectors = [];
  const maxOffset = Math.min(512, bitCount);
  for (let bitOffset = 0; bitOffset < maxOffset; bitOffset += 1) {
    const reader = new BitReader(payload, bitCount, bitOffset);
    const vector = reader.readPackedVector(10);
    if (reader.isError || !vector || !isPlausibleAscentVector(vector)) continue;
    const percent = projectAscent(vector);
    vectors.push({
      bitOffset,
      x: Number(vector.x.toFixed(2)),
      y: Number(vector.y.toFixed(2)),
      z: Number(vector.z.toFixed(2)),
      componentBits: vector.componentBits,
      extraInfo: vector.extraInfo,
      mapPercent: {
        u: Number(percent.u.toFixed(4)),
        v: Number(percent.v.toFixed(4)),
      },
    });
    if (vectors.length >= maxVectors) break;
  }
  return vectors;
}

function readAssemblyMeta(fileName, assemblyPath) {
  const metaPath = assemblyPath.replace(/\.bin$/i, '.json');
  if (fs.existsSync(metaPath)) return JSON.parse(fs.readFileSync(metaPath, 'utf8'));
  const match = fileName.match(/assembly(\d+)_t([\d-]+).*bits(\d+)/i);
  return {
    assemblyIndex: match ? Number(match[1]) : null,
    timeMs: match ? Number(match[2].split('-').at(-1)) : null,
    bitCount: match ? Number(match[3]) : fs.statSync(assemblyPath).size * 8,
  };
}

function analyzeAssemblies(assembliesDir) {
  if (!assembliesDir || !fs.existsSync(assembliesDir)) return [];
  const candidates = [];
  for (const fileName of fs.readdirSync(assembliesDir).filter((name) => name.endsWith('.bin'))) {
    const assemblyPath = path.join(assembliesDir, fileName);
    const meta = readAssemblyMeta(fileName, assemblyPath);
    const buffer = fs.readFileSync(assemblyPath);
    const bitCount = meta.bitCount ?? buffer.length * 8;

    for (let propertyBitOffset = 0; propertyBitOffset < Math.min(1000, bitCount); propertyBitOffset += 1) {
      for (const skipLeadingBit of [false, true]) {
        const fields = parseReplayPropertyFieldsAt(buffer, bitCount, propertyBitOffset, skipLeadingBit);
        const hasGuidField = fields.some(
          (field) => field.handle === 2 && field.numBits > 0 && field.numBits <= 160,
        );
        for (const field of fields) {
          if (![1, 3].includes(field.handle) || field.bad || field.numBits < 64 || !field.payload) {
            continue;
          }
          const vectors = findPackedVectors(field.payload, field.numBits);
          if (!vectors.length) continue;
          const score =
            (hasGuidField ? 1_000_000 : 0) +
            (field.handle === 3 ? 100_000 : 0) -
            propertyBitOffset * 100 -
            vectors[0].bitOffset * 10 +
            Math.min(20_000, Math.abs(vectors[0].x) + Math.abs(vectors[0].y));
          candidates.push({
            fileName,
            timeMs: meta.timeMs ?? meta.endMs ?? meta.startMs ?? null,
            source: meta.source ?? null,
            bitCount,
            score,
            propertyBitOffset,
            skipLeadingBit,
            hasGuidField,
            handles: fields
              .filter((fieldEntry) => fieldEntry.handle != null)
              .map((fieldEntry) => fieldEntry.handle),
            fieldHandle: field.handle,
            fieldBits: field.numBits,
            vectors,
          });
        }
      }
    }
  }
  const seen = new Set();
  return candidates
    .sort((a, b) => b.score - a.score)
    .filter((candidate) => {
      const key = [
        candidate.fileName,
        candidate.propertyBitOffset,
        candidate.skipLeadingBit,
        candidate.fieldHandle,
      ].join(':');
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .slice(0, 200);
}

function summarizeUsmapSchema(schemaPath) {
  if (!schemaPath || !fs.existsSync(schemaPath)) return null;
  const schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
  const wanted = new Set(['RemoteCharacterUpdate', 'ComponentDataStream', 'RemoteClientMovementComponent']);
  return {
    filePath: schema.filePath,
    version: schema.version,
    compression: schema.compression,
    structs: schema.structs
      .filter((struct) => wanted.has(struct.name))
      .map((struct) => ({
        name: struct.name,
        superType: struct.superType,
        propertyCount: struct.propertyCount,
        properties: struct.properties,
      })),
  };
}

function summarizeConfirmedActorOpenTransforms(diagnostics) {
  const samples = diagnostics?.frameSummary?.compactChannelOpenSamples ?? [];
  return samples
    .filter((sample) => sample.location && isPlausibleAscentVector(sample.location))
    .map((sample) => ({
      timeMs: sample.timeMs,
      chIndex: sample.chIndex,
      actorNetGuid: sample.actorNetGuid,
      archetype: sample.archetype,
      archetypePath: sample.archetypePath,
      location: sample.location,
      rotation: sample.rotation,
      mapPercent: projectAscent(sample.location),
    }));
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  const assembliesDir = resolveUserPath(options.assemblies);
  const schemaPath = resolveUserPath(options.usmapSchema);
  const outPath = resolveUserPath(options.out);

  if (!diagnosticsPath) {
    console.error(
      'usage: node analyze_component_stream.mjs --diagnostics diagnostics.json --assemblies diagnostics_assemblies --usmap-schema parsed.json --out report.json',
    );
    process.exitCode = 1;
    return;
  }

  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const candidates = analyzeAssemblies(assembliesDir);
  const report = {
    generatedAt: new Date().toISOString(),
    input: {
      diagnosticsPath,
      assembliesDir,
      schemaPath,
    },
    status:
      'ComponentDataStream is still opaque. This report ranks map-plausible packed-vector candidates; it does not prove per-player replay tracks by itself.',
    map: {
      id: diagnostics.header?.mapPath ?? null,
      bounds: ASCENT_TRANSFORM,
    },
    usmap: summarizeUsmapSchema(schemaPath),
    confirmedActorOpenTransforms: summarizeConfirmedActorOpenTransforms(diagnostics),
    candidateCounts: {
      total: candidates.length,
      strictGuidField: candidates.filter((candidate) => candidate.hasGuidField).length,
    },
    strictGuidFieldCandidates: candidates.filter((candidate) => candidate.hasGuidField).slice(0, 40),
    topCandidates: candidates.slice(0, 80),
  };

  if (outPath) writeJson(outPath, report);
  else process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exitCode = 1;
});
