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
  lineupsPayload,
  oneLineupPayload,
  type TestLineup,
  type TestLineupGroup,
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

/** A group row holding one lineup, as a test sends it: its key and payload. */
function lineup(id: string, details: TestLineup = {}) {
  return { key: id, payload: oneLineupPayload(id, details) };
}

/** A lineup group row as a test sends it: its key and its payload. */
function group(id: string, lineups: TestLineupGroup) {
  return { key: id, payload: lineupsPayload(id, lineups) };
}

type Row = { key: string; payload: { kind: string; data: object } };

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

/// A strategy's lineupAgents rows, each named by its group's and page's
/// public ids, ordered by group and origin. Fails on a row that names a
/// group gone or out of step with it (another strategy or page).
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
    return described.sort(
      (a, b) =>
        a.lineup.localeCompare(b.lineup) ||
        a.originId.localeCompare(b.originId),
    );
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

/// One group: two lineups from different origins into one shared landing
/// (fan-in), and a third from the first one's origin to another landing
/// (fan-out). A fresh copy each call, for a test to change.
function siteLineups(): TestLineupGroup {
  return {
    origins: [
      { id: "heaven", agentType: "brimstone", position: { dx: 120, dy: 340 } },
      { id: "mid", agentType: "viper", position: { dx: 200, dy: 100 } },
    ],
    landings: [
      { id: "site", position: { dx: 400, dy: 220 } },
      { id: "hell", position: { dx: 500, dy: 300 } },
    ],
    links: [
      {
        id: "from-heaven",
        originId: "heaven",
        landingId: "site",
        name: "From heaven",
        youtubeLink: "https://youtu.be/heaven",
        notes: "Jump throw",
      },
      { id: "from-mid", originId: "mid", landingId: "site", name: "From mid" },
      {
        id: "heaven-to-hell",
        originId: "heaven",
        landingId: "hell",
        name: "Hell",
      },
    ],
  };
}

const siteKey = "site-group";

function siteGroup(edit: (lineups: TestLineupGroup) => void = () => {}) {
  const lineups = siteLineups();
  edit(lineups);
  return group(siteKey, lineups);
}

describe("one row per lineup group", () => {
  test("a group round-trips with its origins, landings and links intact", async () => {
    const { owner } = await createHarness();
    const row = siteGroup();
    const results = await apply(owner, "owner-client", [addOp(row, 0)]);
    expect(results[0]).toMatchObject({ status: "applied", appliedRevision: 1 });

    const rows = await pageLineups(owner);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      publicId: siteKey,
      revision: 1,
      deleted: false,
    });
    expect(rows[0]!.payload).toEqual(row.payload);
    expect(rows[0]!.payload.kind).toBe("lineups");

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

  test("a group, its lineup and that lineup's landing may share one id", async () => {
    const { owner } = await createHarness();
    const row = group("same-id", {
      origins: [{ id: "origin" }],
      landings: [{ id: "same-id" }],
      links: [{ id: "same-id", originId: "origin", landingId: "same-id" }],
    });
    const results = await apply(owner, "owner-client", [addOp(row, 0)]);
    expect(results[0]).toMatchObject({ status: "applied" });
    expect((await pageLineups(owner))[0]!.payload).toEqual(row.payload);
  });

  test("moving a shared spot is one patch of its group, seen by every lineup in it", async () => {
    const { owner } = await createHarness();
    await apply(owner, "owner-client", [addOp(siteGroup(), 0)]);
    const moved = { dx: 10, dy: 20 };
    const edit = siteGroup((lineups) => {
      lineups.landings[0]!.position = moved;
    });

    const results = await apply(owner, "owner-client", [
      patchOp("move-site", edit, 1),
    ]);
    expect(results[0]).toMatchObject({ status: "applied", appliedRevision: 2 });
    const rows = await pageLineups(owner);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ revision: 2 });
    expect(rows[0]!.payload).toEqual(edit.payload);
    const data = rows[0]!.payload.data as {
      landings: Array<{ id: string; ability: { position: unknown } }>;
      links: Array<{ landingId: string }>;
    };
    // The spot is stored once, and both lineups into it name it.
    expect(data.landings.filter((landing) => landing.id === "site")).toEqual([
      {
        id: "site",
        ability: { id: "ability-site", position: moved, lineUpID: "site" },
      },
    ]);
    expect(data.links.map((link) => link.landingId)).toEqual([
      "site",
      "site",
      "hell",
    ]);
  });

  test("teammates editing different lineups of one group from the same revision: the second is a conflict, not a silent overwrite", async () => {
    const { owner, editor } = await createHarness();
    await apply(owner, "owner-client", [addOp(siteGroup(), 0)]);
    const ownerEdit = siteGroup((lineups) => {
      lineups.links[0]!.name = "Owner name";
    });
    const ownerResults = await apply(owner, "owner-client", [
      patchOp("owner-renames", ownerEdit, 1),
    ]);
    expect(ownerResults[0]).toMatchObject({
      status: "applied",
      appliedRevision: 2,
    });

    // The editor, still on revision 1, writes notes on another lineup of
    // the same group.
    const stale = await apply(editor, "editor-client", [
      patchOp(
        "editor-notes",
        siteGroup((lineups) => {
          lineups.links[1]!.notes = "Editor notes";
        }),
        1,
      ),
    ]);
    expect(stale[0]).toMatchObject({
      status: "rejected",
      reason: "revision_mismatch",
      current: { type: "lineup", revision: 2, value: ownerEdit.payload },
    });
    const row = byKey(await pageLineups(owner)).get(siteKey);
    expect(row).toMatchObject({ revision: 2 });
    expect(row!.payload).toEqual(ownerEdit.payload);
  });

  test("a viewer reads lineup groups but cannot write them", async () => {
    const { owner, viewer } = await createHarness();
    await apply(owner, "owner-client", [addOp(siteGroup(), 0)]);
    await expect(
      apply(viewer, "viewer-client", [addOp(lineup("viewer-lineup"), 1)]),
    ).rejects.toThrow("Forbidden");
    await expect(
      apply(viewer, "viewer-client", [
        patchOp(
          "viewer-renames",
          siteGroup((lineups) => {
            lineups.links[0]!.name = "Viewer";
          }),
          1,
        ),
      ]),
    ).rejects.toThrow("Forbidden");
    expect((await pageLineups(viewer)).map((row) => row.publicId)).toEqual([
      siteKey,
    ]);
  });
});

