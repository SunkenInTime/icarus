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
import { modules } from "./test.setup";
import { lineupsPayload } from "./testContent.helpers";

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createStrategy = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const applyBatch = makeFunctionReference<"mutation">("ops:applyBatch");
const getSnapshot = makeFunctionReference<"query">("page:getSnapshot");
const getFrame = makeFunctionReference<"query">("page:getFrame");
const getElementSlice = makeFunctionReference<"query">("page:getElementSlice");

type Harness = TestConvexForDataModel<DataModel>;
type RootHarness = TestConvexForDataModelAndIdentity<DataModel>;
type Row = Record<string, any>;

const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };
const strategy = "slice-strategy";
const pageA = "slice-page-a";
const pageB = "slice-page-b";

beforeAll(() => {
  process.env.R2_ACCOUNT_ID = "slice-account";
  process.env.R2_BUCKET = "slice-bucket";
  process.env.R2_ACCESS_KEY_ID = "slice-access-key";
  process.env.R2_SECRET_ACCESS_KEY = "slice-secret";
  process.env.R2_PUBLIC_BASE_URL = "https://media.slice.test";
  process.env.R2_S3_ENDPOINT = "https://slice.r2.test";
});

// Ids spread over the hexadecimal range, as UUIDs are, plus ids that sort
// outside it.
const ids = [
  "0a1-text",
  "3f2-agent",
  "7c3-image",
  "7c4-copy",
  // Exactly on a slice boundary: in the slice it starts, not the one before.
  "8",
  "9d5-ability",
  "b06-text",
  "c9a-copy",
  "e17-utility",
  "f28-agent",
  "gt-jett",
  "gt-jett~cp1~11111111-2222-3333-4444-555555555555",
];

async function seed(): Promise<{ t: RootHarness; owner: Harness }> {
  const t = convexTest(schema, modules);
  await t.run(markAssetReferencesReady);
  const owner = t.withIdentity({
    issuer: "https://slice.test",
    subject: "owner",
    tokenIdentifier: "slice|owner",
    name: "Owner",
  });
  await owner.mutation(ensureCurrentUser, protocol);
  await owner.mutation(createStrategy, {
    ...protocol,
    publicId: strategy,
    name: "Slices",
    mapData: "ascent",
    initialPagePublicId: pageA,
    initialPageName: "Page 1",
    initialPageIsAttack: true,
  });
  await send(owner, "page", [
    {
      opId: "add-page-b",
      type: "page.add",
      pagePublicId: pageB,
      payload: { name: "Page 2", isAttack: false },
      sortIndex: 1,
      expectedStrategyRevision: await strategyRevision(t),
    },
  ]);
  await t.run(async (ctx) => {
    const row = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", strategy))
      .unique();
    const now = Date.now();
    for (const publicId of ["7c3-image", "lineup-shot"]) {
      await ctx.db.insert("imageAssets", {
        publicId,
        provider: "r2",
        strategyId: row!._id,
        objectKey: `strategies/${strategy}/${publicId}.png`,
        uploadStatus: "active",
        fileExtension: ".png",
        mimeType: "image/png",
        width: 64,
        height: 32,
        byteSize: 100,
        uploadedAt: now,
        createdAt: now,
        updatedAt: now,
      });
    }
  });
  await send(owner, "seed", [
    ...ids.map((id, index) => add(id, index % 3)),
    {
      opId: "add-lineup",
      type: "lineup.add",
      lineupPublicId: "lineup-1",
      pagePublicId: pageA,
      payload: lineupsPayload("lineup-1", {
        origins: [{ id: "o1" }],
        landings: [{ id: "l1" }],
        links: [
          {
            id: "link-1",
            originId: "o1",
            landingId: "l1",
            images: [{ id: "lineup-shot", fileExtension: ".png" }],
          },
        ],
      }),
      sortIndex: 0,
    },
  ]);
  return { t, owner };
}

async function strategyRevision(t: RootHarness) {
  return await t.run(async (ctx) => {
    const row = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", strategy))
      .unique();
    return row!.revision;
  });
}

/// An element of a kind its id names, with sortIndex [sortIndex] so that
/// several share one.
function add(id: string, sortIndex: number, page = pageA) {
  const kind = id.includes("image") || id.includes("copy")
    ? "image"
    : id.includes("agent") || id.startsWith("gt-")
      ? "agent"
      : id.includes("ability")
        ? "ability"
        : id.includes("utility")
          ? "utility"
          : "text";
  const data: Record<string, unknown> = {
    id,
    position: { dx: 10, dy: 20 },
  };
  if (kind === "image") {
    data.scale = 1;
    // Copies show the original's picture: one beside it, one in another
    // slice.
    if (id.includes("copy")) data.assetId = "7c3-image";
  }
  if (kind === "agent") data.type = "jett";
  if (kind === "text") data.text = id;
  return {
    opId: `add-${id}-${page}`,
    type: "element.add",
    elementPublicId: id,
    pagePublicId: page,
    payload: { kind, payloadVersion: 1, data },
    sortIndex,
  };
}

