const MASK_32 = 0xffffffff;
const MASK_64 = (1n << 64n) - 1n;
const MULTIPLIER = 0x2545f4914f6cdd1dn;
const SEED_ADDEND_V12_10 = 0x12fd0ee5;
const SEED_ADDEND_V12_11 = 0x409d36a3;
const SEED_ADDEND_V13_00 = 0x2949b6ef;
const INIT_A_OFFSET_V12_10 = 0x1b;
const INIT_A_OFFSET_V12_11 = 0x23;
const INIT_A_OFFSET_V13_00 = 0x11;
const TAIL_XOR_V12_10 = 0xe5;
const TAIL_XOR_V12_11 = 0xa3;
const TAIL_XOR_V13_00 = 0xef;

const SUBSTITUTE_TABLE_32_V13_00 = Buffer.from(
  '2167b396313fbad3d5062b16f1b651a79c7b419584251536a4703546b05fa6c3' +
    'bb8638f62ea2a994831b6239f3d228149e9af2c9decc26a1d8d0748d69127189' +
    'f758cd4db7114809b968c77cf42042f56b54756da81d6a07d7c50ea066db' +
    'f899ad1004ff8fb1ef986c29e201183d371e654b4a6e24d9bd90fe135693' +
    '34aa8b0d79e74992f98eca43cbc6da022d8c0fb2c08a4785aee0d477c40b' +
    '5c617e335745e62ffd6f915b9fcf3c4fe33aede480087372ea63fbfcb8' +
    '7a23a51f815952875dfa78c1b5beb4a3641c3253f07fdc3b7640ec309755' +
    '4c00bc880c05e1df197d22c25a9be52a50bf1ac8035e2cd1abdd44ee82' +
    'ce27afebd64e0ae9173e9de8ac60',
  'hex',
);

const SUBSTITUTE_TABLE_64_V13_00 = Buffer.from(
  '77b9042feb7d27c944739a3f36f565ddf7e0302da9985dde69a394a05e170678' +
    'a4f6ab0343c828e56a8e1cf270cf5305d30dffa7a23a32255a1f48c1' +
    'b7e16e85996047bbe48acbc01bea6164f0c2d88bcdfdadb819b5bf0e9181' +
    '839d45d249e9c731bd20bec66680d179d7e6fca15b5fdff1d0506752fe' +
    '7b3513f846b3758de33e2ef4dc342a0823e20c094beec30f248f544c' +
    '5539cc1d1e3b2272da296b41aaa6122c93ca9c970a56a87a9eb462923' +
    'd9f38f3408437b2d4af7633fa21effb716f9082511ac574f95907ba11' +
    'b1acd6ede702ae9610167c4f881426bc1501684a2b0b7fa54ee86dec4d' +
    'b05cc4009558b6d57e42db5718866cced99b89873c8c63',
  'hex',
);

const SUBSTITUTE_TABLE_8_V13_00 = Buffer.from(
  '0a6c6996cadc5a08b38339a0f9adf4560e6e4c85649982d4885c8736239a' +
    '112db8c4341866136f59e07422faa665e2d7954e94b0779e1aeee705a' +
    '2c830900d9bd219c93a471512a9291f53acaf4352aef54dbfbee34a06' +
    'd5d0a378a7d61c7a6b81d8dee568fb267ebcbae8cce4727f2cfcf0' +
    'ec28716048ef3e038f1ef16a8df2461b9c86f7b476628a10fd6d0b' +
    '3f9f2f555fc3c6921627d344840fe1808cb7738945db332550ea0414' +
    'c50c32415e79a41d3d5b4037c1cffe2b54eb9d4991f307173cda57' +
    '8bcd61f6ce702eff2193972a7d67abb57c5d0042a5d92051eddd0209' +
    'c2d1f8bdbbe93524985838aab9a8b27501cbc063df3b8ec731b1a1' +
    'b6e67b4b4f',
  'hex',
);

function u32(value) {
  return value >>> 0;
}

function u64(value) {
  return value & MASK_64;
}

function rotateLeft64(value, count) {
  const shift = BigInt(count);
  return u64((value << shift) | (value >> (64n - shift)));
}

function rotateLeft32(value, count) {
  return u32((value << count) | (value >>> (32 - count)));
}

