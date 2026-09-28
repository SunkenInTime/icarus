import { env, runDurableObjectAlarm, SELF } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { signPass, verifyPass, type PassClaims } from "../src/pass";
import { CLOSE_PASS_EXPIRED } from "../src/room";

const SECRET = "test-secret";
// A fresh room per test, so sockets closing after one test never reach the next.
let roomCount = 0;
let ROOM = "";
beforeEach(() => {
  ROOM = `strat_${++roomCount}`;
});

function claims(overrides: Partial<PassClaims> = {}): PassClaims {
  return {
    room: ROOM,
    uid: "u-ana",
    name: "Ana",
    avatar: null,
    role: "editor",
    exp: Date.now() + 120_000,
    ...overrides,
  };
}

interface Client {
  ws: WebSocket;
  messages: any[];
  closed: Promise<CloseEvent>;
  next(type: string): Promise<any>;
}

const open: WebSocket[] = [];

async function connect(pass: string, room = ROOM): Promise<Client> {
  const response = await SELF.fetch(
    `https://presence.test/v1/rooms/${room}?pass=${encodeURIComponent(pass)}`,
    { headers: { Upgrade: "websocket" } },
  );
  const ws = response.webSocket;
  if (ws == null) throw new Error(`No socket: ${response.status}`);
  ws.accept();
  open.push(ws);
  const messages: any[] = [];
  const waiters: { type: string; resolve: (m: any) => void }[] = [];
  ws.addEventListener("message", (event: MessageEvent) => {
    const message = JSON.parse(event.data as string);
    const i = waiters.findIndex((w) => w.type === message.t);
    if (i >= 0) waiters.splice(i, 1)[0]!.resolve(message);
    else messages.push(message);
  });
  const closed = new Promise<CloseEvent>((resolve) =>
    ws.addEventListener("close", resolve),
  );
  return {
    ws,
    messages,
    closed,
    next(type) {
      const i = messages.findIndex((m) => m.t === type);
      if (i >= 0) return Promise.resolve(messages.splice(i, 1)[0]);
      return new Promise((resolve) => waiters.push({ type, resolve }));
    },
  };
}

