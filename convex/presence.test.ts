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
  metadata?: Record<string, JSONValue>,
): Partial<UserIdentity> {
  return {
    issuer: "https://presence.test",
    subject,
    tokenIdentifier: `presence|${subject}`,
    name: `User ${subject}`,
    ...(metadata === undefined ? {} : { user_metadata: metadata }),
  };
}

async function harness() {
  const t = convexTest(schema, modules);
  const owner = t.withIdentity(
    identity("owner", {
      full_name: "ana",
      avatar_url: "https://cdn.discordapp.com/avatars/1/a.png",
      custom_claims: { global_name: "Ana" },
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
