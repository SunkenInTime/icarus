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

  test("legacy lineup group rows stay readable and writable beside graph rows", async () => {
    const { owner } = await createHarness();
    const group = {
      kind: "lineupGroup" as const,
      payloadVersion: 1,
      data: {
        id: "group",
        agent: { type: "sova", lineUpID: "group" },
        items: [{ id: "item", ability: { lineUpID: "group" }, images: [] }],
      },
    };
    const results = await apply(owner, "old-client", [
      {
        opId: "old-client-adds-group",
        type: "lineup.add",
        lineupPublicId: "group",
        pagePublicId,
        payload: group,
        sortIndex: 0,
      },
      addOp(origin("o"), 1),
    ]);
    expect(results.map((result) => result.status)).toEqual([
      "applied",
      "applied",
    ]);
    const rows = await pageLineups(owner);
    expect(rows.map((row) => [row.publicId, row.payload.kind])).toEqual([
      ["group", "lineupGroup"],
      ["lineupOrigin:o", "lineupOrigin"],
    ]);

    const emptyGroup = await apply(owner, "old-client", [
      {
        opId: "old-client-adds-empty-group",
        type: "lineup.add",
        lineupPublicId: "empty",
        pagePublicId,
        payload: { ...group, data: { ...group.data, items: [] } },
        sortIndex: 2,
      },
    ]);
    expect(emptyGroup[0]).toMatchObject({
      status: "failed",
      code: "INVALID_LINEUP_PAYLOAD_DATA",
    });
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
  function legacyGroup(groupId: string, itemId: string) {
    return {
      kind: "lineupGroup" as const,
      payloadVersion: 1,
      data: {
        id: groupId,
        agent: { id: `agent-${groupId}`, type: "sova", lineUpID: groupId },
        items: [
          {
            id: itemId,
            ability: { id: `ability-${itemId}`, lineUpID: groupId },
            youtubeLink: "",
            notes: `notes ${groupId}`,
            images: [],
          },
        ],
      },
    };
  }

  /** The ops a new client sends to convert [groupId] (see cloud_lineup_rows). */
  function conversion(groupId: string, itemId: string, page: string) {
    return [
      addOp(origin(groupId), 10, page),
      addOp(landing(itemId), 11, page),
      addOp(
        link(itemId, groupId, itemId, { notes: `notes ${groupId}` }),
        12,
        page,
      ),
    ];
  }

  test("a strategy copied before the graph and its original both convert", async () => {
    const { owner } = await createHarness();
    const copyId = "copied-strategy";
    const copyPage = "copied-page";
    await createCopy(owner, copyId, copyPage);
    // The old client-side copy gave the group a fresh id and kept item ids.
    for (const [strategy, page, groupId] of [
      [strategyPublicId, pagePublicId, "group-original"],
      [copyId, copyPage, "group-copy"],
    ] as const) {
      const added = await apply(
        owner,
        "old-client",
        [
          {
            opId: `old-add-${groupId}`,
            type: "lineup.add",
            lineupPublicId: groupId,
            pagePublicId: page,
            payload: legacyGroup(groupId, "shared-item"),
            sortIndex: 0,
          },
        ],
        strategy,
      );
      expect(added[0]).toMatchObject({ status: "applied" });
    }

    // Each strategy converts: graph rows first, then the group delete.
    for (const [strategy, page, groupId] of [
      [strategyPublicId, pagePublicId, "group-original"],
      [copyId, copyPage, "group-copy"],
    ] as const) {
      const results = await apply(
        owner,
        `new-client-${groupId}`,
        [
          ...conversion(groupId, "shared-item", page),
          {
            opId: `delete-${groupId}`,
            type: "lineup.delete",
            lineupPublicId: groupId,
            pagePublicId: page,
            expectedLineupRevision: 1,
          },
        ],
        strategy,
      );
      expect(results.map((result) => result.status)).toEqual([
        "applied",
        "applied",
        "applied",
        "applied",
      ]);
    }

    for (const [strategy, page, groupId] of [
      [strategyPublicId, pagePublicId, "group-original"],
      [copyId, copyPage, "group-copy"],
    ] as const) {
      const live = (await pageLineups(owner, strategy, page)).filter(
        (row) => !row.deleted,
      );
      expect(live.map((row) => row.publicId)).toEqual([
        `lineupOrigin:${groupId}`,
        "lineupLanding:shared-item",
        "lineupLink:shared-item",
      ]);
      expect(live[2]!.payload.data).toMatchObject({
        originId: groupId,
        landingId: "shared-item",
        notes: `notes ${groupId}`,
      });
    }
  });

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
