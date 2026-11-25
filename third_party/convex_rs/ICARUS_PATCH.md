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
gets the server's answer, as long as that comes before its own timeout (the
`convex_flutter` bridge gives up on a call after 30 seconds by default).

A single query subscription is handed over the same way. Upstream returned
early when the connection failed while the subscription was being sent, so the
caller got `channel closed` while the query stayed subscribed and was added
again on the next connection. Nothing held its subscription, so nothing could
unsubscribe it, and it kept costing reads for the life of the client. Now the
caller gets the subscription either way, and dropping it unsubscribes. Sent
upstream as convex/convex-rs#26.

A mutation now resolves only once a transition has reached the timestamp it
committed at, as in the JS client. 0.10.4 resolved a successful mutation on the
first transition after its response arrived, even when that transition was
older than the write, so `mutation(...).await` could return while subscribed
queries still showed the data from before it. This is upstream's change from
convex/convex-rs 1dbad3046e449224f8ec0bdd6b432ff6544ac2f9 ("Complete Rust
client mutations only once they're reflected in queries", #60513), applied as
is: a mutation whose transition arrived before its response completes when the
response arrives, a mutation that fails with a `ConvexError` completes at once,
and a response to a mutation that already completed (one resent after a
reconnect) is ignored instead of causing a reconnect.
`client::tests::test_mutation_waits_for_its_commit_transition` checks the same
through the public client and this crate's worker.

What that establishes is that the write reached this client's query results,
not that Dart has seen them. The worker can wake the mutation's caller before a
`convex_flutter` subscription callback carrying the same transition has run, so
"the mutation resolved, so the live result I hold includes my write" is true of
the Rust client's state and not yet of what Dart was handed. Code that needs
the updated state in Dart has to observe it there, by the result timestamps
described below.

One behavior changed for slow transitions. If a transition older than the
write arrives before the `convex_flutter` bridge's 30-second deadline on the
call, and the one that reaches the commit timestamp arrives after it, 0.10.4
reported success where this now times out. Icarus's outbox then sends the same
op ids again, and the server answers them as replays of the write it already
applied.

Every query result now carries the timestamp of the server state it comes
from: `QueryResults::ts`, the end of the last transition the client applied
(`None` before the first). `QuerySubscription::timed` yields each result with
that timestamp (`TimedResult`), and `ConvexClient::query_timed` does the same
for a one-shot read. A later server state has a later timestamp, so two results
of one query can be put in the server's order however late either reaches its
reader: a subscription's first result is the state when it subscribed, and it
can be read after a one-shot answered from a newer state. Upstream exposes no
timestamp, so a reader had no way to tell which of two results is newer.
`client::tests::test_a_live_result_from_an_earlier_state_read_after_a_one_shot_sorts_before_it`
covers that case.
