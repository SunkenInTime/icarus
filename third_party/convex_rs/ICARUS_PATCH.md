# Icarus convex-rs patch

Source: the published `convex` 0.10.4 crate.

Icarus adds a public `reconnect_now` request that tells the existing worker to
restart its WebSocket and replay current auth, subscriptions, and in-flight
mutations. The upstream client already owns that recovery path, but 0.10.4 does
not expose a way for a host application to trigger it.

The local `convex_flutter` package uses this method for its documented manual
reconnect API. This keeps the runtime fault symmetric with Dartvex instead of
mistaking an authenticated health query for a socket reconnect.

Icarus also separates server auth rejection from generic network failure in the
client worker. Auth rejection and the protocol-close errors caused by its old
socket retry the stored refresh callback every 250 ms. Buffered transitions from
the rejected socket cannot end recovery: the client first observes that the
callback produced a different token, then requires a server transition or
function response on that attempt. Other failures retain the upstream
randomized exponential backoff. This prevents a fresh token from sitting behind
a network backoff of up to 15 seconds without creating a hot reconnect loop
while the auth provider refreshes.

The reconnect request carries that auth-recovery state to the WebSocket worker.
The client worker already supplies the 250 ms pacing, so the WebSocket worker
resets and skips its independent network backoff for those attempts. Without
that coordination, the two workers can each back off the same rejected socket
and still strand a fresh token for up to 15 seconds.

Before a reconnect, the worker drains responses buffered by the connection it
is replacing. Auth rejection can otherwise be followed by a stale socket-close
failure during the retry delay; replaying that old failure on the new connection
starts a second backoff and can also apply old query-set transitions after the
client has rebuilt its versions.

WebSocket reconnects now retain one session ID for the lifetime of the client
and increment `connection_count` after every successful socket open, including
client-requested reconnects. The published Rust client created a new session ID
for every socket and did not advance the count on clean reconnects, unlike the
Convex sync protocol's client-lifetime session and monotonic connection model.
