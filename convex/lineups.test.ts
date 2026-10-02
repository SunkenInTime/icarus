import {
  convexTest,
  type TestConvexForDataModel,
  type TestConvexForDataModelAndIdentity,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { afterEach, beforeAll, describe, expect, test, vi } from "vitest";
import type { DataModel } from "./_generated/dataModel";
import { markAssetReferencesReady } from "./lib/assetReferences";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "./lib/cloudProtocol";
import schema from "./schema";
import {
  insertLineup,
  lineupPayload,
  type TestLineup,
} from "./testContent.helpers";
import { modules } from "./test.setup";

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createStrategy = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const createShare = makeFunctionReference<"mutation">("shares:create");
const redeemShare = makeFunctionReference<"mutation">("shares:redeem");
const addPage = makeFunctionReference<"mutation">("pages:add");
const applyBatch = makeFunctionReference<"mutation">("ops:applyBatch");
const getPageSnapshot = makeFunctionReference<"query">("page:getSnapshot");
const getFullSnapshot = makeFunctionReference<"query">(
  "strategy:getFullSnapshot",
);
const listForStrategy = makeFunctionReference<"query">(
  "lineups:listForStrategy",
);
const listReferencedAssetIds = makeFunctionReference<"query">(
  "images:listReferencedAssetIds",
);
const duplicateStrategy = makeFunctionReference<"mutation">(
  "strategies:duplicate",
);
const restorePage = makeFunctionReference<"mutation">("pages:restore");
const purgeOldTombstones = makeFunctionReference<"mutation">(
  "maintenance:purgeOldTombstones",
);

type Harness = TestConvexForDataModel<DataModel>;
type RootHarness = TestConvexForDataModelAndIdentity<DataModel>;
type Result = Record<string, unknown>;
type LineupRow = {
  publicId: string;
  payload: { kind: string; data: Record<string, unknown> };
  revision: number;
  deleted: boolean;
};

const strategyPublicId = "lineups-strategy";
const pagePublicId = "lineups-page";

function identity(subject: string) {
  return {
    issuer: "https://lineups.test",
    subject,
    tokenIdentifier: `lineups|${subject}`,
    name: subject,
  };
}

async function createHarness(): Promise<{
  t: RootHarness;
  owner: Harness;
  editor: Harness;
  viewer: Harness;
}> {
  const t = convexTest(schema, modules);
  const owner = t.withIdentity(identity("owner"));
  const editor = t.withIdentity(identity("editor"));
  const viewer = t.withIdentity(identity("viewer"));
  for (const user of [owner, editor, viewer]) {
    await user.mutation(ensureCurrentUser, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    });
  }
  await owner.mutation(createStrategy, {
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    publicId: strategyPublicId,
    name: "Lineups",
    mapData: "ascent",
    initialPagePublicId: pagePublicId,
    initialPageName: "Page 1",
    initialPageIsAttack: true,
  });
  for (const [user, role] of [
    [editor, "editor"],
    [viewer, "viewer"],
  ] as const) {
    await owner.mutation(createShare, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      targetType: "strategy",
      targetPublicId: strategyPublicId,
      token: `${role}-token`,
      role,
    });
    await user.mutation(redeemShare, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      token: `${role}-token`,
    });
  }
  return { t, owner, editor, viewer };
}

/** A lineup row as a test sends it: its key and its payload. */
function lineup(id: string, details: TestLineup = {}) {
  return { key: id, payload: lineupPayload(id, details) };
}

type Row = ReturnType<typeof lineup>;

function addOp(row: Row, sortIndex: number, page = pagePublicId) {
  return {
    opId: `add-${row.key}`,
    type: "lineup.add",
    lineupPublicId: row.key,
    pagePublicId: page,
    payload: row.payload,
    sortIndex,
  };
}

function patchOp(opId: string, row: Row, expectedLineupRevision: number) {
  return {
    opId,
    type: "lineup.patch",
    lineupPublicId: row.key,
    pagePublicId,
    payload: row.payload,
    expectedLineupRevision,
  };
}

function deleteOp(opId: string, key: string, expectedLineupRevision: number) {
  return {
    opId,
    type: "lineup.delete",
    lineupPublicId: key,
    pagePublicId,
    expectedLineupRevision,
  };
}

async function apply(
  user: Harness,
  clientId: string,
  ops: Array<Record<string, unknown>>,
  strategy = strategyPublicId,
): Promise<Result[]> {
  const response = (await user.mutation(applyBatch, {
    strategyPublicId: strategy,
    clientId,
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    ops,
  })) as { results: Result[] };
  return response.results;
}

async function pageLineups(
  user: Harness,
  strategy = strategyPublicId,
  page = pagePublicId,
): Promise<LineupRow[]> {
  const snapshot = (await user.query(getPageSnapshot, {
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    strategyPublicId: strategy,
    pagePublicId: page,
  })) as { lineups: LineupRow[] };
  return snapshot.lineups;
}

function byKey(rows: LineupRow[]): Map<string, LineupRow> {
  return new Map(rows.map((row) => [row.publicId, row]));
}

function liveKeys(rows: LineupRow[]): string[] {
  return rows.filter((row) => !row.deleted).map((row) => row.publicId);
}

async function addSecondPage(owner: Harness, publicId: string) {
  await owner.mutation(addPage, {
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    strategyPublicId,
    expectedRevision: 0,
    pagePublicId: publicId,
    name: "Page 2",
    sortIndex: 1,
    isAttack: false,
  });
}

async function agentSummary(
  t: RootHarness,
  strategy = strategyPublicId,
): Promise<string[]> {
  return await t.run(async (ctx) => {
    const row = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", strategy))
      .unique();
    const summary = await ctx.db
      .query("strategyAgentSummaries")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", row!._id))
      .unique();
    return summary?.agentTypes ?? [];
  });
}

