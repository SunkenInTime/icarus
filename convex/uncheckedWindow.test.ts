import {
  convexTest,
  type TestConvexForDataModel,
  type TestConvexForDataModelAndIdentity,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import type { DataModel } from "./_generated/dataModel";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "./lib/cloudProtocol";
import { UNCHECKED_WINDOW_MS } from "./ops";
import schema from "./schema";
import { modules } from "./test.setup";

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createStrategy = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const createShare = makeFunctionReference<"mutation">("shares:create");
const redeemShare = makeFunctionReference<"mutation">("shares:redeem");
const applyBatch = makeFunctionReference<"mutation">("ops:applyBatch");
const getPageSnapshot = makeFunctionReference<"query">("page:getSnapshot");

type Harness = TestConvexForDataModel<DataModel>;
type RootHarness = TestConvexForDataModelAndIdentity<DataModel>;
type Op = Record<string, unknown>;
type Answer = {
  strategyPublicId: string;
  results: Array<Record<string, unknown>>;
  serverTime?: number;
};
type Row = {
  publicId: string;
  payload: { data: Record<string, unknown> };
  revision: number;
  deleted: boolean;
};

const strategyPublicId = "window-strategy";
const pagePublicId = "window-page";
const start = Date.UTC(2026, 10, 22, 12, 0, 0);

function identity(subject: string) {
  return {
    issuer: "https://window.test",
    subject,
    tokenIdentifier: `window|${subject}`,
    name: subject,
  };
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(start);
});

afterEach(() => {
  vi.useRealTimers();
});

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
  await me.mutation(createStrategy, {
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    publicId: strategyPublicId,
    name: "Window",
    mapData: "ascent",
    initialPagePublicId: pagePublicId,
    initialPageName: "Page 1",
    initialPageIsAttack: true,
  });
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
  await batch(me, "setup", [
    {
      opId: "add-agent",
      type: "element.add",
      elementPublicId: "agent-1",
      pagePublicId,
      payload: agentPayload(),
      sortIndex: 0,
    },
  ]);
  return { t, me, teammate };
}

function agentPayload(overrides: Record<string, unknown> = {}) {
  return {
    kind: "agent",
    payloadVersion: 1,
    data: {
      id: "agent-1",
      elementType: "agent",
      kind: "plain",
      type: "sova",
      position: { dx: 10, dy: 20 },
      isAlly: true,
      state: "none",
      weapon: "none",
      isDeleted: false,
      lineUpID: null,
      ...overrides,
    },
  };
}

function batchArgs(clientId: string, ops: Op[], extra: Op = {}) {
  return {
    strategyPublicId,
    clientId,
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    ops,
    ...extra,
  };
}

async function batch(
  user: Harness,
  clientId: string,
  ops: Op[],
  extra: Op = {},
): Promise<Answer> {
  return (await user.mutation(
    applyBatch,
    batchArgs(clientId, ops, extra),
  )) as Answer;
}

async function refusal(promise: Promise<unknown>): Promise<unknown> {
  const outcome = await promise.then(
    () => undefined,
    (error: unknown) => error,
  );
  if (outcome === undefined) return "answered";
  const data = (outcome as { data?: unknown }).data;
  return (typeof data === "string" ? JSON.parse(data) : data)?.code;
}

async function liveBasis(user: Harness): Promise<number> {
  const answer = await batch(user, "basis", [], { sendsLiveBasis: true });
  expect(answer.serverTime).toBe(Date.now());
  return answer.serverTime!;
}

async function agent(user: Harness): Promise<Row> {
  const snapshot = (await user.query(getPageSnapshot, {
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    strategyPublicId,
    pagePublicId,
  })) as { elements: Row[] };
  return snapshot.elements.find((row) => row.publicId === "agent-1")!;
}

async function eventsFor(t: RootHarness, clientId: string, opId: string) {
  return await t.run(async (ctx) =>
    (await ctx.db.query("operationEvents").collect()).filter(
      (event) => event.clientId === clientId && event.opId === opId,
    ),
  );
}

function movePatch(
  opId: string,
  position: { dx: number; dy: number },
  base?: { dx: number; dy: number },
): Op {
  return {
    opId,
    type: "element.patch",
    elementPublicId: "agent-1",
    pagePublicId,
    payload: agentPayload({ position }),
    expectedElementRevision: 1,
    merge: {
      fields: ["position"],
      ...(base === undefined ? {} : { base: [{ field: "position", value: base }] }),
    },
  };
}

function sidePatch(opId: string, isAlly: boolean): Op {
  return {
    opId,
    type: "element.patch",
    elementPublicId: "agent-1",
    pagePublicId,
    payload: agentPayload({ isAlly }),
    expectedElementRevision: 1,
    merge: { fields: ["isAlly"] },
  };
}

function deleteAgent(opId: string, lastWriterWins: boolean): Op {
  return {
    opId,
    type: "element.delete",
    elementPublicId: "agent-1",
    pagePublicId,
    expectedElementRevision: 1,
    ...(lastWriterWins ? { lastWriterWins: true } : {}),
  };
}

