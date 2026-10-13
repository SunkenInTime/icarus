import {
  convexTest,
  type TestConvexForDataModel,
  type TestConvexForDataModelAndIdentity,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { describe, expect, test } from "vitest";
import type { DataModel } from "./_generated/dataModel";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "./lib/cloudProtocol";
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
  currentHarness = t;
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

let currentHarness: TestConvexForDataModelAndIdentity<DataModel>;

async function rename(who: Harness, strategyPublicId: string) {
  const strategy = await currentHarness.run((ctx) =>
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

function members(
  who: Harness,
  targetPublicId: string,
  targetType: "strategy" | "folder" = "strategy",
) {
  return who.query(listMembers, { targetType, targetPublicId });
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
        inheritedFromFolder: null,
      },
      {
        displayName: "User C",
        role: "editor",
        shareLinkToken: "edit-link",
        inheritedFromFolder: null,
      },
    ]);
    await expect(members(c, "s1")).rejects.toThrow("Forbidden");
    await expect(members(b, "s1")).rejects.toThrow("Forbidden");
  });

  test("a role change reaches the person's next read and write", async () => {
    const { users } = await createHarness();
    const { a, b } = users;
    await seedStrategy(a, "s1");
    await share(a, "s1", "edit-link", "editor");
    await redeem(b, "edit-link");
    await expect(rename(b, "s1")).resolves.toMatchObject({ ok: true });

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
    await expect(rename(b, "s1")).rejects.toThrow("Forbidden");

    await a.mutation(setMemberRole, {
      ...protocol,
      targetType: "strategy",
      targetPublicId: "s1",
      memberId,
      role: "editor",
    });
    await expect(rename(b, "s1")).resolves.toMatchObject({ ok: true });
  });

  test("a removed person loses the strategy at once and can rejoin only through a live link", async () => {
    const { users } = await createHarness();
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
    await expect(rename(b, "s1")).rejects.toThrow("Forbidden");
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
    const { users } = await createHarness();
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

    await expect(rename(b, "s1")).resolves.toMatchObject({ ok: true });
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
      { displayName: "User C", role: "viewer", inheritedFromFolder: null },
      {
        displayName: "User B",
        role: "editor",
        inheritedFromFolder: { publicId: "team", name: "Team plans" },
      },
    ]);

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
});
