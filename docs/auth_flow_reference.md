# Auth Flow Reference

This document describes the current authentication flow in Icarus as it exists today.

It is meant to answer four questions:

1. What provider are we actually using?
2. How does Flutter authenticate with Supabase and then with Convex?
3. Why do both `Supabase` auth state and `users:ensureCurrentUser` exist?
4. Where should we look first if cloud auth starts failing?

## High-Level Summary

The app uses **Supabase Auth as the identity provider** and **Convex as the application backend**.

The important detail is that Convex is **not** the primary login provider here. Convex trusts a **Supabase-issued JWT** through `convex/auth.config.ts`, and the Flutter app forwards that token to Convex using `ConvexClient.setAuthWithRefresh(...)`.

That means the flow is:

`User signs in -> Supabase gets a session -> Flutter extracts/refreshes the access token -> Convex validates the JWT -> Convex functions can read identity -> app ensures a local Convex users row exists -> cloud features are enabled`

## Core Files

These are the files that define the current behavior:

- `lib/main.dart`
- `lib/providers/auth_provider.dart`
- `lib/widgets/dialogs/auth/auth_dialog.dart`
- `convex/auth.config.ts`
- `convex/users.ts`
- `convex/lib/auth.ts`
- `convex/schema.ts`
- `lib/providers/library_workspace_provider.dart`
- `lib/providers/collab/cloud_collab_provider.dart`

## 1. Startup: both clients are initialized up front

At startup the app initializes the Convex client and then Supabase:

```dart
await ConvexClient.initialize(
  const ConvexConfig(
    deploymentUrl: 'https://majestic-eel-413.convex.cloud',
    clientId: 'dev:majestic-eel-413',
    operationTimeout: Duration(seconds: 30),
    healthCheckQuery: 'health:ping',
  ),
);

await Supabase.initialize(
  url: 'https://gjdirtrtgnawqoruavqn.supabase.co',
  anonKey: '...',
  authOptions: const FlutterAuthClientOptions(detectSessionInUri: false),
);
```

Why this matters:

- `ConvexClient.initialize(...)` creates the global Convex client used by the app.
- `Supabase.initialize(...)` sets up the auth provider that will issue JWTs.
- `detectSessionInUri: false` is intentional because the desktop app handles OAuth callback URIs itself instead of relying on automatic URI parsing.

## 2. Convex trusts Supabase JWTs

Convex is configured to accept a custom JWT provider:

```ts
export default {
  providers: [
    {
      type: "customJwt",
      applicationID: "authenticated",
      issuer: "https://gjdirtrtgnawqoruavqn.supabase.co/auth/v1",
      jwks: "https://gjdirtrtgnawqoruavqn.supabase.co/auth/v1/.well-known/jwks.json",
      algorithm: "ES256",
    },
  ],
} satisfies AuthConfig;
```

This is the bridge between Supabase and Convex.

Why it works:

- Supabase signs access tokens.
- Convex validates those tokens against the configured `issuer`, `jwks`, and `algorithm`.
- If validation succeeds, `ctx.auth.getUserIdentity()` returns a non-null identity inside Convex functions.
- If this file is wrong, missing, or out of sync with Supabase, Convex will treat every request as unauthenticated.

## 3. Flutter auth state is owned by `authProvider`

The single source of truth on the client is `authProvider` in `lib/providers/auth_provider.dart`.

It tracks:

- Whether Supabase has a session
- Whether Convex auth has been configured successfully
- Whether a Convex-side incident is active
- Whether the app is safe to use cloud features

The important state enum is:

```dart
enum ConvexAuthStatus {
  signedOut,
  configuring,
  ready,
  incident,
}
```

This is intentionally more specific than just "logged in / logged out".

Why this exists:

- A Supabase session by itself is not enough.
- The app only enables cloud mode when Convex has also accepted the token and the app-level user row exists.

## 4. Login entry points

### Email/password

The dialog calls:

- `signInWithEmailPassword(...)`
- `signUpWithEmailPassword(...)`

