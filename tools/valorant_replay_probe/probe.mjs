#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

const DEFAULT_REPLAY_DIR =
  'C:\\Users\\shawn\\AppData\\Local\\VALORANT\\Saved\\Demos';
const UNREAL_REPLAY_MAGIC = 0x2cf5a13d;
const CHUNK_TYPES = new Map([
  [0, 'HEADER'],
  [1, 'REPLAY_DATA'],
  [2, 'CHECKPOINT'],
  [3, 'EVENT'],
]);

class Cursor {
  constructor(buffer, offset = 0) {
    this.buffer = buffer;
    this.offset = offset;
  }

  remaining() {
    return this.buffer.length - this.offset;
  }

  readUInt32() {
    const value = this.buffer.readUInt32LE(this.offset);
    this.offset += 4;
    return value;
  }

  readInt32() {
    const value = this.buffer.readInt32LE(this.offset);
    this.offset += 4;
    return value;
  }

  readBytes(length) {
    const bytes = this.buffer.subarray(this.offset, this.offset + length);
    this.offset += length;
    return bytes;
  }
}

function toHex(value) {
  return `0x${value.toString(16)}`;
}

function decodeFStringAt(buffer, offset) {
  if (offset + 4 > buffer.length) return null;

  const length = buffer.readInt32LE(offset);
  const start = offset + 4;

  if (length === 0) {
    return { value: '', length, byteLength: 4, encoding: 'empty' };
  }

  if (length > 0) {
    const end = start + length;
    if (end > buffer.length || length > 1024 * 1024) return null;
    let raw = buffer.subarray(start, end);
    if (raw.length && raw[raw.length - 1] === 0) raw = raw.subarray(0, -1);
    const value = raw.toString('utf8');
    return { value, length, byteLength: 4 + length, encoding: 'utf8' };
  }

  const charCount = -length;
  const byteLength = charCount * 2;
  const end = start + byteLength;
  if (end > buffer.length || charCount > 512 * 1024) return null;
  let raw = buffer.subarray(start, end);
  if (raw.length >= 2 && raw[raw.length - 2] === 0 && raw[raw.length - 1] === 0) {
    raw = raw.subarray(0, -2);
  }
  const value = raw.toString('utf16le');
  return { value, length, byteLength: 4 + byteLength, encoding: 'utf16le' };
}

function readFString(cursor) {
  const result = decodeFStringAt(cursor.buffer, cursor.offset);
  if (!result) {
    throw new Error(`Invalid FString at ${toHex(cursor.offset)}`);
  }

  cursor.offset += result.byteLength;
  return result.value;
}

function looksPrintable(value) {
  if (!value || value.length > 2_000_000) return false;
  let printable = 0;
  for (const ch of value) {
    const code = ch.charCodeAt(0);
    if (code === 9 || code === 10 || code === 13 || (code >= 32 && code < 127)) {
      printable += 1;
    }
  }
  return printable / value.length > 0.9;
}

function scanFStrings(buffer) {
  const strings = [];
  for (let offset = 0; offset <= buffer.length - 4; offset += 1) {
    const decoded = decodeFStringAt(buffer, offset);
    if (!decoded || !looksPrintable(decoded.value)) continue;

    const value = decoded.value.trimEnd();
    if (!value) continue;
    strings.push({
      offset,
      encoding: decoded.encoding,
      length: decoded.length,
      value,
    });
  }

  return strings;
}

function findLatestReplayFile() {
  const candidates = fs
    .readdirSync(DEFAULT_REPLAY_DIR)
    .filter((name) => name.toLowerCase().endsWith('.vrf'))
    .map((name) => {
      const fullPath = path.join(DEFAULT_REPLAY_DIR, name);
      return { fullPath, mtimeMs: fs.statSync(fullPath).mtimeMs };
    })
    .sort((a, b) => b.mtimeMs - a.mtimeMs);

  if (!candidates.length) {
    throw new Error(`No .vrf files found in ${DEFAULT_REPLAY_DIR}`);
  }

  return candidates[0].fullPath;
}

function findLocalStreamOffset(buffer) {
  const maxOffset = Math.min(buffer.length - 12, 4096);
  for (let offset = 0; offset <= maxOffset; offset += 1) {
    const chunkType = buffer.readUInt32LE(offset);
    const chunkSize = buffer.readInt32LE(offset + 4);
    const dataOffset = offset + 8;
    if (
      chunkType === 0 &&
      chunkSize > 0 &&
      dataOffset + 4 <= buffer.length &&
      buffer.readUInt32LE(dataOffset) === UNREAL_REPLAY_MAGIC
    ) {
      return offset;
    }
  }

  throw new Error('Could not locate Unreal local replay chunk stream');
}