function rotateRight64(value, count) {
  const shift = BigInt(count);
  return u64((value >> shift) | (value << (64n - shift)));
}

function rotateRight32(value, count) {
  return u32((value >>> count) | (value << (32 - count)));
}

function rotateRight8(value, count) {
  return ((value >>> count) | (value << (8 - count))) & 0xff;
}

function swapAdjacentBits64(value) {
  return u64(((value & 0x5555555555555555n) << 1n) | ((value >> 1n) & 0x5555555555555555n));
}

function swapAdjacentBits32(value) {
  return u32(((value & 0x55555555) << 1) | ((value >>> 1) & 0x55555555));
}

function swapAdjacentBits8(value) {
  return (((value & 0x55) << 1) | ((value >>> 1) & 0x55)) & 0xff;
}

function initialPrngA(seed) {
  const seedPlus = u32(seed + SEED_ADDEND_V12_10);
  const firstMix = u32(((seedPlus >>> 15) ^ seedPlus) >>> 12);
  const secondMix = Math.imul(u32(seed - INIT_A_OFFSET_V12_10), 0x02000000);
  const mixed = u32(firstMix ^ secondMix ^ seedPlus);
  return u64(BigInt(mixed) * MULTIPLIER);
}

function initialPrngAV12_11(seed) {
  const seedPlus = u32(seed + SEED_ADDEND_V12_11);
  const firstMix = u32(((seedPlus >>> 15) ^ seedPlus) >>> 12);
  const secondMix = Math.imul(u32(seed + INIT_A_OFFSET_V12_11), 0x02000000);
  const mixed = u32(firstMix ^ secondMix ^ seedPlus);
  return u64(BigInt(mixed) * MULTIPLIER);
}

function initialPrngAV13_00(seed) {
  const seedPlus = u32(seed + SEED_ADDEND_V13_00);
  const firstMix = u32(((seedPlus >>> 15) ^ seedPlus) >>> 12);
  const secondMix = Math.imul(u32(seed - INIT_A_OFFSET_V13_00), 0x02000000);
  const mixed = u32(firstMix ^ secondMix ^ seedPlus);
  return u64(BigInt(mixed) * MULTIPLIER);
}

function initialPrngB(seed) {
  const firstMix = u32(((seed >>> 15) ^ seed) >>> 12);
  const mixed = u32(firstMix ^ u32(seed << 25) ^ seed);
  return u64(BigInt(mixed) * MULTIPLIER);
}

function advanceTransformState(state, prngA, prngB) {
  const sum = u64(prngB + prngA);
  let nextPrngB = u64(prngB ^ prngA);
  const nextPrngA = u64(rotateRight64(prngA, 9) ^ u64(nextPrngB << 14n) ^ nextPrngB);
  nextPrngB = rotateLeft64(nextPrngB, 36);
  const nextState = Number((sum >> 32n) & 0xffffffffn);
  return {
    state: nextState,
    prngA: nextPrngA,
    prngB: nextPrngB,
    streamByte: nextState & 0xff,
  };
}

function transformConstants64(state) {
  const ror1 = rotateRight32(state, 1);
  const ror2 = rotateRight32(ror1, 1);
  const ror3 = rotateRight32(ror2, 1);
  const ror4 = rotateRight32(ror3, 1);
  const ror5 = rotateRight32(ror4, 1);
  const ror6 = rotateRight32(ror5, 1);
  const ror7 = rotateRight32(ror6, 1);
  const ror8 = rotateRight32(ror7, 1);
  return {
    addend1: ror4,
    addend2: ror6,
    rotate1: (ror5 % 63) + 1,
    rotate2: (ror8 % 63) + 1,
  };
}

function transformConstants32(state) {
  const rot1 = u32((state << 1) | (state >>> 31));
  const rot2 = u32((rot1 << 1) | (rot1 >>> 31));
  const rot3 = u32((rot2 << 1) | (rot2 >>> 31));
  const rot4 = u32((rot3 << 1) | (rot3 >>> 31));
  const rot5 = u32((rot4 << 1) | (rot4 >>> 31));
  const rot6 = u32((rot5 << 1) | (rot5 >>> 31));
  const rot7 = u32((rot6 << 1) | (rot6 >>> 31));
  const rot8 = u32((rot7 << 1) | (rot7 >>> 31));
  return {
    addend1: rot4,
    addend2: rot6,
    rotate1: (rot5 % 31) + 1,
    rotate2: (rot8 % 31) + 1,
  };
}

