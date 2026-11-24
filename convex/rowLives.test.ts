import {
  convexTest,
  type TestConvexForDataModel,
  type TestConvexForDataModelAndIdentity,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import type { DataModel } from "./_generated/dataModel";
import { markAssetReferencesReady } from "./lib/assetReferences";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "./lib/cloudProtocol";
import schema from "./schema";
import { modules } from "./test.setup";

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createStrategy = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const deleteStrategy = makeFunctionReference<"mutation">("strategies:delete");
const abandonMove = makeFunctionReference<"mutation">("strategies:abandonMove");
const createShare = makeFunctionReference<"mutation">("shares:create");
const redeemShare = makeFunctionReference<"mutation">("shares:redeem");
const applyBatch = makeFunctionReference<"mutation">("ops:applyBatch");
const purgeOldTombstones = makeFunctionReference<"mutation">(
  "maintenance:purgeOldTombstones",
);

type Harness = TestConvexForDataModel<DataModel>;
type RootHarness = TestConvexForDataModelAndIdentity<DataModel>;
type Op = Record<string, unknown>;
type Result = Record<string, unknown>;

const strategyPublicId = "lives-strategy";
const pagePublicId = "lives-page";
const start = Date.UTC(2026, 10, 22, 12, 0, 0);
const day = 24 * 60 * 60 * 1000;

function identity(subject: string) {
  return {
    issuer: "https://lives.test",
    subject,
    tokenIdentifier: `lives|${subject}`,
    name: subject,
  };
}

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(start);
});

afterEach(() => {
  vi.useRealTimers();
});

async function create(
  user: Harness,
  extra: { unfinishedMove?: boolean } = {},
) {
  await user.mutation(createStrategy, {
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    publicId: strategyPublicId,
    name: "Lives",
    mapData: "ascent",
    initialPagePublicId: pagePublicId,
    initialPageName: "Page 1",
    initialPageIsAttack: true,
    ...extra,
  });
}

async function createHarness(): Promise<{
  t: RootHarness;
  me: Harness;
  teammate: Harness;
}> {
  const t = convexTest(schema, modules);
  const me = t.withIdentity(identity("me"));
  const teammate = t.withIdentity(identity("teammate"));
  for (const user of [me, teammate]) {
    await user.mutation(ensureCurrentUser, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    });
  }
  await create(me);
  await me.mutation(createShare, {
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    targetType: "strategy",
    targetPublicId: strategyPublicId,
    token: "editor-token",
    role: "editor",
  });
  await teammate.mutation(redeemShare, {
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    token: "editor-token",
  });
  return { t, me, teammate };
}

async function send(
  user: Harness,
  clientId: string,
  ops: Op[],
  lives = false,
): Promise<Result[]> {
  const answer = (await user.mutation(applyBatch, {
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    strategyPublicId,
    clientId,
    includeWasApplied: true,
    ...(lives ? { sendsLives: true } : {}),
    ops,
  })) as { results: Result[] };
  return answer.results;
}

function agent(id: string, fields: Record<string, unknown> = {}) {
  return { kind: "agent", payloadVersion: 1, data: { id, type: "jett", ...fields } };
}

function add(opId: string, fields: Record<string, unknown> = {}): Op {
  return {
    opId,
    type: "element.add",
    elementPublicId: "e1",
    pagePublicId,
    payload: agent("e1", fields),
    sortIndex: 0,
  };
}

function move(opId: string, expected: number, life?: number): Op {
  return {
    opId,
    type: "element.patch",
    elementPublicId: "e1",
    payload: agent("e1", { position: { dx: 40, dy: 0 } }),
    sortIndex: 0,
    expectedElementRevision: expected,
    ...(life === undefined ? {} : { expectedLife: life }),
  };
}

function remove(opId: string, expected: number, life?: number): Op {
  return {
    opId,
    type: "element.delete",
    elementPublicId: "e1",
    pagePublicId,
    expectedElementRevision: expected,
    ...(life === undefined ? {} : { expectedLife: life }),
  };
}

async function element(t: RootHarness) {
  return await t.run(async (ctx) =>
    ctx.db
      .query("elements")
      .withIndex("by_publicId", (q) => q.eq("publicId", "e1"))
      .first(),
  );
}

