import { DurableObject } from "cloudflare:workers";
import { verifyPass, type PassClaims, type PassRole } from "./pass";

// One room per strategy. The room is a relay: it remembers who is connected
// and where their cursor last was, only for as long as they are connected.
// Nothing here is written to storage; a cursor is worth nothing a second
// after it moves.

export interface Env {
  PRESENCE_ROOM: DurableObjectNamespace<PresenceRoom>;
  PRESENCE_PASS_SECRET: string;
}

export interface Cursor {
  page: string;
  x: number;
  y: number;
}

export interface Peer {
  sid: string;
  uid: string;
  name: string;
  avatar: string | null;
  role: PassRole;
  cursor: Cursor | null;
}

/** Everything the room knows about one socket. Survives hibernation. */
interface Attachment extends Peer {
  room: string;
  exp: number;
  lastCursorAt: number;
}

export const MAX_PEERS = 25;
/** How often the room looks for passes that ran out without a renewal. */
export const SWEEP_INTERVAL_MS = 30_000;
/** Faster than any client sends (20/s); only a misbehaving client hits it. */
const MIN_CURSOR_INTERVAL_MS = 25;
const MAX_MESSAGE_CHARS = 2048;
const MAX_PAGE_ID_CHARS = 128;
/** The map is 1000 units tall and 1778 wide; allow the margin around it. */
const COORDINATE_LIMIT = 10_000;

export const CLOSE_PASS_EXPIRED = 4001;
export const CLOSE_ROOM_FULL = 4008;

/** Header the Worker uses to hand verified claims to the room. */
export const CLAIMS_HEADER = "X-Icarus-Presence-Claims";

