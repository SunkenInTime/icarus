import {
  convexTest,
  type TestConvexForDataModel,
  type TestConvexForDataModelAndIdentity,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import type { DataModel } from "./_generated/dataModel";
import { markAssetReferencesReady } from "./lib/assetReferences";
import {
  CURRENT_CLOUD_PROTOCOL_VERSION,
  MAX_CLOUD_OPERATION_BYTES,
  serializedConvexValueUtf8Bytes,
} from "./lib/cloudProtocol";
import schema from "./schema";
import { oneLineupPayload } from "./testContent.helpers";
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

const shippedReasons = [
  "already_exists",
  "deleted",
  "element_strategy_mismatch",
  "lineup_strategy_mismatch",
  "missing_expected_revision",
  "not_found",
  "page_strategy_mismatch",
  "revision_mismatch",
  "field_conflict",
  "merge_invalid",
];

function expectShippedContract(answers: Result[]) {
  for (const answer of answers) {
    expect(JSON.stringify(answer)).not.toMatch(/[Ll]ife/);
    if (answer.status === "rejected") {
      expect(shippedReasons).toContain(answer.reason);
    }
  }
}

function lineupAdd(opId: string, id: string): Op {
  return {
    opId,
    type: "lineup.add",
    lineupPublicId: id,
    pagePublicId,
    payload: oneLineupPayload(id),
    sortIndex: 0,
  };
}

describe("a client that sends no lives stays inside the contract it shipped with", () => {
  test("a sequence over every row kind, with a stale patch, a failed op and a replay of an opted-in refusal, answers only in fields and reasons shipped clients know", async () => {
    const { t, me } = await replacedElement();
    const [refused] = await send(me, "me", [move("refused-once", 1, start)], true);
    expect(refused!.reason).toBe("row_replaced");
    const answers: Result[] = [];
    const plain = async (ops: Op[]) => {
      answers.push(...(await send(me, "me", ops)));
    };
    await plain([
      {
        opId: "rename",
        type: "strategy.patch",
        payload: { name: "Renamed" },
        expectedStrategyRevision: 0,
      },
    ]);
    await plain([
      {
        opId: "page-2",
        type: "page.add",
        pagePublicId: "page-2",
        payload: { name: "Page 2", isAttack: true },
        sortIndex: 1,
        expectedStrategyRevision: 1,
      },
    ]);
    await plain([
      {
        opId: "page-rename",
        type: "page.patch",
        pagePublicId: "page-2",
        payload: { name: "Two" },
        expectedPageRevision: 1,
      },
    ]);
    await plain([
      {
        opId: "settings",
        type: "pageContent.patch",
        pagePublicId: "page-2",
        settings: { agentSize: 2, abilitySize: 1, useNeutralTeamColors: false },
        expectedPageContentRevision: 1,
      },
    ]);
    await plain([
      {
        opId: "page-reorder",
        type: "page.reorder",
        pagePublicId: "page-2",
        sortIndex: 0,
        expectedStrategyRevision: 2,
      },
    ]);
    await plain([move("stale", 1)]);
    await plain([
      {
        opId: "wrong-kind",
        type: "element.patch",
        elementPublicId: "e1",
        payload: { kind: "text", payloadVersion: 1, data: { id: "e1" } },
        sortIndex: 0,
        expectedElementRevision: 1,
      },
    ]);
    await plain([lineupAdd("lineup-add", "g1")]);
    await plain([
      {
        opId: "lineup-delete",
        type: "lineup.delete",
        lineupPublicId: "g1",
        pagePublicId,
        expectedLineupRevision: 1,
      },
    ]);
    await plain([remove("plain-delete", 1)]);
    await plain([move("refused-once", 1, start)]);
    const statuses = answers.map((answer) => answer.status);
    expect(statuses).toContain("rejected");
    expect(statuses).toContain("failed");
    expect(statuses).toContain("applied");
    const replayed = answers[answers.length - 1]!;
    expect(replayed).toMatchObject({
      opId: "refused-once",
      status: "rejected",
      reason: "revision_mismatch",
    });
    expectShippedContract(answers);
    const receipts = await t.run(async (ctx) =>
      (await ctx.db.query("operationEvents").collect()).filter(
        (event) => event.opId === "refused-once",
      ),
    );
    expect(receipts).toHaveLength(1);
  });
});

describe("an op id sent again", () => {
  test("after its row's id was reused, an op that carried a life replays the revision and life it landed on, leaves the replacement alone and writes no second receipt", async () => {
    const { t, me, teammate } = await createHarness();
    await send(me, "me", [add("add-1")], true);
    const [moved] = await send(me, "me", [move("move-1", 1, start)], true);
    expect(moved).toMatchObject({ appliedRevision: 2, appliedLife: start });
    await send(teammate, "teammate", [remove("teammate-delete", 2)]);
    await purge(t);
    await send(teammate, "teammate", [add("teammate-add", { rotation: 135 })]);
    const replacement = await element(t);
    const [again] = await send(me, "me", [move("move-1", 1, start)], true);
    expect(again).toEqual({
      opId: "move-1",
      status: "noop",
      currentRevision: 2,
      currentLife: start,
      wasApplied: true,
    });
    expect(await element(t)).toEqual(replacement);
    const receipts = await t.run(async (ctx) =>
      (await ctx.db.query("operationEvents").collect()).filter(
        (event) => event.opId === "move-1",
      ),
    );
    expect(receipts).toHaveLength(1);
  });
});

describe("each op checks the life of the row whose revision it checks", () => {
  test("with a strategy, its page and the page's settings created at three different times, a strategy patch, a page patch and a settings patch each accept only their own row's life", async () => {
    const { t, me } = await createHarness();
    vi.setSystemTime(start + 1000);
    await send(me, "me", [
      {
        opId: "page-2",
        type: "page.add",
        pagePublicId: "page-2",
        payload: { name: "Page 2", isAttack: true },
        sortIndex: 1,
        expectedStrategyRevision: 0,
      },
    ]);
    const pageLife = start + 1000;
    const contentLife = start + 2000;
    await t.run(async (ctx) => {
      const page = await ctx.db
        .query("pages")
        .withIndex("by_publicId", (q) => q.eq("publicId", "page-2"))
        .first();
      const content = await ctx.db
        .query("pageContents")
        .withIndex("by_pageId", (q) => q.eq("pageId", page!._id))
        .first();
      await ctx.db.patch(content!._id, { createdAt: contentLife });
    });
    const lives = [start, pageLife, contentLife];
    const cases: Array<[string, (opId: string, life: number) => Op, number]> = [
      [
        "strategy",
        (opId, life) => ({
          opId,
          type: "strategy.patch",
          payload: { name: opId },
          expectedStrategyRevision: 1,
          expectedLife: life,
        }),
        start,
      ],
      [
        "page",
        (opId, life) => ({
          opId,
          type: "page.patch",
          pagePublicId: "page-2",
          payload: { name: opId },
          expectedPageRevision: 1,
          expectedLife: life,
        }),
        pageLife,
      ],
      [
        "settings",
        (opId, life) => ({
          opId,
          type: "pageContent.patch",
          pagePublicId: "page-2",
          settings: { agentSize: 3, abilitySize: 1, useNeutralTeamColors: false },
          expectedPageContentRevision: 1,
          expectedLife: life,
        }),
        contentLife,
      ],
    ];
    for (const [name, op, own] of cases) {
      for (const life of lives.filter((life) => life !== own)) {
        const [answer] = await send(me, "me", [op(`${name}-${life}`, life)], true);
        expect(answer, `${name} with life ${life}`).toMatchObject({
          status: "rejected",
          reason: "row_replaced",
          current: { life: own },
        });
      }
      const [answer] = await send(me, "me", [op(`${name}-own`, own)], true);
      expect(answer, name).toMatchObject({ status: "applied", appliedLife: own });
    }
  });

  test("a put-back in a batch that sends lives is not_found when its row is gone, with or without a life on the op", async () => {
    const { t, me } = await createHarness();
    await send(me, "me", [add("add-1")], true);
    await send(me, "me", [remove("delete-1", 1)], true);
    await purge(t);
    const [answer] = await send(
      me,
      "me",
      [{ ...add("back"), expectedElementRevision: 2 }],
      true,
    );
    expect(answer).toEqual({ opId: "back", status: "rejected", reason: "not_found" });
    expect(await element(t)).toBeNull();
  });

  test("a life mismatch on a page in the trash meets the trash first, as today, so row_replaced always carries the row", async () => {
    const { me } = await createHarness();
    await send(me, "me", [
      {
        opId: "page-2",
        type: "page.add",
        pagePublicId: "page-2",
        payload: { name: "Page 2", isAttack: true },
        sortIndex: 1,
        expectedStrategyRevision: 0,
      },
    ]);
    await send(me, "me", [
      {
        opId: "trash",
        type: "page.delete",
        pagePublicId: "page-2",
        expectedStrategyRevision: 1,
      },
    ]);
    const [answer] = await send(
      me,
      "me",
      [
        {
          opId: "rename",
          type: "page.patch",
          pagePublicId: "page-2",
          payload: { name: "Late" },
          expectedPageRevision: 1,
          expectedLife: start - 1,
        },
      ],
      true,
    );
    expect(answer).toMatchObject({ status: "failed", code: "PAGE_DELETED" });
  });

  test("a page with two settings rows fails only its own op when lives are sent, and the rest of the batch applies", async () => {
    const { t, me } = await createHarness();
    await t.run(async (ctx) => {
      const page = await ctx.db
        .query("pages")
        .withIndex("by_publicId", (q) => q.eq("publicId", pagePublicId))
        .first();
      await ctx.db.insert("pageContents", {
        pageId: page!._id,
        revision: 1,
        createdAt: start,
        updatedAt: start,
      });
    });
    const answers = await send(
      me,
      "me",
      [
        {
          opId: "settings",
          type: "pageContent.patch",
          pagePublicId,
          settings: { agentSize: 2, abilitySize: 1, useNeutralTeamColors: false },
          expectedPageContentRevision: 1,
          expectedLife: start - 1,
        },
        add("add-1"),
      ],
      true,
    );
    expect(answers[0]).toMatchObject({
      status: "failed",
      code: "INVALID_PAGE_CONTENT_COUNT",
    });
    expect(answers[1]).toMatchObject({ status: "applied", appliedRevision: 1 });
  });
});

describe("the op size limit", () => {
  function patchOfSize(bytes: number, life?: number): Op {
    const op = (pad: string): Op => ({
      opId: "big",
      type: "element.patch",
      elementPublicId: "e1",
      payload: agent("e1", { note: pad }),
      sortIndex: 0,
      expectedElementRevision: 1,
    });
    const base = serializedConvexValueUtf8Bytes(op(""));
    return {
      ...op("x".repeat(bytes - base)),
      ...(life === undefined ? {} : { expectedLife: life }),
    };
  }

  test("an op exactly at the limit fits with or without a life, and with or without sendsLives; one byte more does not", async () => {
    expect(serializedConvexValueUtf8Bytes(patchOfSize(MAX_CLOUD_OPERATION_BYTES))).toBe(
      MAX_CLOUD_OPERATION_BYTES,
    );
    for (const [life, lives] of [
      [undefined, false],
      [start, false],
      [start, true],
    ] as const) {
      const { me } = await createHarness();
      await send(me, "me", [add("add-1")], true);
      const [fits] = await send(
        me,
        "me",
        [patchOfSize(MAX_CLOUD_OPERATION_BYTES, life)],
        lives,
      );
      expect(fits, `life ${life}, lives ${lives}`).toMatchObject({
        status: "applied",
      });
    }
    const { me } = await createHarness();
    await send(me, "me", [add("add-1")], true);
    const [over] = await send(me, "me", [
      patchOfSize(MAX_CLOUD_OPERATION_BYTES + 1),
    ]);
    expect(over).toMatchObject({ status: "failed", code: "INVALID_PAYLOAD" });
  });
});