Those methods authenticate directly with Supabase.

### Discord OAuth

Discord login uses Supabase OAuth with a custom desktop deep link:

```dart
final launched = await _supabaseApi.signInWithOAuth(
  OAuthProvider.discord,
  redirectTo: 'icarus://auth/callback',
  authScreenLaunchMode: LaunchMode.externalApplication,
  scopes: 'identify email',
);
```

Why this works:

- Supabase handles the OAuth exchange with Discord.
- On success, Supabase redirects back to `icarus://auth/callback`.
- The app listens for that deep link and hands it to Supabase to finalize the session.

## 5. OAuth callback handling

The app bootstraps `authProvider` immediately and routes deep links into it:

```dart
ref.read(authProvider);

unawaited(
  ref.read(authProvider.notifier).handleAuthCallbackUri(uri, source: source),
);
```

The provider decides whether the incoming URI is an auth callback:

```dart
bool isAuthCallbackUri(Uri uri) {
  final isIcarusScheme = uri.scheme.toLowerCase() == 'icarus';
  final isAuthCallback =
      uri.host.toLowerCase() == 'auth' &&
      uri.path.toLowerCase() == '/callback';

  final hasAuthPayload =
      uri.fragment.contains('access_token') ||
      uri.queryParameters.containsKey('code') ||
      uri.fragment.contains('error_description') ||
      uri.queryParameters.containsKey('error_description');

  return isIcarusScheme && isAuthCallback && hasAuthPayload;
}
```

Then it completes the Supabase session:

```dart
await _supabaseApi.getSessionFromUrl(uri);
```

Why this matters:

- Desktop OAuth relies on the custom URI handler working correctly.
- If the deep link never reaches `handleAuthCallbackUri(...)`, the browser may show a successful login while the app stays signed out.

## 6. Supabase auth changes trigger Convex auth setup

When `authProvider` builds, it subscribes to the Supabase auth stream:

```dart
_supabaseAuthSub ??= _supabaseApi.onAuthStateChange.listen(
  _handleSupabaseAuthStateChange,
  onError: _handleSupabaseAuthStreamError,
);
```

Every auth state change immediately resets Convex readiness and reruns the bridge setup:

```dart
state = AppAuthState.fromSession(
  currentSession,
  isLoading: false,
  isConvexUserReady: false,
  convexAuthStatus: currentSession == null
      ? ConvexAuthStatus.signedOut
      : ConvexAuthStatus.configuring,
);

unawaited(
  _configureConvexAuth(
    trigger: 'supabase:${event.event}',
    generation: generation,
    sessionFingerprint: _sessionFingerprint(currentSession),
  ),
);
```

Why this is important:

- Supabase is the source of identity.
- Convex auth must be re-bound whenever the session changes, refreshes, or disappears.

## 7. The client forwards the Supabase token to Convex

This is the most important bridge in the whole system.

The provider configures the Convex client like this:

```dart
final authHandle = await _convexApi.setAuthWithRefresh(
  fetchToken: _fetchSupabaseAccessToken,
  onAuthChange: (isAuthenticated) {
    if (!isAuthenticated && _supabaseApi.currentSession != null) {
      unawaited(
        reportConvexUnauthenticated(
          source: 'convex:onAuthChange',
          error: Exception('Convex auth state changed to unauthenticated'),
        ),
      );
    }
  },
);
```

The token supplier is:

```dart
Future<String?> _fetchSupabaseAccessToken() async {
  final session = _supabaseApi.currentSession;
  if (session == null) return null;

  final expiresAt = session.expiresAt;
  if (expiresAt != null) {
    final expiresAtUtc = DateTime.fromMillisecondsSinceEpoch(
      expiresAt * 1000,
      isUtc: true,
    );
    final shouldRefresh = expiresAtUtc
        .isBefore(DateTime.now().toUtc().add(const Duration(minutes: 1)));

    if (shouldRefresh) {
      final refreshed = await _supabaseApi.refreshSession();
      final refreshedToken = refreshed.session?.accessToken;
      if (refreshedToken != null && refreshedToken.isNotEmpty) {
        return refreshedToken;
      }
    }
  }

  return session.accessToken;
}
```

