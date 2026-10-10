import {
  convexTest,
  type TestConvexForDataModel,
  type TestConvexForDataModelAndIdentity,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { describe, expect, test } from "vitest";
import type { DataModel } from "./_generated/dataModel";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "./lib/cloudProtocol";
import schema from "./schema";
import { lineupsPayload, type TestLineupGroup } from "./testContent.helpers";
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
type Result = Record<string, unknown>;
type Row = {
  publicId: string;
  payload: { kind: string; payloadVersion: number; data: Record<string, any> };
  revision: number;
  deleted: boolean;
  sortIndex: number;
};

const strategyPublicId = "merge-strategy";
const pagePublicId = "merge-page";

function identity(subject: string) {
  return {
    issuer: "https://merge.test",
    subject,
    tokenIdentifier: `merge|${subject}`,
    name: subject,
  };
}

/// Two editors of one strategy: its owner and a teammate.
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
    name: "Merge",
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
  return { t, me, teammate };
}

let opCount = 0;
function nextOpId(): string {
  opCount += 1;
  return `op-${opCount}`;
}

async function apply(
  user: Harness,
  clientId: string,
  ops: Array<Record<string, unknown>>,
): Promise<Result[]> {
  const response = (await user.mutation(applyBatch, {
    strategyPublicId,
    clientId,
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    ops,
  })) as { results: Result[] };
  return response.results;
}

async function applyOne(
  user: Harness,
  clientId: string,
  op: Record<string, unknown>,
): Promise<Result> {
  const [result] = await apply(user, clientId, [op]);
  return result;
}

async function snapshot(user: Harness): Promise<{
  elements: Row[];
  lineups: Row[];
}> {
  return (await user.query(getPageSnapshot, {
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    strategyPublicId,
    pagePublicId,
  })) as { elements: Row[]; lineups: Row[] };
}

async function element(user: Harness, id: string): Promise<Row> {
  const row = (await snapshot(user)).elements.find((e) => e.publicId === id);
  expect(row).toBeDefined();
  return row!;
}

async function lineup(user: Harness, id: string): Promise<Row> {
  const row = (await snapshot(user)).lineups.find((l) => l.publicId === id);
  expect(row).toBeDefined();
  return row!;
}

// ---------------------------------------------------------------- elements

type AgentData = Record<string, unknown>;

function agentData(overrides: AgentData = {}): AgentData {
  return {
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
  };
}

function agentPayload(data: AgentData, payloadVersion = 1) {
  return { kind: "agent", payloadVersion, data };
}

async function addAgent(user: Harness, data: AgentData = agentData()) {
  const result = await applyOne(user, "setup", {
    opId: nextOpId(),
    type: "element.add",
    elementPublicId: data.id,
    pagePublicId,
    payload: agentPayload(data),
    sortIndex: 0,
  });
  expect(result.status).toBe("applied");
}

/// A patch from a client that merges by field: the whole agent as that
/// client has it, naming the fields it changed, and their base values when
/// it waited offline.
function mergePatch(
  data: AgentData,
  fields: string[],
  expectedElementRevision: number,
  base?: Record<string, unknown>,
  payloadVersion = 1,
) {
  return {
    opId: nextOpId(),
    type: "element.patch",
    elementPublicId: data.id,
    pagePublicId,
    payload: agentPayload(data, payloadVersion),
    expectedElementRevision,
    merge: {
      fields,
      ...(base === undefined
        ? {}
        : {
            base: fields.map((field) =>
              field in base && base[field] !== undefined
                ? { field, value: base[field] }
                : { field },
            ),
          }),
    },
  };
}

