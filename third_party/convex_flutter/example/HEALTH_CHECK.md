# Health Check Query Setup (Optional)

To use the health check functionality in this example app, you can optionally create a simple health check query in your Convex backend. This is **recommended but not required** - you can use any existing query instead.

## Why Create a Dedicated Health Check?

A dedicated health check query provides:
- **Lightweight**: No database queries or complex logic
- **Fast**: Minimal processing time
- **Clear Purpose**: Obviously for health checks
- **No Side Effects**: Doesn't modify any data
- **Best Practice**: Follows Convex and REST API conventions

However, if you prefer, you can use any existing lightweight query (like `users:count` or `messages:list`) instead.

## Creating the Health Check Query

Create a file `convex/health.ts` in your Convex backend with the following content:

```typescript
// convex/health.ts
import { query } from "./_generated/server";

export const ping = query({
  args: {},
  handler: async () => {
    return "ok";
  },
});
```

This creates a lightweight query endpoint at `health:ping` that:
- Takes no arguments
- Returns a simple "ok" response
- Can be used for connection health checks
- Has minimal overhead

## Using the Health Check

The example app uses this query in two ways:

### 1. Automatic Connection on Startup

The HomeScreen triggers the health check automatically when the app starts:

```dart
await ConvexClient.instance.query('health:ping', {});
```

This establishes the WebSocket connection immediately, allowing the connection state to transition from "connecting" to "connected".

### 2. Manual Connection Checks (Deprecated)

The deprecated `checkConnection()` method uses the configured `healthCheckQuery`:

```dart
await ConvexClient.initialize(
  ConvexConfig(
    healthCheckQuery: "health:ping",
  ),
);

final status = await ConvexClient.instance.checkConnection();
```

## Why Use a Dedicated Health Check Query?

1. **Lightweight**: No database queries or complex logic
2. **Fast**: Minimal processing time
3. **Idempotent**: Safe to call repeatedly
4. **No Side Effects**: Doesn't modify any data
5. **Clear Purpose**: Obvious what it's for

## Alternative

If you don't want to create a dedicated health check query, you can use any existing lightweight query from your backend:

```dart
// Use any existing query
await ConvexClient.initialize(
  ConvexConfig(
    healthCheckQuery: "users:count", // Any lightweight query
  ),
);
```

However, a dedicated health check endpoint is the recommended best practice.