describe("an unchecked change held by the transport past the window", () => {
  test("a field edit is refused, the teammate's value stays, and the checked retry is the ordinary conflict", async () => {
    const { t, me, teammate } = await createHarness();
    const basis = await liveBasis(me);
    const held = batchArgs("me", [movePatch("me-move", { dx: 90, dy: 90 })], {
      sendsLiveBasis: true,
      liveBasis: basis,
    });

    await batch(teammate, "teammate", [movePatch("their-move", { dx: 50, dy: 60 })]);
    vi.advanceTimersByTime(UNCHECKED_WINDOW_MS + 1);

    expect(await refusal(me.mutation(applyBatch, held))).toBe(
      "UNCHECKED_OUTSIDE_WINDOW",
    );
    expect((await agent(me)).payload.data.position).toEqual({ dx: 50, dy: 60 });
    expect(await eventsFor(t, "me", "me-move")).toEqual([]);

    const retried = await batch(
      me,
      "me",
      [movePatch("me-move", { dx: 90, dy: 90 }, { dx: 10, dy: 20 })],
      { sendsLiveBasis: true },
    );
    expect(retried.results).toMatchObject([
      { status: "rejected", reason: "field_conflict" },
    ]);
    expect((await agent(me)).payload.data.position).toEqual({ dx: 50, dy: 60 });
  });

  test("a delete is refused, the teammate's edit stays, and the checked retry is the ordinary conflict", async () => {
    const { t, me, teammate } = await createHarness();
    const basis = await liveBasis(me);
    const held = batchArgs("me", [deleteAgent("me-delete", true)], {
      sendsLiveBasis: true,
      liveBasis: basis,
    });

    await batch(teammate, "teammate", [sidePatch("their-side", false)]);
    vi.advanceTimersByTime(UNCHECKED_WINDOW_MS + 1);

    expect(await refusal(me.mutation(applyBatch, held))).toBe(
      "UNCHECKED_OUTSIDE_WINDOW",
    );
    expect(await agent(me)).toMatchObject({
      deleted: false,
      payload: { data: { isAlly: false } },
    });
    expect(await eventsFor(t, "me", "me-delete")).toEqual([]);

    const retried = await batch(me, "me", [deleteAgent("me-delete", false)], {
      sendsLiveBasis: true,
    });
    expect(retried.results).toMatchObject([
      { status: "rejected", reason: "revision_mismatch" },
    ]);
    expect(await agent(me)).toMatchObject({
      deleted: false,
      payload: { data: { isAlly: false } },
    });
  });
});

describe("an unchecked change inside the window", () => {
  test("a field edit lands as the last arrival", async () => {
    const { me, teammate } = await createHarness();
    const basis = await liveBasis(me);
    await batch(teammate, "teammate", [movePatch("their-move", { dx: 50, dy: 60 })]);
    vi.advanceTimersByTime(UNCHECKED_WINDOW_MS - 1);

    const answer = await batch(
      me,
      "me",
      [movePatch("me-move", { dx: 90, dy: 90 })],
      { sendsLiveBasis: true, liveBasis: basis },
    );
    expect(answer.results).toMatchObject([
      { status: "applied", appliedRevision: 3 },
    ]);
    expect(answer.serverTime).toBe(basis + UNCHECKED_WINDOW_MS - 1);
    expect((await agent(me)).payload.data.position).toEqual({ dx: 90, dy: 90 });
  });

  test("a delete lands over the teammate's edit", async () => {
    const { me, teammate } = await createHarness();
    const basis = await liveBasis(me);
    await batch(teammate, "teammate", [sidePatch("their-side", false)]);

    const answer = await batch(me, "me", [deleteAgent("me-delete", true)], {
      sendsLiveBasis: true,
      liveBasis: basis,
    });
    expect(answer.results).toMatchObject([{ status: "applied" }]);
    expect((await agent(me)).deleted).toBe(true);
  });
});

describe("the window's edge", () => {
  test("exactly the window after the basis is still inside it", async () => {
    const { me } = await createHarness();
    const basis = await liveBasis(me);
    vi.advanceTimersByTime(UNCHECKED_WINDOW_MS);

    const answer = await batch(
      me,
      "me",
      [movePatch("me-move", { dx: 90, dy: 90 })],
      { sendsLiveBasis: true, liveBasis: basis },
    );
    expect(answer.results).toMatchObject([{ status: "applied" }]);
  });

  test("one millisecond past the window is refused", async () => {
    const { me } = await createHarness();
    const basis = await liveBasis(me);
    vi.advanceTimersByTime(UNCHECKED_WINDOW_MS + 1);

    expect(
      await refusal(
        batch(me, "me", [movePatch("me-move", { dx: 90, dy: 90 })], {
          sendsLiveBasis: true,
          liveBasis: basis,
        }),
      ),
    ).toBe("UNCHECKED_OUTSIDE_WINDOW");
  });

  test("a basis later than the server's time is refused", async () => {
    const { me } = await createHarness();
    const basis = await liveBasis(me);

    expect(
      await refusal(
        batch(me, "me", [movePatch("me-move", { dx: 90, dy: 90 })], {
          sendsLiveBasis: true,
          liveBasis: basis + 1,
        }),
      ),
    ).toBe("UNCHECKED_OUTSIDE_WINDOW");
    expect((await agent(me)).revision).toBe(1);
  });
});