type LineupAgentRow = {
  lineup: string;
  page: string;
  originId: string;
  agentType: string;
};

/// A strategy's lineupAgents rows, each named by its lineup's and page's
/// public ids, ordered by lineup. Fails on a row that names a lineup gone
/// or out of step with it (another strategy or page).
async function lineupAgentRows(
  t: RootHarness,
  strategy = strategyPublicId,
): Promise<LineupAgentRow[]> {
  return await t.run(async (ctx) => {
    const strategyRow = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", strategy))
      .unique();
    const rows = await ctx.db
      .query("lineupAgents")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", strategyRow!._id))
      .collect();
    const described: LineupAgentRow[] = [];
    for (const row of rows) {
      const lineup = await ctx.db.get(row.lineupId);
      const page = await ctx.db.get(row.pageId);
      if (
        lineup === null ||
        page === null ||
        lineup.strategyId !== row.strategyId ||
        lineup.pageId !== row.pageId
      ) {
        throw new Error(`lineupAgents row ${row._id} is out of step`);
      }
      described.push({
        lineup: lineup.publicId,
        page: page.publicId,
        originId: row.originId,
        agentType: row.agentType,
      });
    }
    return described.sort((a, b) => a.lineup.localeCompare(b.lineup));
  });
}

async function strategyRevision(t: RootHarness): Promise<number> {
  return await t.run(async (ctx) => {
    const strategy = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", strategyPublicId))
      .unique();
    return strategy!.revision;
  });
}

beforeAll(() => {
  // Page snapshots serialize asset URLs from the R2 public base.
  process.env.R2_ACCOUNT_ID = "lineups-account";
  process.env.R2_BUCKET = "lineups-bucket";
  process.env.R2_ACCESS_KEY_ID = "lineups-access-key";
  process.env.R2_SECRET_ACCESS_KEY = "lineups-secret";
  process.env.R2_PUBLIC_BASE_URL = "https://assets.lineups.test";
  process.env.R2_S3_ENDPOINT = "https://lineups.r2.test";
});

afterEach(() => {
  vi.useRealTimers();
});

/** Two lineups from different origins aiming at one shared landing. */
const fanIn = [
  lineup("from-heaven", {
    originId: "heaven",
    landingId: "site",
    name: "From heaven",
  }),
  lineup("from-mid", { originId: "mid", landingId: "site", name: "From mid" }),
];

/** Two lineups thrown from one shared origin to different landings. */
const fanOut = [
  lineup("to-default", {
    originId: "spawn",
    landingId: "default",
    name: "Default plant",
  }),
  lineup("to-hell", { originId: "spawn", landingId: "hell", name: "Hell" }),
];

