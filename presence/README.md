# icarus-presence

Live presence for cloud strategies: who else has a strategy open (the avatars
in the editor's window strip) and where their cursor is on the map. A
Cloudflare Worker with one Durable Object per strategy relays it. Nothing is
stored: cursors live in memory for as long as someone is connected.

## How a client gets in

1. The app calls the Convex mutation `presence:issueRoomPass`
   (`convex/presence.ts`). Convex checks the caller can view the strategy and
   returns the room URL and a pass signed with `PRESENCE_PASS_SECRET`, valid for
   two minutes. It returns null if the deployment has no `PRESENCE_URL`, and
   the app then shows no presence.
2. The app opens `wss://<worker>/v1/rooms/<strategyPublicId>?pass=<pass>`. The
   Worker verifies the pass (`src/pass.ts`, shared with Convex) and hands the
   socket to that strategy's room (`src/room.ts`).
3. The app sends a `renew` with a fresh pass every minute. The room closes any
   socket whose pass runs out, so someone whose access is revoked drops out
   within two minutes.

Messages are JSON. From the client: `cursor {page, x, y}` (canonical
attack-side world coordinates, at most 20 a second), `hide`,
`editing {page, groups}`, `renew {pass}`, and the text `ping`, which the
runtime answers with `pong` without waking the room. From the room:
`welcome {self, uid, peers}`, `join {peer}`, `leave {sid}`,
`cursor {sid, page, x, y}`, `hide {sid}`, `editing {sid, page, groups}`,
`renewed {exp}`. Close code 4001 means the pass ran out or a renewal was
refused.

`editing` names the lineup groups a session is editing on one page: at most 8
group ids of at most 128 characters each. An empty `groups` means editing
nothing, and the room relays it as `{page: null, groups: []}`. The room sorts
the ids, drops duplicates, relays only a change, and ignores a non-empty
`editing` that arrives within 100 ms of the last one it accepted. An ignored
`editing` is dropped, not delayed, so a client that changes faster than that
must hold the latest state and send it once 100 ms have passed. A clear (empty
`groups`) always goes through, however soon it arrives: dropped, it would
leave the notice on everyone's screen. Each peer in `welcome` and `join`
carries `editing` as `{page, groups}` or null. Clients and rooms that predate
`editing` ignore it, so either side can deploy first.

## Environments

| Worker | URL | Paired Convex deployment |
|---|---|---|
| `icarus-presence-dev` (`--env dev`) | `https://icarus-presence-dev.shawnadedeji.workers.dev` | development, `majestic-eel-413` |
| `icarus-presence` (`--env production`) | `https://icarus-presence.shawnadedeji.workers.dev` | production, `basic-dove-69` |

Each pair shares one secret. Convex holds it with the Worker's URL:

```sh
# Generate a secret, then set it on both sides of one pair.
npx wrangler secret put PRESENCE_PASS_SECRET --env dev   # from presence/
npx convex env set PRESENCE_PASS_SECRET <secret>          # CONVEX_DEPLOYMENT=dev:majestic-eel-413
npx convex env set PRESENCE_URL https://icarus-presence-dev.shawnadedeji.workers.dev
```

For production, use `--env production`, `npx convex env set --prod`, and the
production URL. Rotating the secret signs everyone out of presence until they
rejoin (about a minute); nothing else notices.

## Working on it

```sh
cd presence
npm ci
npm test            # Worker and room, in the real Workers runtime (Miniflare)
npm run typecheck
npm run deploy:dev  # wrangler deploy --env dev
```

The `Deploy Web` workflow deploys `--env production` on every push to
`icarus-cloud`, before the web build. CI runs the tests and typecheck.
