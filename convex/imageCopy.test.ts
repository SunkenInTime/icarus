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
import { modules } from "./test.setup";

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createStrategy = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const deleteStrategy = makeFunctionReference<"mutation">("strategies:delete");
const addPage = makeFunctionReference<"mutation">("pages:add");
const applyBatch = makeFunctionReference<"mutation">("ops:applyBatch");
const purgeOldTombstones = makeFunctionReference<"mutation">(
  "maintenance:purgeOldTombstones",
);
const listImages = makeFunctionReference<"query">("images:listForStrategy");
const copyAsset = makeFunctionReference<"mutation">("images:copyAsset");
const createShare = makeFunctionReference<"mutation">("shares:create");
const redeemShare = makeFunctionReference<"mutation">("shares:redeem");

type Harness = TestConvexForDataModel<DataModel>;
type RootHarness = TestConvexForDataModelAndIdentity<DataModel>;

const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };
const strategyPublicId = "copy-strategy";
const firstPage = "copy-page-1";
const secondPage = "copy-page-2";
const original = "placed-image";
const copy = `placed-image~cp1~6f1c2d0e-3b4a-4c5d-8e9f-0a1b2c3d4e5f`;
const settings = { agentSize: 40, abilitySize: 30, useNeutralTeamColors: true };

function identity(subject: string) {
  return {
    issuer: "https://image-copy.test",
    subject,
    tokenIdentifier: `image-copy|${subject}`,
    name: `User ${subject}`,
  };
}

/// A two-page strategy whose first page shows a placed image, with the
/// image's upload [status] ("active" once its bytes landed).
async function createHarness(status: "active" | "pending" = "active"): Promise<{
  t: RootHarness;
  owner: Harness;
  other: Harness;
}> {
  const t = convexTest(schema, modules);
  await t.run(markAssetReferencesReady);
  const owner = t.withIdentity(identity("owner"));
  const other = t.withIdentity(identity("other"));
  await owner.mutation(ensureCurrentUser, protocol);
  await other.mutation(ensureCurrentUser, protocol);
  await owner.mutation(createStrategy, {
    ...protocol,
    publicId: strategyPublicId,
    name: "Bind B split",
    mapData: "bind",
    initialPagePublicId: firstPage,
    initialPageName: "Setup",
    initialPageIsAutoNamed: false,
    initialPageIsAttack: true,
    initialPageSettings: settings,
  });
  await owner.mutation(addPage, {
    ...protocol,
    strategyPublicId,
    pagePublicId: secondPage,
    name: "Hit",
    sortIndex: 1,
    isAttack: true,
    expectedRevision: 0,
  });
  await t.run(async (ctx) => {
    const strategy = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", strategyPublicId))
      .unique();
    const now = Date.now();
    await ctx.db.insert("imageAssets", {
      publicId: original,
      provider: "r2",
      strategyId: strategy!._id,
      uploadAttemptPublicId: "placed-image-attempt",
      objectKey: `strategies/${strategyPublicId}/${original}.png`,
      uploadStatus: status,
      fileExtension: ".png",
      mimeType: "image/png",
      width: 64,
      height: 32,
      byteSize: 100,
      ...(status === "active" ? { uploadedAt: now } : {}),
      createdAt: now,
      updatedAt: now,
    });
  });
  await addImage(owner, original, firstPage);
  return { t, owner, other };
}

async function addImage(user: Harness, id: string, pagePublicId: string) {
  await user.mutation(applyBatch, {
    ...protocol,
    strategyPublicId,
    clientId: `add-${id}`,
    ops: [
      {
        opId: `add-${id}`,
        type: "element.add",
        elementPublicId: id,
        pagePublicId,
        payload: {
          kind: "image",
          payloadVersion: 1,
          data: { id, elementType: "image", scale: 2 },
        },
        sortIndex: 1,
      },
    ],
  });
}

