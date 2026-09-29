import {
  convexTest,
  type TestConvexForDataModel,
  type TestConvexForDataModelAndIdentity,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { describe, expect, test } from "vitest";
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
const createShare = makeFunctionReference<"mutation">("shares:create");
const redeemShare = makeFunctionReference<"mutation">("shares:redeem");
const listReferencedAssetIds = makeFunctionReference<"query">(
  "images:listReferencedAssetIds",
);

type Harness = TestConvexForDataModel<DataModel>;
type RootHarness = TestConvexForDataModelAndIdentity<DataModel>;

const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };
const strategyPublicId = "referenced-assets-strategy";
const pagePublicId = "referenced-assets-page";
// Every image the tests' content ever showed, and one it never did.
const asked = {
  strategyPublicId,
  assetPublicIds: ["removed", "shown", "shot", "never-placed"],
};

function identity(subject: string) {
  return {
    issuer: "https://referenced-assets.test",
    subject,
    tokenIdentifier: `referenced-assets|${subject}`,
    name: subject,
  };
}

function imagePayload(assetPublicId: string) {
  return {
    kind: "image" as const,
    payloadVersion: 1,
    data: { id: assetPublicId, elementType: "image" },
  };
}

async function user(t: RootHarness, subject: string): Promise<Harness> {
  const harness = t.withIdentity(identity(subject));
  await harness.mutation(ensureCurrentUser, protocol);
  return harness;
}

let opCounter = 0;

async function apply(owner: Harness, ops: Array<Record<string, unknown>>) {
  const result = (await owner.mutation(applyBatch, {
    ...protocol,
    strategyPublicId,
    clientId: "client",
    ops: ops.map((op) => ({ opId: `op-${++opCounter}`, ...op })),
  })) as { results: Array<{ status: string }> };
  expect(result.results.map((entry) => entry.status)).toEqual(
    ops.map(() => "applied"),
  );
}

/// A strategy whose page shows 'shown' as an image and 'shot' in a lineup,
/// and once showed 'removed'.
async function seed(t: RootHarness): Promise<Harness> {
  const owner = await user(t, "owner");
  await owner.mutation(createStrategy, {
    ...protocol,
    publicId: strategyPublicId,
    name: "Referenced assets",
    mapData: "ascent",
    initialPagePublicId: pagePublicId,
    initialPageName: "Page 1",
    initialPageIsAttack: true,
  });
  await apply(owner, [
    {
      type: "element.add",
      elementPublicId: "shown",
      pagePublicId,
      payload: imagePayload("shown"),
      sortIndex: 0,
    },
    {
      type: "element.add",
      elementPublicId: "removed",
      pagePublicId,
      payload: imagePayload("removed"),
      sortIndex: 1,
    },
    {
      type: "lineup.add",
      lineupPublicId: "lineupLink:k",
      pagePublicId,
      payload: {
        kind: "lineupLink" as const,
        payloadVersion: 1,
        data: {
          id: "k",
          originId: "o",
          landingId: "l",
          images: [{ id: "shot" }],
        },
      },
      sortIndex: 0,
    },
  ]);
  await apply(owner, [
    {
      type: "element.delete",
      elementPublicId: "removed",
      pagePublicId,
      expectedElementRevision: 1,
    },
  ]);
  return owner;
}

describe("images:listReferencedAssetIds", () => {
  test("answers which of the images asked about the strategy's content shows, deleted content left out", async () => {
    const t = convexTest(schema, modules);
    await t.run(markAssetReferencesReady);
    const owner = await seed(t);

    expect(
      await owner.query(listReferencedAssetIds, asked),
    ).toEqual(["shot", "shown"]);
  });

  test("reads a bounded number of rows: it answers at most 100 images at once", async () => {
    const t = convexTest(schema, modules);
    await t.run(markAssetReferencesReady);
    const owner = await seed(t);
    const many = Array.from({ length: 100 }, (_, index) => `image-${index}`);

    expect(
      await owner.query(listReferencedAssetIds, {
        strategyPublicId,
        assetPublicIds: [...many.slice(1), "shown"],
      }),
    ).toEqual(["shown"]);
    await expect(
      owner.query(listReferencedAssetIds, {
        strategyPublicId,
        assetPublicIds: [...many, "shown"],
      }),
    ).rejects.toThrow(/at most 100/);
  });

  test("is null until the reference backfill has finished", async () => {
    const t = convexTest(schema, modules);
    const owner = await seed(t);

    expect(
      await owner.query(listReferencedAssetIds, asked),
    ).toBeNull();
  });

  test("answers anyone who can view the strategy, and no one else", async () => {
    const t = convexTest(schema, modules);
    await t.run(markAssetReferencesReady);
    const owner = await seed(t);
    const viewer = await user(t, "viewer");
    await owner.mutation(createShare, {
      ...protocol,
      targetType: "strategy",
      targetPublicId: strategyPublicId,
      token: "viewer-token",
      role: "viewer",
    });
    await viewer.mutation(redeemShare, { ...protocol, token: "viewer-token" });
    const stranger = await user(t, "stranger");

    expect(
      await viewer.query(listReferencedAssetIds, asked),
    ).toEqual(["shot", "shown"]);
    await expect(
      stranger.query(listReferencedAssetIds, asked),
    ).rejects.toThrow();
  });
});