describe("element field merge", () => {
  test("two teammates changing different fields from the same revision both land", async () => {
    const { me, teammate } = await createHarness();
    await addAgent(me);

    // Both start from revision 1. The teammate's move lands first.
    const moved = await applyOne(
      teammate,
      "teammate",
      mergePatch(agentData({ position: { dx: 50, dy: 60 } }), ["position"], 1),
    );
    expect(moved).toMatchObject({ status: "applied", appliedRevision: 2 });

    // My change of side is still based on revision 1, and still lands.
    const turned = await applyOne(
      me,
      "me",
      mergePatch(agentData({ isAlly: false }), ["isAlly"], 1),
    );
    expect(turned).toMatchObject({ status: "applied", appliedRevision: 3 });

    const row = await element(me, "agent-1");
    expect(row.revision).toBe(3);
    expect(row.payload.data.position).toEqual({ dx: 50, dy: 60 });
    expect(row.payload.data.isAlly).toBe(false);
  });

  test("two live changes to the same field: the last one to arrive wins", async () => {
    const { me, teammate } = await createHarness();
    await addAgent(me);

    await applyOne(
      teammate,
      "teammate",
      mergePatch(agentData({ position: { dx: 50, dy: 60 } }), ["position"], 1),
    );
    const mine = await applyOne(
      me,
      "me",
      mergePatch(agentData({ position: { dx: 70, dy: 80 } }), ["position"], 1),
    );
    expect(mine.status).toBe("applied");
    expect((await element(me, "agent-1")).payload.data.position).toEqual({
      dx: 70,
      dy: 80,
    });
  });

  test("an offline change to a field a teammate changed meanwhile is refused and writes nothing", async () => {
    const { me, teammate } = await createHarness();
    await addAgent(me);
    await applyOne(
      teammate,
      "teammate",
      mergePatch(agentData({ position: { dx: 50, dy: 60 } }), ["position"], 1),
    );

    const offline = await applyOne(
      me,
      "me",
      mergePatch(
        agentData({ position: { dx: 70, dy: 80 }, isAlly: false }),
        ["position", "isAlly"],
        1,
        { position: { dx: 10, dy: 20 }, isAlly: true },
      ),
    );
    expect(offline).toMatchObject({
      status: "rejected",
      reason: "field_conflict",
      current: { type: "element", revision: 2 },
    });
    // Not even the side, which nobody else changed: the item waits whole.
    const row = await element(me, "agent-1");
    expect(row.revision).toBe(2);
    expect(row.payload.data.position).toEqual({ dx: 50, dy: 60 });
    expect(row.payload.data.isAlly).toBe(true);
  });

  test("an offline change lands when a teammate changed only other fields", async () => {
    const { me, teammate } = await createHarness();
    await addAgent(me);
    await applyOne(
      teammate,
      "teammate",
      mergePatch(agentData({ isAlly: false }), ["isAlly"], 1),
    );

    const offline = await applyOne(
      me,
      "me",
      mergePatch(agentData({ position: { dx: 70, dy: 80 } }), ["position"], 1, {
        position: { dx: 10, dy: 20 },
      }),
    );
    expect(offline.status).toBe("applied");
    const row = await element(me, "agent-1");
    expect(row.payload.data.position).toEqual({ dx: 70, dy: 80 });
    expect(row.payload.data.isAlly).toBe(false);
  });

  test("an offline change a teammate already made is no collision", async () => {
    const { me, teammate } = await createHarness();
    await addAgent(me);
    await applyOne(
      teammate,
      "teammate",
      mergePatch(agentData({ position: { dx: 70, dy: 80 } }), ["position"], 1),
    );

    const offline = await applyOne(
      me,
      "me",
      mergePatch(agentData({ position: { dx: 70, dy: 80 } }), ["position"], 1, {
        position: { dx: 10, dy: 20 },
      }),
    );
    expect(offline).toMatchObject({ status: "noop", currentRevision: 2 });
  });

  test("a field the client no longer has is removed", async () => {
    const { me } = await createHarness();
    await addAgent(me, agentData({ lineUpID: "spot-1" }));
    const { lineUpID: _, ...withoutLink } = agentData();

    const result = await applyOne(
      me,
      "me",
      mergePatch(withoutLink, ["lineUpID"], 1),
    );
    expect(result.status).toBe("applied");
    expect("lineUpID" in (await element(me, "agent-1")).payload.data).toBe(
      false,
    );
  });

  test("changing what an element is falls back to a revision-checked write", async () => {
    const { me, teammate } = await createHarness();
    await addAgent(me);
    await applyOne(
      teammate,
      "teammate",
      mergePatch(agentData({ isAlly: false }), ["isAlly"], 1),
    );

    // A view cone in place of the plain agent: its kind changes, so it can
    // only replace the whole item, and only from the revision it saw.
    const converted = await applyOne(
      me,
      "me",
      mergePatch(
        agentData({ kind: "viewCone", presetType: "viewCone90", rotation: 0, length: 1 }),
        ["kind", "presetType", "rotation", "length"],
        1,
      ),
    );
    expect(converted).toMatchObject({
      status: "rejected",
      reason: "revision_mismatch",
    });
    expect((await element(me, "agent-1")).payload.data.kind).toBe("plain");
  });

  test("a patch on another payload version falls back to a revision-checked write", async () => {
    const { me, teammate } = await createHarness();
    await addAgent(me);
    await applyOne(
      teammate,
      "teammate",
      mergePatch(agentData({ isAlly: false }), ["isAlly"], 1),
    );

    const otherVersion = await applyOne(
      me,
      "me",
      mergePatch(agentData({ position: { dx: 1, dy: 1 } }), ["position"], 1, undefined, 2),
    );
    expect(otherVersion).toMatchObject({
      status: "rejected",
      reason: "revision_mismatch",
    });
    expect((await element(me, "agent-1")).payload.payloadVersion).toBe(1);
  });

  test("a whole-item patch from an older client is still revision-checked after a merge", async () => {
    const { me, teammate } = await createHarness();
    await addAgent(me);
    await applyOne(
      teammate,
      "teammate",
      mergePatch(agentData({ isAlly: false }), ["isAlly"], 1),
    );

    const legacy = await applyOne(me, "old-client", {
      opId: nextOpId(),
      type: "element.patch",
      elementPublicId: "agent-1",
      pagePublicId,
      payload: agentPayload(agentData({ position: { dx: 5, dy: 5 } })),
      expectedElementRevision: 1,
    });
    expect(legacy).toMatchObject({
      status: "rejected",
      reason: "revision_mismatch",
    });
  });

  test("a merge cannot change an element a teammate deleted", async () => {
    const { me, teammate } = await createHarness();
    await addAgent(me);
    await applyOne(teammate, "teammate", {
      opId: nextOpId(),
      type: "element.delete",
      elementPublicId: "agent-1",
      pagePublicId,
      expectedElementRevision: 1,
    });

    const result = await applyOne(
      me,
      "me",
      mergePatch(agentData({ isAlly: false }), ["isAlly"], 1),
    );
    expect(result).toMatchObject({ status: "rejected", reason: "deleted" });
  });

  test("a merge whose base leaves out a field it changes is refused", async () => {
    const { me } = await createHarness();
    await addAgent(me);
    const op = mergePatch(
      agentData({ position: { dx: 1, dy: 1 }, isAlly: false }),
      ["position", "isAlly"],
      1,
    );
    const result = await applyOne(me, "me", {
      ...op,
      merge: { ...op.merge, base: [{ field: "position", value: { dx: 10, dy: 20 } }] },
    });
    expect(result).toMatchObject({ status: "failed", code: "INVALID_OP" });
    expect((await element(me, "agent-1")).revision).toBe(1);
  });

  test("a merge naming a field twice is refused", async () => {
    const { me } = await createHarness();
    await addAgent(me);
    const result = await applyOne(
      me,
      "me",
      mergePatch(agentData({ isAlly: false }), ["isAlly", "isAlly"], 1),
    );
    expect(result).toMatchObject({ status: "failed", code: "INVALID_OP" });
  });

  test("a live delete wins over a teammate's edit made just before it", async () => {
    const { me, teammate } = await createHarness();
    await addAgent(me);
    await applyOne(
      teammate,
      "teammate",
      mergePatch(agentData({ isAlly: false }), ["isAlly"], 1),
    );

    const deleted = await applyOne(me, "me", {
      opId: nextOpId(),
      type: "element.delete",
      elementPublicId: "agent-1",
      pagePublicId,
      expectedElementRevision: 1,
      lastWriterWins: true,
    });
    expect(deleted.status).toBe("applied");
    expect((await element(me, "agent-1")).deleted).toBe(true);
  });

  test("a delete without lastWriterWins is still revision-checked", async () => {
    const { me, teammate } = await createHarness();
    await addAgent(me);
    await applyOne(
      teammate,
      "teammate",
      mergePatch(agentData({ isAlly: false }), ["isAlly"], 1),
    );

    const deleted = await applyOne(me, "me", {
      opId: nextOpId(),
      type: "element.delete",
      elementPublicId: "agent-1",
      pagePublicId,
      expectedElementRevision: 1,
    });
    expect(deleted).toMatchObject({
      status: "rejected",
      reason: "revision_mismatch",
    });
  });

  test("a place named by the merge moves by last writer", async () => {
    const { me, teammate } = await createHarness();
    await addAgent(me);
    await applyOne(
      teammate,
      "teammate",
      mergePatch(agentData({ isAlly: false }), ["isAlly"], 1),
    );
    const result = await applyOne(me, "me", {
      ...mergePatch(agentData(), ["@sortIndex"], 1),
      sortIndex: 7,
    });
    expect(result.status).toBe("applied");
    const row = await element(me, "agent-1");
    expect(row.sortIndex).toBe(7);
    expect(row.payload.data.isAlly).toBe(false);
  });

  test("a place the merge does not name stays where a teammate put it", async () => {
    const { me, teammate } = await createHarness();
    await addAgent(me);
    await applyOne(teammate, "teammate", {
      ...mergePatch(agentData(), ["@sortIndex"], 1),
      sortIndex: 5,
    });
    // My edit carries the place I last saw, without naming it.
    const result = await applyOne(me, "me", {
      ...mergePatch(agentData({ isAlly: false }), ["isAlly"], 1),
      sortIndex: 0,
    });
    expect(result.status).toBe("applied");
    const row = await element(me, "agent-1");
    expect(row.sortIndex).toBe(5);
    expect(row.payload.data.isAlly).toBe(false);
  });

  test("a merge naming another page than the row's is a revision-checked write", async () => {
    const { me, teammate } = await createHarness();
    await addAgent(me);
    await me.mutation(makeFunctionReference<"mutation">("pages:add"), {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      strategyPublicId,
      expectedRevision: 0,
      pagePublicId: "merge-page-2",
      name: "Page 2",
      sortIndex: 1,
      isAttack: false,
    });
    // A teammate moves the agent to page 2.
    await applyOne(teammate, "teammate", {
      opId: nextOpId(),
      type: "element.patch",
      elementPublicId: "agent-1",
      pagePublicId: "merge-page-2",
      expectedElementRevision: 1,
    });
    // My edit still names page 1: merging it would move the agent back.
    const result = await applyOne(
      me,
      "me",
      mergePatch(agentData({ isAlly: false }), ["isAlly"], 1),
    );
    expect(result).toMatchObject({
      status: "rejected",
      reason: "revision_mismatch",
    });
  });
});

