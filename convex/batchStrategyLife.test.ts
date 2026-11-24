import {
  convexTest,
  type TestConvexForDataModel,
  type TestConvexForDataModelAndIdentity,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import type { DataModel } from "./_generated/dataModel";
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
const createShare = makeFunctionReference<"mutation">("shares:create");
const redeemShare = makeFunctionReference<"mutation">("shares:redeem");
const applyBatch = makeFunctionReference<"mutation">("ops:applyBatch");

type Harness = TestConvexForDataModel<DataModel>;
type RootHarness = TestConvexForDataModelAndIdentity<DataModel>;
type Op = Record<string, unknown>;
type Answer = { results: Record<string, unknown>[] };

const strategyPublicId = "replaced-strategy";
const pagePublicId = "replaced-page";
const firstLife = Date.UTC(2026, 10, 24, 12, 0, 0);
const secondLife = firstLife + 60_000;

function identity(subject: string) {
  return {
    issuer: "https://strategy-life.test",
    subject,
    tokenIdentifier: `strategy-life|${subject}`,
    name: subject,
  };
}

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(firstLife);
});

afterEach(() => {
  vi.useRealTimers();
});

async function create(user: Harness) {
  await user.mutation(createStrategy, {
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    publicId: strategyPublicId,
    name: "Replaced",
    mapData: "ascent",
    initialPagePublicId: pagePublicId,
    initialPageName: "Page 1",
    initialPageIsAttack: true,
  });
}

async function harness(): Promise<{
  t: RootHarness;
  me: Harness;
  viewer: Harness;
}> {
  const t = convexTest(schema, modules);
  const me = t.withIdentity(identity("me"));
  const viewer = t.withIdentity(identity("viewer"));
  for (const user of [me, viewer]) {
    await user.mutation(ensureCurrentUser, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    });
  }
  await create(me);
  return { t, me, viewer };
}

async function replace(t: RootHarness, me: Harness, viewer: Harness) {
  await me.mutation(deleteStrategy, {
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    strategyPublicId,
    expectedRevision: 0,
  });
  vi.setSystemTime(secondLife);
  await create(me);
  await me.mutation(createShare, {
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    targetType: "strategy",
    targetPublicId: strategyPublicId,
    token: "viewer-token",
    role: "viewer",
  });
  await viewer.mutation(redeemShare, {
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    token: "viewer-token",
  });
  return await stored(t);
}

async function stored(t: RootHarness) {
  return await t.run(async (ctx) => {
    const strategy = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", strategyPublicId))
      .first();
    const strip = <R extends { _creationTime: number }>(rows: R[]) =>
      rows.map(({ _creationTime, ...row }) => row);
    return {
      strategy: strategy === null ? null : strip([strategy])[0],
      pages: strip(await ctx.db.query("pages").collect()),
      contents: strip(await ctx.db.query("pageContents").collect()),
      elements: strip(await ctx.db.query("elements").collect()),
      receipts: strip(await ctx.db.query("operationEvents").collect()),
    };
  });
}

function addItem(opId: string): Op {
  return {
    opId,
    type: "element.add",
    elementPublicId: `${opId}-item`,
    pagePublicId,
    payload: {
      kind: "agent",
      payloadVersion: 1,
      data: { id: `${opId}-item`, type: "jett" },
    },
    sortIndex: 0,
  };
}

function renamePage(opId: string): Op {
  return {
    opId,
    type: "page.patch",
    pagePublicId,
    payload: { name: "Renamed" },
    expectedPageRevision: 1,
  };
}

function renameStrategy(opId: string): Op {
  return {
    opId,
    type: "strategy.patch",
    payload: { name: "Renamed" },
    expectedStrategyRevision: 0,
  };
}

async function send(
  user: Harness,
  ops: Op[],
  options: { sendsLives?: boolean; strategyLife?: number } = {},
): Promise<Answer> {
  return (await user.mutation(applyBatch, {
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    strategyPublicId,
    clientId: "device",
    includeWasApplied: true,
    ops,
    ...(options.sendsLives === undefined
      ? {}
      : { sendsLives: options.sendsLives }),
    ...(options.strategyLife === undefined
      ? {}
      : { strategyLife: options.strategyLife }),
  })) as Answer;
}

