import { convexTest } from "convex-test";
import { makeFunctionReference } from "convex/server";
import { expect, test } from "vitest";
import { markAssetReferencesReady } from "./lib/assetReferences";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "./lib/cloudProtocol";
import schema from "./schema";
import { modules } from "./test.setup";

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createFolder = makeFunctionReference<"mutation">("folders:create");
const createStrategy = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const moveStrategy = makeFunctionReference<"mutation">("strategies:move");
const listInventory = makeFunctionReference<"query">(
  "strategies:listInventory",
);

const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };

function identity(subject: string) {
  return {
    issuer: "https://inventory.test",
    subject,
    tokenIdentifier: `inventory|${subject}`,
    name: `User ${subject}`,
  };
}

test("the inventory places every folder and listed strategy of the caller", async () => {
  const t = convexTest(schema, modules);
  await t.run(markAssetReferencesReady);
  const owner = t.withIdentity(identity("owner"));
  const other = t.withIdentity(identity("other"));
  await owner.mutation(ensureCurrentUser, protocol);
  await other.mutation(ensureCurrentUser, protocol);

  const create = async (
    who: typeof owner,
    publicId: string,
    extra: { folderPublicId?: string; unfinishedMove?: boolean } = {},
  ) =>
    who.mutation(createStrategy, {
      ...protocol,
      publicId,
      name: publicId,
      mapData: "ascent",
      initialPagePublicId: `${publicId}-page`,
      initialPageName: "Page 1",
      initialPageIsAttack: true,
      ...extra,
    });

  await owner.mutation(createFolder, {
    ...protocol,
    publicId: "plays",
    name: "Plays",
  });
  await owner.mutation(createFolder, {
    ...protocol,
    publicId: "retakes",
    name: "Retakes",
    parentFolderPublicId: "plays",
  });
  await create(owner, "root");
  await create(owner, "nested", { folderPublicId: "retakes" });
  await create(owner, "moving", { unfinishedMove: true });
  await create(other, "theirs");

  const byId = <T extends { publicId: string }>(rows: T[]) =>
    [...rows].sort((a, b) => a.publicId.localeCompare(b.publicId));
  const inventory = (await owner.query(listInventory, {})) as {
    folders: Array<{ publicId: string; parentFolderPublicId: string | null }>;
    strategies: Array<{ publicId: string; folderPublicId: string | null }>;
  };
  expect(byId(inventory.folders)).toEqual([
    { publicId: "plays", parentFolderPublicId: null },
    { publicId: "retakes", parentFolderPublicId: "plays" },
  ]);
  expect(byId(inventory.strategies)).toEqual([
    { publicId: "nested", folderPublicId: "retakes" },
    { publicId: "root", folderPublicId: null },
  ]);

  // A strategy moved to another folder is placed there.
  await owner.mutation(moveStrategy, {
    ...protocol,
    strategyPublicId: "root",
    expectedRevision: 0,
    folderPublicId: "plays",
  });
  const moved = (await owner.query(listInventory, {})) as {
    strategies: Array<{ publicId: string; folderPublicId: string | null }>;
  };
  expect(moved.strategies.find((s) => s.publicId === "root")).toEqual({
    publicId: "root",
    folderPublicId: "plays",
  });
});
