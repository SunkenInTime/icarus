// Checks that every JS member the web Convex binding declares exists in the
// Convex browser bundle the web build ships.
//
// lib/collab/src/convex_client_web.dart binds the bundle through
// `dart:js_interop` extension types. A member the bundle lacks compiles fine
// and only throws at runtime in the browser (a web build once called
// `clearAuth` on the browser ConvexClient, which has none). This script reads
// the `external` members from the Dart source, builds a real ConvexClient from
// web/convex.browser.bundle.js over a stub WebSocket (no network), and fails
// if any member is missing.
//
// Run: node tool/check_convex_web_binding.mjs
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const bindingPath = path.join(root, 'lib/collab/src/convex_client_web.dart');
const bundlePath = path.join(root, 'web/convex.browser.bundle.js');

/** The `external` members of each extension type, and its `@JS` name. */
function readBinding(source) {
  const types = new Map();
  const typePattern =
    /(?:@JS\(\s*(?:'([^']*)')?\s*\)\s*)?extension type (\w+)\._\([^)]*\)[^{]*\{([\s\S]*?)\n\}/g;
  for (const [, jsName, typeName, body] of source.matchAll(typePattern)) {
    const members = [];
    for (const line of body.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed.startsWith('external ')) continue;
      if (/^external factory\b/.test(trimmed)) continue; // checked via jsName
      const getter = trimmed.match(/\bget\s+(\w+)\s*;/);
      const operator = trimmed.match(/\boperator\s*(\S+?)\s*\(/);
      const method = trimmed.match(/(\w+)\s*\(/);
      if (getter) members.push(getter[1]);
      else if (operator) members.push(`operator ${operator[1]}`);
      else if (method) members.push(method[1]);
    }
    types.set(typeName, { jsName, members });
  }
  return types;
}

/** A WebSocket that never connects, so constructing a client stays offline. */
class StubWebSocket {
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSING = 2;
  static CLOSED = 3;
  constructor(url) {
    this.url = url;
    this.readyState = StubWebSocket.CONNECTING;
  }
  send() {}
  close() {
    this.readyState = StubWebSocket.CLOSED;
  }
  addEventListener() {}
  removeEventListener() {}
}

function loadBundle() {
  const context = vm.createContext({
    console,
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
    queueMicrotask,
    URL,
    TextEncoder,
    TextDecoder,
    crypto: globalThis.crypto,
    fetch: async () => {
      throw new Error('network disabled in binding check');
    },
    WebSocket: StubWebSocket,
  });
  context.globalThis = context;
  vm.runInContext(
    `${fs.readFileSync(bundlePath, 'utf8')}\nglobalThis.convex = convex;`,
    context,
    { filename: bundlePath },
  );
  return context;
}

const failures = [];
const types = readBinding(fs.readFileSync(bindingPath, 'utf8'));
const context = loadBundle();

// How to get a live instance of each bound JS type. A new extension type in
// the binding must be added here, so it cannot go unchecked.
const client = new context.convex.ConvexClient('https://binding-check.convex.cloud');
const browserBuiltins = new Set(['_JsUint8ArrayView', '_JsReadableUint8Array']);
const instances = {
  _JsConvexClient: client,
  _JsBaseConvexClient: client.client,
  _JsConnectionState: client.connectionState(),
};

const constructorPath = types.get('_JsConvexClient')?.jsName;
if (constructorPath !== 'convex.ConvexClient') {
  failures.push(
    `_JsConvexClient is bound to '${constructorPath}', expected 'convex.ConvexClient'`,
  );
}

for (const [typeName, { members }] of types) {
  if (browserBuiltins.has(typeName)) continue;
  const instance = instances[typeName];
  if (instance === undefined) {
    failures.push(
      `${typeName}: no instance to check. Add it to the table in ` +
        'tool/check_convex_web_binding.mjs.',
    );
    continue;
  }
  for (const member of members) {
    if (member.startsWith('operator ')) continue;
    if (!(member in instance)) {
      failures.push(`${typeName}.${member} does not exist in the Convex browser bundle`);
    } else {
      console.log(`ok  ${typeName}.${member}`);
    }
  }
}

// The stub socket never reports closing, so close() is not awaited.
void client.close();

if (failures.length > 0) {
  console.error('\nConvex web binding does not match web/convex.browser.bundle.js:');
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}
console.log('\nConvex web binding matches the browser bundle.');