describe("one row per lineup", () => {
  test("a lineup round-trips with its origin and landing intact", async () => {
    const { owner } = await createHarness();
    const row = lineup("smoke", {
      originId: "smoke-origin",
      landingId: "smoke-landing",
      agentType: "brimstone",
      originPosition: { dx: 120, dy: 340 },
      landingPosition: { dx: 400, dy: 220 },
      name: "A main smoke",
      youtubeLink: "https://youtu.be/smoke",
      notes: "Jump throw",
    });
    const results = await apply(owner, "owner-client", [addOp(row, 0)]);
    expect(results[0]).toMatchObject({ status: "applied", appliedRevision: 1 });

    const rows = await pageLineups(owner);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      publicId: "smoke",
      revision: 1,
      deleted: false,
    });
    expect(rows[0]!.payload).toEqual(row.payload);

    const full = (await owner.query(getFullSnapshot, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      strategyPublicId,
    })) as { lineups: LineupRow[] };
    expect(full.lineups.map((entry) => entry.payload)).toEqual([row.payload]);

    const listed = (await owner.query(listForStrategy, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      strategyPublicId,
    })) as LineupRow[];
    expect(listed.map((entry) => entry.payload)).toEqual([row.payload]);
  });

  test("lineups sharing a landing each store and read back their own copy", async () => {
    const { owner } = await createHarness();
    const results = await apply(
      owner,
      "owner-client",
      fanIn.map((row, index) => addOp(row, index)),
    );
    expect(results.map((result) => result.status)).toEqual([
      "applied",
      "applied",
    ]);

    const rows = byKey(await pageLineups(owner));
    expect([...rows.keys()]).toEqual(["from-heaven", "from-mid"]);
    for (const row of fanIn) {
      expect(rows.get(row.key)!.payload).toEqual(row.payload);
    }
    expect(rows.get("from-heaven")!.payload.data.landing).toEqual(
      rows.get("from-mid")!.payload.data.landing,
    );
  });

  test("lineups sharing an origin each store and read back their own copy", async () => {
    const { owner } = await createHarness();
    const results = await apply(
      owner,
      "owner-client",
      fanOut.map((row, index) => addOp(row, index)),
    );
    expect(results.map((result) => result.status)).toEqual([
      "applied",
      "applied",
    ]);

    const rows = byKey(await pageLineups(owner));
    for (const row of fanOut) {
      expect(rows.get(row.key)!.payload).toEqual(row.payload);
    }
    expect(rows.get("to-default")!.payload.data.origin).toEqual(
      rows.get("to-hell")!.payload.data.origin,
    );
  });

  test("a lineup may share its id with its landing", async () => {
    const { owner } = await createHarness();
    const row = lineup("same-id", { landingId: "same-id" });
    const results = await apply(owner, "owner-client", [addOp(row, 0)]);
    expect(results[0]).toMatchObject({ status: "applied" });
    expect((await pageLineups(owner))[0]!.payload).toEqual(row.payload);
  });

  test("moving a shared spot patches each lineup that carries it on its own", async () => {
    const { owner } = await createHarness();
    await apply(
      owner,
      "owner-client",
      fanIn.map((row, index) => addOp(row, index)),
    );
    const moved = { dx: 10, dy: 20 };

    const first = await apply(owner, "owner-client", [
      patchOp(
        "move-site-heaven",
        lineup("from-heaven", {
          originId: "heaven",
          landingId: "site",
          landingPosition: moved,
          name: "From heaven",
        }),
        1,
      ),
    ]);
    expect(first[0]).toMatchObject({ status: "applied", appliedRevision: 2 });
    // The other row keeps its own copy until its own patch lands.
    let rows = byKey(await pageLineups(owner));
    expect(rows.get("from-heaven")).toMatchObject({ revision: 2 });
    expect(rows.get("from-mid")).toMatchObject({ revision: 1 });
    expect(rows.get("from-mid")!.payload).toEqual(fanIn[1]!.payload);

    const second = await apply(owner, "owner-client", [
      patchOp(
        "move-site-mid",
        lineup("from-mid", {
          originId: "mid",
          landingId: "site",
          landingPosition: moved,
          name: "From mid",
        }),
        1,
      ),
    ]);
    expect(second[0]).toMatchObject({ status: "applied", appliedRevision: 2 });
    rows = byKey(await pageLineups(owner));
    for (const key of ["from-heaven", "from-mid"]) {
      expect(rows.get(key)).toMatchObject({ revision: 2 });
      expect(rows.get(key)!.payload.data.landing).toMatchObject({
        id: "site",
        ability: { position: moved, lineUpID: "site" },
      });
    }
  });

  test("teammates editing different lineups that share a spot never conflict", async () => {
    const { owner, editor } = await createHarness();
    await apply(
      owner,
      "owner-client",
      fanIn.map((row, index) => addOp(row, index)),
    );

    // Both edit from the same loaded revision (1) of their own lineup: the
    // owner moves the shared landing on theirs, the editor writes notes on
    // the other.
    const ownerResults = await apply(owner, "owner-client", [
      patchOp(
        "owner-moves-site",
        lineup("from-heaven", {
          originId: "heaven",
          landingId: "site",
          landingPosition: { dx: 5, dy: 5 },
          name: "From heaven",
        }),
        1,
      ),
    ]);
    const editorResults = await apply(editor, "editor-client", [
      patchOp(
        "editor-notes-mid",
        lineup("from-mid", {
          originId: "mid",
          landingId: "site",
          name: "From mid",
          notes: "Editor notes",
        }),
        1,
      ),
    ]);
    expect(ownerResults[0]).toMatchObject({
      status: "applied",
      appliedRevision: 2,
    });
    expect(editorResults[0]).toMatchObject({
      status: "applied",
      appliedRevision: 2,
    });

    const rows = byKey(await pageLineups(owner));
    expect(rows.get("from-heaven")!.payload.data).toMatchObject({
      notes: "",
      landing: { ability: { position: { dx: 5, dy: 5 } } },
    });
    expect(rows.get("from-mid")!.payload.data).toMatchObject({
      notes: "Editor notes",
      landing: { ability: { position: { dx: 0, dy: 0 } } },
    });
  });

  test("a stale edit to the same lineup is a conflict, not a silent overwrite", async () => {
    const { owner, editor } = await createHarness();
    await apply(owner, "owner-client", [addOp(fanIn[0]!, 0)]);
    const ownerEdit = lineup("from-heaven", {
      originId: "heaven",
      landingId: "site",
      name: "Owner name",
    });
    await apply(owner, "owner-client", [patchOp("owner-renames", ownerEdit, 1)]);

    const stale = await apply(editor, "editor-client", [
      patchOp(
        "editor-renames",
        lineup("from-heaven", {
          originId: "heaven",
          landingId: "site",
          name: "Stale name",
        }),
        1,
      ),
    ]);
    expect(stale[0]).toMatchObject({
      status: "rejected",
      reason: "revision_mismatch",
      current: { type: "lineup", revision: 2, value: ownerEdit.payload },
    });
    const row = byKey(await pageLineups(owner)).get("from-heaven");
    expect(row).toMatchObject({ revision: 2 });
    expect(row!.payload).toEqual(ownerEdit.payload);
  });

  test("deleting a spot's lineups leaves a teammate's new lineup from that spot", async () => {
    const { owner, editor } = await createHarness();
    await apply(
      owner,
      "owner-client",
      fanIn.map((row, index) => addOp(row, index)),
    );

    // The owner deletes every lineup into "site" while the editor, who has
    // not seen that yet, places a new lineup into the same spot.
    const deletes = await apply(owner, "owner-client", [
      deleteOp("delete-heaven", "from-heaven", 1),
      deleteOp("delete-mid", "from-mid", 1),
    ]);
    const added = await apply(editor, "editor-client", [
      addOp(lineup("from-garage", { originId: "garage", landingId: "site" }), 2),
    ]);
    expect(deletes.map((result) => result.status)).toEqual([
      "applied",
      "applied",
    ]);
    expect(added[0]).toMatchObject({ status: "applied" });

    const rows = await pageLineups(owner);
    expect(liveKeys(rows)).toEqual(["from-garage"]);
    expect(byKey(rows).get("from-garage")!.payload.data.landing).toMatchObject(
      { id: "site" },
    );
  });

  test("a viewer reads lineups but cannot write them", async () => {
    const { owner, viewer } = await createHarness();
    await apply(owner, "owner-client", [addOp(fanIn[0]!, 0)]);
    await expect(
      apply(viewer, "viewer-client", [addOp(fanIn[1]!, 1)]),
    ).rejects.toThrow("Forbidden");
    await expect(
      apply(viewer, "viewer-client", [
        patchOp(
          "viewer-renames",
          lineup("from-heaven", {
            originId: "heaven",
            landingId: "site",
            name: "Viewer",
          }),
          1,
        ),
      ]),
    ).rejects.toThrow("Forbidden");
    expect((await pageLineups(viewer)).map((row) => row.publicId)).toEqual([
      "from-heaven",
    ]);
  });
});

