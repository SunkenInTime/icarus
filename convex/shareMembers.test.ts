import {
  convexTest,
  type TestConvexForDataModel,
  type TestConvexForDataModelAndIdentity,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { describe, expect, test, vi } from "vitest";
import type { DataModel } from "./_generated/dataModel";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "./lib/cloudProtocol";
import type { Id } from "./_generated/dataModel";
import {
  LINK_JOIN_COUNT_CAP,
  LINK_MEMBER_REMOVAL_BATCH,
  MEMBER_PAGE_SIZE,
} from "./shares";
import schema from "./schema";
import { modules } from "./test.setup";

const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createFolder = makeFunctionReference<"mutation">("folders:create");
const createStrategy = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const listSharedWithMe = makeFunctionReference<"query">(
  "strategies:listSharedWithMe",
);
const getShell = makeFunctionReference<"query">("strategy:getShell");
const updateStrategy = makeFunctionReference<"mutation">("strategies:update");
const createShare = makeFunctionReference<"mutation">("shares:create");
const redeemShare = makeFunctionReference<"mutation">("shares:redeem");
const revokeShare = makeFunctionReference<"mutation">("shares:revoke");
const listMembers = makeFunctionReference<"query">("shares:listMembers");
const setMemberRole = makeFunctionReference<"mutation">("shares:setMemberRole");
const removeMember = makeFunctionReference<"mutation">("shares:removeMember");
const leave = makeFunctionReference<"mutation">("shares:leave");
const preview = makeFunctionReference<"query">("shares:preview");
const listFolderAccess = makeFunctionReference<"query">("shares:listFolderAccess");
const listLinkJoins = makeFunctionReference<"query">("shares:listLinkJoins");
const applyBatch = makeFunctionReference<"mutation">("ops:applyBatch");

type Harness = TestConvexForDataModel<DataModel>;
type Who = "a" | "b" | "c" | "d";

function identity(subject: Who) {
  return {
    issuer: "https://share-members.test",
    subject,
    tokenIdentifier: `share-members|${subject}`,
    name: `User ${subject.toUpperCase()}`,
  };
}

async function createHarness(): Promise<{
  t: TestConvexForDataModelAndIdentity<DataModel>;
  users: Record<Who, Harness>;
}> {
  const t = convexTest(schema, modules);
  const users = {
    a: t.withIdentity(identity("a")),
    b: t.withIdentity(identity("b")),
    c: t.withIdentity(identity("c")),
    d: t.withIdentity(identity("d")),
  };
  for (const user of Object.values(users)) {
    await user.mutation(ensureCurrentUser, protocol);
  }
  return { t, users };
}

async function seedStrategy(
  owner: Harness,
  publicId: string,
  folderPublicId?: string,
) {
  await owner.mutation(createStrategy, {
    ...protocol,
    publicId,
    name: `Strategy ${publicId}`,
    mapData: "ascent",
    folderPublicId,
    initialPagePublicId: `${publicId}-page`,
    initialPageName: "Page 1",
    initialPageIsAttack: true,
  });
}

async function share(
  owner: Harness,
  targetPublicId: string,
  token: string,
  role: "viewer" | "editor",
  targetType: "strategy" | "folder" = "strategy",
) {
  await owner.mutation(createShare, {
    ...protocol,
    targetType,
    targetPublicId,
    token,
    role,
  });
}

function redeem(who: Harness, token: string) {
  return who.mutation(redeemShare, { ...protocol, token });
}

function shell(who: Harness, strategyPublicId: string) {
  return who.query(getShell, { ...protocol, strategyPublicId });
}

async function rename(
  t: TestConvexForDataModelAndIdentity<DataModel>,
  who: Harness,
  strategyPublicId: string,
) {
  const strategy = await t.run((ctx) =>
    ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", strategyPublicId))
      .first(),
  );
  return who.mutation(updateStrategy, {
    ...protocol,
    strategyPublicId,
    expectedRevision: strategy!.revision,
    name: `Renamed ${strategy!.revision}`,
  });
}

/** The first page of people, which in these tests is everyone. */
async function members(
  who: Harness,
  targetPublicId: string,
  targetType: "strategy" | "folder" = "strategy",
) {
  const page = await who.query(listMembers, { targetType, targetPublicId });
  return page.members;
}

async function memberIdOf(
  owner: Harness,
  targetPublicId: string,
  displayName: string,
  targetType: "strategy" | "folder" = "strategy",
): Promise<string> {
  const list = (await members(owner, targetPublicId, targetType)) as {
    memberId: string;
    displayName: string | null;
  }[];
  const member = list.find((entry) => entry.displayName === displayName);
  if (member === undefined) {
    throw new Error(`${displayName} is not a member of ${targetPublicId}`);
  }
  return member.memberId;
}

describe("share members", () => {
  test("only the owner sees who joined, and through which link", async () => {
    const { users } = await createHarness();
    const { a, b, c } = users;
    await seedStrategy(a, "s1");
    await share(a, "s1", "view-link", "viewer");
    await share(a, "s1", "edit-link", "editor");
    await redeem(b, "view-link");
    await redeem(c, "edit-link");

    await expect(members(a, "s1")).resolves.toMatchObject([
      {
        displayName: "User B",
        role: "viewer",
        shareLinkToken: "view-link",
      },
      {
        displayName: "User C",
        role: "editor",
        shareLinkToken: "edit-link",
      },
    ]);
    await expect(members(c, "s1")).rejects.toThrow("Forbidden");
    await expect(members(b, "s1")).rejects.toThrow("Forbidden");
  });

  test("a role change reaches the person's next read and write", async () => {
    const { t, users } = await createHarness();
    const { a, b } = users;
    await seedStrategy(a, "s1");
    await share(a, "s1", "edit-link", "editor");
    await redeem(b, "edit-link");
    await expect(rename(t, b, "s1")).resolves.toMatchObject({ ok: true });

    const memberId = await memberIdOf(a, "s1", "User B");
    await a.mutation(setMemberRole, {
      ...protocol,
      targetType: "strategy",
      targetPublicId: "s1",
      memberId,
      role: "viewer",
    });

    await expect(shell(b, "s1")).resolves.toMatchObject({
      header: { role: "viewer" },
    });
    await expect(rename(t, b, "s1")).rejects.toThrow("Forbidden");

    await a.mutation(setMemberRole, {
      ...protocol,
      targetType: "strategy",
      targetPublicId: "s1",
      memberId,
      role: "editor",
    });
    await expect(rename(t, b, "s1")).resolves.toMatchObject({ ok: true });
  });

  test("a removed person loses the strategy at once and can rejoin only through a live link", async () => {
    const { t, users } = await createHarness();
    const { a, b } = users;
    await seedStrategy(a, "s1");
    await share(a, "s1", "edit-link", "editor");
    await redeem(b, "edit-link");
    await expect(b.query(listSharedWithMe, {})).resolves.toHaveLength(1);

    await a.mutation(removeMember, {
      ...protocol,
      targetType: "strategy",
      targetPublicId: "s1",
      memberId: await memberIdOf(a, "s1", "User B"),
    });

    await expect(shell(b, "s1")).rejects.toThrow("Forbidden");
    await expect(rename(t, b, "s1")).rejects.toThrow("Forbidden");
    await expect(
      b.mutation(applyBatch, {
        ...protocol,
        strategyPublicId: "s1",
        clientId: "b-client",
        ops: [],
      }),
    ).rejects.toThrow("Forbidden");
    await expect(b.query(listSharedWithMe, {})).resolves.toEqual([]);
    await expect(members(a, "s1")).resolves.toEqual([]);

    // The link still works until the owner disables it.
    await redeem(b, "edit-link");
    await expect(shell(b, "s1")).resolves.toMatchObject({
      header: { role: "editor" },
    });
  });

  test("an owner can only manage memberships of what they own", async () => {
    const { users } = await createHarness();
    const { a, b, c } = users;
    await seedStrategy(a, "victim");
    await seedStrategy(c, "attacker");
    await share(a, "victim", "edit-link", "editor");
    await redeem(b, "edit-link");
    const memberId = await memberIdOf(a, "victim", "User B");

    // C owns a strategy, but B's membership belongs to A's.
    await expect(
      c.mutation(removeMember, {
        ...protocol,
        targetType: "strategy",
        targetPublicId: "attacker",
        memberId,
      }),
    ).rejects.toThrow("Member not found");
    await expect(
      c.mutation(setMemberRole, {
        ...protocol,
        targetType: "strategy",
        targetPublicId: "victim",
        memberId,
        role: "viewer",
      }),
    ).rejects.toThrow("Forbidden");
    // An editor is not an owner.
    await expect(
      b.mutation(removeMember, {
        ...protocol,
        targetType: "strategy",
        targetPublicId: "victim",
        memberId,
      }),
    ).rejects.toThrow("Forbidden");
    await expect(
      a.mutation(removeMember, {
        ...protocol,
        targetType: "strategy",
        targetPublicId: "victim",
        memberId: "not-an-id",
      }),
    ).rejects.toThrow("Member not found");
    await expect(shell(b, "victim")).resolves.toMatchObject({
      header: { role: "editor" },
    });
  });

  test("disabling a link can remove exactly the people who joined through it", async () => {
    const { users } = await createHarness();
    const { a, b, c, d } = users;
    await seedStrategy(a, "s1");
    await share(a, "s1", "edit-link", "editor");
    await share(a, "s1", "view-link", "viewer");
    await redeem(b, "edit-link");
    await redeem(c, "view-link");
    // D joined to view, then took the edit link: the edit link gave D's role.
    await redeem(d, "view-link");
    await redeem(d, "edit-link");

    await a.mutation(revokeShare, {
      ...protocol,
      targetType: "strategy",
      targetPublicId: "s1",
      token: "edit-link",
      removeMembers: true,
    });

    await expect(shell(b, "s1")).rejects.toThrow("Forbidden");
    await expect(shell(d, "s1")).rejects.toThrow("Forbidden");
    await expect(shell(c, "s1")).resolves.toMatchObject({
      header: { role: "viewer" },
    });
    await expect(redeem(b, "edit-link")).rejects.toThrow("Share link revoked");
  });

  test("disabling a link without removal keeps everyone who joined", async () => {
    const { t, users } = await createHarness();
    const { a, b } = users;
    await seedStrategy(a, "s1");
    await share(a, "s1", "edit-link", "editor");
    await redeem(b, "edit-link");

    // What clients from before removal send.
    await a.mutation(revokeShare, {
      ...protocol,
      targetType: "strategy",
      targetPublicId: "s1",
      token: "edit-link",
    });

    await expect(rename(t, b, "s1")).resolves.toMatchObject({ ok: true });
  });

  test("people who joined before links were recorded are never removed with a link", async () => {
    const { t, users } = await createHarness();
    const { a, b } = users;
    await seedStrategy(a, "s1");
    await share(a, "s1", "edit-link", "editor");
    await redeem(b, "edit-link");
    // A membership written before shareLinkId existed.
    await t.run(async (ctx) => {
      const row = await ctx.db.query("strategyCollaborators").first();
      await ctx.db.patch(row!._id, { shareLinkId: undefined });
    });

    await expect(members(a, "s1")).resolves.toMatchObject([
      { displayName: "User B", shareLinkToken: null },
    ]);
    await a.mutation(revokeShare, {
      ...protocol,
      targetType: "strategy",
      targetPublicId: "s1",
      token: "edit-link",
      removeMembers: true,
    });
    await expect(shell(b, "s1")).resolves.toMatchObject({
      header: { role: "editor" },
    });
  });

  test("a folder's people show on the strategies inside it, managed from the folder", async () => {
    const { users } = await createHarness();
    const { a, b, c } = users;
    await a.mutation(createFolder, {
      ...protocol,
      publicId: "team",
      name: "Team plans",
    });
    await seedStrategy(a, "inside", "team");
    await share(a, "team", "folder-link", "editor", "folder");
    await share(a, "inside", "strategy-link", "viewer");
    await redeem(b, "folder-link");
    await redeem(c, "strategy-link");

    await expect(members(a, "inside")).resolves.toMatchObject([
      { displayName: "User C", role: "viewer" },
    ]);
    await expect(
      a.query(listFolderAccess, { targetType: "strategy", targetPublicId: "inside" }),
    ).resolves.toEqual([{ publicId: "team", name: "Team plans" }]);

    const folderMemberId = await memberIdOf(a, "team", "User B", "folder");
    await expect(
      a.mutation(removeMember, {
        ...protocol,
        targetType: "strategy",
        targetPublicId: "inside",
        memberId: folderMemberId,
      }),
    ).rejects.toThrow("Member not found");

    await a.mutation(removeMember, {
      ...protocol,
      targetType: "folder",
      targetPublicId: "team",
      memberId: folderMemberId,
    });
    await expect(shell(b, "inside")).rejects.toThrow("Forbidden");
  });

  test("nested folders pass access down, and direct access outlives a folder's", async () => {
    const { users } = await createHarness();
    const { a, b, c } = users;
    await a.mutation(createFolder, { ...protocol, publicId: "outer", name: "Outer" });
    await a.mutation(createFolder, {
      ...protocol,
      publicId: "inner",
      name: "Inner",
      parentFolderPublicId: "outer",
    });
    await seedStrategy(a, "deep", "inner");
    await share(a, "outer", "outer-link", "editor", "folder");
    await share(a, "deep", "deep-link", "viewer");
    await redeem(b, "outer-link");
    await redeem(c, "outer-link");
    // C also holds the strategy directly.
    await redeem(c, "deep-link");

    await expect(members(a, "deep")).resolves.toMatchObject([
      { displayName: "User C", role: "viewer" },
    ]);
    // "Inner" is shared with no one; "Outer" is.
    await expect(
      a.query(listFolderAccess, { targetType: "strategy", targetPublicId: "deep" }),
    ).resolves.toEqual([{ publicId: "outer", name: "Outer" }]);

    // Demoting at the folder reaches the strategy two levels down.
    await a.mutation(setMemberRole, {
      ...protocol,
      targetType: "folder",
      targetPublicId: "outer",
      memberId: await memberIdOf(a, "outer", "User B", "folder"),
      role: "viewer",
    });
    await expect(shell(b, "deep")).resolves.toMatchObject({
      header: { role: "viewer" },
    });

    // Leaving the folder ends B's access; C's direct access survives C
    // being removed from the folder.
    await b.mutation(leave, {
      ...protocol,
      targetType: "folder",
      targetPublicId: "outer",
    });
    await expect(shell(b, "deep")).rejects.toThrow("Forbidden");
    await a.mutation(removeMember, {
      ...protocol,
      targetType: "folder",
      targetPublicId: "outer",
      memberId: await memberIdOf(a, "outer", "User C", "folder"),
    });
    await expect(shell(c, "deep")).resolves.toMatchObject({
      header: { role: "viewer" },
    });
  });

  test("a collaborator can leave; an owner cannot", async () => {
    const { users } = await createHarness();
    const { a, b } = users;
    await seedStrategy(a, "s1");
    await share(a, "s1", "view-link", "viewer");
    await redeem(b, "view-link");

    await b.mutation(leave, {
      ...protocol,
      targetType: "strategy",
      targetPublicId: "s1",
    });
    await expect(shell(b, "s1")).rejects.toThrow("Forbidden");
    await expect(b.query(listSharedWithMe, {})).resolves.toEqual([]);
    // Leaving twice is harmless.
    await b.mutation(leave, {
      ...protocol,
      targetType: "strategy",
      targetPublicId: "s1",
    });

    await expect(
      a.mutation(leave, {
        ...protocol,
        targetType: "strategy",
        targetPublicId: "s1",
      }),
    ).rejects.toThrow("An owner cannot leave");
  });

  test("a preview names what a link opens without joining it", async () => {
    const { users } = await createHarness();
    const { a, b } = users;
    await seedStrategy(a, "s1");
    await share(a, "s1", "view-link", "viewer");

    await expect(b.query(preview, { token: "view-link" })).resolves.toEqual({
      targetType: "strategy",
      publicId: "s1",
      name: "Strategy s1",
      linkRole: "viewer",
      myRole: null,
    });
    await expect(shell(b, "s1")).rejects.toThrow("Forbidden");
    await expect(a.query(preview, { token: "view-link" })).resolves.toMatchObject({
      myRole: "owner",
    });

    await redeem(b, "view-link");
    await expect(b.query(preview, { token: "view-link" })).resolves.toMatchObject({
      myRole: "viewer",
    });

    await a.mutation(revokeShare, {
      ...protocol,
      targetType: "strategy",
      targetPublicId: "s1",
      token: "view-link",
    });
    await expect(b.query(preview, { token: "view-link" })).rejects.toThrow(
      "Share link revoked",
    );
  });

  describe("at a link's scale", () => {
    /** Lets [count] people into strategy [publicId] through link [token]. */
    async function letIn(
      t: TestConvexForDataModelAndIdentity<DataModel>,
      publicId: string,
      token: string,
      count: number,
    ) {
      await t.run(async (ctx) => {
        const strategy = await ctx.db
          .query("strategies")
          .withIndex("by_publicId", (q) => q.eq("publicId", publicId))
          .first();
        const link = await ctx.db
          .query("shareLinks")
          .withIndex("by_token", (q) => q.eq("token", token))
          .first();
        for (let i = 0; i < count; i++) {
          const userId: Id<"users"> = await ctx.db.insert("users", {
            externalId: `crowd-${token}-${i}`,
            displayName: `Crowd ${i}`,
            createdAt: i,
            updatedAt: i,
          });
          await ctx.db.insert("strategyCollaborators", {
            strategyId: strategy!._id,
            userId,
            role: "viewer",
            shareLinkId: link!._id,
            createdAt: i,
            updatedAt: i,
          });
        }
      });
    }

    async function joinedThrough(
      t: TestConvexForDataModelAndIdentity<DataModel>,
      token: string,
    ) {
      return await t.run(async (ctx) => {
        const link = await ctx.db
          .query("shareLinks")
          .withIndex("by_token", (q) => q.eq("token", token))
          .first();
        return (
          await ctx.db
            .query("strategyCollaborators")
            .withIndex("by_shareLinkId", (q) => q.eq("shareLinkId", link!._id))
            .collect()
        ).length;
      });
    }

    test("people come a page at a time, each once", async () => {
      const { t, users } = await createHarness();
      const { a } = users;
      await seedStrategy(a, "s1");
      await share(a, "s1", "crowd-link", "viewer");
      const total = MEMBER_PAGE_SIZE * 2 + 7;
      await letIn(t, "s1", "crowd-link", total);

      const seen = new Set<string>();
      let cursor: string | undefined;
      let pages = 0;
      for (;;) {
        const page = await a.query(listMembers, {
          targetType: "strategy",
          targetPublicId: "s1",
          cursor,
        });
        pages += 1;
        for (const member of page.members) seen.add(member.memberId);
        if (pages === 1) {
          // Someone already listed leaves between pages; no one shifts past
          // the cursor.
          const first = page.members[0]!.memberId as Id<"strategyCollaborators">;
          await t.run(async (ctx) => ctx.db.delete(first));
        }
        if (page.nextCursor === null) break;
        expect(page.members).toHaveLength(MEMBER_PAGE_SIZE);
        cursor = page.nextCursor;
      }
      expect(pages).toBe(3);
      expect(seen.size).toBe(total);
    });

    test("a link's joiners are counted up to a cap, with a few names", async () => {
      const { t, users } = await createHarness();
      const { a } = users;
      await seedStrategy(a, "s1");
      await share(a, "s1", "crowd-link", "viewer");
      await share(a, "s1", "quiet-link", "viewer");
      await letIn(t, "s1", "crowd-link", LINK_JOIN_COUNT_CAP + 3);

      const joins = (await a.query(listLinkJoins, {
        targetType: "strategy",
        targetPublicId: "s1",
      })) as { token: string; joined: number; more: boolean; names: string[] }[];
      const byToken = Object.fromEntries(joins.map((j) => [j.token, j]));
      expect(byToken["crowd-link"]).toMatchObject({
        joined: LINK_JOIN_COUNT_CAP,
        more: true,
      });
      expect(byToken["crowd-link"]!.names).toHaveLength(5);
      expect(byToken["quiet-link"]).toEqual({
        token: "quiet-link",
        joined: 0,
        more: false,
        names: [],
      });
    });

    test("disabling a widely joined link removes everyone, a batch at a time", async () => {
      vi.useFakeTimers();
      try {
        const { t, users } = await createHarness();
        const { a, b } = users;
        await seedStrategy(a, "s1");
        await share(a, "s1", "crowd-link", "viewer");
        await share(a, "s1", "other-link", "viewer");
        await letIn(t, "s1", "crowd-link", LINK_MEMBER_REMOVAL_BATCH * 2 + 13);
        await redeem(b, "other-link");

        await a.mutation(revokeShare, {
          ...protocol,
          targetType: "strategy",
          targetPublicId: "s1",
          token: "crowd-link",
          removeMembers: true,
        });
        // The link stops at once; the first batch went with it.
        expect(await joinedThrough(t, "crowd-link")).toBe(
          LINK_MEMBER_REMOVAL_BATCH + 13,
        );

        await t.finishAllScheduledFunctions(vi.runAllTimers);
        expect(await joinedThrough(t, "crowd-link")).toBe(0);
        // Someone who came through another link stays.
        await expect(shell(b, "s1")).resolves.toMatchObject({
          header: { role: "viewer" },
        });
      } finally {
        vi.useRealTimers();
      }
    });
  });
});
