// A room pass is Convex's word that a signed-in user may open one strategy's
// room until `exp`. Convex signs it (convex/lib/presencePass.ts, same format)
// with the secret both sides share; this Worker only verifies.
//
// Format: "v1.<base64url(JSON claims)>.<base64url(HMAC-SHA256)>", where the
// MAC covers "v1.<claims>".

export type PassRole = "owner" | "editor" | "viewer";

export interface PassClaims {
  /** Strategy public id; one room per strategy. */
  room: string;
  /** Opaque, stable per user. Two tabs of one user share it. */
  uid: string;
  name: string;
  avatar: string | null;
  role: PassRole;
  /** Expiry, epoch milliseconds. */
  exp: number;
}

const PREFIX = "v1";
const encoder = new TextEncoder();

export async function signPass(
  claims: PassClaims,
  secret: string,
): Promise<string> {
  const body = `${PREFIX}.${base64UrlEncode(encoder.encode(JSON.stringify(claims)))}`;
  const mac = await hmac(secret, body);
  return `${body}.${base64UrlEncode(mac)}`;
}

/** The claims of a valid, unexpired pass, or null. */
export async function verifyPass(
  pass: string,
  secret: string,
  now: number,
): Promise<PassClaims | null> {
  const parts = pass.split(".");
  if (parts.length !== 3 || parts[0] !== PREFIX) return null;
  const [, encodedClaims, encodedMac] = parts as [string, string, string];
  const mac = base64UrlDecode(encodedMac);
  if (mac === null) return null;
  const key = await hmacKey(secret);
  const valid = await crypto.subtle.verify(
    "HMAC",
    key,
    mac,
    encoder.encode(`${PREFIX}.${encodedClaims}`),
  );
  if (!valid) return null;

  const claimBytes = base64UrlDecode(encodedClaims);
  if (claimBytes === null) return null;
  let claims: unknown;
  try {
    claims = JSON.parse(new TextDecoder().decode(claimBytes));
  } catch {
    return null;
  }
  if (!isPassClaims(claims) || claims.exp <= now) return null;
  return claims;
}

function isPassClaims(value: unknown): value is PassClaims {
  if (typeof value !== "object" || value === null) return false;
  const c = value as Record<string, unknown>;
  return (
    typeof c.room === "string" &&
    typeof c.uid === "string" &&
    typeof c.name === "string" &&
    (c.avatar === null || typeof c.avatar === "string") &&
    (c.role === "owner" || c.role === "editor" || c.role === "viewer") &&
    typeof c.exp === "number"
  );
}

async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

async function hmac(secret: string, message: string): Promise<Uint8Array> {
  const key = await hmacKey(secret);
  return new Uint8Array(
    await crypto.subtle.sign("HMAC", key, encoder.encode(message)),
  );
}

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64UrlDecode(text: string): Uint8Array<ArrayBuffer> | null {
  if (!/^[A-Za-z0-9_-]*$/.test(text)) return null;
  const padded = text.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(padded + "=".repeat((4 - (padded.length % 4)) % 4));
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}