describe("a lineup row must be drawable on its own", () => {
  test("a row missing its origin or landing, or keyed apart from its id, is refused", async () => {
    const { owner } = await createHarness();
    const valid = lineupPayload("k");
    const withData = (id: string, data: Record<string, unknown>) => ({
      ...addOp(lineup(id), 0),
      payload: { ...valid, data: { ...valid.data, id, ...data } },
    });
    const withoutOrigin = withData("no-origin", { origin: undefined });
    delete (withoutOrigin.payload.data as Record<string, unknown>).origin;
    const withoutLanding = withData("no-landing", {});
    delete (withoutLanding.payload.data as Record<string, unknown>).landing;
    const originWithoutAgent = withData("no-agent", {
      origin: { id: "o" },
    });
    const landingWithoutAbility = withData("no-ability", {
      landing: { id: "l" },
    });
    const originWithoutId = withData("no-origin-id", {
      origin: { agent: valid.data.origin.agent },
    });
    const mismatchedKey = { ...addOp(lineup("k"), 0), lineupPublicId: "other" };
    const graphKey = { ...addOp(lineup("k"), 0), lineupPublicId: "lineupLink:k" };

    const results = await apply(owner, "owner-client", [
      withoutOrigin,
      withoutLanding,
      originWithoutAgent,
      landingWithoutAbility,
      originWithoutId,
      mismatchedKey,
      graphKey,
    ]);
    expect(results).toHaveLength(7);
    for (const result of results) {
      expect(result).toMatchObject({
        status: "failed",
        code: "INVALID_LINEUP_PAYLOAD_DATA",
      });
    }
    expect(await pageLineups(owner)).toEqual([]);
  });

  test("a patch that drops an end is refused and leaves the row as it was", async () => {
    const { owner } = await createHarness();
    await apply(owner, "owner-client", [addOp(fanIn[0]!, 0)]);
    const { landing: _landing, ...withoutLanding } = fanIn[0]!.payload.data;
    const results = await apply(owner, "owner-client", [
      {
        ...patchOp("drop-landing", fanIn[0]!, 1),
        payload: { ...fanIn[0]!.payload, data: withoutLanding },
      },
    ]);
    expect(results[0]).toMatchObject({
      status: "failed",
      code: "INVALID_LINEUP_PAYLOAD_DATA",
    });
    const row = (await pageLineups(owner))[0]!;
    expect(row).toMatchObject({ revision: 1 });
    expect(row.payload).toEqual(fanIn[0]!.payload);
  });

  test("a row of an old graph kind is refused by the handler, the legacy group by the contract", async () => {
    const { owner } = await createHarness();
    // Protocol 4's graph rows get past argument validation so an old client
    // reaches the protocol gate; on protocol 5 the handler refuses each op.
    const graphKinds = ["lineupOrigin", "lineupLanding", "lineupLink"];
    const results = await apply(
      owner,
      "old-shapes",
      graphKinds.map((kind) => ({
        opId: `add-${kind}`,
        type: "lineup.add",
        lineupPublicId: `${kind}:k`,
        pagePublicId,
        payload: {
          kind,
          payloadVersion: 1,
          data: { id: "k", originId: "o", landingId: "l", images: [] },
        },
        sortIndex: 0,
      })),
    );
    expect(results).toHaveLength(graphKinds.length);
    for (const [index, kind] of graphKinds.entries()) {
      expect(results[index]).toMatchObject({
        opId: `add-${kind}`,
        status: "failed",
        code: "INVALID_LINEUP_PAYLOAD_KIND",
      });
    }
    // The group of protocol 3 and earlier is still refused whole.
    await expect(
      apply(owner, "old-client", [
        {
          opId: "add-lineupGroup",
          type: "lineup.add",
          lineupPublicId: "group",
          pagePublicId,
          payload: {
            kind: "lineupGroup",
            payloadVersion: 1,
            data: { id: "group", items: [{ id: "item" }] },
          },
          sortIndex: 0,
        },
      ]),
    ).rejects.toThrow(/Validator error|ArgumentValidationError/);
    expect(await pageLineups(owner)).toEqual([]);
  });

});

describe("clients on protocol 4", () => {
  test("a protocol 4 batch with its lineup options and a link row is told to upgrade", async () => {
    const { owner } = await createHarness();
    const error = await owner
      .mutation(applyBatch, {
        strategyPublicId,
        clientId: "protocol-4-client",
        clientProtocolVersion: 4,
        checkLineupLinkEnds: true,
        checkLineupEndDeletes: true,
        ops: [
          {
            opId: "add-link",
            type: "lineup.add",
            lineupPublicId: "lineupLink:k",
            pagePublicId,
            payload: {
              kind: "lineupLink",
              payloadVersion: 1,
              data: { id: "k", originId: "o", landingId: "l", images: [] },
            },
            sortIndex: 0,
          },
        ],
      })
      .then(
        () => null,
        (caught: unknown) => caught as { data?: unknown; message?: string },
      );
    expect(error).not.toBeNull();
    // The protocol gate answered, not argument validation.
    expect(error?.message ?? "").not.toMatch(
      /Validator error|ArgumentValidationError/,
    );
    expect(typeof error?.data).toBe("string");
    expect(JSON.parse(error?.data as string)).toMatchObject({
      code: "CLIENT_UPGRADE_REQUIRED",
    });
    expect(await pageLineups(owner)).toEqual([]);
  });

  test("a protocol 5 batch with an origin row fails that op and applies the rest", async () => {
    const { owner } = await createHarness();
    const response = (await owner.mutation(applyBatch, {
      strategyPublicId,
      clientId: "mixed-client",
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      // Still accepted (and ignored) on protocol 5.
      checkLineupLinkEnds: true,
      checkLineupEndDeletes: true,
      ops: [
        {
          opId: "add-origin",
          type: "lineup.add",
          lineupPublicId: "lineupOrigin:o",
          pagePublicId,
          payload: {
            kind: "lineupOrigin",
            payloadVersion: 1,
            data: { id: "o", agent: { type: "sova" } },
          },
          sortIndex: 0,
        },
        {
          opId: "add-text",
          type: "element.add",
          elementPublicId: "note",
          pagePublicId,
          payload: {
            kind: "text",
            payloadVersion: 1,
            data: { id: "note", elementType: "text", text: "Default" },
          },
          sortIndex: 0,
        },
      ],
    })) as { results: Result[] };
    expect(response.results).toMatchObject([
      {
        opId: "add-origin",
        status: "failed",
        code: "INVALID_LINEUP_PAYLOAD_KIND",
      },
      { opId: "add-text", status: "applied", appliedRevision: 1 },
    ]);
    const snapshot = (await owner.query(getPageSnapshot, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      strategyPublicId,
      pagePublicId,
    })) as {
      elements: Array<{ publicId: string }>;
      lineups: LineupRow[];
    };
    expect(snapshot.elements.map((row) => row.publicId)).toEqual(["note"]);
    expect(snapshot.lineups).toEqual([]);
  });
});

