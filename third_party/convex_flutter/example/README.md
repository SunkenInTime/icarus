# convex_flutter_example

Demonstrates how to use the convex_flutter plugin.

## Usage Example

Here's an example of how to send a message using a Convex mutation:

```dart
await ConvexClient.instance.mutation(
  name: "messages:send",
  args: {"body": message, "author": "Singh"},
);
```

Here's an example of how to query the backend:

```dart
final result = await client.query('your_query');
```