// ------------------------------------------------------------ lineup groups

const twoLinks: TestLineupGroup = {
  origins: [{ id: "o1" }],
  landings: [{ id: "l1" }, { id: "l2" }],
  links: [
    { id: "k1", originId: "o1", landingId: "l1", name: "One" },
    { id: "k2", originId: "o1", landingId: "l2", name: "Two" },
  ],
};

function groupPayload(group: TestLineupGroup) {
  return lineupsPayload("g", group);
}

async function addGroup(user: Harness, group: TestLineupGroup = twoLinks) {
  const result = await applyOne(user, "setup", {
    opId: nextOpId(),
    type: "lineup.add",
    lineupPublicId: "g",
    pagePublicId,
    payload: groupPayload(group),
    sortIndex: 0,
  });
  expect(result.status).toBe("applied");
}

function withLink(
  group: TestLineupGroup,
  id: string,
  change: Partial<TestLineupGroup["links"][number]>,
): TestLineupGroup {
  return {
    ...group,
    links: group.links.map((link) =>
      link.id === id ? { ...link, ...change } : link,
    ),
  };
}

function groupMerge(
  group: TestLineupGroup,
  fields: string[],
  expectedLineupRevision: number,
  base?: Array<{ field: string; value?: unknown }>,
) {
  return {
    opId: nextOpId(),
    type: "lineup.patch",
    lineupPublicId: "g",
    pagePublicId,
    payload: groupPayload(group),
    expectedLineupRevision,
    merge: { fields, ...(base === undefined ? {} : { base }) },
  };
}