describe("lineup row keys belong to their strategy and page", () => {
  test("the same lineup ids in two strategies are separate rows", async () => {
    const { owner } = await createHarness();
    const copyId = "local-duplicate";
    const copyPage = "local-duplicate-page";
    await owner.mutation(createStrategy, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      publicId: copyId,
      name: "Copy",
      mapData: "ascent",
      initialPagePublicId: copyPage,
      initialPageName: "Page 1",
      initialPageIsAttack: true,
    });
    // A strategy duplicated on the device keeps every lineup id; each upload
    // keeps them too (ids only need to be unique within a strategy).
    for (const [strategy, page] of [
      [strategyPublicId, pagePublicId],
      [copyId, copyPage],
    ] as const) {
      const results = await apply(
        owner,
        `upload-${strategy}`,
        fanIn.map((row, index) => addOp(row, index, page)),
        strategy,
      );
      expect(results.map((result) => result.status)).toEqual([
        "applied",
        "applied",
      ]);
    }
    // Editing one copy leaves the other untouched.
    await apply(
      owner,
      "edit-copy",
      [
        {
          ...patchOp(
            "rename-in-copy",
            lineup("from-heaven", {
              originId: "heaven",
              landingId: "site",
              name: "Copy name",
            }),
            1,
          ),
          pagePublicId: copyPage,
        },
      ],
      copyId,
    );
    const original = byKey(await pageLineups(owner));
    const copy = byKey(await pageLineups(owner, copyId, copyPage));
    expect(original.get("from-heaven")!.payload.data.name).toBe("From heaven");
    expect(copy.get("from-heaven")!.payload.data.name).toBe("Copy name");
  });

  test("a lineup row is never moved to another page by a patch", async () => {
    const { owner } = await createHarness();
    const secondPage = "lineups-page-2";
    await addSecondPage(owner, secondPage);
    await apply(owner, "page-1-client", [addOp(lineup("k"), 0)]);

    // Another page wants the same key: the add is refused, and "Keep mine"
    // would turn it into a patch naming the other page.
    const clashing = lineup("k", { originId: "o2", name: "Page 2 lineup" });
    const added = await apply(owner, "page-2-client", [
      addOp(clashing, 0, secondPage),
    ]);
    expect(added[0]).toMatchObject({
      status: "rejected",
      reason: "already_exists",
    });
    const moved = await apply(owner, "page-2-client", [
      { ...patchOp("keep-mine", clashing, 1), pagePublicId: secondPage },
    ]);
    expect(moved[0]).toMatchObject({
      status: "failed",
      code: "LINEUP_PAGE_MISMATCH",
    });

    // The row stays on its page, untouched.
    const first = await pageLineups(owner);
    expect(first.map((row) => row.publicId)).toEqual(["k"]);
    expect(first[0]!.payload).toEqual(lineup("k").payload);
    expect(await pageLineups(owner, strategyPublicId, secondPage)).toEqual([]);
  });

  test("the same lineup added twice with a different order is one add", async () => {
    const { owner, editor } = await createHarness();
    const first = await apply(owner, "owner-client", [addOp(fanIn[0]!, 3)]);
    const second = await apply(editor, "editor-client", [addOp(fanIn[0]!, 7)]);
    expect(first[0]).toMatchObject({ status: "applied" });
    expect(second[0]).toMatchObject({ status: "noop" });
    const conflicting = await apply(editor, "editor-client", [
      {
        ...addOp(
          lineup("from-heaven", {
            originId: "heaven",
            landingId: "site",
            agentType: "jett",
          }),
          7,
        ),
        opId: "different-content",
      },
    ]);
    expect(conflicting[0]).toMatchObject({
      status: "rejected",
      reason: "already_exists",
    });
  });
});