function transformConstants8(state) {
  return {
    addend1: Math.imul(state, 0x31) & 0xff,
    addend2: Math.imul(state, 0x29) & 0xff,
    rotate1: (u32(Math.imul(state, 0x2751b)) % 7) + 1,
    rotate2: (u32(Math.imul(state, 0xcc6db61)) % 7) + 1,
  };
}

function shuffleBits64V12_11(value) {
  let result = value;
  result = u64(((result & 0x5555555555555555n) << 1n) | ((result >> 1n) & 0x5555555555555555n));
  result = u64(((result & 0x3333333333333333n) << 2n) | ((result >> 2n) & 0x3333333333333333n));
  result = u64(((result & 0x0f0f0f0f0f0f0f0fn) << 4n) | ((result >> 4n) & 0x0f0f0f0f0f0f0f0fn));
  result = u64(((result & 0x00ff00ff00ff00ffn) << 8n) | ((result >> 8n) & 0x00ff00ff00ff00ffn));
  return u64((result << 32n) | (result >> 32n));
}

function reverseBits32(value) {
  let result = value;
  result = u32(((result & 0x55555555) << 1) | ((result >>> 1) & 0x55555555));
  result = u32(((result & 0x33333333) << 2) | ((result >>> 2) & 0x33333333));
  result = u32(((result & 0x0f0f0f0f) << 4) | ((result >>> 4) & 0x0f0f0f0f));
  result = u32(((result & 0x00ff00ff) << 8) | ((result >>> 8) & 0x00ff00ff));
  return u32((result << 16) | (result >>> 16));
}

function reverseBits8(value) {
  let result = value & 0xff;
  result = (((result & 0x55) << 1) | ((result >>> 1) & 0x55)) & 0xff;
  result = (((result & 0x33) << 2) | ((result >>> 2) & 0x33)) & 0xff;
  return (((result & 0x0f) << 4) | ((result >>> 4) & 0x0f)) & 0xff;
}

function substituteBytes64(value, table) {
  let result = 0n;
  for (let i = 0; i < 8; i++) {
    const index = Number((value >> BigInt(i * 8)) & 0xffn);
    result |= BigInt(table[index]) << BigInt(i * 8);
  }
  return u64(result);
}

function substituteBytes32(value, table) {
  let result = 0;
  for (let i = 0; i < 4; i++) {
    const index = (value >>> (i * 8)) & 0xff;
    result = u32(result | (table[index] << (i * 8)));
  }
  return result;
}

function resolveTransformVersion(branch) {
  // A null branch is retained only for the original transform fixture/callers.
  // Real replay headers must identify a supported release instead of silently
  // falling back to a transform that can produce plausible-looking garbage.
  if (branch == null) return 'v12_10';
  const match = /release-(\d+)\.(\d+)/i.exec(branch ?? '');
  if (!match) {
    throw new Error(
      `Unsupported Valorant replay branch "${branch}": the seeded payload transform requires an explicit release version. Supported releases are 12.10, 12.11, and 13.00.`,
    );
  }
  const major = Number(match[1]);
  const minor = Number(match[2]);
  if (major === 13 && minor === 0) return 'v13_00';
  if (major === 12 && minor === 11) return 'v12_11';
  if (major === 12 && minor === 10) return 'v12_10';
  throw new Error(
    `Unsupported Valorant seeded payload transform for release-${match[1]}.${match[2]} (${branch}). Supported releases are 12.10, 12.11, and 13.00; add and verify a branch-specific transform before decoding this replay.`,
  );
}