const uncheckedForms: Record<string, Op> = {
  "element field edit without a base": sidePatch("unchecked", false),
  "element delete by last writer": deleteAgent("unchecked", true),
  "lineup field edit without a base": {
    opId: "unchecked",
    type: "lineup.patch",
    lineupPublicId: "g",
    pagePublicId,
    payload: { kind: "lineups", payloadVersion: 1, data: {} },
    expectedLineupRevision: 1,
    merge: { fields: ["links/k1"] },
  },
  "lineup delete by last writer": {
    opId: "unchecked",
    type: "lineup.delete",
    lineupPublicId: "g",
    pagePublicId,
    expectedLineupRevision: 1,
    lastWriterWins: true,
  },
};

const checkedForms: Record<string, Op> = {
  "element field edit with its base": movePatch(
    "checked",
    { dx: 90, dy: 90 },
    { dx: 10, dy: 20 },
  ),
  "element delete checked by revision": deleteAgent("checked", false),
  "lineup field edit with its base": {
    opId: "checked",
    type: "lineup.patch",
    lineupPublicId: "g",
    pagePublicId,
    payload: { kind: "lineups", payloadVersion: 1, data: {} },
    expectedLineupRevision: 1,
    merge: { fields: ["links/k1"], base: [{ field: "links/k1" }] },
  },
  "element move to a new place": {
    opId: "checked",
    type: "element.reorder",
    elementPublicId: "agent-1",
    pagePublicId,
    sortIndex: 3,
    expectedElementRevision: 1,
  },
  "element add": {
    opId: "checked",
    type: "element.add",
    elementPublicId: "agent-2",
    pagePublicId,
    payload: agentPayload({ id: "agent-2" }),
    sortIndex: 1,
  },
  "lineup delete checked by revision": {
    opId: "checked",
    type: "lineup.delete",
    lineupPublicId: "g",
    pagePublicId,
    expectedLineupRevision: 1,
  },
};

describe("a client that sends live bases, with no basis", () => {
  test.each(Object.entries(uncheckedForms))(
    "is refused an %s",
    async (_, op) => {
      const { t, me } = await createHarness();
      expect(
        await refusal(batch(me, "me", [op], { sendsLiveBasis: true })),
      ).toBe("UNCHECKED_OUTSIDE_WINDOW");
      expect(await eventsFor(t, "me", "unchecked")).toEqual([]);
      expect((await agent(me)).revision).toBe(1);
    },
  );

  test.each(Object.entries(checkedForms))(
    "is answered for an %s",
    async (_, op) => {
      const { me } = await createHarness();
      const answer = await batch(me, "me", [op], { sendsLiveBasis: true });
      expect(answer.results).toHaveLength(1);
      expect(answer.serverTime).toBe(Date.now());
    },
  );

  test("the element field edit with its base lands", async () => {
    const { me } = await createHarness();
    const answer = await batch(
      me,
      "me",
      [movePatch("checked", { dx: 90, dy: 90 }, { dx: 10, dy: 20 })],
      { sendsLiveBasis: true },
    );
    expect(answer.results).toMatchObject([{ status: "applied" }]);
    expect((await agent(me)).payload.data.position).toEqual({ dx: 90, dy: 90 });
  });
});

describe("a client that does not send live bases", () => {
  test.each(Object.entries({ ...uncheckedForms, ...checkedForms }))(
    "is answered for an %s as before, with no server time",
    async (_, op) => {
      const { me } = await createHarness();
      const answer = await batch(me, "me", [op]);
      expect(Object.keys(answer).sort()).toEqual(["results", "strategyPublicId"]);
    },
  );

  test("has an unchecked edit land however long it was held", async () => {
    const { me, teammate } = await createHarness();
    const held = batchArgs("me", [movePatch("me-move", { dx: 90, dy: 90 })]);
    await batch(teammate, "teammate", [movePatch("their-move", { dx: 50, dy: 60 })]);
    vi.advanceTimersByTime(60 * 60 * 1000);

    const answer = (await me.mutation(applyBatch, held)) as Answer;
    expect(Object.keys(answer).sort()).toEqual(["results", "strategyPublicId"]);
    expect(answer.results).toMatchObject([
      { status: "applied", appliedRevision: 3 },
    ]);
    expect((await agent(me)).payload.data.position).toEqual({ dx: 90, dy: 90 });
  });

  test("has an unchecked delete land however long it was held", async () => {
    const { me, teammate } = await createHarness();
    const held = batchArgs("me", [deleteAgent("me-delete", true)]);
    await batch(teammate, "teammate", [sidePatch("their-side", false)]);
    vi.advanceTimersByTime(60 * 60 * 1000);

    const answer = (await me.mutation(applyBatch, held)) as Answer;
    expect(Object.keys(answer).sort()).toEqual(["results", "strategyPublicId"]);
    expect(answer.results).toMatchObject([{ status: "applied" }]);
    expect((await agent(me)).deleted).toBe(true);
  });
});