describe("lineup images", () => {
  test("a lineup's images are referenced while it lives and released when it is deleted", async () => {
    const { t, owner } = await createHarness();
    await t.run(markAssetReferencesReady);
    await t.run(async (ctx) => {
      const strategy = await ctx.db
        .query("strategies")
        .withIndex("by_publicId", (q) => q.eq("publicId", strategyPublicId))
        .unique();
      const now = Date.now();
      for (const publicId of ["shot-1", "shot-2"]) {
        await ctx.db.insert("imageAssets", {
          publicId,
          provider: "r2",
          strategyId: strategy!._id,
          objectKey: `tests/${publicId}.png`,
          uploadStatus: "active",
          fileExtension: ".png",
          createdAt: now,
          updatedAt: now,
        });
      }
    });
    const row = lineup("k", {
      images: [
        { id: "shot-1", fileExtension: ".png" },
        { id: "shot-2", fileExtension: ".png" },
      ],
    });
    await apply(owner, "owner-client", [addOp(row, 0)]);

    const snapshot = (await owner.query(getPageSnapshot, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      strategyPublicId,
      pagePublicId,
    })) as { assets: Array<{ publicId: string }> };
    expect(snapshot.assets.map((asset) => asset.publicId).sort()).toEqual([
      "shot-1",
      "shot-2",
    ]);
    const references = await t.run(async (ctx) =>
      (await ctx.db.query("assetReferences").collect()).filter(
        (reference) => reference.lineupId !== undefined,
      ),
    );
    expect(
      references.map((reference) => reference.assetPublicId).sort(),
    ).toEqual(["shot-1", "shot-2"]);
    const asked = {
      strategyPublicId,
      assetPublicIds: ["shot-1", "shot-2", "never-shown"],
    };
    expect(await owner.query(listReferencedAssetIds, asked)).toEqual([
      "shot-1",
      "shot-2",
    ]);

    // Dropping one image from the lineup releases only that one.
    await apply(owner, "owner-client", [
      patchOp(
        "drop-shot-2",
        lineup("k", { images: [{ id: "shot-1", fileExtension: ".png" }] }),
        1,
      ),
    ]);
    expect(await owner.query(listReferencedAssetIds, asked)).toEqual([
      "shot-1",
    ]);

    await apply(owner, "owner-client", [deleteOp("delete-k", "k", 2)]);
    expect(await owner.query(listReferencedAssetIds, asked)).toEqual([]);
  });
});