async function purge(t: RootHarness) {
  await t.run(markAssetReferencesReady);
  vi.setSystemTime(Date.now() + 31 * day);
  await t.mutation(purgeOldTombstones, {});
  await t.finishAllScheduledFunctions(vi.runAllTimers);
}

async function replacedElement() {
  const harness = await createHarness();
  const { t, me, teammate } = harness;
  await send(me, "me", [add("add-1")], true);
  await send(teammate, "teammate", [remove("teammate-delete", 1)]);
  await purge(t);
  await send(teammate, "teammate", [add("teammate-add", { rotation: 135 })]);
  return { ...harness, replacement: await element(t) };
}

describe("an op names the life of the row it was authored on", () => {
  test("a write or a delete authored on an earlier life of its row is refused as row_replaced, and the replacement is untouched", async () => {
    const { t, me, replacement } = await replacedElement();
    expect(replacement!.createdAt).toBe(start + 31 * day);
    for (const op of [move("my-move", 1, start), remove("my-delete", 1, start)]) {
      const [answer] = await send(me, "me", [op], true);
      expect(answer).toEqual({
        opId: op.opId,
        status: "rejected",
        reason: "row_replaced",
        current: {
          type: "element",
          revision: 1,
          life: start + 31 * day,
          value: replacement!.payload,
        },
      });
      expect(await element(t)).toEqual(replacement);
    }
  });

  test("the same write from a client that sends no lives lands on the replacement, as it does today, and so does one that names a life without opting in", async () => {
    for (const life of [undefined, start]) {
      const { t, me } = await replacedElement();
      const [answer] = await send(me, "me", [move("plain-move", 1, life)]);
      expect(answer).toEqual({
        opId: "plain-move",
        status: "applied",
        appliedRevision: 2,
      });
      expect((await element(t))!.revision).toBe(2);
    }
  });

  test("an op on the life it was authored on goes as before, and its answer names that life", async () => {
    const { t, me } = await createHarness();
    const [added] = await send(me, "me", [add("add-1")], true);
    expect(added).toEqual({
      opId: "add-1",
      status: "applied",
      appliedRevision: 1,
      appliedLife: start,
    });
    const [moved] = await send(me, "me", [move("move-1", 1, start)], true);
    expect(moved).toEqual({
      opId: "move-1",
      status: "applied",
      appliedRevision: 2,
      appliedLife: start,
    });
    expect((await element(t))!.revision).toBe(2);
  });

  test("a put-back authored on a tombstone that was purged is refused as not_found; without lives it adds the row again, as it does today", async () => {
    const { t, me } = await createHarness();
    await send(me, "me", [add("add-1")], true);
    await send(me, "me", [remove("delete-1", 1)], true);
    await purge(t);
    const putBack = (life?: number): Op => ({
      ...add(life === undefined ? "plain-back" : "back"),
      expectedElementRevision: 2,
      ...(life === undefined ? {} : { expectedLife: life }),
    });
    const [refused] = await send(me, "me", [putBack(start)], true);
    expect(refused).toEqual({
      opId: "back",
      status: "rejected",
      reason: "not_found",
    });
    expect(await element(t)).toBeNull();
    const [plain] = await send(me, "me", [putBack()]);
    expect(plain).toEqual({
      opId: "plain-back",
      status: "applied",
      appliedRevision: 1,
    });
  });

  test("a replayed answer names the life the op landed on, from its receipt", async () => {
    const { me } = await createHarness();
    await send(me, "me", [add("add-1")], true);
    const [replayed] = await send(me, "me", [add("add-1")], true);
    expect(replayed).toEqual({
      opId: "add-1",
      status: "noop",
      currentRevision: 1,
      wasApplied: true,
      currentLife: start,
    });
  });
});

