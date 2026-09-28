import { verifyPass } from "./pass";
import { CLAIMS_HEADER, type Env } from "./room";

export { PresenceRoom } from "./room";

// GET /v1/rooms/<strategyPublicId>?pass=<room pass>, upgraded to a WebSocket.
// Browsers can't set headers on a WebSocket, so the pass rides in the query.
const ROOM_PATH = /^\/v1\/rooms\/([A-Za-z0-9_-]{1,128})$/;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const match = ROOM_PATH.exec(url.pathname);
    if (match === null) return new Response("Not found", { status: 404 });
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected a WebSocket upgrade", { status: 426 });
    }

    const room = match[1]!;
    const claims = await verifyPass(
      url.searchParams.get("pass") ?? "",
      env.PRESENCE_PASS_SECRET,
      Date.now(),
    );
    if (claims === null || claims.room !== room) {
      return new Response("Invalid or expired pass", { status: 401 });
    }

    // The room gets the verified claims, never the pass itself.
    const headers = new Headers(request.headers);
    headers.set(CLAIMS_HEADER, JSON.stringify(claims));
    url.search = "";
    const stub = env.PRESENCE_ROOM.get(env.PRESENCE_ROOM.idFromName(room));
    return stub.fetch(new Request(url, { headers }));
  },
} satisfies ExportedHandler<Env>;