Why this works:

- Convex does not know how to log the user in to Supabase.
- Instead, Convex asks the Flutter client for a valid token whenever it needs one.
- The provider refreshes the Supabase session if the token is about to expire.
- That keeps long-lived desktop sessions working without forcing the user to log in again constantly.

## 8. Convex auth is not considered ready until the connection authenticates

After setting the auth handler, the provider explicitly reconnects the Convex client and waits for it to become authenticated:

```dart
reconnectResult = await _convexApi.reconnect();
final readinessSource = await _waitForConvexAuthenticated(
  trigger: trigger,
  reconnectResult: reconnectResult,
);
```

And `_waitForConvexAuthenticated(...)` blocks until either:

- the client is already authenticated, or
- `authState` emits `true`, or
- a timeout occurs

Why this exists:

- A Supabase session can exist before the Convex websocket/query layer has fully reconnected with the new token.
- Without this wait, the app could immediately fire protected Convex queries and get intermittent unauthenticated errors.

## 9. The app provisions a Convex `users` row after auth is ready

Once Convex says the token is accepted, the app immediately runs:

```dart
await _convexApi.mutation(name: 'users:ensureCurrentUser', args: {});
```

That mutation does this:

```ts
export const ensureCurrentUser = mutation({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (identity === null) {
      throw unauthenticatedError();
    }

    const externalId = getCanonicalExternalId(identity);
    const displayName = identity.name ?? identity.nickname ?? "Discord user";
    const avatarUrl = identity.pictureUrl ?? undefined;

    const existingUser = await findUserByIdentity(ctx, identity);

    if (existingUser !== null) {
      await ctx.db.patch(existingUser._id, {
        externalId,
        displayName,
        avatarUrl,
        updatedAt: Date.now(),
      });
      return existingUser._id;
    }

    return await ctx.db.insert("users", {
      externalId,
      displayName,
      avatarUrl,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    });
  },
});
```

Why this exists:

- Convex auth gives us an authenticated identity, but that identity is not the same thing as an app-level `users` table row.
- The rest of the data model uses `users._id` as a foreign key for folders, strategies, collaborators, invites, and images.
- So the app must materialize "the current authenticated identity" into a stable row in `users`.

## 10. Identity mapping uses `tokenIdentifier` as the canonical key

The backend auth helper makes this explicit:

```ts
export function getCanonicalExternalId(identity: {
  tokenIdentifier: string;
}): string {
  return identity.tokenIdentifier;
}
```

It also supports a fallback for older records:

```ts
export function getLegacyExternalId(identity: {
  subject?: string | null;
  tokenIdentifier: string;
}): string | null {
  const subject = identity.subject;
  if (subject == null || subject == identity.tokenIdentifier) {
    return null;
  }
  return subject;
}
```

Then user lookup tries the canonical value first and the legacy value second.

Why this matters:

- `tokenIdentifier` is the current stable identity key used by Convex auth.
- The legacy fallback strongly suggests the app used `subject` at some point and later migrated.
- This is a compatibility layer so older `users.externalId` values do not strand existing accounts.

## 11. Protected Convex functions always derive the user server-side

Protected functions never trust a client-supplied `userId`.

They call:

```ts
export async function requireCurrentUser(ctx: AnyCtx): Promise<Doc<"users">> {
  const identity = await ctx.auth.getUserIdentity();
  if (identity === null) {
    throw unauthenticatedError();
  }

  const user = await findUserByIdentity(ctx, identity);
  if (user === null) {
    throw new Error(
      "Missing user record. Call users:ensureCurrentUser before querying collaborative data.",
    );
  }

  return user;
}
```

And for strategy-level access:

