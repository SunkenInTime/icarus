import { describe, expect, test } from "vitest";
import { pageCopyId, pageCopyRoot } from "./lib/pageCopyId";

const fresh = "6f1c2d0e-3b4a-4c5d-8e9f-0a1b2c3d4e5f";

describe("page copy ids", () => {
  test("a copy's root is the id it was first copied from", () => {
    expect(pageCopyRoot("agent-1")).toBe("agent-1");
    expect(pageCopyRoot(`agent-1~cp1~${fresh}`)).toBe("agent-1");
  });

  test("an id that only looks like a copy stays its own root", () => {
    for (const id of [
      "a~cp1~not-a-uuid",
      `~cp1~${fresh}`,
      `agent-1~cp1~${fresh.toUpperCase()}`,
      "team~notes",
    ]) {
      expect(pageCopyRoot(id)).toBe(id);
    }
  });

  test("a copy of a copy keeps the first root, so ids never nest", () => {
    const first = pageCopyId("agent-1", () => fresh);
    expect(first).toBe(`agent-1~cp1~${fresh}`);
    expect(pageCopyId(first, () => "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d")).toBe(
      "agent-1~cp1~0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d",
    );
  });

  test("an unusually long root gets a plain id the app can store", () => {
    expect(pageCopyId("x".repeat(81), () => fresh)).toBe(fresh);
    expect(pageCopyId("x".repeat(80), () => fresh)).toBe(
      `${"x".repeat(80)}~cp1~${fresh}`,
    );
    // Measured as the app stores it, URL-encoded.
    expect(pageCopyId(" ".repeat(30), () => fresh)).toBe(fresh);
  });
});
