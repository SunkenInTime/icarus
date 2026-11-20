import { readFileSync } from "node:fs";
import { expect, test } from "vitest";
import { mergeElementPayload } from "../../convex/lib/fieldMerge";

const cases = JSON.parse(
  readFileSync(new URL("./cases/field_defaults.json", import.meta.url), "utf8"),
);

for (const entry of cases) {
  test(`${entry.name}: the server holds the merged payload`, () => {
    const envelope = (data: Record<string, unknown>) => ({
      kind: entry.kind,
      payloadVersion: 1,
      data,
    });
    expect(
      mergeElementPayload(envelope(entry.current), envelope(entry.desired), {
        fields: entry.fields,
      }),
    ).toEqual({ status: "merged", value: envelope(entry.merged) });
  });
}