```ts
export async function assertStrategyRole(
  ctx: AnyCtx,
  strategy: Doc<"strategies">,
  required: StrategyRole,
): Promise<{ user: Doc<"users">; role: StrategyRole }> {
  const user = await requireCurrentUser(ctx);
  const role = await getStrategyRoleForUser(ctx, strategy, user._id);

  if (!hasRole(role, required)) {
    throw new Error("Forbidden");
  }

  return { user, role: role as StrategyRole };
}
```

Why this works:

- The client cannot impersonate another user by sending a fake ID.
- Ownership and collaboration checks are done against the authenticated identity that Convex extracted from the JWT.

## 12. App data is linked to the Convex user row

The schema makes that explicit:

```ts
users: defineTable({
  externalId: v.string(),
  displayName: v.string(),
  avatarUrl: v.optional(v.string()),
  createdAt: v.number(),
  updatedAt: v.number(),
}).index("by_externalId", ["externalId"]),
```

And other tables point to `users._id`:

- `folders.ownerId`
- `strategies.ownerId`
- `strategyCollaborators.userId`
- `inviteTokens.createdByUserId`
- `imageAssets.createdByUserId`

So auth is not just "can this request run?".
It is also "which app-level user owns this data?".

## 13. Cloud mode is gated on both auth layers

The app does **not** consider cloud mode available when only Supabase is signed in.

It requires both:

- `isAuthenticated == true`
- `isConvexUserReady == true`

That gate is here:

```dart
final isCloudWorkspaceAvailableProvider = Provider<bool>((ref) {
  final auth = ref.watch(authProvider);
  return auth.isAuthenticated && auth.isConvexUserReady;
});
```

And again here:

```dart
return featureFlagEnabled &&
    isAuthenticated &&
    isConvexUserReady &&
    !forceLocalFallback;
```

Why this matters:

- It prevents the UI from exposing cloud functionality during the gap between "Supabase has a session" and "Convex has accepted the token and provisioned a user".
- That is a major reason the current flow is more stable than a simple boolean login flag.

## 14. Real cloud queries and mutations depend on this contract

The repository calls Convex functions directly:

```dart
final response = await _client.query('folders:listForParent', {
  if (parentFolderPublicId != null)
    'parentFolderPublicId': parentFolderPublicId,
});
```

Backend functions enforce auth immediately:

```ts
export const listForParent = query({
  args: {
    parentFolderPublicId: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);
    // ...
  },
});
```

And collaborative editing requires role checks:

```ts
export const applyBatch = mutation({
  args: {
    strategyPublicId: v.string(),
    clientId: v.string(),
    ops: v.array(strategyOpValidator),
  },
  handler: async (ctx, args) => {
    let strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");
    // ...
  },
});
```

So if auth fails anywhere upstream, these functions are where the break becomes visible.

## 15. How unauthenticated incidents are detected

The system has a special "Supabase says signed in, but Convex says unauthenticated" path.

Convex returns a structured error:

```ts
export function unauthenticatedError(): ConvexError<{
  code: 'UNAUTHENTICATED';
  message: string;
}> {
  return new ConvexError({
    code: 'UNAUTHENTICATED',
    message: 'Unauthenticated',
  });
}
```

The Flutter client looks for that code in either structured payloads or error strings:

```dart
bool isConvexUnauthenticatedError(Object error) {
  if (error is Map) {
    final code = error['code']?.toString().toUpperCase();
    if (code == 'UNAUTHENTICATED') {
      return true;
    }
  }

  return isConvexUnauthenticatedMessage(error.toString());
}
```

When that happens, the provider enters `incident` state and can prompt the user to:

- retry Convex auth
- sign out
- dismiss and keep cloud paused

Why this exists:

- Desktop sessions can drift out of sync.
- Supabase may still think the user is signed in while Convex no longer accepts the token or has lost the authenticated connection.
- This gives the app a controlled recovery path instead of repeated silent failures.

## 16. Why the race-protection code exists

`authProvider` contains several safeguards that are easy to overlook but are very important:

- `_authGeneration`
- `_sessionFingerprint(...)`
- `_isAuthContextCurrent(...)`
- `_inFlightConvexSetup`
- `_queuedConvexSetup`

