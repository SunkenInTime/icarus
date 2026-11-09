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
client worker. After the server refuses auth, the first retry comes within
250 ms and asks the stored refresh callback for a fresh token, so an expired
token is usually replaced on that retry. Each further refusal in a row doubles
the wait, up to 15 seconds, less up to half at random. Before Nov 2026 every
retry waited 250 ms, so a token the server kept refusing (a removed account, a
misconfigured issuer, a clock that's off) reconnected about four times a second
forever. Recovery ends with a server transition or function response to auth
sent after the last refusal: on a new connection (whose predecessor's messages
are all handled before the resend, see below), or a different token on the
current one. Messages the refused socket had already sent can't end it. The
same token counts, since the server may accept a token it refused before (its
auth config was fixed, say). Other failures retain the upstream randomized
exponential backoff.

`reconnect_now` ends a wait after a refusal early, including one that begins
just after the call. Icarus calls it whenever it hands the client new auth (its
token provider refreshed, or the user retried), so a fresh token never waits
out the backoff.

`ConvexClient::watch_auth_refused` turns true once the server has refused five
times in a row, and false again once it accepts a token. The `convex_flutter`
bridge reports that to the app as signed out of the cloud.

The reconnect request carries that auth-recovery state to the WebSocket worker.
The client worker already paces those attempts, so the WebSocket worker resets
and skips its independent network backoff for them. Without that coordination,
the two workers can each back off the same rejected socket and strand a fresh
token for up to 15 seconds.

The WebSocket worker answers every reconnect request with
`ProtocolResponse::ReconnectAcknowledged` once it stops reading the connection
it replaces. After asking for a reconnect, the client worker handles everything
that arrived before that acknowledgement against the old state, before it
resends, and ignores its errors. An action or mutation the old connection
already answered completes instead of being sent again, and the old socket's
close failure or stale transitions can't start a second reconnect. This is the
approach of convex/convex-rs#23. It replaces an earlier Icarus patch that
dropped whatever was buffered before reconnecting: that raced with the old
socket's late messages and threw away finished action results.

WebSocket reconnects now retain one session ID for the lifetime of the client
and increment `connection_count` after every successful socket open, including
client-requested reconnects. The published Rust client created a new session ID
for every socket and did not advance the count on clean reconnects, unlike the
Convex sync protocol's client-lifetime session and monotonic connection model.

Icarus adds `subscribe_set`, which subscribes to several queries in one worker
step and returns their tokens, the results of every subscribed query at that
moment, and a watch of every later change. Upstream offers `watch_all`, but a
new watch yields nothing until the next server transition, so a set whose
queries were all answered already would wait for an unrelated change, and
results read from separate `subscribe` calls can each come from a different
transition. Taking the results and opening the watch with nothing awaited in
between means the watch only yields results newer than the snapshot. The
`convex_flutter` bridge uses it to deliver a page read in parts (its frame and
slices) as one consistent page.

A transition now publishes only results the server holds on the current
connection. Upstream kept every result across a reconnect and published them
again with the first transition on the new connection, which can be the one
that only acknowledges re-authentication, before the server has answered any
query. Subscribers then took old results for current ones. Until the reconnect
lands, the old results stay readable as before.

A mutation or action now gets its answer channel as soon as the client starts
tracking it, before the worker sends it. Upstream handed the channel over only
after the send, so a connection that failed during the send (the server
refusing auth, a dropped socket) dropped the channel: the caller got
`channel closed`, while the request stayed tracked and was sent again after the
reconnect, where the server ran it. Icarus took that error as a failed save and
sent the work again, and the server refused the resend as a conflict with the
write it had already applied. Now the caller waits through the reconnect and
gets the server's answer.
