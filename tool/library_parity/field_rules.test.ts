import { readFileSync } from "node:fs";
import { expect, test } from "vitest";
import { ELEMENT_IDENTITY_KEYS } from "../../convex/lib/fieldMerge";
import { LATER_ELEMENT_FIELDS } from "../../convex/lib/elementFields";

const rules = JSON.parse(readFileSync(process.env.FIELD_RULES!, "utf8"));

test("the package and the server name the same identity keys", () => {
  expect([...rules.elementIdentityKeys].sort()).toEqual(
    [...ELEMENT_IDENTITY_KEYS].sort(),
  );
});

test("the package and the server hold the same later fields", () => {
  const shape = (entries: Array<{ field: string; level: number; kinds: readonly string[] }>) =>
    entries
      .map(({ field, level, kinds }) => ({ field, level, kinds: [...kinds].sort() }))
      .sort((a, b) => a.field.localeCompare(b.field));
  expect(shape(rules.laterElementFields)).toEqual(shape(LATER_ELEMENT_FIELDS));
});
