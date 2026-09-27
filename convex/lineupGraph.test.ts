import {
  convexTest,
  type TestConvexForDataModel,
  type TestConvexForDataModelAndIdentity,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { beforeAll, describe, expect, test } from "vitest";
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
const createShare = makeFunctionReference<"mutation">("shares:create");
const redeemShare = makeFunctionReference<"mutation">("shares:redeem");
const addPage = makeFunctionReference<"mutation">("pages:add");
const applyBatch = makeFunctionReference<"mutation">("ops:applyBatch");
const getPageSnapshot = makeFunctionReference<"query">("page:getSnapshot");
const getFullSnapshot = makeFunctionReference<"query">(
  "strategy:getFullSnapshot",
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

const strategyPublicId = "lineup-graph-strategy";
const pagePublicId = "lineup-graph-page";

function identity(subject: string) {
  return {
    issuer: "https://lineup-graph.test",
    subject,
    tokenIdentifier: `lineup-graph|${subject}`,
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
    name: "Lineup graph",
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

function origin(id: string, agentType = "sova") {
  return {
    key: `lineupOrigin:${id}`,
    payload: {
      kind: "lineupOrigin" as const,
      payloadVersion: 1,
      data: { id, agent: { id: `agent-${id}`, type: agentType, lineUpID: id } },
    },
  };
}

function landing(id: string) {
  return {
    key: `lineupLanding:${id}`,
    payload: {
      kind: "lineupLanding" as const,
      payloadVersion: 1,
      data: { id, ability: { id: `ability-${id}`, lineUpID: id } },
    },
  };
}

function link(
  id: string,
  originId: string,
  landingId: string,
  details: Record<string, unknown> = {},
) {
  return {
    key: `lineupLink:${id}`,
    payload: {
      kind: "lineupLink" as const,
      payloadVersion: 1,
      data: {
        id,
        originId,
        landingId,
        name: "",
        youtubeLink: "",
        notes: "",
        images: [],
        ...details,
      },
    },
  };
}

type Row = ReturnType<typeof origin | typeof landing | typeof link>;

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

async function apply(
  user: Harness,
  clientId: string,
  ops: Array<Record<string, unknown>>,
  strategy = strategyPublicId,
  checks: {
    checkLineupLinkEnds?: boolean;
    checkLineupEndDeletes?: boolean;
  } = {},
): Promise<Result[]> {
  const response = (await user.mutation(applyBatch, {
    strategyPublicId: strategy,
    clientId,
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    ops,
    ...checks,
  })) as { results: Result[] };
  return response.results;
}

/**
 * [apply] as a current client sends it: link ends are checked, and so are
 * deletes of an end a live link names.
 */
async function applyChecked(
  user: Harness,
  clientId: string,
  ops: Array<Record<string, unknown>>,
): Promise<Result[]> {
  return await apply(user, clientId, ops, strategyPublicId, {
    checkLineupLinkEnds: true,
    checkLineupEndDeletes: true,
  });
}

async function pageLineups(
  user: Harness,
  strategy = strategyPublicId,
  page = pagePublicId,
): Promise<LineupRow[]> {
  const snapshot = (await user.query(getPageSnapshot, {
    strategyPublicId: strategy,
    pagePublicId: page,
  })) as { lineups: LineupRow[] };
  return snapshot.lineups;
}

/** A second strategy owned by [owner], with one page. */
async function createCopy(owner: Harness, publicId: string, page: string) {
  await owner.mutation(createStrategy, {
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    publicId,
    name: "Copy",
    mapData: "ascent",
    initialPagePublicId: page,
    initialPageName: "Page 1",
    initialPageIsAttack: true,
  });
}

function byKey(rows: LineupRow[]): Map<string, LineupRow> {
  return new Map(rows.map((row) => [row.publicId, row]));
}

beforeAll(() => {
  // Page snapshots serialize asset URLs from the R2 public base.
  process.env.R2_ACCOUNT_ID = "lineup-graph-account";
  process.env.R2_BUCKET = "lineup-graph-bucket";
  process.env.R2_ACCESS_KEY_ID = "lineup-graph-access-key";
  process.env.R2_SECRET_ACCESS_KEY = "lineup-graph-secret";
  process.env.R2_PUBLIC_BASE_URL = "https://assets.lineup-graph.test";
  process.env.R2_S3_ENDPOINT = "https://lineup-graph.r2.test";
});

/** Two origins aiming at one shared landing, each link named. */
const fanIn = [
  origin("origin-a"),
  origin("origin-b"),
  landing("shared"),
  link("link-a", "origin-a", "shared", { name: "From heaven" }),
  link("link-b", "origin-b", "shared", { name: "From mid" }),
];

describe("lineup graph rows", () => {
  test("a fan-in lineup round-trips with its shared landing and link names", async () => {
    const { owner } = await createHarness();
    const results = await apply(
      owner,
      "owner-client",
      fanIn.map((row, index) => addOp(row, index)),
    );
    expect(results.map((result) => result.status)).toEqual(
      fanIn.map(() => "applied"),
    );

    const rows = await pageLineups(owner);
    expect(rows.map((row) => row.payload.kind)).toEqual([
      "lineupOrigin",
      "lineupOrigin",
      "lineupLanding",
      "lineupLink",
      "lineupLink",
    ]);
    const links = rows.filter((row) => row.payload.kind === "lineupLink");
    expect(links.map((row) => row.payload.data)).toEqual([
      expect.objectContaining({
        originId: "origin-a",
        landingId: "shared",
        name: "From heaven",
      }),
      expect.objectContaining({
        originId: "origin-b",
        landingId: "shared",
        name: "From mid",
      }),
    ]);
    const landings = rows.filter((row) => row.payload.kind === "lineupLanding");
    expect(landings).toHaveLength(1);

    const full = (await owner.query(getFullSnapshot, {
      strategyPublicId,
    })) as { lineups: LineupRow[] };
    expect(full.lineups.map((row) => row.publicId)).toEqual(
      fanIn.map((row) => row.key),
    );
  });

  test("a landing and a link may share an entity id", async () => {
    const { owner } = await createHarness();
    const rows = [
      origin("o"),
      landing("same-id"),
      link("same-id", "o", "same-id"),
    ];
    const results = await apply(
      owner,
      "owner-client",
      rows.map((row, index) => addOp(row, index)),
    );
    expect(results.map((result) => result.status)).toEqual([
      "applied",
      "applied",
      "applied",
    ]);
    expect((await pageLineups(owner)).map((row) => row.publicId)).toEqual([
      "lineupOrigin:o",
      "lineupLanding:same-id",
      "lineupLink:same-id",
    ]);
  });

  test("two users editing different links of one origin both land", async () => {
    const { owner, editor } = await createHarness();
    const rows = [
      origin("o"),
      landing("l1"),
      landing("l2"),
      link("k1", "o", "l1"),
      link("k2", "o", "l2"),
    ];
    await apply(
      owner,
      "owner-client",
      rows.map((row, index) => addOp(row, index)),
    );

    // Both edit from the same loaded revision (1) of their own link.
    const ownerResults = await apply(owner, "owner-client", [
      patchOp("owner-renames-k1", link("k1", "o", "l1", { name: "Owner" }), 1),
    ]);
    const editorResults = await apply(editor, "editor-client", [
      patchOp(
        "editor-notes-k2",
        link("k2", "o", "l2", { notes: "Editor notes" }),
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

    const after = byKey(await pageLineups(owner));
    expect(after.get("lineupLink:k1")?.payload.data).toMatchObject({
      name: "Owner",
      notes: "",
    });
    expect(after.get("lineupLink:k2")?.payload.data).toMatchObject({
      name: "",
      notes: "Editor notes",
    });
    // Neither edit touched the origin or the other link's revision.
    expect(after.get("lineupOrigin:o")?.revision).toBe(1);

    // The same link edited from a stale revision is a conflict, not a
    // silent overwrite.
    const stale = await apply(editor, "editor-client", [
      patchOp("editor-renames-k1", link("k1", "o", "l1", { name: "Stale" }), 1),
    ]);
    expect(stale[0]).toMatchObject({
      status: "rejected",
      reason: "revision_mismatch",
      current: { type: "lineup", revision: 2 },
    });
  });

  test("deleting one link leaves the shared landing and the other link", async () => {
    const { owner } = await createHarness();
    await apply(
      owner,
      "owner-client",
      fanIn.map((row, index) => addOp(row, index)),
    );
    const results = await apply(owner, "owner-client", [
      {
        opId: "delete-link-a",
        type: "lineup.delete",
        lineupPublicId: "lineupLink:link-a",
        pagePublicId,
        expectedLineupRevision: 1,
      },
      {
        opId: "delete-origin-a",
        type: "lineup.delete",
        lineupPublicId: "lineupOrigin:origin-a",
        pagePublicId,
        expectedLineupRevision: 1,
      },
    ]);
    expect(results.map((result) => result.status)).toEqual([
      "applied",
      "applied",
    ]);
    const live = (await pageLineups(owner))
      .filter((row) => !row.deleted)
      .map((row) => row.publicId);
    expect(live).toEqual([
      "lineupOrigin:origin-b",
      "lineupLanding:shared",
      "lineupLink:link-b",
    ]);
  });

  test("graph rows that could not be drawn are refused", async () => {
    const { owner } = await createHarness();
    const mismatchedKey = {
      ...addOp(link("k", "o", "l"), 0),
      lineupPublicId: "lineupLink:other",
    };
    const unqualifiedKey = { ...addOp(origin("o"), 0), lineupPublicId: "o" };
    const originWithoutAgent = {
      ...addOp(origin("o2"), 0),
      payload: { kind: "lineupOrigin", payloadVersion: 1, data: { id: "o2" } },
    };
    const linkWithoutLanding = {
      ...addOp(link("k2", "o", "l"), 0),
      payload: {
        kind: "lineupLink",
        payloadVersion: 1,
        data: { id: "k2", originId: "o" },
      },
    };
    const results = await apply(owner, "owner-client", [
      mismatchedKey,
      unqualifiedKey,
      originWithoutAgent,
      linkWithoutLanding,
    ]);
    for (const result of results) {
      expect(result).toMatchObject({
        status: "failed",
        code: "INVALID_LINEUP_PAYLOAD_DATA",
      });
    }
    expect(await pageLineups(owner)).toEqual([]);
  });

  test("a viewer cannot write lineup rows", async () => {
    const { owner, viewer } = await createHarness();
    await apply(owner, "owner-client", [addOp(origin("o"), 0)]);
    await expect(
      apply(viewer, "viewer-client", [addOp(landing("l"), 1)]),
    ).rejects.toThrow("Forbidden");
    await expect(
      apply(viewer, "viewer-client", [
        patchOp("viewer-moves-origin", origin("o", "jett"), 1),
      ]),
    ).rejects.toThrow("Forbidden");
    // Viewers still read them.
    expect((await pageLineups(viewer)).map((row) => row.publicId)).toEqual([
      "lineupOrigin:o",
    ]);
  });

  test("images on a link are referenced assets of the page", async () => {
    const { t, owner } = await createHarness();
    await t.run(async (ctx) => {
      const strategy = await ctx.db
        .query("strategies")
        .withIndex("by_publicId", (q) => q.eq("publicId", strategyPublicId))
        .first();
      const now = Date.now();
      await ctx.db.insert("imageAssets", {
        publicId: "link-image",
        provider: "r2",
        strategyId: strategy!._id,
        objectKey: "tests/link-image.png",
        uploadStatus: "active",
        fileExtension: ".png",
        createdAt: now,
        updatedAt: now,
      });
    });
    await apply(owner, "owner-client", [
      addOp(origin("o"), 0),
      addOp(landing("l"), 1),
      addOp(
        link("k", "o", "l", {
          images: [{ id: "link-image", fileExtension: ".png" }],
        }),
        2,
      ),
    ]);
    const snapshot = (await owner.query(getPageSnapshot, {
      strategyPublicId,
      pagePublicId,
    })) as { assets: Array<{ publicId: string }> };
    expect(snapshot.assets.map((asset) => asset.publicId)).toEqual([
      "link-image",
    ]);
  });
});

describe("lineup row keys belong to their strategy", () => {
  /** A legacy group as a client wrote it before the graph synced. */
  test("strategies uploaded from a local duplicate keep the same row keys", async () => {
    const { owner } = await createHarness();
    const copyId = "local-duplicate";
    const copyPage = "local-duplicate-page";
    await createCopy(owner, copyId, copyPage);
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
      expect(results.map((result) => result.status)).toEqual(
        fanIn.map(() => "applied"),
      );
    }
    // Editing one copy leaves the other untouched.
    await apply(
      owner,
      "edit-copy",
      [
        {
          ...patchOp(
            "rename-in-copy",
            link("link-a", "origin-a", "shared", { name: "Copy name" }),
            1,
          ),
          pagePublicId: copyPage,
        },
      ],
      copyId,
    );
    const original = byKey(await pageLineups(owner));
    const copy = byKey(await pageLineups(owner, copyId, copyPage));
    expect(original.get("lineupLink:link-a")?.payload.data.name).toBe(
      "From heaven",
    );
    expect(copy.get("lineupLink:link-a")?.payload.data.name).toBe("Copy name");
  });

  test("a lineup row is never moved to another page by a patch", async () => {
    const { owner } = await createHarness();
    const secondPage = "lineup-graph-page-2";
    await owner.mutation(addPage, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      strategyPublicId,
      expectedRevision: 0,
      pagePublicId: secondPage,
      name: "Page 2",
      sortIndex: 1,
      isAttack: false,
    });
    await apply(owner, "page-1-client", [addOp(link("k", "o", "l"), 0)]);

    // Another page wants the same key: the add is refused, and "Keep mine"
    // would turn it into a patch naming the other page.
    const clashing = link("k", "o2", "l2", { name: "Page 2 lineup" });
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
    expect(first.map((row) => row.publicId)).toEqual(["lineupLink:k"]);
    expect(first[0]!.payload.data).toMatchObject({ originId: "o" });
    expect(await pageLineups(owner, strategyPublicId, secondPage)).toEqual([]);
  });

  test("the same row added twice with a different order is one add", async () => {
    const { owner, editor } = await createHarness();
    const first = await apply(owner, "owner-client", [addOp(origin("o"), 3)]);
    const second = await apply(editor, "editor-client", [addOp(origin("o"), 7)]);
    expect(first[0]).toMatchObject({ status: "applied" });
    expect(second[0]).toMatchObject({ status: "noop" });
    const conflicting = await apply(editor, "editor-client", [
      { ...addOp(origin("o", "jett"), 7), opId: "different-content" },
    ]);
    expect(conflicting[0]).toMatchObject({
      status: "rejected",
      reason: "already_exists",
    });
  });
});

function deleteOp(opId: string, key: string, expectedLineupRevision: number) {
  return {
    opId,
    type: "lineup.delete",
    lineupPublicId: key,
    pagePublicId,
    expectedLineupRevision,
  };
}

describe("a link needs both of its ends", () => {
  test("a link placed from an origin a teammate deleted is refused", async () => {
    const { owner, editor } = await createHarness();
    await apply(
      owner,
      "owner-client",
      [origin("a"), landing("a"), link("a", "a", "a")].map((row, index) =>
        addOp(row, index),
      ),
    );
    // The editor deletes lineup "a" while the owner is placing a new
    // lineup from its origin.
    await apply(editor, "editor-client", [
      deleteOp("delete-link-a", "lineupLink:a", 1),
      deleteOp("delete-landing-a", "lineupLanding:a", 1),
      deleteOp("delete-origin-a", "lineupOrigin:a", 1),
    ]);

    // The owner's client still had origin "a" as its base, so it sends only
    // the new landing and link.
    const results = await applyChecked(owner, "owner-client", [
      addOp(landing("b"), 3),
      addOp(link("b", "a", "b"), 4),
    ]);
    expect(results[0]).toMatchObject({ status: "applied" });
    expect(results[1]).toMatchObject({
      status: "failed",
      code: "LINEUP_LINK_END_MISSING",
    });
    const rows = byKey(await pageLineups(owner));
    expect(rows.has("lineupLink:b")).toBe(false);
  });

  test("an older client's link a batch ahead of its origin still lands", async () => {
    const { owner } = await createHarness();
    // An outbox reloaded after a restart lists its rows by key (landing,
    // link, origin) and may cut the batch before the origin.
    const first = await apply(owner, "old-client", [
      addOp(landing("l"), 0),
      addOp(link("k", "o", "l"), 1),
    ]);
    const second = await apply(owner, "old-client", [addOp(origin("o"), 2)]);
    expect([...first, ...second].map((result) => result.status)).toEqual([
      "applied",
      "applied",
      "applied",
    ]);
    // The same batch from a current client is refused.
    const checked = await applyChecked(owner, "new-client", [
      addOp(link("k2", "o2", "l"), 3),
    ]);
    expect(checked[0]).toMatchObject({
      status: "failed",
      code: "LINEUP_LINK_END_MISSING",
    });
  });

  test("an origin restored earlier in the same batch lets the link land", async () => {
    const { owner, editor } = await createHarness();
    await apply(
      owner,
      "owner-client",
      [origin("a"), landing("a"), link("a", "a", "a")].map((row, index) =>
        addOp(row, index),
      ),
    );
    await apply(editor, "editor-client", [
      deleteOp("delete-link-a", "lineupLink:a", 1),
      deleteOp("delete-landing-a", "lineupLanding:a", 1),
      deleteOp("delete-origin-a", "lineupOrigin:a", 1),
    ]);

    const results = await applyChecked(owner, "owner-client", [
      {
        ...addOp(origin("a"), 0),
        opId: "restore-origin-a",
        expectedLineupRevision: 2,
      },
      addOp(landing("b"), 3),
      addOp(link("b", "a", "b"), 4),
    ]);
    expect(results.map((result) => result.status)).toEqual([
      "applied",
      "applied",
      "applied",
    ]);
    const live = (await pageLineups(owner))
      .filter((row) => !row.deleted)
      .map((row) => row.publicId);
    expect(live).toEqual([
      "lineupOrigin:a",
      "lineupLanding:b",
      "lineupLink:b",
    ]);
  });

  test("editing a link whose landing a teammate deleted is refused", async () => {
    const { owner, editor } = await createHarness();
    await apply(
      owner,
      "owner-client",
      [origin("o"), landing("l"), link("k", "o", "l")].map((row, index) =>
        addOp(row, index),
      ),
    );
    await apply(editor, "editor-client", [
      deleteOp("delete-landing", "lineupLanding:l", 1),
    ]);

    const results = await applyChecked(owner, "owner-client", [
      patchOp("rename-k", link("k", "o", "l", { name: "Renamed" }), 1),
    ]);
    expect(results[0]).toMatchObject({
      status: "failed",
      code: "LINEUP_LINK_END_MISSING",
    });
    const row = byKey(await pageLineups(owner)).get("lineupLink:k");
    expect(row).toMatchObject({ revision: 1 });
    expect(row!.payload.data).toMatchObject({ name: "" });
  });

  test("a link cannot use an end that lives on another page", async () => {
    const { owner } = await createHarness();
    const secondPage = "lineup-graph-page-2";
    await owner.mutation(addPage, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      strategyPublicId,
      expectedRevision: 0,
      pagePublicId: secondPage,
      name: "Page 2",
      sortIndex: 1,
      isAttack: false,
    });
    await apply(owner, "owner-client", [
      addOp(origin("o"), 0),
      addOp(landing("l"), 1),
    ]);

    const results = await applyChecked(owner, "owner-client", [
      addOp(link("k", "o", "l"), 0, secondPage),
    ]);
    expect(results[0]).toMatchObject({
      status: "failed",
      code: "LINEUP_LINK_END_MISSING",
    });
  });

  test("a link already stored without its origin still loads and deletes", async () => {
    const { t, owner } = await createHarness();
    // Written before the server checked link ends.
    await t.run(async (ctx) => {
      const strategy = await ctx.db
        .query("strategies")
        .withIndex("by_publicId", (q) => q.eq("publicId", strategyPublicId))
        .unique();
      const page = await ctx.db
        .query("pages")
        .withIndex("by_publicId", (q) => q.eq("publicId", pagePublicId))
        .unique();
      const orphan = link("orphan", "gone", "gone");
      const now = Date.now();
      await ctx.db.insert("lineups", {
        publicId: orphan.key,
        strategyId: strategy!._id,
        pageId: page!._id,
        payloadKind: orphan.payload.kind,
        payloadVersion: orphan.payload.payloadVersion,
        payload: orphan.payload,
        sortIndex: 0,
        revision: 1,
        deleted: false,
        createdAt: now,
        updatedAt: now,
      });
    });

    expect((await pageLineups(owner)).map((row) => row.publicId)).toEqual([
      "lineupLink:orphan",
    ]);
    const full = (await owner.query(getFullSnapshot, {
      strategyPublicId,
    })) as { lineups: LineupRow[] };
    expect(full.lineups.map((row) => row.publicId)).toEqual([
      "lineupLink:orphan",
    ]);
    const results = await applyChecked(owner, "owner-client", [
      deleteOp("delete-orphan", "lineupLink:orphan", 1),
    ]);
    expect(results[0]).toMatchObject({ status: "applied" });
  });
});

describe("an origin or landing a live link names is not deleted", () => {
  test("deleting an origin a teammate's new link uses is refused", async () => {
    const { owner, editor } = await createHarness();
    await apply(
      owner,
      "owner-client",
      [origin("a"), landing("a"), link("a", "a", "a")].map((row, index) =>
        addOp(row, index),
      ),
    );
    // The owner places a second lineup from origin "a", and it lands first.
    await applyChecked(owner, "owner-client", [
      addOp(landing("b"), 3),
      addOp(link("b", "a", "b"), 4),
    ]);

    // The editor never saw lineup "b" and deletes lineup "a", which on
    // their canvas takes origin "a" with it.
    const results = await applyChecked(editor, "editor-client", [
      deleteOp("delete-link-a", "lineupLink:a", 1),
      deleteOp("delete-landing-a", "lineupLanding:a", 1),
      deleteOp("delete-origin-a", "lineupOrigin:a", 1),
    ]);
    expect(results.map((result) => result.status)).toEqual([
      "applied",
      "applied",
      "failed",
    ]);
    expect(results[2]).toMatchObject({ code: "LINEUP_END_IN_USE" });

    const rows = byKey(await pageLineups(owner));
    expect(rows.get("lineupOrigin:a")).toMatchObject({
      deleted: false,
      revision: 1,
    });
    expect(rows.get("lineupLink:b")).toMatchObject({ deleted: false });
    expect(rows.get("lineupLink:a")).toMatchObject({ deleted: true });
  });

  test("deleting a landing a live link uses is refused", async () => {
    const { owner, editor } = await createHarness();
    await apply(
      owner,
      "owner-client",
      [origin("o"), landing("l"), link("k", "o", "l")].map((row, index) =>
        addOp(row, index),
      ),
    );
    const results = await applyChecked(editor, "editor-client", [
      deleteOp("delete-landing", "lineupLanding:l", 1),
    ]);
    expect(results[0]).toMatchObject({
      status: "failed",
      code: "LINEUP_END_IN_USE",
    });
    const rows = byKey(await pageLineups(owner));
    expect(rows.get("lineupLanding:l")).toMatchObject({ deleted: false });
  });

  test("a whole lineup deletes when its link goes first", async () => {
    const { owner } = await createHarness();
    await apply(
      owner,
      "owner-client",
      [origin("o"), landing("l"), link("k", "o", "l")].map((row, index) =>
        addOp(row, index),
      ),
    );
    const results = await applyChecked(owner, "owner-client", [
      deleteOp("delete-link", "lineupLink:k", 1),
      deleteOp("delete-origin", "lineupOrigin:o", 1),
      deleteOp("delete-landing", "lineupLanding:l", 1),
    ]);
    expect(results.map((result) => result.status)).toEqual([
      "applied",
      "applied",
      "applied",
    ]);
  });

  test("a link on another page does not hold an end", async () => {
    const { owner } = await createHarness();
    const secondPage = "lineup-graph-page-2";
    await owner.mutation(addPage, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      strategyPublicId,
      expectedRevision: 0,
      pagePublicId: secondPage,
      name: "Page 2",
      sortIndex: 1,
      isAttack: false,
    });
    // A link on page 2 names origin "o", which lives on page 1. Hydration
    // reads each page on its own, so that link is never drawn from it.
    await apply(owner, "owner-client", [
      addOp(origin("o"), 0),
      addOp(landing("l2"), 1, secondPage),
      addOp(link("k2", "o", "l2"), 2, secondPage),
    ]);
    const results = await applyChecked(owner, "owner-client", [
      deleteOp("delete-origin", "lineupOrigin:o", 1),
    ]);
    expect(results[0]).toMatchObject({ status: "applied" });
  });

  test("an older client's end delete still lands ahead of its link", async () => {
    const { owner, editor } = await createHarness();
    await apply(
      owner,
      "owner-client",
      [origin("o"), landing("l"), link("k", "o", "l")].map((row, index) =>
        addOp(row, index),
      ),
    );
    // An outbox reloaded after a restart lists its rows by key (landing,
    // link, origin); an older client does not reorder them.
    const unflagged = await apply(editor, "old-client", [
      deleteOp("delete-landing", "lineupLanding:l", 1),
      deleteOp("delete-link", "lineupLink:k", 1),
      deleteOp("delete-origin", "lineupOrigin:o", 1),
    ]);
    expect(unflagged.map((result) => result.status)).toEqual([
      "applied",
      "applied",
      "applied",
    ]);
  });

  test("a client that only checks link ends is not refused a delete", async () => {
    const { owner, editor } = await createHarness();
    await apply(
      owner,
      "owner-client",
      [origin("o"), landing("l"), link("k", "o", "l")].map((row, index) =>
        addOp(row, index),
      ),
    );
    // The web build that shipped checkLineupLinkEnds did not order its
    // deletes yet.
    const results = await apply(
      editor,
      "web-client",
      [deleteOp("delete-origin", "lineupOrigin:o", 1)],
      strategyPublicId,
      { checkLineupLinkEnds: true },
    );
    expect(results[0]).toMatchObject({ status: "applied" });
  });
});
