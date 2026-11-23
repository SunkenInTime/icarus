import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const bundlePath = path.join(root, 'web/convex.browser.bundle.js');

const sockets = [];
let timers = [];

class StubSocket {
  constructor(url) {
    this.url = url;
    this.sent = [];
    sockets.push(this);
  }
  send(text) {
    this.sent.push(JSON.parse(text));
  }
  close() {}
}

const quietConsole = { ...console, log() {}, info() {}, warn() {}, debug() {} };
const context = vm.createContext({
  console: quietConsole,
  URL,
  TextEncoder,
  TextDecoder,
  performance,
  crypto: webcrypto,
  WebSocket: StubSocket,
  setTimeout: (fn, ms) => {
    const timer = { fn, ms };
    timers.push(timer);
    return timer;
  },
  clearTimeout: (timer) => {
    timers = timers.filter((other) => other !== timer);
  },
  setInterval: () => 1,
  clearInterval: () => {},
});
vm.runInContext(fs.readFileSync(bundlePath, 'utf8'), context);

const mutationsSentOn = (socket) =>
  socket.sent.filter((message) => message.type === 'Mutation');

const client = new context.convex.ConvexClient('https://stub.convex.cloud');
const args = {
  strategyPublicId: 'strategy',
  clientId: 'client',
  clientProtocolVersion: 6,
  sendsLiveBasis: true,
  liveBasis: 1_000_000,
  ops: [
    {
      opId: 'delete-1',
      type: 'element.delete',
      elementPublicId: 'agent-1',
      pagePublicId: 'page-1',
      expectedElementRevision: 1,
      lastWriterWins: true,
    },
  ],
};
let answered = false;
client.mutation('ops:applyBatch', args).then(() => {
  answered = true;
});

assert.equal(sockets.length, 1, 'the client opens one socket');
sockets[0].onopen();
const [first] = mutationsSentOn(sockets[0]);
assert.ok(first, 'the mutation is sent on the first connection');

sockets[0].onclose({ code: 1006, reason: 'connection lost' });
const reconnect = timers.find((timer) => timer.ms < 10_000);
assert.ok(reconnect, 'the client schedules a reconnect');
reconnect.fn();
assert.equal(sockets.length, 2, 'the reconnect opens a second socket');
sockets[1].onopen();

const [replayed] = mutationsSentOn(sockets[1]);
assert.deepEqual(
  replayed,
  first,
  'a mutation pending across a reconnect is sent again unchanged',
);
assert.deepEqual(replayed.args, [args], 'the replay carries the original arguments');
assert.equal(answered, false, 'the caller is still waiting for its answer');
void client.close();

console.log(
  'The browser Convex client sends a mutation pending across a reconnect ' +
    'again with its original arguments, liveBasis included, so ' +
    'ops:applyBatch judges the replay by the time the batch was written.',
);