describe("a lineup group row is checked whole", () => {
  /// An add of the site group under [key] whose payload [edit] has changed.
  function brokenAdd(
    key: string,
    edit: (payload: {
      kind: string;
      payloadVersion: number;
      data: Record<string, any>;
    }) => void,
  ) {
    const payload = structuredClone(group(key, siteLineups()).payload) as {
      kind: string;
      payloadVersion: number;
      data: Record<string, any>;
    };
    edit(payload);
    return { ...addOp({ key, payload }, 0), opId: `add-${key}` };
  }

  test("each broken rule refuses the row with its code, and nothing is stored", async () => {
    const { owner } = await createHarness();
    const cases: Array<{
      op: Record<string, unknown>;
      code: string;
    }> = [
      {
        op: brokenAdd("unknown-version", (payload) => {
          payload.payloadVersion = 2;
        }),
        code: "INVALID_LINEUP_PAYLOAD_VERSION",
      },
      {
        op: brokenAdd("no-id", (payload) => {
          delete payload.data.id;
        }),
        code: "INVALID_LINEUP_PAYLOAD_DATA",
      },
      {
        op: { ...brokenAdd("keyed", () => {}), lineupPublicId: "other-key" },
        code: "INVALID_LINEUP_PAYLOAD_DATA",
      },
      ...(["origins", "landings", "links"] as const).flatMap((field) => [
        {
          op: brokenAdd(`no-${field}`, (payload) => {
            delete payload.data[field];
          }),
          code: "INVALID_LINEUP_PAYLOAD_DATA",
        },
        {
          op: brokenAdd(`${field}-not-a-list`, (payload) => {
            payload.data[field] = { [payload.data[field][0].id]: true };
          }),
          code: "INVALID_LINEUP_PAYLOAD_DATA",
        },
        {
          op: brokenAdd(`${field}-entry-not-an-object`, (payload) => {
            payload.data[field][0] = payload.data[field][0].id;
          }),
          code: "INVALID_LINEUP_PAYLOAD_DATA",
        },
        {
          op: brokenAdd(`${field}-entry-without-id`, (payload) => {
            delete payload.data[field][0].id;
          }),
          code: "INVALID_LINEUP_PAYLOAD_DATA",
        },
        {
          op: brokenAdd(`${field}-entry-with-empty-id`, (payload) => {
            payload.data[field][0].id = "";
          }),
          code: "INVALID_LINEUP_PAYLOAD_DATA",
        },
        {
          op: brokenAdd(`${field}-repeat-an-id`, (payload) => {
            payload.data[field][1].id = payload.data[field][0].id;
          }),
          code: "INVALID_LINEUP_PAYLOAD_DATA",
        },
      ]),
      {
        op: brokenAdd("origin-without-agent", (payload) => {
          delete payload.data.origins[0].agent;
        }),
        code: "INVALID_LINEUP_PAYLOAD_DATA",
      },
      {
        op: brokenAdd("landing-without-ability", (payload) => {
          delete payload.data.landings[0].ability;
        }),
        code: "INVALID_LINEUP_PAYLOAD_DATA",
      },
      {
        op: brokenAdd("no-lineups", (payload) => {
          payload.data.links = [];
        }),
        code: "INVALID_LINEUP_PAYLOAD_DATA",
      },
      {
        op: brokenAdd("link-to-missing-origin", (payload) => {
          payload.data.links[0].originId = "nowhere";
        }),
        code: "INVALID_LINEUP_PAYLOAD_DATA",
      },
      {
        op: brokenAdd("link-to-missing-landing", (payload) => {
          payload.data.links[0].landingId = "nowhere";
        }),
        code: "INVALID_LINEUP_PAYLOAD_DATA",
      },
      {
        op: brokenAdd("link-without-origin", (payload) => {
          delete payload.data.links[0].originId;
        }),
        code: "INVALID_LINEUP_PAYLOAD_DATA",
      },
      {
        op: brokenAdd("link-without-landing", (payload) => {
          delete payload.data.links[0].landingId;
        }),
        code: "INVALID_LINEUP_PAYLOAD_DATA",
      },
      {
        // A link may not name a landing as its origin.
        op: brokenAdd("link-ends-swapped", (payload) => {
          payload.data.links[0].originId = "site";
          payload.data.links[0].landingId = "heaven";
        }),
        code: "INVALID_LINEUP_PAYLOAD_DATA",
      },
    ];

    const results = await apply(
      owner,
      "owner-client",
      cases.map((entry) => entry.op),
    );
    expect(results).toEqual(
      cases.map((entry) =>
        expect.objectContaining({
          opId: entry.op.opId,
          status: "failed",
          code: entry.code,
        }),
      ),
    );
    expect(await pageLineups(owner)).toEqual([]);
  });

  test("a spot no lineup uses is kept", async () => {
    const { owner } = await createHarness();
    const row = siteGroup((lineups) => {
      lineups.origins.push({ id: "unused-origin", agentType: "jett" });
      lineups.landings.push({ id: "unused-landing" });
    });
    const results = await apply(owner, "owner-client", [addOp(row, 0)]);
    expect(results[0]).toMatchObject({ status: "applied" });
    expect((await pageLineups(owner))[0]!.payload).toEqual(row.payload);
  });

  test("a patch that breaks the group is refused and leaves the row as it was", async () => {
    const { owner } = await createHarness();
    await apply(owner, "owner-client", [addOp(siteGroup(), 0)]);
    // The landing two lineups aim at is gone, but they still name it.
    const broken = siteGroup((lineups) => {
      lineups.landings = lineups.landings.filter(
        (landing) => landing.id !== "site",
      );
    });
    const results = await apply(owner, "owner-client", [
      patchOp("drop-site", broken, 1),
    ]);
    expect(results[0]).toMatchObject({
      status: "failed",
      code: "INVALID_LINEUP_PAYLOAD_DATA",
    });
    const row = (await pageLineups(owner))[0]!;
    expect(row).toMatchObject({ revision: 1 });
    expect(row.payload).toEqual(siteGroup().payload);
  });

  test("the graph kinds of protocol 4 are refused by the handler; lineup and lineupGroup by the contract", async () => {
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
    // The group of protocol 3 and earlier, and the one-row-per-lineup shape
    // this branch tried before groups, are refused whole: no client that
    // could send them speaks protocol 5.
    const retired = [
      {
        kind: "lineupGroup",
        payloadVersion: 1,
        data: { id: "group", items: [{ id: "item" }] },
      },
      {
        kind: "lineup",
        payloadVersion: 1,
        data: {
          id: "group",
          origin: { id: "o", agent: { type: "sova" } },
          landing: { id: "l", ability: {} },
        },
      },
    ];
    for (const payload of retired) {
      await expect(
        apply(owner, "old-client", [
          {
            opId: `add-${payload.kind}`,
            type: "lineup.add",
            lineupPublicId: "group",
            pagePublicId,
            payload,
            sortIndex: 0,
          },
        ]),
      ).rejects.toThrow(/Validator error|ArgumentValidationError/);
    }
    expect(await pageLineups(owner)).toEqual([]);
  });
});