async function refusal(call: Promise<unknown>): Promise<string> {
  try {
    await call;
  } catch (error) {
    return JSON.stringify((error as { data?: unknown }).data ?? String(error));
  }
  throw new Error("the call was not refused");
}

describe("a batch made in a strategy life that is gone", () => {
  test("is refused whole as STRATEGY_REPLACED, ops that name no life of their own included, and nothing is written", async () => {
    const { t, me, viewer } = await harness();
    const before = await replace(t, me, viewer);
    expect(before.strategy!.createdAt).toBe(secondLife);
    const ops = [
      addItem("add"),
      renamePage("rename-page"),
      renameStrategy("rename"),
    ];
    const refused = await refusal(
      send(me, ops, { sendsLives: true, strategyLife: firstLife }),
    );
    expect(refused).toContain("STRATEGY_REPLACED");
    expect(await stored(t)).toEqual(before);
  });

  test("is refused before any receipt is read: an op id the new strategy already holds is not replayed", async () => {
    const { t, me, viewer } = await harness();
    await replace(t, me, viewer);
    await send(me, [addItem("add")], {
      sendsLives: true,
      strategyLife: secondLife,
    });
    const before = await stored(t);
    const refused = await refusal(
      send(me, [addItem("add")], { sendsLives: true, strategyLife: firstLife }),
    );
    expect(refused).toContain("STRATEGY_REPLACED");
    expect(await stored(t)).toEqual(before);
  });

  test("meets the access check first: a viewer is told FORBIDDEN, not that the strategy was replaced", async () => {
    const { t, me, viewer } = await harness();
    await replace(t, me, viewer);
    const refused = await refusal(
      send(viewer, [addItem("add")], {
        sendsLives: true,
        strategyLife: firstLife,
      }),
    );
    expect(refused).toContain("FORBIDDEN");
    expect(refused).not.toContain("STRATEGY_REPLACED");
  });
});

describe("a batch made in the strategy's current life", () => {
  test("applies, and its answers and receipts equal the same batch sent without strategyLife", async () => {
    async function run(strategyLife?: number) {
      const { t, me, viewer } = await harness();
      await replace(t, me, viewer);
      const answer = await send(
        me,
        [addItem("add"), renamePage("rename-page"), renameStrategy("rename")],
        { sendsLives: true, strategyLife },
      );
      return { answer, stored: await stored(t) };
    }
    const named = await run(secondLife);
    const unnamed = await run();
    expect(named.answer.results.map((result) => result.status)).toEqual([
      "applied",
      "applied",
      "applied",
    ]);
    expect(JSON.stringify(named.answer)).toBe(JSON.stringify(unnamed.answer));
    expect(named.stored.receipts).toEqual(unnamed.stored.receipts);
    expect(named.stored.elements).toEqual(unnamed.stored.elements);
  });
});

describe("a caller that does not set sendsLives", () => {
  test("is answered byte for byte as today, with or without a strategyLife, even one from a life that is gone", async () => {
    async function run(strategyLife?: number) {
      const { t, me, viewer } = await harness();
      await replace(t, me, viewer);
      const answer = await send(
        me,
        [addItem("add"), renamePage("rename-page"), renameStrategy("rename")],
        { strategyLife },
      );
      return { answer, stored: await stored(t) };
    }
    const today = await run();
    const stale = await run(firstLife);
    const current = await run(secondLife);
    expect(JSON.stringify(today.answer)).not.toMatch(/[Ll]ife|REPLACED/);
    for (const other of [stale, current]) {
      expect(JSON.stringify(other.answer)).toBe(JSON.stringify(today.answer));
      expect(other.stored.receipts).toEqual(today.stored.receipts);
      expect(other.stored.elements).toEqual(today.stored.elements);
      expect(other.stored.pages).toEqual(today.stored.pages);
      expect(other.stored.strategy).toEqual(today.stored.strategy);
    }
  });
});