export class PresenceRoom extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // Keepalives are answered without waking the room.
    ctx.setWebSocketAutoResponse(
      new WebSocketRequestResponsePair("ping", "pong"),
    );
  }

  override async fetch(request: Request): Promise<Response> {
    const claims = JSON.parse(
      request.headers.get(CLAIMS_HEADER) ?? "null",
    ) as PassClaims | null;
    if (claims === null) return new Response("Missing claims", { status: 400 });

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    this.ctx.acceptWebSocket(server);

    const others = this.peers();
    if (others.length >= MAX_PEERS) {
      server.close(CLOSE_ROOM_FULL, "Room is full");
      return new Response(null, { status: 101, webSocket: client });
    }

    const self: Attachment = {
      sid: crypto.randomUUID(),
      uid: claims.uid,
      name: claims.name,
      avatar: claims.avatar,
      role: claims.role,
      cursor: null,
      room: claims.room,
      exp: claims.exp,
      lastCursorAt: 0,
    };
    server.serializeAttachment(self);
    send(server, {
      t: "welcome",
      self: self.sid,
      uid: self.uid,
      peers: others.map(toPeer),
    });
    this.broadcast({ t: "join", peer: toPeer(self) }, server);

    if ((await this.ctx.storage.getAlarm()) === null) {
      await this.ctx.storage.setAlarm(Date.now() + SWEEP_INTERVAL_MS);
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  override async webSocketMessage(
    ws: WebSocket,
    raw: string | ArrayBuffer,
  ): Promise<void> {
    const self = attachmentOf(ws);
    if (self === null) return;
    if (self.exp <= Date.now()) {
      this.drop(ws, self, CLOSE_PASS_EXPIRED, "Pass expired");
      return;
    }
    if (typeof raw !== "string" || raw.length > MAX_MESSAGE_CHARS) return;
    let message: unknown;
    try {
      message = JSON.parse(raw);
    } catch {
      return;
    }
    if (typeof message !== "object" || message === null) return;
    const m = message as Record<string, unknown>;

    switch (m.t) {
      case "cursor": {
        const cursor = parseCursor(m);
        const now = Date.now();
        if (cursor === null || now - self.lastCursorAt < MIN_CURSOR_INTERVAL_MS) {
          return;
        }
        ws.serializeAttachment({ ...self, cursor, lastCursorAt: now });
        this.broadcast({ t: "cursor", sid: self.sid, ...cursor }, ws);
        return;
      }
      case "hide": {
        if (self.cursor === null) return;
        ws.serializeAttachment({ ...self, cursor: null });
        this.broadcast({ t: "hide", sid: self.sid }, ws);
        return;
      }
      case "renew": {
        const claims =
          typeof m.pass === "string"
            ? await verifyPass(m.pass, this.env.PRESENCE_PASS_SECRET, Date.now())
            : null;
        // A renewal is for the same person in the same room. Anything else is
        // a client bug or a forgery; either way the socket is done.
        if (claims === null || claims.uid !== self.uid || claims.room !== self.room) {
          this.drop(ws, self, CLOSE_PASS_EXPIRED, "Invalid renewal");
          return;
        }
        const renewed: Attachment = {
          ...self,
          exp: claims.exp,
          name: claims.name,
          avatar: claims.avatar,
          role: claims.role,
        };
        ws.serializeAttachment(renewed);
        send(ws, { t: "renewed", exp: claims.exp });
        // Name, avatar, or role may have changed since the last pass; a join
        // for a known sid replaces that peer.
        if (
          renewed.name !== self.name ||
          renewed.avatar !== self.avatar ||
          renewed.role !== self.role
        ) {
          this.broadcast({ t: "join", peer: toPeer(renewed) }, ws);
        }
        return;
      }
    }
  }

  override async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    const self = attachmentOf(ws);
    if (self !== null) {
      ws.serializeAttachment(null);
      this.broadcast({ t: "leave", sid: self.sid }, ws);
    }
    // 1005 and 1006 are reserved codes that can't be sent back.
    try {
      ws.close(code === 1005 || code === 1006 ? 1000 : code, "Closed");
    } catch {
      // Already closed.
    }
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    const self = attachmentOf(ws);
    if (self !== null) {
      ws.serializeAttachment(null);
      this.broadcast({ t: "leave", sid: self.sid }, ws);
    }
  }

  /** Closes sockets whose pass ran out; keeps sweeping while anyone is here. */
  override async alarm(): Promise<void> {
    const now = Date.now();
    for (const ws of this.ctx.getWebSockets()) {
      const self = attachmentOf(ws);
      if (self !== null && self.exp <= now) {
        this.drop(ws, self, CLOSE_PASS_EXPIRED, "Pass expired");
      }
    }
    if (this.peers().length > 0) {
      await this.ctx.storage.setAlarm(now + SWEEP_INTERVAL_MS);
    }
  }

  private peers(): Attachment[] {
    const peers: Attachment[] = [];
    for (const ws of this.ctx.getWebSockets()) {
      const peer = attachmentOf(ws);
      if (peer !== null) peers.push(peer);
    }
    return peers;
  }

  private drop(ws: WebSocket, self: Attachment, code: number, reason: string) {
    // Clear the attachment first so the socket stops counting as a peer even
    // before the runtime finishes closing it.
    ws.serializeAttachment(null);
    try {
      ws.close(code, reason);
    } catch {
      // Already closed.
    }
    this.broadcast({ t: "leave", sid: self.sid }, ws);
  }

  private broadcast(message: object, except: WebSocket): void {
    const text = JSON.stringify(message);
    for (const ws of this.ctx.getWebSockets()) {
      if (ws === except || attachmentOf(ws) === null) continue;
      try {
        ws.send(text);
      } catch {
        // The runtime reports the close separately.
      }
    }
  }
}

function attachmentOf(ws: WebSocket): Attachment | null {
  return (ws.deserializeAttachment() as Attachment | null) ?? null;
}

function toPeer(a: Attachment): Peer {
  return {
    sid: a.sid,
    uid: a.uid,
    name: a.name,
    avatar: a.avatar,
    role: a.role,
    cursor: a.cursor,
  };
}

function send(ws: WebSocket, message: object): void {
  ws.send(JSON.stringify(message));
}

function parseCursor(m: Record<string, unknown>): Cursor | null {
  const { page, x, y } = m;
  if (
    typeof page !== "string" ||
    page.length === 0 ||
    page.length > MAX_PAGE_ID_CHARS ||
    !isCoordinate(x) ||
    !isCoordinate(y)
  ) {
    return null;
  }
  return { page, x, y };
}

function isCoordinate(value: unknown): value is number {
  return (
    typeof value === "number" &&
    Number.isFinite(value) &&
    Math.abs(value) <= COORDINATE_LIMIT
  );
}