describe("no lineup or spot is in two groups of a page", () => {
  test("a new group holding a spot another group holds is refused, and nothing is stored", async () => {
    const { owner } = await createHarness();
    await apply(owner, "owner-client", [
      addOp(lineup("k1", { landingId: "smoke" }), 0),
    ]);
    const results = await apply(owner, "owner-client", [
      addOp(lineup("k2", { landingId: "smoke" }), 1),
    ]);
    expect(results[0]).toMatchObject({
      status: "failed",
      code: "INVALID_LINEUP_PAYLOAD_DATA",
    });
    expect(liveKeys(await pageLineups(owner))).toEqual(["k1"]);
  });

  test("a patch taking a lineup another group holds is refused and leaves the row as it was", async () => {
    const { owner } = await createHarness();
    await apply(owner, "owner-client", [
      addOp(lineup("k1"), 0),
      addOp(lineup("k2"), 1),
    ]);
    // k2's row also claims k1's lineup, under its own spots.
    const grabbing = group("k2", {
      origins: [{ id: "k2-origin" }],
      landings: [{ id: "k2-landing" }],
      links: [
        { id: "k2", originId: "k2-origin", landingId: "k2-landing" },
        { id: "k1", originId: "k2-origin", landingId: "k2-landing" },
      ],
    });
    const results = await apply(owner, "owner-client", [
      patchOp("grab-k1", grabbing, 1),
    ]);
    expect(results[0]).toMatchObject({
      status: "failed",
      code: "INVALID_LINEUP_PAYLOAD_DATA",
    });
    const rows = byKey(await pageLineups(owner));
    expect(rows.get("k2")).toMatchObject({ revision: 1 });
    expect(rows.get("k2")!.payload).toEqual(lineup("k2").payload);
  });

  test("ids only clash within a kind, within a page, among live rows", async () => {
    const { owner } = await createHarness();
    await addSecondPage(owner, "page-2");
    await apply(owner, "owner-client", [
      addOp(lineup("k1", { landingId: "shared" }), 0),
    ]);
    const results = await apply(owner, "owner-client", [
      // A lineup named like another group's landing.
      addOp(lineup("shared", { landingId: "other" }), 1),
      // The same spot on another page.
      addOp(lineup("k3", { landingId: "shared" }), 0, "page-2"),
    ]);
    expect(results.map((result) => result.status)).toEqual([
      "applied",
      "applied",
    ]);

    // Once k1's group is deleted, its spot is free for another group.
    await apply(owner, "owner-client", [deleteOp("drop-k1", "k1", 1)]);
    const reuse = await apply(owner, "owner-client", [
      addOp(lineup("k4", { landingId: "shared" }), 2),
    ]);
    expect(reuse[0]).toMatchObject({ status: "applied" });
  });

  test("a duplicated strategy's groups hold their spots in the copy too", async () => {
    const { owner } = await createHarness();
    await apply(owner, "owner-client", [addOp(lineup("k1"), 0)]);
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
    const copied = copy.lineups[0]!;
    const landingId = (
      copied.payload.data.landings as Array<{ id: string }>
    )[0]!.id;

    const results = await apply(
      owner,
      "owner-client",
      [addOp(lineup("k2", { landingId }), 1, copied.pagePublicId)],
      "lineups-copy",
    );
    expect(results[0]).toMatchObject({
      status: "failed",
      code: "INVALID_LINEUP_PAYLOAD_DATA",
    });
  });

  test("restoring a deleted group over a spot another group took since is refused", async () => {
    const { owner } = await createHarness();
    await apply(owner, "owner-client", [
      addOp(lineup("k1", { landingId: "smoke" }), 0),
    ]);
    await apply(owner, "owner-client", [deleteOp("drop-k1", "k1", 1)]);
    await apply(owner, "owner-client", [
      addOp(lineup("k2", { landingId: "smoke" }), 1),
    ]);
    const results = await apply(owner, "owner-client", [
      {
        ...addOp(lineup("k1", { landingId: "smoke" }), 0),
        opId: "restore-k1",
        expectedLineupRevision: 2,
      },
    ]);
    expect(results[0]).toMatchObject({
      status: "failed",
      code: "INVALID_LINEUP_PAYLOAD_DATA",
    });
    expect(liveKeys(await pageLineups(owner))).toEqual(["k2"]);
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
  test("the same group ids in two strategies are separate rows", async () => {
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
        [addOp(siteGroup(), 0, page)],
        strategy,
      );
      expect(results[0]).toMatchObject({ status: "applied" });
    }
    // Editing one copy leaves the other untouched.
    await apply(
      owner,
      "edit-copy",
      [
        {
          ...patchOp(
            "rename-in-copy",
            siteGroup((lineups) => {
              lineups.links[0]!.name = "Copy name";
            }),
            1,
          ),
          pagePublicId: copyPage,
        },
      ],
      copyId,
    );
    const firstLinkName = (row: LineupRow | undefined) =>
      (row!.payload.data as { links: Array<{ name: string }> }).links[0]!.name;
    expect(firstLinkName(byKey(await pageLineups(owner)).get(siteKey))).toBe(
      "From heaven",
    );
    expect(
      firstLinkName(
        byKey(await pageLineups(owner, copyId, copyPage)).get(siteKey),
      ),
    ).toBe("Copy name");
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

  test("the same group added twice with a different order is one add", async () => {
    const { owner, editor } = await createHarness();
    const first = await apply(owner, "owner-client", [addOp(siteGroup(), 3)]);
    const second = await apply(editor, "editor-client", [
      addOp(siteGroup(), 7),
    ]);
    expect(first[0]).toMatchObject({ status: "applied" });
    expect(second[0]).toMatchObject({ status: "noop" });
    const conflicting = await apply(editor, "editor-client", [
      {
        ...addOp(
          siteGroup((lineups) => {
            lineups.origins[0]!.agentType = "jett";
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
  test("a group references every image across its lineups while it lives, and releases them when it is deleted", async () => {
    const { t, owner } = await createHarness();
    await t.run(markAssetReferencesReady);
    const shots = ["shot-1", "shot-2", "shot-3"];
    await t.run(async (ctx) => {
      const strategy = await ctx.db
        .query("strategies")
        .withIndex("by_publicId", (q) => q.eq("publicId", strategyPublicId))
        .unique();
      const now = Date.now();
      for (const publicId of shots) {
        await ctx.db.insert("imageAssets", {
          publicId,
          provider: "r2",
          strategyId: strategy!._id,
          objectKey: `tests/${publicId}.png`,
          uploadStatus: "active",
          fileExtension: ".png",
          mimeType: "image/png",
          createdAt: now,
          updatedAt: now,
        });
      }
    });
    // Two lineups of the group show images, one of them shared by both.
    const withImages = (secondLinkShots: string[]) =>
      siteGroup((lineups) => {
        lineups.links[0]!.images = [
          { id: "shot-1", fileExtension: ".png" },
          { id: "shot-2", fileExtension: ".png" },
        ];
        lineups.links[2]!.images = secondLinkShots.map((id) => ({
          id,
          fileExtension: ".png",
        }));
      });
    await apply(owner, "owner-client", [
      addOp(withImages(["shot-2", "shot-3"]), 0),
    ]);

    const snapshot = (await owner.query(getPageSnapshot, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      strategyPublicId,
      pagePublicId,
    })) as { assets: Array<{ publicId: string }> };
    expect(snapshot.assets.map((asset) => asset.publicId).sort()).toEqual(
      shots,
    );
    // One reference per image the row shows, however many lineups show it.
    const lineupReferences = async () =>
      (
        await t.run(async (ctx) => await ctx.db.query("assetReferences").collect())
      )
        .filter((reference) => reference.lineupId !== undefined)
        .map((reference) => reference.assetPublicId)
        .sort();
    expect(await lineupReferences()).toEqual(shots);
    const asked = {
      strategyPublicId,
      assetPublicIds: [...shots, "never-shown"],
    };
    expect(await owner.query(listReferencedAssetIds, asked)).toEqual(shots);

    // Dropping an image one lineup still shows keeps it; dropping the last
    // lineup showing an image releases only that one.
    await apply(owner, "owner-client", [
      patchOp("drop-shared-shot", withImages(["shot-3"]), 1),
    ]);
    expect(await owner.query(listReferencedAssetIds, asked)).toEqual(shots);
    await apply(owner, "owner-client", [
      patchOp("drop-shot-3", withImages([]), 2),
    ]);
    expect(await owner.query(listReferencedAssetIds, asked)).toEqual([
      "shot-1",
      "shot-2",
    ]);
    expect(await lineupReferences()).toEqual(["shot-1", "shot-2"]);

    await apply(owner, "owner-client", [deleteOp("delete-site", siteKey, 3)]);
    expect(await owner.query(listReferencedAssetIds, asked)).toEqual([]);
  });
});

describe("agent summary", () => {
  test("an origin shared by several lineups counts once, distinct origins count each", async () => {
    const { t, owner } = await createHarness();
    await apply(owner, "owner-client", [
      // One astra origin, thrown to two landings.
      addOp(
        group("astra", {
          origins: [{ id: "astra-origin", agentType: "astra" }],
          landings: [{ id: "a-site" }, { id: "b-site" }],
          links: [
            { id: "astra-a", originId: "astra-origin", landingId: "a-site" },
            { id: "astra-b", originId: "astra-origin", landingId: "b-site" },
          ],
        }),
        0,
      ),
      // Two viper origins into one landing.
      addOp(
        group("viper", {
          origins: [
            { id: "viper-1", agentType: "viper" },
            { id: "viper-2", agentType: "viper" },
          ],
          landings: [{ id: "wall" }],
          links: [
            { id: "viper-a", originId: "viper-1", landingId: "wall" },
            { id: "viper-b", originId: "viper-2", landingId: "wall" },
          ],
        }),
        1,
      ),
    ]);
    // Counted per lineup, astra would tie viper and sort first by name;
    // counted per origin, viper (2) leads astra (1).
    expect(await agentSummary(t)).toEqual(["viper", "astra"]);

    // Deleting the group of an origin drops its agent.
    await apply(owner, "owner-client", [deleteOp("delete-astra", "astra", 1)]);
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

  test("each live group keeps one agent row per origin in step with it, and the summary follows them", async () => {
    const { t, owner } = await createHarness();
    const secondPage = "lineups-page-2";
    await addSecondPage(owner, secondPage);
    const kayo = lineup("kayo-a", { originId: "kayo", agentType: "kayo" });
    const rawRows = async () =>
      await t.run(async (ctx) => await ctx.db.query("lineupAgents").collect());

    // Adding a group adds a row for each of its origins.
    await apply(owner, "owner-client", [
      addOp(siteGroup(), 0),
      addOp(kayo, 0, secondPage),
    ]);
    expect(await lineupAgentRows(t)).toEqual([
      { lineup: "kayo-a", page: secondPage, originId: "kayo", agentType: "kayo" },
      { lineup: siteKey, page: pagePublicId, originId: "heaven", agentType: "brimstone" },
      { lineup: siteKey, page: pagePublicId, originId: "mid", agentType: "viper" },
    ]);
    expect(await agentSummary(t)).toEqual(["brimstone", "kayo", "viper"]);

    // A patch that changes one origin's agent updates that row alone; the
    // other origin's row is left exactly as it was.
    const before = await rawRows();
    const heavenRow = before.find((row) => row.originId === "heaven")!;
    const midRow = before.find((row) => row.originId === "mid")!;
    const midToSova = siteGroup((lineups) => {
      lineups.origins[1]!.agentType = "sova";
    });
    expect(
      (await apply(owner, "owner-client", [patchOp("mid-to-sova", midToSova, 1)]))[0],
    ).toMatchObject({ status: "applied" });
    let after = await rawRows();
    expect(after.find((row) => row.originId === "heaven")).toEqual(heavenRow);
    expect(after.find((row) => row.originId === "mid")).toEqual({
      ...midRow,
      agentType: "sova",
    });
    expect(await agentSummary(t)).toEqual(["brimstone", "kayo", "sova"]);

    // A lineup from a new origin adds its row; dropping an origin (and its
    // lineup) deletes its row, leaving the rest.
    const reshaped = siteGroup((lineups) => {
      lineups.origins[1]!.agentType = "sova";
      lineups.origins.push({ id: "garage", agentType: "astra" });
      lineups.links.push({ id: "from-garage", originId: "garage", landingId: "site" });
    });
    await apply(owner, "owner-client", [patchOp("add-garage", reshaped, 2)]);
    expect(
      (await lineupAgentRows(t)).filter((row) => row.lineup === siteKey),
    ).toEqual([
      { lineup: siteKey, page: pagePublicId, originId: "garage", agentType: "astra" },
      { lineup: siteKey, page: pagePublicId, originId: "heaven", agentType: "brimstone" },
      { lineup: siteKey, page: pagePublicId, originId: "mid", agentType: "sova" },
    ]);
    const withoutMid = siteGroup((lineups) => {
      lineups.origins = lineups.origins.filter((origin) => origin.id !== "mid");
      lineups.origins.push({ id: "garage", agentType: "astra" });
      lineups.links = lineups.links.filter((link) => link.originId !== "mid");
      lineups.links.push({ id: "from-garage", originId: "garage", landingId: "site" });
    });
    await apply(owner, "owner-client", [patchOp("drop-mid", withoutMid, 3)]);
    after = await rawRows();
    expect(after.find((row) => row.originId === "heaven")).toEqual(heavenRow);
    expect(
      (await lineupAgentRows(t)).filter((row) => row.lineup === siteKey),
    ).toEqual([
      { lineup: siteKey, page: pagePublicId, originId: "garage", agentType: "astra" },
      { lineup: siteKey, page: pagePublicId, originId: "heaven", agentType: "brimstone" },
    ]);
    expect(await agentSummary(t)).toEqual(["astra", "brimstone", "kayo"]);

    // Deleting a group removes all its rows; restoring it brings them back.
    await apply(owner, "owner-client", [deleteOp("delete-site", siteKey, 4)]);
    expect((await lineupAgentRows(t)).map((row) => row.lineup)).toEqual([
      "kayo-a",
    ]);
    expect(await agentSummary(t)).toEqual(["kayo"]);
    const restored = await apply(owner, "owner-client", [
      { ...addOp(withoutMid, 0), opId: "restore-site", expectedLineupRevision: 5 },
    ]);
    expect(restored[0]).toMatchObject({ status: "applied", appliedRevision: 6 });
    expect(
      (await lineupAgentRows(t)).map((row) => `${row.lineup}:${row.originId}`),
    ).toEqual(["kayo-a:kayo", `${siteKey}:garage`, `${siteKey}:heaven`]);
    expect(await agentSummary(t)).toEqual(["astra", "brimstone", "kayo"]);

    // A page in the trash keeps its groups' rows for a restore, and the
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
      "kayo-a",
      siteKey,
      siteKey,
    ]);
    expect(await agentSummary(t)).toEqual(["astra", "brimstone"]);
    await owner.mutation(restorePage, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      strategyPublicId,
      pagePublicId: secondPage,
    });
    expect(await agentSummary(t)).toEqual(["astra", "brimstone", "kayo"]);
  });

  test("purging leaves no agent row behind, even one a tombstone kept", async () => {
    vi.useFakeTimers();
    const { t, owner } = await createHarness();
    await t.run(markAssetReferencesReady);
    await apply(owner, "owner-client", [
      addOp(siteGroup(), 0),
      addOp(lineup("kept", { agentType: "viper" }), 1),
    ]);
    await apply(owner, "owner-client", [deleteOp("delete-site", siteKey, 1)]);
    expect((await lineupAgentRows(t)).map((row) => row.lineup)).toEqual([
      "kept",
    ]);
    // A row left behind for the tombstone (say by a write before this
    // table existed) goes with the tombstone.
    await t.run(async (ctx) => {
      const gone = (await ctx.db.query("lineups").collect()).find(
        (row) => row.publicId === siteKey,
      )!;
      await ctx.db.insert("lineupAgents", {
        strategyId: gone.strategyId,
        pageId: gone.pageId,
        lineupId: gone._id,
        originId: "heaven",
        agentType: "brimstone",
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

  test("a duplicate's groups get agent rows of their own, one per origin", async () => {
    const { t, owner } = await createHarness();
    await apply(owner, "owner-client", [
      addOp(siteGroup(), 0),
      addOp(lineup("astra-a", { originId: "astra", agentType: "astra" }), 1),
    ]);
    const sourceRows = await lineupAgentRows(t);

    await owner.mutation(duplicateStrategy, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      sourceStrategyPublicId: strategyPublicId,
      publicId: "lineups-copy",
      name: "Lineups (Copy)",
    });

    type Origin = { id: string; agent: { type: string } };
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
        .flatMap((row) =>
          (row.payload.data.origins as Origin[]).map((origin) => ({
            lineup: row.publicId,
            page: row.pagePublicId,
            originId: origin.id,
            agentType: origin.agent.type,
          })),
        )
        .sort(
          (a, b) =>
            a.lineup.localeCompare(b.lineup) ||
            a.originId.localeCompare(b.originId),
        ),
    );
    expect(copyRows).toHaveLength(3);
    expect(copyRows.map((row) => row.page)).toEqual(
      copyRows.map(() => copy.pages[0]!.publicId),
    );
    // The source keeps its rows untouched.
    expect(await lineupAgentRows(t)).toEqual(sourceRows);
    expect(await agentSummary(t, "lineups-copy")).toEqual([
      "astra",
      "brimstone",
      "viper",
    ]);

    // Editing the copy moves only the copy's rows.
    const copiedSite = copy.lineups.find(
      (row) => (row.payload.data.origins as Origin[]).length === 2,
    )!;
    const data = structuredClone(copiedSite.payload.data) as {
      origins: Origin[];
    };
    const viperOrigin = data.origins.find(
      (origin) => origin.agent.type === "viper",
    )!;
    viperOrigin.agent.type = "jett";
    const edited = await apply(
      owner,
      "copy-client",
      [
        {
          opId: "copy-viper-to-jett",
          type: "lineup.patch",
          lineupPublicId: copiedSite.publicId,
          pagePublicId: copiedSite.pagePublicId,
          payload: { ...copiedSite.payload, data },
          expectedLineupRevision: 1,
        },
      ],
      "lineups-copy",
    );
    expect(edited[0]).toMatchObject({ status: "applied" });
    expect(
      (await lineupAgentRows(t, "lineups-copy")).find(
        (row) => row.originId === viperOrigin.id,
      ),
    ).toMatchObject({ lineup: copiedSite.publicId, agentType: "jett" });
    expect(await agentSummary(t, "lineups-copy")).toEqual([
      "astra",
      "brimstone",
      "jett",
    ]);
    expect(await lineupAgentRows(t)).toEqual(sourceRows);
    expect(await agentSummary(t)).toEqual(["astra", "brimstone", "viper"]);
  });
});

describe("a resent lineup op", () => {
  test("reports the revision it landed at, so a successor cannot overwrite a teammate's later edit", async () => {
    const { owner, editor } = await createHarness();
    await apply(owner, "owner-client", [addOp(siteGroup(), 0)]);
    const mine = patchOp(
      "owner-renames",
      siteGroup((lineups) => {
        lineups.links[0]!.name = "Owner name";
      }),
      1,
    );
    const first = await apply(owner, "owner-client", [mine]);
    expect(first[0]).toMatchObject({ status: "applied", appliedRevision: 2 });

    // A teammate edits the same group after it.
    const theirs = siteGroup((lineups) => {
      lineups.links[0]!.name = "Editor name";
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
        siteGroup((lineups) => {
          lineups.links[0]!.name = "Owner name";
          lineups.links[0]!.notes = "Owner notes";
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
    const row = byKey(await pageLineups(owner)).get(siteKey)!;
    expect(row.revision).toBe(3);
    expect(row.payload).toEqual(theirs.payload);
  });

  test("whose event recorded no revision replays with none, not the row's latest", async () => {
    const { t, owner, editor } = await createHarness();
    const mine = addOp(siteGroup(), 0);
    const first = await apply(owner, "owner-client", [mine]);
    expect(first[0]).toMatchObject({ status: "applied", appliedRevision: 1 });
    // An event written without the revision its op landed at.
    await t.run(async (ctx) => {
      const event = (await ctx.db.query("operationEvents").collect()).find(
        (row) => row.opId === mine.opId,
      )!;
      await ctx.db.patch(event._id, { appliedRevision: undefined });
    });
    // A teammate moves the row on.
    const theirs = siteGroup((lineups) => {
      lineups.links[0]!.name = "Editor name";
    });
    await apply(editor, "editor-client", [patchOp("editor-renames", theirs, 1)]);

    // The replay names no revision, so the client cannot rebase a successor
    // onto the teammate's edit; the successor, still on 1, meets the usual
    // revision check.
    const resent = await apply(owner, "owner-client", [
      mine,
      patchOp(
        "owner-renames",
        siteGroup((lineups) => {
          lineups.links[0]!.name = "Owner name";
        }),
        1,
      ),
    ]);
    expect(resent[0]).toEqual({ opId: mine.opId, status: "noop" });
    expect(resent[1]).toMatchObject({
      status: "rejected",
      reason: "revision_mismatch",
      current: { type: "lineup", revision: 2, value: theirs.payload },
    });
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

/// Writes a live group of one lineup straight to the table, bypassing
/// applyBatch and so the agent summary refresh.
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
      payloadKind: "lineups",
      payloadVersion: 1,
      payload: oneLineupPayload(id, { agentType }),
      sortIndex: 0,
      revision: 1,
      deleted: false,
      createdAt: now,
      updatedAt: now,
    });
  });
}