function linkNames(row: Row): Record<string, string> {
  return Object.fromEntries(
    (row.payload.data.links as Array<{ id: string; name: string }>).map(
      (link) => [link.id, link.name],
    ),
  );
}

describe("lineup group merge by item", () => {
  test("two teammates editing different lineups of one group both land", async () => {
    const { me, teammate } = await createHarness();
    await addGroup(me);

    await applyOne(
      teammate,
      "teammate",
      groupMerge(withLink(twoLinks, "k2", { name: "Theirs" }), ["links/k2"], 1),
    );
    const mine = await applyOne(
      me,
      "me",
      groupMerge(withLink(twoLinks, "k1", { name: "Mine" }), ["links/k1"], 1),
    );
    expect(mine.status).toBe("applied");
    expect(linkNames(await lineup(me, "g"))).toEqual({
      k1: "Mine",
      k2: "Theirs",
    });
  });

  test("a lineup added while a teammate edits another lands beside it", async () => {
    const { me, teammate } = await createHarness();
    await addGroup(me);
    await applyOne(
      teammate,
      "teammate",
      groupMerge(withLink(twoLinks, "k2", { name: "Theirs" }), ["links/k2"], 1),
    );

    const added: TestLineupGroup = {
      origins: twoLinks.origins,
      landings: [...twoLinks.landings, { id: "l3" }],
      links: [
        ...twoLinks.links,
        { id: "k3", originId: "o1", landingId: "l3", name: "Three" },
      ],
    };
    const result = await applyOne(
      me,
      "me",
      groupMerge(added, ["landings/l3", "links/k3"], 1),
    );
    expect(result.status).toBe("applied");
    const row = await lineup(me, "g");
    expect(linkNames(row)).toEqual({ k1: "One", k2: "Theirs", k3: "Three" });
  });

  test("removing a lineup drops the spot only it used", async () => {
    const { me, teammate } = await createHarness();
    await addGroup(me);
    await applyOne(
      teammate,
      "teammate",
      groupMerge(withLink(twoLinks, "k1", { name: "Theirs" }), ["links/k1"], 1),
    );

    const removed: TestLineupGroup = {
      origins: twoLinks.origins,
      landings: [{ id: "l1" }],
      links: [twoLinks.links[0]],
    };
    const result = await applyOne(
      me,
      "me",
      // Only the lineup is named: its landing goes because nothing uses it.
      groupMerge(removed, ["links/k2"], 1),
    );
    expect(result.status).toBe("applied");
    const row = await lineup(me, "g");
    expect(linkNames(row)).toEqual({ k1: "Theirs" });
    expect(
      (row.payload.data.landings as Array<{ id: string }>).map((l) => l.id),
    ).toEqual(["l1"]);
  });

  test("a lineup on a spot a teammate removed is refused as a merge that cannot stand", async () => {
    const { me, teammate } = await createHarness();
    await addGroup(me);
    // The teammate removes lineup two and its landing.
    await applyOne(
      teammate,
      "teammate",
      groupMerge(
        { origins: twoLinks.origins, landings: [{ id: "l1" }], links: [twoLinks.links[0]] },
        ["links/k2", "landings/l2"],
        1,
      ),
    );

    // Meanwhile I aimed a new lineup at that landing.
    const added: TestLineupGroup = {
      origins: [...twoLinks.origins, { id: "o2" }],
      landings: twoLinks.landings,
      links: [
        ...twoLinks.links,
        { id: "k3", originId: "o2", landingId: "l2", name: "Three" },
      ],
    };
    const result = await applyOne(
      me,
      "me",
      groupMerge(added, ["origins/o2", "links/k3"], 1),
    );
    expect(result).toMatchObject({
      status: "rejected",
      reason: "merge_invalid",
      current: { type: "lineup", revision: 2 },
    });
    expect(linkNames(await lineup(me, "g"))).toEqual({ k1: "One" });
  });

  test("an offline edit of a lineup a teammate changed meanwhile is refused", async () => {
    const { me, teammate } = await createHarness();
    await addGroup(me);
    await applyOne(
      teammate,
      "teammate",
      groupMerge(withLink(twoLinks, "k1", { name: "Theirs" }), ["links/k1"], 1),
    );

    const original = groupPayload(twoLinks).data.links[0];
    const result = await applyOne(
      me,
      "me",
      groupMerge(withLink(twoLinks, "k1", { name: "Mine" }), ["links/k1"], 1, [
        { field: "links/k1", value: original },
      ]),
    );
    expect(result).toMatchObject({
      status: "rejected",
      reason: "field_conflict",
    });
    expect(linkNames(await lineup(me, "g"))).toEqual({
      k1: "Theirs",
      k2: "Two",
    });
  });

  test("a merged group keeps its item ownership in step", async () => {
    const { t, me } = await createHarness();
    await addGroup(me);
    const added: TestLineupGroup = {
      origins: twoLinks.origins,
      landings: [...twoLinks.landings, { id: "l3" }],
      links: [
        ...twoLinks.links,
        { id: "k3", originId: "o1", landingId: "l3" },
      ],
    };
    await applyOne(me, "me", groupMerge(added, ["landings/l3", "links/k3"], 1));

    const items = await t.run(async (ctx) =>
      (await ctx.db.query("lineupItems").collect()).map((row) => row.item),
    );
    expect(items.sort()).toEqual(
      [
        "landing:l1",
        "landing:l2",
        "landing:l3",
        "link:k1",
        "link:k2",
        "link:k3",
        "origin:o1",
      ].sort(),
    );
  });

  test("a merge that would leave a group with no lineups is refused", async () => {
    const { me, teammate } = await createHarness();
    await addGroup(me);
    // The teammate removes lineup two; I remove lineup one.
    await applyOne(
      teammate,
      "teammate",
      groupMerge(
        { origins: twoLinks.origins, landings: [{ id: "l1" }], links: [twoLinks.links[0]] },
        ["links/k2", "landings/l2"],
        1,
      ),
    );
    const result = await applyOne(
      me,
      "me",
      groupMerge(
        { origins: twoLinks.origins, landings: [{ id: "l2" }], links: [twoLinks.links[1]] },
        ["links/k1", "landings/l1"],
        1,
      ),
    );
    expect(result).toMatchObject({
      status: "rejected",
      reason: "merge_invalid",
    });
  });

  test("a field that names no lineup item falls back to a revision-checked write", async () => {
    const { me, teammate } = await createHarness();
    await addGroup(me);
    await applyOne(
      teammate,
      "teammate",
      groupMerge(withLink(twoLinks, "k2", { name: "Theirs" }), ["links/k2"], 1),
    );
    const result = await applyOne(
      me,
      "me",
      groupMerge(withLink(twoLinks, "k1", { name: "Mine" }), ["links"], 1),
    );
    expect(result).toMatchObject({
      status: "rejected",
      reason: "revision_mismatch",
    });
  });
});

