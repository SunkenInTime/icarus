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

What that establishes is that this client has applied a transition at or after
the write's commit timestamp. The client does not check that any query changed:
that its results then show the write rests on the sync protocol's rule that a
transition leaves every subscribed query at its end timestamp, the same rule
the JS client relies on. It does not establish that Dart has seen those
results. The worker can wake the mutation's caller before a
`convex_flutter` subscription callback carrying the same transition has run, so
"the mutation resolved, so the live result I hold includes my write" is true of
the Rust client's state and not yet of what Dart was handed. Code that needs
the updated state in Dart has to observe it there, by the result snapshots
described below.

One behavior changed for slow transitions. If a transition older than the
write arrives before the `convex_flutter` bridge's deadline on the call (30
seconds by default), and the one that reaches the commit timestamp arrives after it, 0.10.4
reported success where this now times out. If Icarus's outbox retries, it
sends the same op ids again, and the server answers them as replays of the
write it already applied; it can instead pause at its attempt limit.

Every query result, a value or an error, now carries the snapshot it was taken
from. `QueryResults::snapshot` is the number of transitions the client has
applied: it counts up by one with every transition, across reconnects, and
restarts only with the client. Results with the same number come from one
snapshot, which holds one result per query, so for two results of one query
the higher number is the newer and equal numbers mean the same result.
`QueryResults::ts` is that snapshot's server time, the end timestamp of the
last transition applied (`None` before the first); a value that last changed
earlier carries it too. `QuerySubscription::timed` yields each result with both
(`TimedResult`), and `ConvexClient::query_timed` does the same for a one-shot
read. Upstream exposes neither, so a reader had no way to tell which of two
results is newer: a subscription's first result is the snapshot when it
subscribed, and it can be read after a one-shot answered from a newer one
(`client::tests::test_a_live_result_from_an_earlier_snapshot_read_after_a_one_shot_sorts_before_it`).

The timestamp alone does not order two results. Two snapshots can share one:
a transition may end at the time the one before it ended, and if the server
moves to a new time while leaving out a query it has not run again, the client
keeps that query's old result under the new time, then gets its new value in a
later transition at the same time
(`client::tests::test_two_snapshots_at_one_timestamp_order_by_snapshot`). After
a reconnect the client also accepts a first transition whatever its time. The
snapshot number has neither problem; it is only comparable within one run of
the client.

Every stamp also names its client and connection. `QueryResults::client` numbers
the clients built in this process from 1, so snapshots of two clients are never
compared as if they were one count. `QueryResults::connection` is a
generation: 0 until the first reconnect, then one more each time the client
starts again on a new socket, a failed dial included, so the first socket that
opens can be 1 and numbers can be skipped. A higher number is a later
connection. Results kept from an old connection keep its number until the new
connection's first transition replaces them, so a reader can tell a result
taken before a reconnect from one taken after it, whatever order they reach it
in (`base_client::tests::test_the_snapshot_count_goes_on_across_a_reconnect`).
That test also shows a new connection starting at an earlier server time, so a
higher snapshot on a later connection is a later snapshot of this client, not
necessarily a later server time.

`ConvexClient::mutation_timed` gives a mutation's answer with the stamp of the
results the client held when it completed it, and `mutation` and `action`
return the same answers without it. A success's snapshot has a timestamp at or
after its commit. When the response arrives first, the mutation completes on
the first transition that reaches the commit and carries it. When a qualifying
transition arrived first, it carries the snapshot current when the response is
handled: that qualifies, but need not be the first that did. What the stamp
establishes is a snapshot whose time is at or after the commit; that results
show the write rests on the protocol rule above. Across a reconnect, a reader
that needs a result to include the write checks both: its snapshot at or after
the answer's, and its time at or after the answer's. A mutation whose server
function fails completes when its response arrives, with the last snapshot
applied before it (snapshot 0 and no time before the first transition). That is
a fact about when this client handled the answer, not about which server state
the failed mutation ran against; nothing on the wire says that. A Dart timeout
or a bridge error still throws. The tests next to
`base_client::tests::test_a_mutation_answer_carries_the_snapshot_its_write_is_visible_in`
cover each case.

`ConvexClient::connection_generation` gives the connection generation the client
is on, asked of the worker between its steps, so after a reconnect it is the
generation the client started again on, never an earlier one
(`client::worker::tests::test_the_connection_generation_moves_on_with_a_reconnect`).
A reader that holds it can tell that any stamp with a lower generation comes from
an earlier connection, even one that reaches it later.

Unlike upstream, `BaseConvexClient::mutation` and `BaseConvexClient::action`
hand back a `TimedResult` rather than a `FunctionResult`, which would break a
Rust program using the base client directly. Icarus has none; `ConvexClient`'s
methods keep upstream's types.
