import {
  convexTest,
  type TestConvexForDataModel,
  type TestConvexForDataModelAndIdentity,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { beforeAll, describe, expect, test } from "vitest";
import type { DataModel } from "./_generated/dataModel";
import { markAssetReferencesReady } from "./lib/assetReferences";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "./lib/cloudProtocol";
import schema from "./schema";
import { lineupPayload, type TestLineup } from "./testContent.helpers";
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

async function agentSummary(t: RootHarness): Promise<string[]> {
  return await t.run(async (ctx) => {
    const strategy = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", strategyPublicId))
      .unique();
    const summary = await ctx.db
      .query("strategyAgentSummaries")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy!._id))
      .unique();
    return summary?.agentTypes ?? [];
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

  test("a row of an old graph kind is refused by the contract", async () => {
    const { owner } = await createHarness();
    for (const kind of ["lineupLink", "lineupOrigin", "lineupGroup"]) {
      await expect(
        apply(owner, "old-client", [
          {
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
          },
        ]),
      ).rejects.toThrow(/Validator error|ArgumentValidationError/);
    }
    expect(await pageLineups(owner)).toEqual([]);
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
});
