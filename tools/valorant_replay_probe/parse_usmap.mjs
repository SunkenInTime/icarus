#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

const MAGIC = 0x30c4;

const PROPERTY_TYPES = [
  'ByteProperty',
  'BoolProperty',
  'IntProperty',
  'FloatProperty',
  'ObjectProperty',
  'NameProperty',
  'DelegateProperty',
  'DoubleProperty',
  'ArrayProperty',
  'StructProperty',
  'StrProperty',
  'TextProperty',
  'InterfaceProperty',
  'MulticastDelegateProperty',
  'WeakObjectProperty',
  'AssetObjectProperty',
  'UInt64Property',
  'UInt32Property',
  'UInt16Property',
  'Int64Property',
  'Int16Property',
  'Int8Property',
  'MapProperty',
  'SetProperty',
  'EnumProperty',
  'FieldPathProperty',
  'OptionalProperty',
  'Utf8StrProperty',
  'AnsiStrProperty',
  'ClassProperty',
  'MulticastInlineDelegateProperty',
  'SoftClassProperty',
  'VerseStringProperty',
  'VerseDynamicProperty',
  'VerseFunctionProperty',
];

const LEGACY_PROPERTY_TYPES = [
  'ByteProperty',
  'BoolProperty',
  'IntProperty',
  'FloatProperty',
  'ObjectProperty',
  'NameProperty',
  'DelegateProperty',
  'DoubleProperty',
  'ArrayProperty',
  'StructProperty',
  'StrProperty',
  'TextProperty',
  'InterfaceProperty',
  'MulticastDelegateProperty',
  'WeakObjectProperty',
  'LazyObjectProperty',
  'AssetObjectProperty',
  'SoftObjectProperty',
  'UInt64Property',
  'UInt32Property',
  'UInt16Property',
  'Int64Property',
  'Int16Property',
  'Int8Property',
  'MapProperty',
  'SetProperty',
  'EnumProperty',
  'FieldPathProperty',
];

class Cursor {
  constructor(buffer) {
    this.buffer = buffer;
    this.offset = 0;
  }

  readUInt8() {
    return this.buffer[this.offset++];
  }

  readInt32() {
    const value = this.buffer.readInt32LE(this.offset);
    this.offset += 4;
    return value;
  }

  readUInt16() {
    const value = this.buffer.readUInt16LE(this.offset);
    this.offset += 2;
    return value;
  }

  readUInt32() {
    const value = this.buffer.readUInt32LE(this.offset);
    this.offset += 4;
    return value;
  }

  readUInt64() {
    const value = this.buffer.readBigUInt64LE(this.offset);
    this.offset += 8;
    return value;
  }

  readBytes(count) {
    const value = this.buffer.subarray(this.offset, this.offset + count);
    this.offset += count;
    return value;
  }

  readName(names) {
    const index = this.readInt32();
    return index === -1 ? null : names[index];
  }
}

function readHeader(filePath) {
  const input = fs.readFileSync(filePath);
  const cursor = new Cursor(input);
  const magic = cursor.readUInt16();
  if (magic !== MAGIC) throw new Error(`${filePath} is not a .usmap file`);
  const version = cursor.readUInt8();

  let hasVersioning = false;
  if (version >= 1) {
    // FArchive serializes bools as int32 in these mapping files.
    hasVersioning = cursor.readUInt32() !== 0;
    if (hasVersioning) {
      cursor.readUInt32();
      cursor.readUInt32();
      const customVersionCount = cursor.readUInt32();
      cursor.offset += customVersionCount * 20;
      cursor.readUInt32();
    }
  }

  const compression = cursor.readUInt8();
  const compressedSize = cursor.readUInt32();
  const decompressedSize = cursor.readUInt32();
  const payload = cursor.readBytes(compressedSize);
  return { version, compression, compressedSize, decompressedSize, payload };
}

async function decompressPayload(header) {
  switch (header.compression) {
    case 0:
      return header.payload;
    case 2:
      return zlib.brotliDecompressSync(header.payload);
    case 3: {
      const { ZSTDDecoder } = require('zstddec');
      const decoder = new ZSTDDecoder();
      await decoder.init();
      return Buffer.from(decoder.decode(header.payload, header.decompressedSize));
    }
    default:
      throw new Error(`Unsupported .usmap compression method ${header.compression}`);
  }
}

