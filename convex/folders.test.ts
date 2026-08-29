import {
  convexTest,
  type TestConvexForDataModel,
  type TestConvexForDataModelAndIdentity,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { expect, test } from "vitest";
import type { DataModel } from "./_generated/dataModel";
import schema from "./schema";
import { modules } from "./test.setup";

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createFolder = makeFunctionReference<"mutation">("folders:create");
const moveFolder = makeFunctionReference<"mutation">("folders:move");

const identity = {
  issuer: "https://folders.test",
  subject: "owner",
  tokenIdentifier: "folders|owner",
  name: "Folder Owner",
};

type Harness = TestConvexForDataModel<DataModel>;
type RootHarness = TestConvexForDataModelAndIdentity<DataModel>;

async function createHarness(): Promise<{
  t: RootHarness;
  owner: Harness;
}> {
  const t = convexTest(schema, modules);
  const owner = t.withIdentity(identity);
  await owner.mutation(ensureCurrentUser, {});
  return { t, owner };
}

async function seedFolder(
  owner: Harness,
  publicId: string,
  parentFolderPublicId?: string,
) {
  await owner.mutation(createFolder, {
    publicId,
    name: publicId,
    parentFolderPublicId,
  });
}

async function parentPublicId(t: RootHarness, publicId: string) {
  return await t.run(async (ctx) => {
    const folder = await ctx.db
      .query("folders")
      .withIndex("by_publicId", (q) => q.eq("publicId", publicId))
      .unique();
    if (folder === null) {
      throw new Error(`Missing folder ${publicId}`);
    }
    if (folder.parentFolderId === undefined) {
      return null;
    }
    return (await ctx.db.get(folder.parentFolderId))?.publicId ?? null;
  });
}

test("folder move rejects self-parent without changing the folder", async () => {
  const { t, owner } = await createHarness();
  await seedFolder(owner, "root");

  await expect(
    owner.mutation(moveFolder, {
      folderPublicId: "root",
      parentFolderPublicId: "root",
    }),
  ).rejects.toThrow("Folder move would create a cycle");

  await expect(parentPublicId(t, "root")).resolves.toBeNull();
});

test("folder move rejects a descendant parent without changing the tree", async () => {
  const { t, owner } = await createHarness();
  await seedFolder(owner, "root");
  await seedFolder(owner, "child", "root");
  await seedFolder(owner, "grandchild", "child");

  await expect(
    owner.mutation(moveFolder, {
      folderPublicId: "root",
      parentFolderPublicId: "grandchild",
    }),
  ).rejects.toThrow("Folder move would create a cycle");

  await expect(parentPublicId(t, "root")).resolves.toBeNull();
  await expect(parentPublicId(t, "child")).resolves.toBe("root");
  await expect(parentPublicId(t, "grandchild")).resolves.toBe("child");
});