describe("agent summary", () => {
  test("an origin shared by several lineups counts once, distinct origins count each", async () => {
    const { t, owner } = await createHarness();
    await apply(owner, "owner-client", [
      // One astra origin shared by two lineups.
      addOp(lineup("astra-a", { originId: "astra", agentType: "astra" }), 0),
      addOp(lineup("astra-b", { originId: "astra", agentType: "astra" }), 1),
      // Two viper origins.
      addOp(lineup("viper-a", { originId: "viper-1", agentType: "viper" }), 2),
      addOp(lineup("viper-b", { originId: "viper-2", agentType: "viper" }), 3),
    ]);
    // Counted per lineup, astra would tie viper and sort first by name;
    // counted per origin, viper (2) leads astra (1).
    expect(await agentSummary(t)).toEqual(["viper", "astra"]);

    // Deleting every lineup from an origin drops its agent.
    await apply(owner, "owner-client", [
      deleteOp("delete-astra-a", "astra-a", 1),
      deleteOp("delete-astra-b", "astra-b", 1),
    ]);
    expect(await agentSummary(t)).toEqual(["viper"]);
  });

  test("only a batch that may change the agents refreshes the summary", async () => {
    const { t, owner } = await createHarness();
    // A lineup written straight to the table leaves the stored summary
    // stale, so a refresh shows as the summary catching up with it.
    await seedLineupRow(t, "seeded-viper", "viper");
    expect(await agentSummary(t)).toEqual([]);

    // Drawings, utilities and text never carry an agent: no refresh.
    const plain = await apply(owner, "owner-client", [
      elementAdd("drawing-1", "drawing", 0),
      elementAdd("utility-1", "utility", 1),
      elementAdd("text-1", "text", 2),
      {
        opId: "patch-text-1",
        type: "element.patch",
        elementPublicId: "text-1",
        pagePublicId,
        payload: elementPayload("text-1", "text", { text: "Edited" }),
        expectedElementRevision: 1,
      },
      {
        opId: "delete-drawing-1",
        type: "element.delete",
        elementPublicId: "drawing-1",
        pagePublicId,
        expectedElementRevision: 1,
      },
    ]);
    expect(plain.map((result) => result.status)).toEqual([
      "applied",
      "applied",
      "applied",
      "applied",
      "applied",
    ]);
    expect(await agentSummary(t)).toEqual([]);

    // Placing an agent does.
    await apply(owner, "owner-client", [elementAdd("jett-1", "agent", 3)]);
    expect(await agentSummary(t)).toEqual(["jett", "viper"]);

    // Deleting an agent does too, though the op carries no payload.
    await seedLineupRow(t, "seeded-astra", "astra");
    expect(await agentSummary(t)).toEqual(["jett", "viper"]);
    await apply(owner, "owner-client", [
      {
        opId: "delete-jett-1",
        type: "element.delete",
        elementPublicId: "jett-1",
        pagePublicId,
        expectedElementRevision: 1,
      },
    ]);
    expect(await agentSummary(t)).toEqual(["astra", "viper"]);

    // And so does any lineup change.
    await seedLineupRow(t, "seeded-kayo", "kayo");
    expect(await agentSummary(t)).toEqual(["astra", "viper"]);
    await apply(owner, "owner-client", [
      addOp(lineup("placed-sova", { agentType: "sova" }), 9),
    ]);
    expect(await agentSummary(t)).toEqual(["astra", "kayo", "sova", "viper"]);
  });

  test("each live lineup keeps one agent row in step with it, and the summary follows them", async () => {
    const { t, owner } = await createHarness();
    const secondPage = "lineups-page-2";
    await addSecondPage(owner, secondPage);
    const astra = (notes = "") =>
      lineup("astra-a", { originId: "astra", agentType: "astra", notes });
    const viper = (agentType: string) =>
      lineup("viper-a", { originId: "viper-1", agentType });
    const kayo = lineup("kayo-a", { originId: "kayo", agentType: "kayo" });

    // Adding a lineup adds its row.
    await apply(owner, "owner-client", [
      addOp(astra(), 0),
      addOp(viper("viper"), 1),
      addOp(kayo, 0, secondPage),
    ]);
    expect(await lineupAgentRows(t)).toEqual([
      { lineup: "astra-a", page: pagePublicId, originId: "astra", agentType: "astra" },
      { lineup: "kayo-a", page: secondPage, originId: "kayo", agentType: "kayo" },
      { lineup: "viper-a", page: pagePublicId, originId: "viper-1", agentType: "viper" },
    ]);
    expect(await agentSummary(t)).toEqual(["astra", "kayo", "viper"]);

    // A patch that changes the origin's agent updates its row; one that
    // leaves the agent alone leaves it as it was.
    const astraRowBefore = await t.run(async (ctx) =>
      (await ctx.db.query("lineupAgents").collect()).find(
        (row) => row.originId === "astra",
      ),
    );
    const patched = await apply(owner, "owner-client", [
      patchOp("viper-to-sova", viper("sova"), 1),
      patchOp("astra-notes", astra("Run and throw"), 1),
    ]);
    expect(patched.map((result) => result.status)).toEqual([
      "applied",
      "applied",
    ]);
    expect(await lineupAgentRows(t)).toEqual([
      { lineup: "astra-a", page: pagePublicId, originId: "astra", agentType: "astra" },
      { lineup: "kayo-a", page: secondPage, originId: "kayo", agentType: "kayo" },
      { lineup: "viper-a", page: pagePublicId, originId: "viper-1", agentType: "sova" },
    ]);
    expect(
      await t.run(async (ctx) =>
        (await ctx.db.query("lineupAgents").collect()).find(
          (row) => row.originId === "astra",
        ),
      ),
    ).toEqual(astraRowBefore);
    expect(await agentSummary(t)).toEqual(["astra", "kayo", "sova"]);

    // Deleting a lineup removes its row; restoring it brings the row back.
    await apply(owner, "owner-client", [deleteOp("delete-astra", "astra-a", 2)]);
    expect((await lineupAgentRows(t)).map((row) => row.lineup)).toEqual([
      "kayo-a",
      "viper-a",
    ]);
    expect(await agentSummary(t)).toEqual(["kayo", "sova"]);
    const restored = await apply(owner, "owner-client", [
      { ...addOp(astra(), 0), opId: "restore-astra", expectedLineupRevision: 3 },
    ]);
    expect(restored[0]).toMatchObject({ status: "applied", appliedRevision: 4 });
    expect(await lineupAgentRows(t)).toContainEqual({
      lineup: "astra-a",
      page: pagePublicId,
      originId: "astra",
      agentType: "astra",
    });
    expect(await agentSummary(t)).toEqual(["astra", "kayo", "sova"]);

    // A page in the trash keeps its lineups' rows for a restore, and the
    // summary leaves them out until the page comes back.
    const trashed = await apply(owner, "owner-client", [
      {
        opId: "trash-page-2",
        type: "page.delete",
        pagePublicId: secondPage,
        expectedStrategyRevision: await strategyRevision(t),
      },
    ]);
    expect(trashed[0]).toMatchObject({ status: "applied" });
    expect((await lineupAgentRows(t)).map((row) => row.lineup)).toEqual([
      "astra-a",
      "kayo-a",
      "viper-a",
    ]);
    expect(await agentSummary(t)).toEqual(["astra", "sova"]);
    await owner.mutation(restorePage, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      strategyPublicId,
      pagePublicId: secondPage,
    });
    expect(await agentSummary(t)).toEqual(["astra", "kayo", "sova"]);
  });

  test("purging leaves no agent row behind, even one a tombstone kept", async () => {
    vi.useFakeTimers();
    const { t, owner } = await createHarness();
    await t.run(markAssetReferencesReady);
    await apply(owner, "owner-client", [
      addOp(lineup("gone", { agentType: "astra" }), 0),
      addOp(lineup("kept", { agentType: "viper" }), 1),
    ]);
    await apply(owner, "owner-client", [deleteOp("delete-gone", "gone", 1)]);
    expect((await lineupAgentRows(t)).map((row) => row.lineup)).toEqual([
      "kept",
    ]);
    // A row left behind for the tombstone (say by a write before this
    // table existed) goes with the tombstone.
    await t.run(async (ctx) => {
      const gone = (await ctx.db.query("lineups").collect()).find(
        (row) => row.publicId === "gone",
      )!;
      await ctx.db.insert("lineupAgents", {
        strategyId: gone.strategyId,
        pageId: gone.pageId,
        lineupId: gone._id,
        originId: "gone-origin",
        agentType: "astra",
      });
    });

    vi.setSystemTime(Date.now() + 31 * 24 * 60 * 60 * 1000);
    await t.mutation(purgeOldTombstones, {});
    await t.finishAllScheduledFunctions(vi.runAllTimers);

    const left = await t.run(async (ctx) => ({
      lineups: (await ctx.db.query("lineups").collect()).map(
        (row) => row.publicId,
      ),
      lineupAgents: (await ctx.db.query("lineupAgents").collect()).length,
    }));
    expect(left).toEqual({ lineups: ["kept"], lineupAgents: 1 });
    expect((await lineupAgentRows(t)).map((row) => row.lineup)).toEqual([
      "kept",
    ]);
  });

  test("a duplicate's lineups get agent rows of their own", async () => {
    const { t, owner } = await createHarness();
    await apply(owner, "owner-client", [
      addOp(lineup("astra-a", { originId: "astra", agentType: "astra" }), 0),
      addOp(lineup("astra-b", { originId: "astra", agentType: "astra" }), 1),
      addOp(lineup("viper-a", { originId: "viper", agentType: "viper" }), 2),
    ]);
    const sourceRows = await lineupAgentRows(t);

    await owner.mutation(duplicateStrategy, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      sourceStrategyPublicId: strategyPublicId,
      publicId: "lineups-copy",
      name: "Lineups (Copy)",
    });

    const copy = (await owner.query(getFullSnapshot, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      strategyPublicId: "lineups-copy",
    })) as {
      pages: Array<{ publicId: string }>;
      lineups: Array<LineupRow & { pagePublicId: string }>;
    };
    const copyRows = await lineupAgentRows(t, "lineups-copy");
    expect(copyRows).toEqual(
      copy.lineups
        .map((row) => {
          const origin = row.payload.data.origin as {
            id: string;
            agent: { type: string };
          };
          return {
            lineup: row.publicId,
            page: row.pagePublicId,
            originId: origin.id,
            agentType: origin.agent.type,
          };
        })
        .sort((a, b) => a.lineup.localeCompare(b.lineup)),
    );
    expect(copyRows).toHaveLength(3);
    expect(copyRows.map((row) => row.page)).toEqual(
      copyRows.map(() => copy.pages[0]!.publicId),
    );
    // The source keeps its rows untouched.
    expect(await lineupAgentRows(t)).toEqual(sourceRows);
    expect(await agentSummary(t, "lineups-copy")).toEqual(["astra", "viper"]);

    // Editing the copy moves only the copy's rows.
    const viperCopy = copyRows.find((row) => row.agentType === "viper")!;
    const viperCopyLanding = copy.lineups.find(
      (row) => row.publicId === viperCopy.lineup,
    )!.payload.data.landing as { id: string };
    const edited = await apply(
      owner,
      "copy-client",
      [
        {
          opId: "copy-viper-to-jett",
          type: "lineup.patch",
          lineupPublicId: viperCopy.lineup,
          pagePublicId: viperCopy.page,
          payload: lineupPayload(viperCopy.lineup, {
            originId: viperCopy.originId,
            landingId: viperCopyLanding.id,
            agentType: "jett",
          }),
          expectedLineupRevision: 1,
        },
      ],
      "lineups-copy",
    );
    expect(edited[0]).toMatchObject({ status: "applied" });
    expect(
      (await lineupAgentRows(t, "lineups-copy")).find(
        (row) => row.lineup === viperCopy.lineup,
      ),
    ).toEqual({ ...viperCopy, agentType: "jett" });
    expect(await agentSummary(t, "lineups-copy")).toEqual(["astra", "jett"]);
    expect(await lineupAgentRows(t)).toEqual(sourceRows);
    expect(await agentSummary(t)).toEqual(["astra", "viper"]);
  });
});

