#!/usr/bin/env node

import { applyValorantSeededPayloadTransform } from './valorant_seeded_payload_transform.mjs';

const cases = [
  {
    name: 'playground-backcompat-field-chain',
    payloadHex: 'BFDF6F9EA1F27BA00000C66EAFAF2E0000339C0DD34B0C45C48063038003562A43C0C949',
    expectedHex: '100CA461300F080493400100000040394E5120000000B0792C626000000080FE7F3C2000',
    payloadBits: 287,
    seed: 287 ^ 2,
    branch: null,
  },
  {
    name: 'release-12.11-replay-smoke',
    payloadHex: '1172',
    expectedHex: '4000',
    payloadBits: 15,
    seed: 13,
    branch: '++Ares-Core+release-12.11',
  },
  {
    name: 'release-13.00-replay-smoke',
    payloadHex: '7003',
    expectedHex: '4000',
    payloadBits: 15,
    seed: 13,
    branch: '++Ares-Core+release-13.00',
  },
  {
    name: 'release-13.00-replay-smoke-24bit',
    payloadHex: 'b981cb',
    expectedHex: '680900',
    payloadBits: 24,
    seed: 26,
    branch: '++Ares-Core+release-13.00',
  },
  {
    name: 'release-13.00-replay-smoke-48bit',
    payloadHex: '2ecddb7126b7',
    expectedHex: '152102100100',
    payloadBits: 48,
    seed: 50,
    branch: '++Ares-Core+release-13.00',
  },
];

for (const entry of cases) {
  const actualHex = applyValorantSeededPayloadTransform(
    Buffer.from(entry.payloadHex, 'hex'),
    entry.payloadBits,
    entry.seed,
    entry.branch,
  )
    .toString('hex')
    .toUpperCase();

  if (actualHex !== entry.expectedHex) {
    console.error(`Valorant seeded payload transform verification failed: ${entry.name}`);
    console.error(`expected ${entry.expectedHex}`);
    console.error(`actual   ${actualHex}`);
    process.exit(1);
  }
}

for (const branch of ['', '++Ares-Core+release-13.01', 'unversioned-replay-branch']) {
  try {
    applyValorantSeededPayloadTransform(Buffer.from('00', 'hex'), 8, 0, branch);
    console.error(
      `Valorant seeded payload transform verification failed: unsupported branch ${branch} did not throw`,
    );
    process.exit(1);
  } catch (error) {
    if (!/Unsupported Valorant/.test(error.message)) {
      console.error(
        `Valorant seeded payload transform verification failed: unsupported branch ${branch} produced an unactionable error`,
      );
      console.error(error);
      process.exit(1);
    }
  }
}

console.log('Valorant seeded payload transform verification passed.');
