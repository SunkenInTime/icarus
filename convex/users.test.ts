import { convexTest } from "convex-test";
import { makeFunctionReference } from "convex/server";
import { describe, expect, test } from "vitest";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "./lib/cloudProtocol";
import schema from "./schema";
import { modules } from "./test.setup";

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const me = makeFunctionReference<"query">("users:me");
const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };

const base = { issuer: "https://users.test" };

describe("users:ensureCurrentUser", () => {
  test("stores the Discord profile Convex hands over as flattened claims", async () => {
    const t = convexTest(schema, modules);
    const discord = t.withIdentity({
      ...base,
      subject: "discord",
      tokenIdentifier: "users|discord",
      email: "ana@example.com",
      "user_metadata.full_name": "ana_lyst",
      "user_metadata.custom_claims.global_name": "Ana",
      "user_metadata.avatar_url": "https://cdn.discordapp.com/avatars/1/a.png",
    });
    await discord.mutation(ensureCurrentUser, protocol);
    expect(await discord.query(me, {})).toMatchObject({
      displayName: "Ana",
      avatarUrl: "https://cdn.discordapp.com/avatars/1/a.png",
    });
  });

  test("refreshes a stored placeholder on the next sign-in", async () => {
    const t = convexTest(schema, modules);
    const claims = { ...base, subject: "later", tokenIdentifier: "users|later" };
    await t.withIdentity(claims).mutation(ensureCurrentUser, protocol);
    expect(await t.withIdentity(claims).query(me, {})).toMatchObject({
      displayName: "Discord user",
      avatarUrl: null,
    });

    const signedInAgain = t.withIdentity({
      ...claims,
      "user_metadata.full_name": "later_player",
    });
    await signedInAgain.mutation(ensureCurrentUser, protocol);
    expect(await signedInAgain.query(me, {})).toMatchObject({
      displayName: "later_player",
    });
  });

  test("names an email sign-in by its address", async () => {
    const t = convexTest(schema, modules);
    const email = t.withIdentity({
      ...base,
      subject: "email",
      tokenIdentifier: "users|email",
      email: "sam.smokes@example.com",
    });
    await email.mutation(ensureCurrentUser, protocol);
    expect(await email.query(me, {})).toMatchObject({
      displayName: "sam.smokes",
    });
  });
});