describe("merge edge cases", () => {
  test("an offline restack of an element a teammate restacked meanwhile is refused", async () => {
    const { me, teammate } = await createHarness();
    await addAgent(me);
    await applyOne(teammate, "teammate", {
      ...mergePatch(agentData(), ["@sortIndex"], 1),
      sortIndex: 9,
    });

    const offline = await applyOne(me, "me", {
      ...mergePatch(agentData(), ["@sortIndex"], 1, { "@sortIndex": 0 }),
      sortIndex: 7,
    });
    expect(offline).toMatchObject({
      status: "rejected",
      reason: "field_conflict",
    });
    expect((await element(me, "agent-1")).sortIndex).toBe(9);
  });

  test("a base that says a field was absent differs from one that says it was null", async () => {
    const { me } = await createHarness();
    // The stored agent holds lineUpID: null.
    await addAgent(me);

    const absent = await applyOne(
      me,
      "me",
      mergePatch(agentData({ lineUpID: "spot-1" }), ["lineUpID"], 1, {}),
    );
    expect(absent).toMatchObject({
      status: "rejected",
      reason: "field_conflict",
    });

    const wasNull = await applyOne(
      me,
      "me",
      mergePatch(agentData({ lineUpID: "spot-1" }), ["lineUpID"], 1, {
        lineUpID: null,
      }),
    );
    expect(wasNull.status).toBe("applied");
    expect((await element(me, "agent-1")).payload.data.lineUpID).toBe("spot-1");
  });

  test("a merge refusal replayed by a client that sends no merge reads as a revision mismatch", async () => {
    const { me, teammate } = await createHarness();
    await addAgent(me);
    await applyOne(
      teammate,
      "teammate",
      mergePatch(agentData({ isAlly: false }), ["isAlly"], 1),
    );
    const op = mergePatch(agentData({ isAlly: true }), ["isAlly"], 1, {
      isAlly: true,
    });
    const refused = await applyOne(me, "me", op);
    expect(refused).toMatchObject({
      status: "rejected",
      reason: "field_conflict",
    });

    // An older tab sends the same op from the shared outbox, without the
    // merge it cannot read.
    const { merge: _, ...withoutMerge } = op;
    const replayed = await applyOne(me, "me", withoutMerge);
    expect(replayed).toMatchObject({
      status: "rejected",
      reason: "revision_mismatch",
    });
    // The merge client replaying it still hears its own reason.
    expect(await applyOne(me, "me", op)).toMatchObject({
      status: "rejected",
      reason: "field_conflict",
    });
  });

  test("a merged group that would take a spot another group holds fails as any overlap does", async () => {
    const { me } = await createHarness();
    await addGroup(me);
    const other = await applyOne(me, "setup", {
      opId: nextOpId(),
      type: "lineup.add",
      lineupPublicId: "h",
      pagePublicId,
      payload: lineupsPayload("h", {
        origins: [{ id: "o9" }],
        landings: [{ id: "l9" }],
        links: [{ id: "k9", originId: "o9", landingId: "l9" }],
      }),
      sortIndex: 1,
    });
    expect(other.status).toBe("applied");

    const taking: TestLineupGroup = {
      origins: twoLinks.origins,
      landings: [...twoLinks.landings, { id: "l9" }],
      links: [...twoLinks.links, { id: "k3", originId: "o1", landingId: "l9" }],
    };
    const result = await applyOne(
      me,
      "me",
      groupMerge(taking, ["landings/l9", "links/k3"], 1),
    );
    expect(result).toMatchObject({
      status: "failed",
      code: "INVALID_LINEUP_PAYLOAD_DATA",
    });
    expect(linkNames(await lineup(me, "g"))).toEqual({ k1: "One", k2: "Two" });
  });
});

