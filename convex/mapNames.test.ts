import { convexTest } from "convex-test";
import { makeFunctionReference } from "convex/server";
import { expect, test } from "vitest";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "./lib/cloudProtocol";
import schema from "./schema";
import { modules } from "./test.setup";

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const create = makeFunctionReference<"mutation">("strategies:create");
const createWithInitialPage = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const update = makeFunctionReference<"mutation">("strategies:update");
const applyBatch = makeFunctionReference<"mutation">("ops:applyBatch");

const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };

async function createHarness() {
  const t = convexTest(schema, modules);
  const owner = t.withIdentity({
    issuer: "https://maps.test",
    subject: "owner",
    tokenIdentifier: "maps|owner",
  });
  await owner.mutation(ensureCurrentUser, protocol);
  await owner.mutation(create, {
    ...protocol,
    publicId: "s",
    name: "s",
    mapData: "ascent",
  });
  return { t, owner };
}

async function mapOf(t: Awaited<ReturnType<typeof createHarness>>["t"]) {
  return await t.run(async (ctx) => {
    const strategy = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", "s"))
      .unique();
    return strategy?.mapData;
  });
}

test("a strategy is only created on a map the app knows", async () => {
  const { owner } = await createHarness();
  await expect(
    owner.mutation(create, { ...protocol, publicId: "a", name: "a", mapData: "x" }),
  ).rejects.toThrow(/INVALID_PAYLOAD/);
  await expect(
    owner.mutation(createWithInitialPage, {
      ...protocol,
      publicId: "b",
      name: "b",
      mapData: "Ascent",
      initialPagePublicId: "b-page",
      initialPageName: "Page 1",
      initialPageIsAttack: true,
    }),
  ).rejects.toThrow(/INVALID_PAYLOAD/);
  // Every map a shipped build offers is accepted.
  for (const map of [
    "ascent", "breeze", "lotus", "icebox", "sunset", "split", "haven",
    "fracture", "abyss", "pearl", "bind", "corrode", "summit",
  ]) {
    await owner.mutation(create, {
      ...protocol,
      publicId: `on-${map}`,
      name: map,
      mapData: map,
    });
  }
});

test("an editor cannot move a strategy to a map the app does not know", async () => {
  const { t, owner } = await createHarness();
  await expect(
    owner.mutation(update, {
      ...protocol,
      strategyPublicId: "s",
      expectedRevision: 0,
      mapData: "x",
    }),
  ).rejects.toThrow(/INVALID_PAYLOAD/);

  const response = (await owner.mutation(applyBatch, {
    ...protocol,
    strategyPublicId: "s",
    clientId: "client-a",
    ops: [
      {
        opId: "bad-map",
        type: "strategy.patch",
        payload: { mapData: "x" },
        expectedStrategyRevision: 0,
      },
      {
        opId: "good-map",
        type: "strategy.patch",
        payload: { mapData: "bind" },
        expectedStrategyRevision: 0,
      },
    ],
  })) as { results: Array<Record<string, unknown>> };
  expect(response.results.map(({ opId, status, code }) => ({ opId, status, code })))
    .toEqual([
      { opId: "bad-map", status: "failed", code: "INVALID_PAYLOAD" },
      { opId: "good-map", status: "applied", code: undefined },
    ]);
  expect(await mapOf(t)).toBe("bind");
});

test("a strategy already on an unknown map can still be edited", async () => {
  const { t, owner } = await createHarness();
  await t.run(async (ctx) => {
    const strategy = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", "s"))
      .unique();
    await ctx.db.patch(strategy!._id, { mapData: "future-map" });
  });
  // Clients send the map they hold back with other changes.
  await owner.mutation(update, {
    ...protocol,
    strategyPublicId: "s",
    expectedRevision: 0,
    name: "renamed",
    mapData: "future-map",
  });
  const response = (await owner.mutation(applyBatch, {
    ...protocol,
    strategyPublicId: "s",
    clientId: "client-a",
    ops: [
      {
        opId: "same-map",
        type: "strategy.patch",
        payload: { name: "again", mapData: "future-map" },
        expectedStrategyRevision: 1,
      },
    ],
  })) as { results: Array<Record<string, unknown>> };
  expect(response.results[0]).toMatchObject({ status: "applied" });
  expect(await mapOf(t)).toBe("future-map");
});

test("a strategy already on an unknown map cannot be duplicated", async () => {
  const { t, owner } = await createHarness();
  await t.run(async (ctx) => {
    const strategy = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", "s"))
      .unique();
    await ctx.db.patch(strategy!._id, { mapData: "x" });
  });
  const duplicate = makeFunctionReference<"mutation">("strategies:duplicate");
  await expect(
    owner.mutation(duplicate, {
      ...protocol,
      sourceStrategyPublicId: "s",
      publicId: "copy",
      name: "copy",
    }),
  ).rejects.toThrow(/INVALID_PAYLOAD/);
});
