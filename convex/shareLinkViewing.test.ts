import { convexTest } from "convex-test";
import { makeFunctionReference } from "convex/server";
import { describe, expect, test } from "vitest";
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
const updateStrategy = makeFunctionReference<"mutation">("strategies:update");
const getStrategyShell = makeFunctionReference<"query">("strategy:getShell");
const getFullSnapshot = makeFunctionReference<"query">(
  "strategy:getFullSnapshot",
);
const getPageSnapshot = makeFunctionReference<"query">("page:getSnapshot");
const resolveShare = makeFunctionReference<"query">("shares:resolve");
const createShare = makeFunctionReference<"mutation">("shares:create");
const revokeShare = makeFunctionReference<"mutation">("shares:revoke");

const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };

function identity(subject: "owner" | "stranger") {
  return {
    issuer: "https://share-link-viewing.test",
    subject,
    tokenIdentifier: `share-link-viewing|${subject}`,
    name: subject,
  };
}

async function createHarness() {
  const t = convexTest(schema, modules);
  const owner = t.withIdentity(identity("owner"));
  const stranger = t.withIdentity(identity("stranger"));
  await owner.mutation(ensureCurrentUser, protocol);
  await stranger.mutation(ensureCurrentUser, protocol);
  return { t, owner, stranger };
}

async function seedStrategy(
  owner: ReturnType<ReturnType<typeof convexTest>["withIdentity"]>,
  strategyPublicId: string,
  pagePublicId: string,
  folderPublicId?: string,
) {
  await owner.mutation(createStrategy, {
    ...protocol,
    publicId: strategyPublicId,
    name: "Shared Strategy",
    mapData: "ascent",
    folderPublicId,
    initialPagePublicId: pagePublicId,
    initialPageName: "Page 1",
    initialPageIsAttack: true,
  });
}

describe("viewing through a share link without an account", () => {
  test("a live strategy link lets anyone holding it read, never write", async () => {
    const { t, owner, stranger } = await createHarness();
    const strategyPublicId = "linked-strategy";
    const pagePublicId = "linked-page";
    const shareToken = "linked-token";
    await seedStrategy(owner, strategyPublicId, pagePublicId);
    await seedStrategy(owner, "other-strategy", "other-page");
    await owner.mutation(createShare, {
      ...protocol,
      targetType: "strategy",
      targetPublicId: strategyPublicId,
      token: shareToken,
      role: "editor",
    });

    await expect(t.query(resolveShare, { token: shareToken })).resolves.toEqual(
      { targetType: "strategy", strategyPublicId, role: "editor" },
    );
    await expect(
      t.query(getStrategyShell, { strategyPublicId }),
    ).rejects.toThrow("Unauthenticated");
    // Even an editor link lets a holder who has not redeemed it only view.
    await expect(
      t.query(getStrategyShell, { strategyPublicId, shareToken }),
    ).resolves.toMatchObject({
      header: { publicId: strategyPublicId, role: "viewer" },
      pages: [{ publicId: pagePublicId }],
    });
    await expect(
      t.query(getFullSnapshot, { strategyPublicId, shareToken }),
    ).resolves.toMatchObject({ header: { role: "viewer" } });
    await expect(
      t.query(getPageSnapshot, { strategyPublicId, pagePublicId, shareToken }),
    ).resolves.toMatchObject({ page: { publicId: pagePublicId } });

    // The link opens its own strategy and nothing else.
    await expect(
      t.query(getStrategyShell, {
        strategyPublicId: "other-strategy",
        shareToken,
      }),
    ).rejects.toThrow("Unauthenticated");
    await expect(
      stranger.query(getStrategyShell, {
        strategyPublicId: "other-strategy",
        shareToken,
      }),
    ).rejects.toThrow("Forbidden");

    // A signed-in holder reads as a viewer; the owner keeps their own role.
    await expect(
      stranger.query(getStrategyShell, { strategyPublicId, shareToken }),
    ).resolves.toMatchObject({ header: { role: "viewer" } });
    await expect(
      owner.query(getStrategyShell, { strategyPublicId, shareToken }),
    ).resolves.toMatchObject({ header: { role: "owner" } });
    await expect(
      stranger.mutation(updateStrategy, {
        ...protocol,
        strategyPublicId,
        expectedRevision: 0,
        name: "A link holder must not write",
      }),
    ).rejects.toThrow("Forbidden");

    await owner.mutation(revokeShare, {
      ...protocol,
      targetType: "strategy",
      targetPublicId: strategyPublicId,
      token: shareToken,
    });
    await expect(
      t.query(resolveShare, { token: shareToken }),
    ).rejects.toThrow("Share link revoked");
    await expect(
      t.query(getStrategyShell, { strategyPublicId, shareToken }),
    ).rejects.toThrow("Share link revoked");
    await expect(
      stranger.query(getStrategyShell, { strategyPublicId, shareToken }),
    ).rejects.toThrow("Share link revoked");
  });

  test("a folder link names only its kind and opens nothing signed out", async () => {
    const { t, owner } = await createHarness();
    await owner.mutation(createFolder, {
      ...protocol,
      publicId: "linked-folder",
      name: "Linked folder",
    });
    await seedStrategy(owner, "foldered-strategy", "foldered-page", "linked-folder");
    await owner.mutation(createShare, {
      ...protocol,
      targetType: "folder",
      targetPublicId: "linked-folder",
      token: "folder-token",
      role: "viewer",
    });

    await expect(
      t.query(resolveShare, { token: "folder-token" }),
    ).resolves.toEqual({ targetType: "folder", role: "viewer" });
    await expect(
      t.query(getStrategyShell, {
        strategyPublicId: "foldered-strategy",
        shareToken: "folder-token",
      }),
    ).rejects.toThrow("Unauthenticated");
    await expect(
      t.query(resolveShare, { token: "no-such-token" }),
    ).rejects.toThrow("Share link not found");
  });
});