function parseWrapper(buffer) {
  const magic = buffer.readUInt32LE(0);
  const version = buffer.readUInt32LE(4);
  let replayId = null;

  const possibleReplayId = decodeFStringAt(buffer, 0x2c);
  if (possibleReplayId) replayId = possibleReplayId.value.trim();

  return {
    magic,
    version,
    replayId,
    streamOffset: findLocalStreamOffset(buffer),
  };
}

function parseChunks(buffer, streamOffset) {
  const chunks = [];
  let offset = streamOffset;

  while (offset < buffer.length) {
    if (offset + 8 > buffer.length) {
      throw new Error(`Truncated chunk header at ${toHex(offset)}`);
    }

    const type = buffer.readUInt32LE(offset);
    const size = buffer.readInt32LE(offset + 4);
    const dataOffset = offset + 8;
    const dataEnd = dataOffset + size;

    if (!CHUNK_TYPES.has(type)) {
      throw new Error(`Unknown chunk type ${type} at ${toHex(offset)}`);
    }
    if (size < 0 || dataEnd > buffer.length) {
      throw new Error(`Invalid chunk size ${size} at ${toHex(offset)}`);
    }

    chunks.push({
      index: chunks.length,
      type,
      typeName: CHUNK_TYPES.get(type),
      size,
      offset,
      dataOffset,
      dataEnd,
    });

    offset = dataEnd;
  }

  return chunks;
}