async function copyImage(user: Harness) {
  return await user.mutation(copyAsset, {
    ...protocol,
    strategyPublicId,
    sourceAssetPublicId: original,
    targetAssetPublicId: copy,
  });
}

type ImageRow = { publicId: string; uploadStatus: string; url: string | null };

async function images(user: Harness) {
  const rows = (await user.query(listImages, { strategyPublicId })) as ImageRow[];
  return Object.fromEntries(
    rows.map((row) => [row.publicId, [row.uploadStatus, row.url]]),
  );
}

async function rowsFor(t: RootHarness, publicId: string) {
  return await t.run(async (ctx) =>
    (await ctx.db.query("imageAssets").collect()).filter(
      (row) => row.publicId === publicId,
    ),
  );
}

const url = `https://media.copy.test/strategies/${strategyPublicId}/${original}.png`;

beforeAll(() => {
  process.env.R2_ACCOUNT_ID = "copy-account";
  process.env.R2_BUCKET = "copy-bucket";
  process.env.R2_ACCESS_KEY_ID = "copy-access-key";
  process.env.R2_SECRET_ACCESS_KEY = "copy-secret";
  process.env.R2_PUBLIC_BASE_URL = "https://media.copy.test";
  process.env.R2_S3_ENDPOINT = "https://copy.r2.test";
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe("images:copyAsset", () => {
  test("a copied image shows the original's picture under its own id", async () => {
    const { owner } = await createHarness();

    expect(await copyImage(owner)).toBe("copied");
    await addImage(owner, copy, secondPage);

    expect(await images(owner)).toEqual({
      [original]: ["active", url],
      [copy]: ["active", url],
    });
  });

  test("a copy whose content landed first takes over its placeholder", async () => {
    const { t, owner } = await createHarness();
    await addImage(owner, copy, secondPage);
    expect((await images(owner))[copy]).toEqual(["pending", null]);

    expect(await copyImage(owner)).toBe("copied");

    expect((await images(owner))[copy]).toEqual(["active", url]);
    expect((await rowsFor(t, copy)).map((row) => row.uploadStatus)).toEqual([
      "active",
    ]);
  });

  test("copying again changes nothing", async () => {
    const { t, owner } = await createHarness();
    await copyImage(owner);

    expect(await copyImage(owner)).toBe("copied");
    expect(await rowsFor(t, copy)).toHaveLength(1);
  });

  test("a copy replaces a failed upload under its id", async () => {
    const { t, owner } = await createHarness();
    await t.run(async (ctx) => {
      const strategy = await ctx.db
        .query("strategies")
        .withIndex("by_publicId", (q) => q.eq("publicId", strategyPublicId))
        .unique();
      const now = Date.now();
      await ctx.db.insert("imageAssets", {
        publicId: copy,
        provider: "r2",
        strategyId: strategy!._id,
        uploadAttemptPublicId: "failed-attempt",
        objectKey: `strategies/${strategyPublicId}/failed.png`,
        uploadStatus: "failed",
        fileExtension: ".png",
        mimeType: "image/png",
        createdAt: now,
        updatedAt: now,
      });
    });
    await addImage(owner, copy, secondPage);

    expect(await copyImage(owner)).toBe("copied");
    expect((await images(owner))[copy]).toEqual(["active", url]);
  });

  test("a copy nothing shows is removed a day later; one in use stays", async () => {
    vi.useFakeTimers();
    const fetchMock = vi.fn(async () => new Response(null, { status: 204 }));
    vi.stubGlobal("fetch", fetchMock);
    const { t, owner } = await createHarness();
    const unused = `placed-image~cp1~0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d`;
    await copyImage(owner);
    await addImage(owner, copy, secondPage);
    await owner.mutation(copyAsset, {
      ...protocol,
      strategyPublicId,
      sourceAssetPublicId: original,
      targetAssetPublicId: unused,
    });

    vi.setSystemTime(Date.now() + 25 * 60 * 60 * 1000);
    await t.finishAllScheduledFunctions(vi.runAllTimers);

    expect((await rowsFor(t, unused)).map((row) => row.uploadStatus)).toEqual(
      [],
    );
    // Its bytes are the original's, so they stay.
    expect(fetchMock).not.toHaveBeenCalled();
    expect(await images(owner)).toEqual({
      [original]: ["active", url],
      [copy]: ["active", url],
    });
  });

  test("an image still uploading has nothing to copy yet", async () => {
    const { t, owner } = await createHarness("pending");
    await addImage(owner, copy, secondPage);

    expect(await copyImage(owner)).toBe("uploading");
    // The copy's placeholder waits, as for any image on its way.
    expect((await rowsFor(t, copy)).map((row) => row.uploadStatus)).toEqual([
      "pending",
    ]);
  });

  test("an image the strategy cannot show is unavailable", async () => {
    const { owner } = await createHarness();

    expect(
      await owner.mutation(copyAsset, {
        ...protocol,
        strategyPublicId,
        sourceAssetPublicId: "missing-image",
        targetAssetPublicId: `missing-image~cp1~6f1c2d0e-3b4a-4c5d-8e9f-0a1b2c3d4e5f`,
      }),
    ).toBe("unavailable");
  });

  test("only an editor of the strategy can copy, and never onto itself", async () => {
    const { owner, other } = await createHarness();

    await expect(copyImage(other)).rejects.toThrow();
    // A collaborator who may only view cannot copy; an editor can.
    for (const role of ["viewer", "editor"] as const) {
      await owner.mutation(createShare, {
        ...protocol,
        targetType: "strategy",
        targetPublicId: strategyPublicId,
        token: `as-${role}`,
        role,
      });
    }
    await other.mutation(redeemShare, { ...protocol, token: "as-viewer" });
    await expect(copyImage(other)).rejects.toThrow();
    await other.mutation(redeemShare, { ...protocol, token: "as-editor" });
    expect(await copyImage(other)).toBe("copied");

    await expect(
      owner.mutation(copyAsset, {
        ...protocol,
        strategyPublicId,
        sourceAssetPublicId: original,
        targetAssetPublicId: original,
      }),
    ).rejects.toThrow();
  });

  test("deleting the original keeps the copy's bytes; deleting both frees them", async () => {
    vi.useFakeTimers();
    const fetchMock = vi.fn(
      async (_input: RequestInfo | URL, _init?: RequestInit) =>
        new Response(null, { status: 204 }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const { t, owner } = await createHarness();
    await copyImage(owner);
    await addImage(owner, copy, secondPage);

    await owner.mutation(applyBatch, {
      ...protocol,
      strategyPublicId,
      clientId: "remove-original",
      ops: [
        {
          opId: "remove-original",
          type: "element.delete",
          elementPublicId: original,
          pagePublicId: firstPage,
          expectedElementRevision: 1,
        },
      ],
    });
    vi.setSystemTime(Date.now() + 31 * 24 * 60 * 60 * 1000);
    await t.mutation(purgeOldTombstones, {});
    await t.finishAllScheduledFunctions(vi.runAllTimers);

    expect(fetchMock).not.toHaveBeenCalled();
    expect((await images(owner))[copy]).toEqual(["active", url]);

    const revision = await t.run(async (ctx) => {
      const strategy = await ctx.db
        .query("strategies")
        .withIndex("by_publicId", (q) => q.eq("publicId", strategyPublicId))
        .unique();
      return strategy!.revision;
    });
    await owner.mutation(deleteStrategy, {
      ...protocol,
      strategyPublicId,
      expectedRevision: revision,
    });
    await t.finishAllScheduledFunctions(vi.runAllTimers);

    expect(
      fetchMock.mock.calls.map((call) => new URL(String(call[0])).pathname),
    ).toEqual([`/copy-bucket/strategies/${strategyPublicId}/${original}.png`]);
  });
});