describe("a resent lineup op", () => {
  test("reports the revision it landed at, so a successor cannot overwrite a teammate's later edit", async () => {
    const { owner, editor } = await createHarness();
    await apply(owner, "owner-client", [addOp(fanIn[0]!, 0)]);
    const mine = patchOp(
      "owner-renames",
      lineup("from-heaven", {
        originId: "heaven",
        landingId: "site",
        name: "Owner name",
      }),
      1,
    );
    const first = await apply(owner, "owner-client", [mine]);
    expect(first[0]).toMatchObject({ status: "applied", appliedRevision: 2 });

    // A teammate edits the same lineup after it.
    const theirs = lineup("from-heaven", {
      originId: "heaven",
      landingId: "site",
      name: "Editor name",
    });
    const teammate = await apply(editor, "editor-client", [
      patchOp("editor-renames", theirs, 2),
    ]);
    expect(teammate[0]).toMatchObject({ status: "applied", appliedRevision: 3 });

    // The owner's ack was lost: it sends the op again, with the successor it
    // queued on top of it (expecting the revision the first landed at).
    const resent = await apply(owner, "owner-client", [
      mine,
      patchOp(
        "owner-notes",
        lineup("from-heaven", {
          originId: "heaven",
          landingId: "site",
          name: "Owner name",
          notes: "Owner notes",
        }),
        2,
      ),
    ]);
    expect(resent[0]).toEqual({
      opId: "owner-renames",
      status: "noop",
      currentRevision: 2,
    });
    expect(resent[1]).toMatchObject({
      status: "rejected",
      reason: "revision_mismatch",
      current: { type: "lineup", revision: 3, value: theirs.payload },
    });
    const row = byKey(await pageLineups(owner)).get("from-heaven")!;
    expect(row.revision).toBe(3);
    expect(row.payload).toEqual(theirs.payload);
  });
});

function elementPayload(
  id: string,
  kind: "agent" | "drawing" | "text" | "utility",
  extra: Record<string, unknown> = {},
) {
  return {
    kind,
    payloadVersion: 1,
    data: {
      id,
      elementType: kind,
      ...(kind === "agent" ? { type: "jett" } : {}),
      ...extra,
    },
  };
}

function elementAdd(
  id: string,
  kind: "agent" | "drawing" | "text" | "utility",
  sortIndex: number,
) {
  return {
    opId: `add-${id}`,
    type: "element.add",
    elementPublicId: id,
    pagePublicId,
    payload: elementPayload(id, kind),
    sortIndex,
  };
}

/// Writes a live lineup straight to the table, bypassing applyBatch and so
/// the agent summary refresh.
async function seedLineupRow(t: RootHarness, id: string, agentType: string) {
  await t.run(async (ctx) => {
    const strategy = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", strategyPublicId))
      .unique();
    const page = await ctx.db
      .query("pages")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy!._id))
      .first();
    const now = Date.now();
    await insertLineup(ctx, {
      publicId: id,
      strategyId: strategy!._id,
      pageId: page!._id,
      payloadKind: "lineup",
      payloadVersion: 1,
      payload: lineupPayload(id, { agentType }),
      sortIndex: 0,
      revision: 1,
      deleted: false,
      createdAt: now,
      updatedAt: now,
    });
  });
}