function countBy(values, keyFn) {
  const counts = new Map();
  for (const value of values) {
    const key = keyFn(value);
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return [...counts.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
}

function parseHeader(buffer, chunk) {
  const data = buffer.subarray(chunk.dataOffset, chunk.dataEnd);
  const strings = scanFStrings(data);
  const jsonStrings = strings
    .filter((entry) => entry.value.startsWith('{') || entry.value.startsWith('['))
    .map((entry) => entry.value);

  return {
    magic: data.readUInt32LE(0),
    networkVersion: data.readUInt32LE(4),
    mapPath: strings.find((entry) => entry.value.startsWith('/Game/Maps/'))?.value ?? null,
    branch: strings.find((entry) => entry.value.startsWith('++'))?.value ?? null,
    jsonSummaries: jsonStrings.map(summarizeJsonString),
    interestingStrings: strings
      .filter((entry) =>
        entry.value.startsWith('/Game/') ||
        entry.value.startsWith('/Script/') ||
        entry.value.startsWith('++') ||
        entry.value.startsWith('{'),
      )
      .slice(0, 20)
      .map((entry) => ({
        ...entry,
        value: previewValue(entry.value),
        truncated: entry.value.length > 200,
      })),
  };
}

function summarizeJsonString(value) {
  try {
    const parsed = JSON.parse(value);
    return {
      length: value.length,
      keys: Object.keys(parsed),
      playerLoadouts: Array.isArray(parsed.playerLoadouts) ? parsed.playerLoadouts.length : undefined,
      serializedVersion: parsed.serializedVersion,
    };
  } catch {
    return { length: value.length, parseError: true };
  }
}

function previewValue(value, limit = 200) {
  if (value.length <= limit) return value;
  return `${value.slice(0, limit)}...`;
}

function parseReplayDataEnvelope(buffer, chunk) {
  const cursor = new Cursor(buffer, chunk.dataOffset);
  const startMs = cursor.readUInt32();
  const endMs = cursor.readUInt32();
  const payloadSize = cursor.readUInt32();

  let compression = null;
  if (cursor.remaining() >= 12) {
    const decompressedSize = cursor.readUInt32();
    const repeatedDecompressedSize = cursor.readUInt32();
    const compressedSize = cursor.readUInt32();
    const compressedOffset = cursor.offset;

    if (
      decompressedSize === repeatedDecompressedSize &&
      compressedSize >= 0 &&
      compressedOffset + compressedSize <= chunk.dataEnd
    ) {
      compression = {
        decompressedSize,
        compressedSize,
        compressedOffset,
      };
    }
  }

  return {
    index: chunk.index,
    startMs,
    endMs,
    payloadSize,
    compression,
  };
}

function parseTimelineChunk(buffer, chunk) {
  const cursor = new Cursor(buffer, chunk.dataOffset);
  return {
    index: chunk.index,
    typeName: chunk.typeName,
    id: readFString(cursor),
    group: readFString(cursor),
    metadata: readFString(cursor),
    startMs: cursor.readUInt32(),
    endMs: cursor.readUInt32(),
    payloadSize: cursor.readUInt32(),
    payloadOffset: cursor.offset,
  };
}

async function decompressFirstReplayData(buffer, replayData) {
  const first = replayData.find((entry) => entry.compression);
  if (!first) return null;

  let ooz;
  try {
    ooz = require('ooz-wasm');
  } catch (error) {
    return {
      error: `ooz-wasm is not installed. Run: npm --prefix tools\\valorant_replay_probe install`,
    };
  }

  const { compressedOffset, compressedSize, decompressedSize } = first.compression;
  const compressed = buffer.subarray(compressedOffset, compressedOffset + compressedSize);
  const decompressed = Buffer.from(await ooz.decompressUnsafe(compressed, decompressedSize));

  return {
    replayDataIndex: first.index,
    decompressedSize: decompressed.length,
    firstBytesHex: decompressed.subarray(0, 64).toString('hex'),
    firstAscii: decompressed
      .subarray(0, 256)
      .toString('latin1')
      .replace(/[^\x20-\x7e]+/g, ' ')
      .trim(),
  };
}

function printHuman(result, options) {
  const { filePath, fileSize, wrapper, chunks, header, replayData, checkpoints, events } = result;
  const lastChunk = chunks[chunks.length - 1];

  console.log(`file: ${filePath}`);
  console.log(`size: ${fileSize} bytes`);
  console.log(`wrapper: magic=${toHex(wrapper.magic)} version=${wrapper.version}`);
  console.log(`replay id: ${wrapper.replayId ?? '(not found)'}`);
  console.log(`local replay stream: ${toHex(wrapper.streamOffset)}`);
  console.log(
    `chunks: ${chunks.length} (${countBy(chunks, (chunk) => chunk.typeName)
      .map(([type, count]) => `${type}=${count}`)
      .join(', ')})`,
  );
  console.log(`chunk end: ${toHex(lastChunk.dataEnd)}`);

  if (header) {
    console.log('');
    console.log('header:');
    console.log(`  magic: ${toHex(header.magic)}`);
    console.log(`  networkVersion: ${header.networkVersion}`);
    console.log(`  mapPath: ${header.mapPath ?? '(not found)'}`);
    console.log(`  branch: ${header.branch ?? '(not found)'}`);
    for (const summary of header.jsonSummaries) {
      console.log(`  json: ${JSON.stringify(summary)}`);
    }
  }

  if (replayData.length) {
    const first = replayData[0];
    console.log('');
    console.log(`replay data chunks: ${replayData.length}`);
    console.log(
      `  first: start=${first.startMs}ms end=${first.endMs}ms payload=${first.payloadSize}`,
    );
    if (first.compression) {
      console.log(
        `  first compression: ${first.compression.compressedSize} -> ${first.compression.decompressedSize}`,
      );
    }
  }

  console.log('');
  console.log(`checkpoints: ${checkpoints.length}`);
  console.log(`events: ${events.length}`);
  for (const [group, count] of countBy(events, (event) => event.group)) {
    console.log(`  ${group}: ${count}`);
  }

  const eventLimit = options.eventLimit;
  if (eventLimit > 0) {
    console.log('');
    console.log(`first ${Math.min(eventLimit, events.length)} events:`);
    for (const event of events.slice(0, eventLimit)) {
      console.log(
        `  ${event.startMs}ms..${event.endMs}ms ${event.group} id=${event.id} payload=${event.payloadSize}`,
      );
    }
  }
}

function parseArgs(argv) {
  const options = {
    json: false,
    decompressFirst: false,
    eventLimit: 12,
    filePath: null,
  };

  for (const arg of argv) {
    if (arg === '--json') {
      options.json = true;
    } else if (arg === '--decompress-first') {
      options.decompressFirst = true;
    } else if (arg.startsWith('--events=')) {
      options.eventLimit = Number.parseInt(arg.slice('--events='.length), 10);
    } else {
      options.filePath = arg;
    }
  }

  return options;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const filePath = options.filePath ?? findLatestReplayFile();
  const buffer = fs.readFileSync(filePath);
  const wrapper = parseWrapper(buffer);
  const chunks = parseChunks(buffer, wrapper.streamOffset);

  const headerChunk = chunks.find((chunk) => chunk.type === 0);
  const replayDataChunks = chunks.filter((chunk) => chunk.type === 1);
  const checkpointChunks = chunks.filter((chunk) => chunk.type === 2);
  const eventChunks = chunks.filter((chunk) => chunk.type === 3);

  const replayData = replayDataChunks.map((chunk) => parseReplayDataEnvelope(buffer, chunk));
  const result = {
    filePath,
    fileSize: buffer.length,
    wrapper,
    chunks,
    header: headerChunk ? parseHeader(buffer, headerChunk) : null,
    replayData,
    checkpoints: checkpointChunks.map((chunk) => parseTimelineChunk(buffer, chunk)),
    events: eventChunks.map((chunk) => parseTimelineChunk(buffer, chunk)),
  };

  if (options.decompressFirst) {
    result.firstDecompression = await decompressFirstReplayData(buffer, replayData);
  }

  if (options.json) {
    console.log(JSON.stringify(result, null, 2));
    return;
  }

  printHuman(result, options);
  if (options.decompressFirst) {
    console.log('');
    console.log('first decompression:');
    console.log(JSON.stringify(result.firstDecompression, null, 2));
  }
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exitCode = 1;
});
