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

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createStrategy = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const applyBatch = makeFunctionReference<"mutation">("ops:applyBatch");
const getPageSnapshot = makeFunctionReference<"query">("page:getSnapshot");
const getFullSnapshot = makeFunctionReference<"query">(
  "strategy:getFullSnapshot",
);

type Harness = TestConvexForDataModel<DataModel>;
type RootHarness = TestConvexForDataModelAndIdentity<DataModel>;
type Row = Record<string, any>;

const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };
const strategy = "picture-strategy";
const page = "picture-page";
const pictureUrl = `https://media.picture.test/strategies/${strategy}/original.png`;

beforeAll(() => {
  process.env.R2_ACCOUNT_ID = "picture-account";
  process.env.R2_BUCKET = "picture-bucket";
  process.env.R2_ACCESS_KEY_ID = "picture-access-key";
  process.env.R2_SECRET_ACCESS_KEY = "picture-secret";
  process.env.R2_PUBLIC_BASE_URL = "https://media.picture.test";
  process.env.R2_S3_ENDPOINT = "https://picture.r2.test";
});

/// A strategy with an uploaded image, "original", and a copy of it, "copy",
/// that shows the original's picture.
async function seed(): Promise<{ t: RootHarness; owner: Harness }> {
  const t = convexTest(schema, modules);
  await t.run(markAssetReferencesReady);
  const owner = t.withIdentity({
    issuer: "https://picture.test",
    subject: "owner",
    tokenIdentifier: "picture|owner",
    name: "Owner",
  });
  await owner.mutation(ensureCurrentUser, protocol);
  await owner.mutation(createStrategy, {
    ...protocol,
    publicId: strategy,
    name: "Pictures",
    mapData: "ascent",
    initialPagePublicId: page,
    initialPageName: "Page 1",
    initialPageIsAttack: true,
  });
  await t.run(async (ctx) => {
    const row = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", strategy))
      .unique();
    const now = Date.now();
    await ctx.db.insert("imageAssets", {
      publicId: "original",
      provider: "r2",
      strategyId: row!._id,
      objectKey: `strategies/${strategy}/original.png`,
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
  });
  await send(owner, "seed", [
    addImage("add-original", { id: "original", scale: 1 }),
    addImage("add-copy", { id: "copy", assetId: "original", scale: 1 }),
  ]);
  return { t, owner };
}

function addImage(opId: string, data: Record<string, unknown>) {
  return {
    opId,
    type: "element.add",
    elementPublicId: data.id,
    pagePublicId: page,
    payload: { kind: "image", payloadVersion: 1, data },
    sortIndex: 0,
  };
}

async function send(owner: Harness, clientId: string, ops: unknown[]) {
  const { results } = (await owner.mutation(applyBatch, {
    ...protocol,
    strategyPublicId: strategy,
    clientId,
    ops,
  })) as { results: Row[] };
  return results;
}

async function copyRow(t: RootHarness) {
  return await t.run(async (ctx) =>
    (await ctx.db.query("elements").collect()).find(
      (row) => row.publicId === "copy",
    ),
  );
}

describe("an image showing another image's picture", () => {
  test("shows the picture, under its own id too for builds that look it up there", async () => {
    const { owner } = await seed();

    const pageSnapshot = (await owner.query(getPageSnapshot, {
      ...protocol,
      strategyPublicId: strategy,
      pagePublicId: page,
    })) as { assets: Row[] };
    const full = (await owner.query(getFullSnapshot, {
      ...protocol,
      strategyPublicId: strategy,
    })) as { assets: Row[] };

    for (const assets of [pageSnapshot.assets, full.assets]) {
      expect(assets.map((asset) => [asset.publicId, asset.url])).toEqual([
        ["copy", pictureUrl],
        ["original", pictureUrl],
      ]);
    }
  });

  test("keeps the picture referenced after the original is deleted", async () => {
    const { t, owner } = await seed();
    await send(owner, "delete", [
      {
        opId: "delete-original",
        type: "element.delete",
        elementPublicId: "original",
        pagePublicId: page,
        expectedElementRevision: 1,
      },
    ]);

    const references = await t.run(async (ctx) => {
      const copy = (await ctx.db.query("elements").collect()).find(
        (row) => row.publicId === "copy",
      )!;
      return (await ctx.db.query("assetReferences").collect())
        .filter((ref) => ref.elementId === copy._id)
        .map((ref) => [ref.assetPublicId, ref.deleted]);
    });
    expect(references).toEqual([["original", false]]);
    const pageSnapshot = (await owner.query(getPageSnapshot, {
      ...protocol,
      strategyPublicId: strategy,
      pagePublicId: page,
    })) as { assets: Row[] };
    expect(pageSnapshot.assets.map((asset) => asset.publicId)).toEqual([
      "copy",
      "original",
    ]);
  });

  test("keeps its picture when an older build writes it whole without it", async () => {
    const { t, owner } = await seed();

    // An older build moves the copy, sending the payload it knows.
    const [moved] = await send(owner, "old-build", [
      {
        opId: "move-copy",
        type: "element.patch",
        elementPublicId: "copy",
        pagePublicId: page,
        payload: {
          kind: "image",
          payloadVersion: 1,
          data: { id: "copy", scale: 2 },
        },
        expectedElementRevision: 1,
      },
    ]);

    expect(moved).toMatchObject({ status: "applied" });
    expect((await copyRow(t))!.payload.data).toEqual({
      id: "copy",
      assetId: "original",
      scale: 2,
    });
  });

  test("keeps its picture when an older build restores it without it", async () => {
    const { t, owner } = await seed();
    await send(owner, "delete", [
      {
        opId: "delete-copy",
        type: "element.delete",
        elementPublicId: "copy",
        pagePublicId: page,
        expectedElementRevision: 1,
      },
    ]);

    // Undo on an older build adds the copy back as it knows it.
    const [restored] = await send(owner, "old-build", [
      {
        ...addImage("restore-copy", { id: "copy", scale: 1 }),
        expectedElementRevision: 2,
      },
    ]);

    expect(restored).toMatchObject({ status: "applied" });
    const copy = (await copyRow(t))!;
    expect(copy.deleted).toBe(false);
    expect(copy.payload.data.assetId).toBe("original");
  });
});