describe("a strategy deleted and made again under the same id is another life", () => {
  async function recreated(how: "deleted" | "abandoned") {
    const t = convexTest(schema, modules);
    const me = t.withIdentity(identity("me"));
    await me.mutation(ensureCurrentUser, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    });
    if (how === "deleted") {
      await create(me);
      await me.mutation(deleteStrategy, {
        clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
        strategyPublicId,
        expectedRevision: 0,
      });
      vi.setSystemTime(start + 60_000);
      await create(me);
    } else {
      await create(me, { unfinishedMove: true });
      await me.mutation(abandonMove, {
        clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
        strategyPublicId,
      });
      vi.setSystemTime(start + 60_000);
      await create(me, { unfinishedMove: true });
    }
    const strategy = async () =>
      await t.run(async (ctx) =>
        ctx.db
          .query("strategies")
          .withIndex("by_publicId", (q) => q.eq("publicId", strategyPublicId))
          .first(),
      );
    return { t, me, strategy, before: await strategy() };
  }

  for (const how of ["deleted", "abandoned"] as const) {
    test(`${how === "deleted" ? "a deleted strategy uploaded again" : "an abandoned move made again"}: an op authored on the old strategy is refused as row_replaced and the new strategy is untouched; without lives it applies, as it does today`, async () => {
      const { me, strategy, before } = await recreated(how);
      expect(before!.createdAt).toBe(start + 60_000);
      const rename = (opId: string, life?: number): Op => ({
        opId,
        type: "strategy.patch",
        payload: { name: "Renamed" },
        expectedStrategyRevision: before!.revision,
        ...(life === undefined ? {} : { expectedLife: life }),
      });
      const addPage = (opId: string, life?: number): Op => ({
        opId,
        type: "page.add",
        pagePublicId: `${opId}-page`,
        payload: { name: "Page 2", isAttack: true },
        sortIndex: 1,
        expectedStrategyRevision: before!.revision,
        ...(life === undefined ? {} : { expectedLife: life }),
      });
      for (const op of [rename("old-rename", start), addPage("old-page", start)]) {
        const [answer] = await send(me, "me", [op], true);
        expect(answer).toMatchObject({
          opId: op.opId,
          status: "rejected",
          reason: "row_replaced",
          current: { type: "strategy", life: start + 60_000 },
        });
        expect(await strategy()).toEqual(before);
      }
      const [plain] = await send(me, "me", [rename("plain-rename")]);
      expect(plain).toMatchObject({ opId: "plain-rename", status: "applied" });
      expect((await strategy())!.name).toBe("Renamed");
    });
  }
});

describe("a client that sends no lives sees nothing new", () => {
  const sequence = (lives: boolean): Op[][] => [
    [add("add-1")],
    [move("move-1", 1, lives ? start : undefined)],
    [move("stale", 1, lives ? start : undefined)],
    [remove("delete-1", 2, lives ? start : undefined)],
    [add("add-1")],
  ];

  function withoutLives(value: unknown): unknown {
    if (Array.isArray(value)) return value.map(withoutLives);
    if (value === null || typeof value !== "object") return value;
    return Object.fromEntries(
      Object.entries(value)
        .filter(([key]) => !key.endsWith("Life") && key !== "life")
        .map(([key, entry]) => [key, withoutLives(entry)]),
    );
  }

  async function run(lives: boolean) {
    const { t, me } = await createHarness();
    const answers: Result[][] = [];
    for (const ops of sequence(lives)) {
      answers.push(await send(me, "me", ops, lives));
    }
    const receipts = await t.run(async (ctx) =>
      (await ctx.db.query("operationEvents").collect()).map(
        ({ _id, _creationTime, strategyId, pageId, ...event }) => event,
      ),
    );
    return { answers, receipts, element: await element(t) };
  }

  test("its answers carry no life field, its receipts record none, and both equal an opted-in client's with the lives taken out", async () => {
    const plain = await run(false);
    const opted = await run(true);
    expect(JSON.stringify(plain.answers)).not.toMatch(/[Ll]ife/);
    expect(JSON.stringify(plain.receipts)).not.toMatch(/[Ll]ife/);
    expect(JSON.stringify(opted.answers)).toMatch(/appliedLife/);
    expect(plain.answers).toEqual(withoutLives(opted.answers));
    expect(plain.receipts).toEqual(withoutLives(opted.receipts));
    expect(withoutLives(plain.element)).toEqual(withoutLives(opted.element));
  });
});