describe("merge fallbacks keep the older rules", () => {
  test("an offline merge that must write whole is revision-checked, not place-checked", async () => {
    const { me, teammate } = await createHarness();
    await addAgent(me);
    await applyOne(teammate, "teammate", {
      ...mergePatch(agentData(), ["@sortIndex"], 1),
      sortIndex: 9,
    });

    // A change of kind can't merge. From the row's own revision, it is
    // written whole, place and all, however stale its place's base.
    const whole = await applyOne(me, "me", {
      ...mergePatch(
        agentData({ kind: "circle" }),
        ["kind", "@sortIndex"],
        2,
        { kind: "plain", "@sortIndex": 0 },
      ),
      sortIndex: 7,
    });
    expect(whole.status).toBe("applied");
    const row = await element(me, "agent-1");
    expect(row.payload.data.kind).toBe("circle");
    expect(row.sortIndex).toBe(7);
  });

  test("a whole patch is checked for its kind before its page, as before", async () => {
    const { me } = await createHarness();
    await addAgent(me);
    const result = await applyOne(me, "old-client", {
      opId: nextOpId(),
      type: "element.patch",
      elementPublicId: "agent-1",
      pagePublicId: "no-such-page",
      payload: { kind: "ability", payloadVersion: 1, data: {} },
      expectedElementRevision: 1,
    });
    expect(result).toMatchObject({
      status: "failed",
      code: "ELEMENT_TYPE_PAYLOAD_KIND_MISMATCH",
    });
  });
});