function applyV12_10(payload, bitCount, seed) {
  const output = Buffer.from(payload);
  let state = u32(seed);
  let streamByte = state & 0xff;
  let prngA = initialPrngA(state);
  let prngB = initialPrngB(state);
  let byteOffset = 0;
  let bitsRemaining = bitCount;

  while (bitsRemaining > 63) {
    const constants = transformConstants64(state);
    let value = output.readBigUInt64LE(byteOffset);
    value = rotateRight64(value, constants.rotate2);
    value = swapAdjacentBits64(value);
    value = u64(value - BigInt(constants.addend2));
    value = rotateRight64(value, constants.rotate1);
    value = swapAdjacentBits64(value ^ u64(~BigInt(constants.addend1)));
    output.writeBigUInt64LE(value, byteOffset);
    ({ state, prngA, prngB, streamByte } = advanceTransformState(state, prngA, prngB));
    byteOffset += 8;
    bitsRemaining -= 64;
  }

  while (bitsRemaining > 31) {
    const constants = transformConstants32(state);
    let value = output.readUInt32LE(byteOffset);
    value = rotateRight32(value, constants.rotate2);
    value = swapAdjacentBits32(value);
    value = u32(value - constants.addend2);
    value = rotateRight32(value, constants.rotate1);
    value = swapAdjacentBits32(value ^ constants.addend1);
    output.writeUInt32LE(value, byteOffset);
    ({ state, prngA, prngB, streamByte } = advanceTransformState(state, prngA, prngB));
    byteOffset += 4;
    bitsRemaining -= 32;
  }

  while (bitsRemaining > 7) {
    const constants = transformConstants8(state);
    let value = output[byteOffset];
    value = rotateRight8(value, constants.rotate2);
    value = swapAdjacentBits8(value);
    value = (value - constants.addend2) & 0xff;
    value = rotateRight8(value, constants.rotate1);
    value = swapAdjacentBits8(value ^ constants.addend1);
    output[byteOffset] = value;
    ({ state, prngA, prngB, streamByte } = advanceTransformState(state, prngA, prngB));
    byteOffset += 1;
    bitsRemaining -= 8;
  }

  if (bitsRemaining !== 0) {
    const mask = 0xff >>> (7 - ((bitCount - 1) & 7));
    output[byteOffset] ^= mask & (streamByte ^ TAIL_XOR_V12_10);
  }

  return output;
}

function applyV12_11(payload, bitCount, seed) {
  const output = Buffer.from(payload);
  let state = u32(seed);
  let streamByte = state & 0xff;
  let prngA = initialPrngAV12_11(state);
  let prngB = initialPrngB(state);
  let byteOffset = 0;
  let bitsRemaining = bitCount;

  while (bitsRemaining > 63) {
    const ror2 = rotateRight32(state, 2);
    const ror3 = rotateRight32(state, 3);
    const ror4 = rotateRight32(state, 4);
    const ror6 = rotateRight32(state, 6);
    const ror8 = rotateRight32(state, 8);
    let value = output.readBigUInt64LE(byteOffset);
    value = rotateRight64(value, (ror8 % 63) + 1);
    value = swapAdjacentBits64(value);
    value = u64(value + BigInt(ror6));
    value = shuffleBits64V12_11(value);
    value = u64(value - BigInt(ror4));
    value = u64(value - BigInt(ror3));
    value = u64(value - BigInt(ror2));
    value = swapAdjacentBits64(value);
    output.writeBigUInt64LE(value, byteOffset);
    ({ state, prngA, prngB, streamByte } = advanceTransformState(state, prngA, prngB));
    byteOffset += 8;
    bitsRemaining -= 64;
  }

  while (bitsRemaining > 31) {
    const rol2 = rotateLeft32(state, 2);
    const rol3 = rotateLeft32(state, 3);
    const rol4 = rotateLeft32(state, 4);
    const rol6 = rotateLeft32(state, 6);
    const rol8 = rotateLeft32(state, 8);
    let value = output.readUInt32LE(byteOffset);
    value = rotateRight32(value, (rol8 % 31) + 1);
    value = swapAdjacentBits32(value);
    value = u32(value + rol6);
    value = reverseBits32(value);
    value = u32(value - rol4);
    value = u32(value - rol3);
    value = u32(value - rol2);
    value = swapAdjacentBits32(value);
    output.writeUInt32LE(value, byteOffset);
    ({ state, prngA, prngB, streamByte } = advanceTransformState(state, prngA, prngB));
    byteOffset += 4;
    bitsRemaining -= 32;
  }

  while (bitsRemaining > 7) {
    const stateByte = state & 0xff;
    let value = output[byteOffset];
    value = rotateRight8(value, (u32(Math.imul(state, 0x0cc6db61)) % 7) + 1);
    value = swapAdjacentBits8(value);
    value = (value + ((stateByte * 0x29) & 0xff)) & 0xff;
    value = reverseBits8(value);
    value = (value + ((stateByte * 0x23) & 0xff)) & 0xff;
    value = swapAdjacentBits8(value);
    output[byteOffset] = value;
    ({ state, prngA, prngB, streamByte } = advanceTransformState(state, prngA, prngB));
    byteOffset += 1;
    bitsRemaining -= 8;
  }

  if (bitsRemaining !== 0) {
    const mask = 0xff >>> (7 - ((bitCount - 1) & 7));
    output[byteOffset] ^= mask & (streamByte ^ TAIL_XOR_V12_11);
  }

  return output;
}