function parseType(cursor, names, version) {
  const typeId = cursor.readUInt8();
  const propertyTypes = version <= 3 ? LEGACY_PROPERTY_TYPES : PROPERTY_TYPES;
  const type = {
    type: propertyTypes[typeId] ?? `Unknown(${typeId})`,
  };
  switch (type.type) {
    case 'EnumProperty':
      type.innerType = parseType(cursor, names, version);
      type.enumName = cursor.readName(names);
      break;
    case 'StructProperty':
      type.structType = cursor.readName(names);
      break;
    case 'SetProperty':
    case 'ArrayProperty':
    case 'OptionalProperty':
      type.innerType = parseType(cursor, names, version);
      break;
    case 'MapProperty':
      type.innerType = parseType(cursor, names, version);
      type.valueType = parseType(cursor, names, version);
      break;
    default:
      break;
  }
  return type;
}

async function parseUsmap(filePath) {
  const header = readHeader(filePath);
  const cursor = new Cursor(await decompressPayload(header));
  const nameCount = cursor.readUInt32();
  const names = [];
  for (let i = 0; i < nameCount; i += 1) {
    const length = header.version >= 2 ? cursor.readUInt16() : cursor.readUInt8();
    names.push(cursor.readBytes(length).toString('utf8'));
  }

  const enumCount = cursor.readUInt32();
  const enums = [];
  for (let i = 0; i < enumCount; i += 1) {
    const name = cursor.readName(names);
    const valueCount = header.version >= 3 ? cursor.readUInt16() : cursor.readUInt8();
    const values = [];
    for (let j = 0; j < valueCount; j += 1) {
      if (header.version >= 4) {
        values.push({ value: cursor.readUInt64().toString(), name: cursor.readName(names) });
      } else {
        values.push({ value: j, name: cursor.readName(names) });
      }
    }
    enums.push({ name, values });
  }

  const structCount = cursor.readUInt32();
  const structs = [];
  for (let i = 0; i < structCount; i += 1) {
    const name = cursor.readName(names);
    const superType = cursor.readName(names);
    const propertyCount = cursor.readUInt16();
    const serializablePropertyCount = cursor.readUInt16();
    const properties = [];
    for (let j = 0; j < serializablePropertyCount; j += 1) {
      const index = cursor.readUInt16();
      const arraySize = cursor.readUInt8();
      const propertyName = cursor.readName(names);
      const propertyType = parseType(cursor, names, header.version);
      for (let arrayIndex = 0; arrayIndex < arraySize; arrayIndex += 1) {
        properties.push({
          index: index + arrayIndex,
          name: propertyName,
          arrayIndex,
          type: propertyType,
        });
      }
    }
    structs.push({ name, superType, propertyCount, properties });
  }

  return {
    filePath,
    version: header.version,
    compression: header.compression,
    nameCount,
    enumCount,
    structCount,
    structs,
    enums,
  };
}

function matchesQuery(struct, query) {
  if (!query) return true;
  const haystack = [
    struct.name,
    struct.superType,
    ...struct.properties.flatMap((property) => [
      property.name,
      property.type.type,
      property.type.structType,
      property.type.enumName,
      property.type.innerType?.type,
      property.type.innerType?.structType,
    ]),
  ]
    .filter(Boolean)
    .join('\n')
    .toLowerCase();
  return query.every((term) => haystack.includes(term.toLowerCase()));
}

async function main() {
  const args = process.argv.slice(2);
  const input = args.find((arg) => !arg.startsWith('--'));
  if (!input) {
    console.error('usage: node parse_usmap.mjs <Mappings.usmap> [--query Replay,ComponentDataStream] [--out out.json]');
    process.exitCode = 1;
    return;
  }
  const queryArg = args.find((arg) => arg.startsWith('--query='));
  const query = queryArg
    ? queryArg
        .slice('--query='.length)
        .split(',')
        .map((term) => term.trim())
        .filter(Boolean)
    : [];
  const outIndex = args.indexOf('--out');
  const out = outIndex >= 0 ? args[outIndex + 1] : null;
  const parsed = await parseUsmap(input);
  const result = {
    ...parsed,
    structs: parsed.structs.filter((struct) => matchesQuery(struct, query)),
  };
  const json = `${JSON.stringify(result, null, 2)}\n`;
  if (out) {
    fs.mkdirSync(path.dirname(path.resolve(out)), { recursive: true });
    fs.writeFileSync(out, json);
  } else {
    process.stdout.write(json);
  }
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exitCode = 1;
});