These exist because auth setup is asynchronous and can be triggered many times:

- initial app startup
- Supabase sign-in
- OAuth callback completion
- session refresh
- manual retry
- sign-out

Without these guards, a stale setup task could finish late and overwrite state for a newer session.

In other words, this code is preventing classic auth race conditions.

## 17. Why this flow works overall

The flow is stable because each layer has a single responsibility:

- **Supabase** proves who the user is and issues JWTs.
- **Flutter authProvider** owns session lifecycle, token refresh, deep link handling, and bridge state.
- **Convex auth config** teaches Convex how to verify Supabase JWTs.
- `**users:ensureCurrentUser`** converts external identity into an app-level `users` row.
- `**requireCurrentUser` / `assertStrategyRole**` protect actual business data and collaboration rules.
- **Cloud feature gates** stop the UI from using Convex too early.
- **Incident handling** gives recovery behavior when Supabase and Convex drift apart.

That separation is the main reason the system is understandable and debuggable.

## 18. Failure points and what they usually mean

### Symptom: Supabase login succeeds but Convex queries return unauthenticated

Likely causes:

- `convex/auth.config.ts` no longer matches the Supabase issuer or JWKS
- the access token is not being forwarded to Convex
- token refresh failed and an expired token is being reused
- Convex connection did not fully re-authenticate after session change

First places to inspect:

- `convex/auth.config.ts`
- `_fetchSupabaseAccessToken()`
- `_runConvexAuthSetup(...)`
- `reportConvexUnauthenticated(...)`

### Symptom: user is authenticated but gets "Missing user record"

Likely causes:

- `users:ensureCurrentUser` never ran
- it ran before Convex auth was actually ready
- identity mapping changed and `findUserByIdentity(...)` can no longer find the row
- the `users` row was deleted or corrupted

First places to inspect:

- `users:ensureCurrentUser`
- `findUserByIdentity(...)`
- `users.externalId`
- `getCanonicalExternalId(...)`
- `getLegacyExternalId(...)`

### Symptom: Discord browser flow completes but app never signs in

Likely causes:

- the `icarus://auth/callback` deep link is not reaching the app
- the callback URI shape changed
- `getSessionFromUrl(...)` is failing
- duplicate-link filtering or platform URI handling is dropping the callback

First places to inspect:

- `signInWithDiscord()`
- `main.dart` deep link handling
- `handleAuthCallbackUri(...)`
- `isAuthCallbackUri(...)`

### Symptom: signed-in user cannot access a strategy

Likely causes:

- the user exists, but has no owner/collaborator mapping for that strategy
- collaborator rows are missing or wrong
- backend is correctly returning `Forbidden`

First places to inspect:

- `assertStrategyRole(...)`
- `getStrategyRoleForUser(...)`
- `strategyCollaborators`
- `strategies.ownerId`

## 19. Practical debug checklist

If auth breaks, verify these in order:

1. Does Supabase have a non-null current session?
2. Is `_fetchSupabaseAccessToken()` returning a real token?
3. Does `ConvexClient` transition to authenticated after `setAuthWithRefresh(...)` and `reconnect()`?
4. Does `ctx.auth.getUserIdentity()` return a value inside Convex?
5. Does `users:ensureCurrentUser` succeed?
6. Does `users.me` return the expected app user?
7. Does `requireCurrentUser(...)` resolve that user inside protected functions?
8. If the request is strategy-scoped, does `assertStrategyRole(...)` return the expected role?

If one of these steps fails, the break is usually in that layer or the layer immediately before it.

## 20. Mental model to keep in mind

The most useful mental model is:

- **Supabase session** means "the user has logged in".
- **Convex authenticated connection** means "Convex trusts the Supabase JWT".
- **Convex user row exists** means "the application can attach ownership and permissions to this identity".
- **Cloud enabled** means "all three conditions are true enough for the UI to rely on cloud state".

That distinction is the key to understanding the current system.