function base64Url(text: string): string {
  return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

afterEach(() => {
  for (const ws of open.splice(0)) {
    try {
      ws.close(1000);
    } catch {
      // Already closed.
    }
  }
});

describe("room pass", () => {
  it("round-trips valid claims", async () => {
    const c = claims();
    expect(await verifyPass(await signPass(c, SECRET), SECRET, Date.now())).toEqual(c);
  });

  it("rejects a wrong secret, a tampered body, a missing MAC, and expiry", async () => {
    const pass = await signPass(claims(), SECRET);
    const [version, body, mac] = pass.split(".");
    const forged = base64Url(JSON.stringify(claims({ role: "owner" })));
    expect(await verifyPass(pass, "other", Date.now())).toBeNull();
    expect(await verifyPass(`${version}.${forged}.${mac}`, SECRET, Date.now())).toBeNull();
    expect(await verifyPass(`${version}.${body}`, SECRET, Date.now())).toBeNull();
    expect(await verifyPass(pass, SECRET, Date.now() + 121_000)).toBeNull();
  });

  it("rejects malformed base64 instead of throwing", async () => {
    expect(await verifyPass("v1.a.a", SECRET, Date.now())).toBeNull();
    expect(await verifyPass("v1.abcde.ab", SECRET, Date.now())).toBeNull();
    const response = await SELF.fetch(`https://presence.test/v1/rooms/${ROOM}?pass=v1.a.a`, {
      headers: { Upgrade: "websocket" },
    });
    expect(response.status).toBe(401);
  });
});

describe("worker", () => {
  it("refuses a pass for another room", async () => {
    const pass = await signPass(claims({ room: "other_room" }), SECRET);
    const response = await SELF.fetch(
      `https://presence.test/v1/rooms/${ROOM}?pass=${pass}`,
      { headers: { Upgrade: "websocket" } },
    );
    expect(response.status).toBe(401);
  });

  it("refuses an expired pass, plain HTTP, and unknown paths", async () => {
    const expired = await signPass(claims({ exp: Date.now() - 1 }), SECRET);
    const url = `https://presence.test/v1/rooms/${ROOM}?pass=${expired}`;
    const upgrade = { headers: { Upgrade: "websocket" } };
    expect((await SELF.fetch(url, upgrade)).status).toBe(401);
    expect((await SELF.fetch(url)).status).toBe(426);
    expect((await SELF.fetch("https://presence.test/")).status).toBe(404);
  });
});

describe("room", () => {
  it("welcomes, announces joins, relays cursors, and announces leaves", async () => {
    const ana = await connect(await signPass(claims(), SECRET));
    expect(await ana.next("welcome")).toMatchObject({ uid: "u-ana", peers: [] });

    const ben = await connect(
      await signPass(claims({ uid: "u-ben", name: "Ben", role: "viewer" }), SECRET),
    );
    const benWelcome = await ben.next("welcome");
    expect(benWelcome.peers.map((p: any) => p.name)).toEqual(["Ana"]);
    expect((await ana.next("join")).peer).toMatchObject({
      sid: benWelcome.self,
      name: "Ben",
      role: "viewer",
      cursor: null,
    });

    ben.ws.send(JSON.stringify({ t: "cursor", page: "p1", x: 400, y: 300 }));
    expect(await ana.next("cursor")).toEqual({
      t: "cursor",
      sid: benWelcome.self,
      page: "p1",
      x: 400,
      y: 300,
    });

    // A newcomer sees where an existing cursor already is.
    const cy = await connect(await signPass(claims({ uid: "u-cy", name: "Cy" }), SECRET));
    const cyWelcome = await cy.next("welcome");
    const benSeenByCy = cyWelcome.peers.find((p: any) => p.name === "Ben");
    expect(benSeenByCy.cursor).toEqual({ page: "p1", x: 400, y: 300 });

    ben.ws.send(JSON.stringify({ t: "hide" }));
    expect(await ana.next("hide")).toEqual({ t: "hide", sid: benWelcome.self });

    ben.ws.close(1000, "bye");
    expect(await ana.next("leave")).toEqual({ t: "leave", sid: benWelcome.self });
    expect(await cy.next("leave")).toEqual({ t: "leave", sid: benWelcome.self });
  });

  it("ignores malformed cursors", async () => {
    const ana = await connect(await signPass(claims(), SECRET));
    await ana.next("welcome");
    const ben = await connect(await signPass(claims({ uid: "u-ben", name: "Ben" }), SECRET));
    await ben.next("welcome");
    await ana.next("join");

    ben.ws.send("not json");
    ben.ws.send(JSON.stringify({ t: "cursor", page: "p1", x: "1", y: 2 }));
    ben.ws.send(JSON.stringify({ t: "cursor", page: "", x: 1, y: 2 }));
    ben.ws.send(JSON.stringify({ t: "cursor", page: "p1", x: 1e9, y: 2 }));
    ben.ws.send(JSON.stringify({ t: "cursor", page: "p1", x: 5, y: 6 }));
    expect(await ana.next("cursor")).toMatchObject({ x: 5, y: 6 });
    expect(ana.messages.filter((m) => m.t === "cursor")).toEqual([]);
  });

  it("renews a pass for the same person and closes on a forged renewal", async () => {
    const ana = await connect(await signPass(claims(), SECRET));
    await ana.next("welcome");
    const exp = Date.now() + 240_000;
    ana.ws.send(JSON.stringify({ t: "renew", pass: await signPass(claims({ exp }), SECRET) }));
    expect(await ana.next("renewed")).toEqual({ t: "renewed", exp });

    const eve = await connect(await signPass(claims({ uid: "u-eve" }), SECRET));
    await eve.next("welcome");
    eve.ws.send(
      JSON.stringify({ t: "renew", pass: await signPass(claims({ uid: "u-ana" }), SECRET) }),
    );
    expect((await eve.closed).code).toBe(CLOSE_PASS_EXPIRED);
  });

  it("ignores renewals faster than one per ten seconds", async () => {
    const ana = await connect(await signPass(claims(), SECRET));
    await ana.next("welcome");
    ana.ws.send(JSON.stringify({ t: "renew", pass: await signPass(claims(), SECRET) }));
    await ana.next("renewed");
    ana.ws.send(JSON.stringify({ t: "renew", pass: "garbage" }));
    await sleep(100);
    expect(ana.messages).toEqual([]);
    ana.ws.send(JSON.stringify({ t: "cursor", page: "p1", x: 1, y: 1 }));
    await sleep(50);
    // Still connected: the garbage renewal was never even checked.
    expect(ana.ws.readyState).toBe(WebSocket.READY_STATE_OPEN);
  });

  it("stops sending to a silent socket once its pass runs out", async () => {
    const ana = await connect(await signPass(claims(), SECRET));
    await ana.next("welcome");
    const ben = await connect(
      await signPass(claims({ uid: "u-ben", name: "Ben", exp: Date.now() + 300 }), SECRET),
    );
    await ben.next("welcome");
    await ana.next("join");
    await sleep(400);

    // No alarm yet; Ana's cursor is the first thing that happens.
    ana.ws.send(JSON.stringify({ t: "cursor", page: "p1", x: 3, y: 4 }));
    expect((await ben.closed).code).toBe(CLOSE_PASS_EXPIRED);
    expect(ben.messages.filter((m) => m.t === "cursor")).toEqual([]);
  });

  it("limits one person to a few sessions", async () => {
    const pass = await signPass(claims(), SECRET);
    for (let i = 0; i < 4; i++) await (await connect(pass)).next("welcome");
    const response = await SELF.fetch(
      `https://presence.test/v1/rooms/${ROOM}?pass=${encodeURIComponent(pass)}`,
      { headers: { Upgrade: "websocket" } },
    );
    expect(response.status).toBe(429);
    // Someone else still gets in.
    const ben = await connect(await signPass(claims({ uid: "u-ben" }), SECRET));
    expect((await ben.next("welcome")).peers).toHaveLength(4);
  });

  it("closes sockets whose pass ran out at the next sweep", async () => {
    const ana = await connect(await signPass(claims(), SECRET));
    await ana.next("welcome");
    const ben = await connect(
      await signPass(claims({ uid: "u-ben", name: "Ben", exp: Date.now() + 300 }), SECRET),
    );
    const benWelcome = await ben.next("welcome");
    await ana.next("join");
    await sleep(400);

    const stub = env.PRESENCE_ROOM.get(env.PRESENCE_ROOM.idFromName(ROOM));
    expect(await runDurableObjectAlarm(stub)).toBe(true);
    expect((await ben.closed).code).toBe(CLOSE_PASS_EXPIRED);
    expect(await ana.next("leave")).toEqual({ t: "leave", sid: benWelcome.self });
  });

  it("keeps rooms apart", async () => {
    const ana = await connect(await signPass(claims(), SECRET));
    await ana.next("welcome");
    const other = await connect(
      await signPass(claims({ room: "other_room", uid: "u-ben" }), SECRET),
      "other_room",
    );
    expect((await other.next("welcome")).peers).toEqual([]);
    other.ws.send(JSON.stringify({ t: "cursor", page: "p1", x: 1, y: 1 }));
    await sleep(100);
    expect(ana.messages).toEqual([]);
  });
});