function applyV13_00(payload, bitCount, seed) {
  const output = Buffer.from(payload);
  let state = u32(seed);
  let streamByte = state & 0xff;
  let prngA = initialPrngAV13_00(state);
  let prngB = initialPrngB(state);
  let byteOffset = 0;
  let bitsRemaining = bitCount;

  while (bitsRemaining > 63) {
    const ror1 = rotateRight32(state, 1);
    const ror3 = rotateRight32(state, 3);
    const ror6 = rotateRight32(state, 6);
    const ror8 = rotateRight32(state, 8);
    let value = output.readBigUInt64LE(byteOffset);
    value = u64(value + BigInt(ror8));
    value = shuffleBits64V12_11(value);
    value = u64((value + BigInt(ror6)) ^ BigInt(ror3));
    value = substituteBytes64(value, SUBSTITUTE_TABLE_64_V13_00);
    value = rotateRight64(value, (ror1 % 63) + 1);
    output.writeBigUInt64LE(value, byteOffset);
    ({ state, prngA, prngB, streamByte } = advanceTransformState(state, prngA, prngB));
    byteOffset += 8;
    bitsRemaining -= 64;
  }

  while (bitsRemaining > 31) {
    const rol1 = rotateLeft32(state, 1);
    const rol3 = rotateLeft32(state, 3);
    const rol6 = rotateLeft32(state, 6);
    const rol8 = rotateLeft32(state, 8);
    let value = output.readUInt32LE(byteOffset);
    value = u32(value + rol8);
    value = reverseBits32(value);
    value = u32(~u32(value + rol6) ^ rol3);
    value = substituteBytes32(value, SUBSTITUTE_TABLE_32_V13_00);
    value = rotateRight32(value, (rol1 % 31) + 1);
    output.writeUInt32LE(value, byteOffset);
    ({ state, prngA, prngB, streamByte } = advanceTransformState(state, prngA, prngB));
    byteOffset += 4;
    bitsRemaining -= 32;
  }

  while (bitsRemaining > 7) {
    const mix = u32(Math.imul(state, 0x533));
    const mixByte = mix & 0xff;
    let value = output[byteOffset];
    value = (value + ((mixByte * 0x1b) & 0xff)) & 0xff;
    value = reverseBits8(value);
    value = (~((value + ((mixByte * 0x33) & 0xff)) & 0xff) ^ mixByte) & 0xff;
    value = SUBSTITUTE_TABLE_8_V13_00[value];
    value = rotateRight8(value, (u32(Math.imul(state, 0x0b)) % 7) + 1);
    output[byteOffset] = value;
    ({ state, prngA, prngB, streamByte } = advanceTransformState(state, prngA, prngB));
    byteOffset += 1;
    bitsRemaining -= 8;
  }

  if (bitsRemaining !== 0) {
    const mask = 0xff >>> (7 - ((bitCount - 1) & 7));
    output[byteOffset] ^= mask & (streamByte ^ TAIL_XOR_V13_00);
  }

  return output;
}

export function applyValorantSeededPayloadTransform(payload, bitCount, seed, branch = null) {
  const version = resolveTransformVersion(branch);
  if (version === 'v13_00') return applyV13_00(payload, bitCount, seed);
  if (version === 'v12_11') return applyV12_11(payload, bitCount, seed);
  return applyV12_10(payload, bitCount, seed);
}