async function send(owner: Harness, clientId: string, ops: unknown[]) {
  const { results } = (await owner.mutation(applyBatch, {
    ...protocol,
    strategyPublicId: strategy,
    clientId,
    ops,
    acceptsPictureIds: true,
  })) as { results: Row[] };
  for (const result of results) {
    expect(result.status, JSON.stringify(result)).toBe("applied");
  }
  return results;
}

const byPlace = (left: Row, right: Row) =>
  left.sortIndex - right.sortIndex ||
  left.publicId.localeCompare(right.publicId);

/// The page as the app puts it together from a frame and slices whose
/// ranges cover every id: elements and lineups in place order (ties by id,
/// as the offline copy orders them), each real asset once, then each alias
/// where no real asset holds its id.
function assemble(frame: Row, slices: Row[]) {
  const assets = new Map<string, Row>();
  for (const asset of [...frame.assets, ...slices.flatMap((s) => s.assets)]) {
    assets.set(asset.publicId, asset);
  }
  for (const alias of slices.flatMap((s) => s.aliases)) {
    if (!assets.has(alias.publicId)) assets.set(alias.publicId, alias);
  }
  return {
    page: frame.page,
    content: frame.content,
    elements: slices.flatMap((s) => s.elements).sort(byPlace),
    lineups: [...frame.lineups].sort(byPlace),
    assets: [...assets.values()].sort((a, b) =>
      a.publicId.localeCompare(b.publicId),
    ),
  };
}

/// The whole-page answer in the same order.
function inPlaceOrder(snapshot: Row) {
  return {
    ...snapshot,
    elements: [...snapshot.elements].sort(byPlace),
    lineups: [...snapshot.lineups].sort(byPlace),
  };
}

async function readInParts(owner: Harness, page: string, bounds: string[]) {
  const args = { ...protocol, strategyPublicId: strategy, pagePublicId: page };
  const frame = (await owner.query(getFrame, args)) as Row;
  const slices = await Promise.all(
    bounds.map(
      (from, index) =>
        owner.query(getElementSlice, {
          ...args,
          fromPublicId: from,
          ...(index + 1 < bounds.length ? { toPublicId: bounds[index + 1] } : {}),
        }) as Promise<Row>,
    ),
  );
  return { frame, slices };
}

async function expectSameAsWholePage(owner: Harness, page: string) {
  const whole = (await owner.query(getSnapshot, {
    ...protocol,
    strategyPublicId: strategy,
    pagePublicId: page,
  })) as Row;
  for (const bounds of [[""], ["", "8"], ["", "4", "8", "c"], ["", ..."123456789abcdef"]]) {
    const { frame, slices } = await readInParts(owner, page, bounds);
    expect(assemble(frame, slices), `slices from ${bounds.join(",")}`).toEqual(
      inPlaceOrder(whole),
    );
  }
}

describe("a page read as a frame and element slices", () => {
  test("holds what the whole-page read holds", async () => {
    const { owner } = await seed();
    await expectSameAsWholePage(owner, pageA);
    await expectSameAsWholePage(owner, pageB);
  });

  test("still does after moves, deletes and restores", async () => {
    const { owner } = await seed();
    await send(owner, "edits", [
      // Moved to the other page.
      {
        opId: "move-b06",
        type: "element.patch",
        elementPublicId: "b06-text",
        pagePublicId: pageB,
        expectedElementRevision: 1,
      },
      // Deleted: the tombstone stays in both reads.
      {
        opId: "delete-e17",
        type: "element.delete",
        elementPublicId: "e17-utility",
        pagePublicId: pageA,
        expectedElementRevision: 1,
      },
    ]);
    await expectSameAsWholePage(owner, pageA);
    await expectSameAsWholePage(owner, pageB);

    // Restored, onto the other page (an undo carries the tombstone's
    // revision).
    await send(owner, "restore", [
      { ...add("e17-utility", 4, pageB), expectedElementRevision: 2 },
    ]);
    await expectSameAsWholePage(owner, pageA);
    await expectSameAsWholePage(owner, pageB);
  });

  test("a slice holds only the ids in its range", async () => {
    const { owner } = await seed();
    const { slices } = await readInParts(owner, pageA, ["", "8", "g"]);
    expect(slices.map((s) => s.elements.map((e: Row) => e.publicId).sort()))
      .toEqual([
        ["0a1-text", "3f2-agent", "7c3-image", "7c4-copy"],
        ["8", "9d5-ability", "b06-text", "c9a-copy", "e17-utility", "f28-agent"],
        ["gt-jett", "gt-jett~cp1~11111111-2222-3333-4444-555555555555"],
      ]);
  });
});
