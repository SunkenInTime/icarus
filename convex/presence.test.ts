import { convexTest } from "convex-test";
import { makeFunctionReference, type UserIdentity } from "convex/server";
import type { JSONValue } from "convex/values";
import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { verifyPass } from "../presence/src/pass";
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
const issueRoomPass = makeFunctionReference<"mutation">(
  "presence:issueRoomPass",
);

const SECRET = "presence-test-secret";
const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };

function identity(
  subject: string,
  claims: Record<string, JSONValue> = {},
): Partial<UserIdentity> {
  return {
    issuer: "https://presence.test",
    subject,
    tokenIdentifier: `presence|${subject}`,
    name: `User ${subject}`,
    ...claims,
  };
}

async function harness() {
  const t = convexTest(schema, modules);
  const owner = t.withIdentity(
    // What Convex actually hands over for a Supabase Discord sign-in: nested
    // claims flattened into dotted keys.
    identity("owner", {
      "user_metadata.full_name": "ana",
      "user_metadata.avatar_url": "https://cdn.discordapp.com/avatars/1/a.png",
      "user_metadata.custom_claims.global_name": "Ana",
    }),
  );
  const viewer = t.withIdentity(identity("viewer"));
  const stranger = t.withIdentity(identity("stranger"));
  for (const user of [owner, viewer, stranger]) {
    await user.mutation(ensureCurrentUser, protocol);
  }
  await owner.mutation(createStrategy, {
    ...protocol,
    publicId: "strat-1",
    name: "Split B exec",
    mapData: "split",
    initialPagePublicId: "page-1",
    initialPageName: "Page 1",
    initialPageIsAttack: true,
  });
  await owner.mutation(createShare, {
    ...protocol,
    targetType: "strategy",
    targetPublicId: "strat-1",
    token: "viewer-token",
    role: "viewer",
  });
  await viewer.mutation(redeemShare, { ...protocol, token: "viewer-token" });
  return { owner, viewer, stranger };
}

describe("presence:issueRoomPass", () => {
  beforeEach(() => {
    process.env.PRESENCE_URL = "https://presence.test/";
    process.env.PRESENCE_PASS_SECRET = SECRET;
  });
  afterEach(() => {
    delete process.env.PRESENCE_URL;
    delete process.env.PRESENCE_PASS_SECRET;
  });

  test("signs a pass the Worker accepts, with the Discord profile", async () => {
    const { owner } = await harness();
    const issued = await owner.mutation(issueRoomPass, {
      ...protocol,
      strategyPublicId: "strat-1",
    });
    expect(issued.url).toBe("wss://presence.test/v1/rooms/strat-1");
    const claims = await verifyPass(issued.pass, SECRET, Date.now());
    expect(claims).toMatchObject({
      room: "strat-1",
      name: "Ana",
      avatar: "https://cdn.discordapp.com/avatars/1/a.png",
      role: "owner",
      exp: issued.expiresAt,
    });
    expect(claims!.uid).toMatch(/^[0-9a-f]{24}$/);
  });

  test("gives a viewer a viewer pass and the same uid every time", async () => {
    const { viewer } = await harness();
    const args = { ...protocol, strategyPublicId: "strat-1" };
    const first = await verifyPass(
      (await viewer.mutation(issueRoomPass, args)).pass,
      SECRET,
      Date.now(),
    );
    const second = await verifyPass(
      (await viewer.mutation(issueRoomPass, args)).pass,
      SECRET,
      Date.now(),
    );
    expect(first).toMatchObject({ role: "viewer", name: "User viewer" });
    expect(second!.uid).toBe(first!.uid);
  });

  test("reads the Discord profile however the claims are nested", async () => {
    const t = convexTest(schema, modules);
    const shapes: Record<string, JSONValue>[] = [
      { "user_metadata.full_name": "bo_b", "user_metadata.avatar_url": "https://cdn.discordapp.com/avatars/2/b.png" },
      { "user_metadata.custom_claims": { global_name: "Bo" }, "user_metadata.avatar_url": "https://cdn.discordapp.com/avatars/2/b.png" },
      { user_metadata: { custom_claims: { global_name: "Bo" }, avatar_url: "https://cdn.discordapp.com/avatars/2/b.png" } },
    ];
    const names: string[] = [];
    for (const [index, claims] of shapes.entries()) {
      const user = t.withIdentity(identity(`shape-${index}`, claims));
      await user.mutation(ensureCurrentUser, protocol);
      await user.mutation(createStrategy, {
        ...protocol,
        publicId: `strat-shape-${index}`,
        name: "Mine",
        mapData: "bind",
        initialPagePublicId: `page-shape-${index}`,
        initialPageName: "Page 1",
        initialPageIsAttack: true,
      });
      const issued = await user.mutation(issueRoomPass, {
        ...protocol,
        strategyPublicId: `strat-shape-${index}`,
      });
      const claimsOut = await verifyPass(issued.pass, SECRET, Date.now());
      expect(claimsOut!.avatar).toBe("https://cdn.discordapp.com/avatars/2/b.png");
      names.push(claimsOut!.name);
    }
    expect(names).toEqual(["bo_b", "Bo", "Bo"]);
  });

  test("signs only a Discord avatar; any other address, which every peer's app would fetch, goes as none", async () => {
    const t = convexTest(schema, modules);
    // What Supabase writes for a Discord sign-in, with and without a
    // picture of one's own.
    const discord = [
      "https://cdn.discordapp.com/avatars/80351110224678912/a_1269e74af4df7417b13759eae50c83dc.gif",
      "https://cdn.discordapp.com/embed/avatars/3.png",
    ];
    // user_metadata can be edited by its user, so it can carry anything.
    const other = [
      "http://127.0.0.1:8080/router/reboot",
      "https://tracker.example/pixel.png",
      "http://cdn.discordapp.com/avatars/1/a.png",
      "https://cdn.discordapp.com.tracker.example/avatars/1/a.png",
      "https://someone@cdn.discordapp.com/avatars/1/a.png",
      "https://cdn.discordapp.com:8443/avatars/1/a.png",
      "https://cdn.discordapp.com/attachments/1/2/a.png",
      "https://cdn.discordapp.com/avatars/../attachments/1/2/a.png",
      "not a url",
    ];
    const signed: (string | null)[] = [];
    for (const [index, avatar] of [...discord, ...other].entries()) {
      const user = t.withIdentity(
        identity(`avatar-${index}`, { "user_metadata.avatar_url": avatar }),
      );
      await user.mutation(ensureCurrentUser, protocol);
      await user.mutation(createStrategy, {
        ...protocol,
        publicId: `strat-avatar-${index}`,
        name: "Mine",
        mapData: "bind",
        initialPagePublicId: `page-avatar-${index}`,
        initialPageName: "Page 1",
        initialPageIsAttack: true,
      });
      const issued = await user.mutation(issueRoomPass, {
        ...protocol,
        strategyPublicId: `strat-avatar-${index}`,
      });
      signed.push((await verifyPass(issued.pass, SECRET, Date.now()))!.avatar);
    }
    expect(signed).toEqual([...discord, ...other.map(() => null)]);
  });

  test("a pass carries no stored avatar off Discord either", async () => {
    const { viewer } = await harness();
    // A row written before avatars were checked.
    await viewer.run(async (ctx) => {
      const row = await ctx.db
        .query("users")
        .withIndex("by_externalId", (q) => q.eq("externalId", "presence|viewer"))
        .unique();
      await ctx.db.patch(row!._id, { avatarUrl: "https://tracker.example/v.png" });
    });
    const issued = await viewer.mutation(issueRoomPass, {
      ...protocol,
      strategyPublicId: "strat-1",
    });
    expect((await verifyPass(issued.pass, SECRET, Date.now()))!.avatar).toBeNull();
  });

  test("names an email sign-in by its address, never the placeholder", async () => {
    const t = convexTest(schema, modules);
    const emailUser = t.withIdentity({
      issuer: "https://presence.test",
      subject: "email-user",
      tokenIdentifier: "presence|email-user",
      email: "ana.lyst@example.com",
    });
    await emailUser.mutation(ensureCurrentUser, protocol);
    await emailUser.mutation(createStrategy, {
      ...protocol,
      publicId: "strat-email",
      name: "Mine",
      mapData: "bind",
      initialPagePublicId: "page-email",
      initialPageName: "Page 1",
      initialPageIsAttack: true,
    });
    const issued = await emailUser.mutation(issueRoomPass, {
      ...protocol,
      strategyPublicId: "strat-email",
    });
    const claims = await verifyPass(issued.pass, SECRET, Date.now());
    expect(claims!.name).toBe("ana.lyst");
  });

  test("refuses someone without access", async () => {
    const { stranger } = await harness();
    await expect(
      stranger.mutation(issueRoomPass, {
        ...protocol,
        strategyPublicId: "strat-1",
      }),
    ).rejects.toThrow("Forbidden");
  });

  test("returns null when the deployment has no presence service", async () => {
    const { owner } = await harness();
    delete process.env.PRESENCE_URL;
    await expect(
      owner.mutation(issueRoomPass, {
        ...protocol,
        strategyPublicId: "strat-1",
      }),
    ).resolves.toBeNull();
  });
});
