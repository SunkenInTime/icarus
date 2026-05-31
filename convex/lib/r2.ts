declare const process: { env: Record<string, string | undefined> };

export type R2Config = {
  accountId: string;
  bucket: string;
  accessKeyId: string;
  secretAccessKey: string;
  endpoint: string;
  publicBaseUrl: string;
  uploadUrlExpiresSeconds: number;
  maxImageBytes: number;
};

export type R2ObjectMetadata = {
  byteSize: number | null;
  mimeType: string | null;
  etag: string | null;
};

const defaultUploadUrlExpiresSeconds = 15 * 60;
const defaultMaxImageBytes = 15 * 1024 * 1024;
const r2Region = "auto";
const r2Service = "s3";
const unsignedPayload = "UNSIGNED-PAYLOAD";
const emptyPayloadHash =
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

const mimeByExtension: Record<string, string> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".bmp": "image/bmp",
};

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (value === undefined || value.trim() === "") {
    throw new Error(
      `Missing Cloudflare R2 environment variable ${name}. Set R2_ACCOUNT_ID, R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, and R2_PUBLIC_BASE_URL on the Convex deployment.`,
    );
  }
  return value.trim();
}

function optionalPositiveIntEnv(
  name: string,
  fallback: number,
  options: { min?: number; max?: number } = {},
): number {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === "") {
    return fallback;
  }
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new Error(`${name} must be a positive integer.`);
  }
  if (options.min !== undefined && parsed < options.min) {
    throw new Error(`${name} must be at least ${options.min}.`);
  }
  if (options.max !== undefined && parsed > options.max) {
    throw new Error(`${name} must be at most ${options.max}.`);
  }
  return parsed;
}

export function getR2Config(): R2Config {
  const accountId = requiredEnv("R2_ACCOUNT_ID");
  const bucket = requiredEnv("R2_BUCKET");
  const endpoint =
    process.env.R2_S3_ENDPOINT?.trim() ||
    `https://${accountId}.r2.cloudflarestorage.com`;

  return {
    accountId,
    bucket,
    endpoint: endpoint.replace(/\/+$/, ""),
    accessKeyId: requiredEnv("R2_ACCESS_KEY_ID"),
    secretAccessKey: requiredEnv("R2_SECRET_ACCESS_KEY"),
    publicBaseUrl: getR2PublicBaseUrl(),
    uploadUrlExpiresSeconds: optionalPositiveIntEnv(
      "R2_UPLOAD_URL_EXPIRES_SECONDS",
      defaultUploadUrlExpiresSeconds,
      { min: 1, max: 604800 },
    ),
    maxImageBytes: optionalPositiveIntEnv(
      "R2_MAX_IMAGE_BYTES",
      defaultMaxImageBytes,
    ),
  };
}

export function getR2PublicBaseUrl(): string {
  return requiredEnv("R2_PUBLIC_BASE_URL").replace(/\/+$/, "");
}

export function normalizeImageExtension(extension: string | undefined): string {
  if (extension === undefined || extension.trim() === "") {
    return "";
  }
  const trimmed = extension.trim().toLowerCase();
  return trimmed.startsWith(".") ? trimmed : `.${trimmed}`;
}

export function expectedMimeTypeForExtension(
  extension: string | undefined,
): string | null {
  const normalized = normalizeImageExtension(extension);
  return mimeByExtension[normalized] ?? null;
}

export function validateImageUploadMetadata(args: {
  fileExtension?: string;
  mimeType?: string;
  byteSize?: number;
  maxImageBytes: number;
}): { fileExtension: string; mimeType: string } {
  const fileExtension = normalizeImageExtension(args.fileExtension);
  const expectedMimeType = expectedMimeTypeForExtension(fileExtension);
  if (expectedMimeType === null) {
    throw new Error(
      `Unsupported image extension "${args.fileExtension ?? ""}". Supported extensions: ${Object.keys(
        mimeByExtension,
      ).join(", ")}.`,
    );
  }

  const mimeType = (args.mimeType ?? expectedMimeType).toLowerCase();
  if (mimeType !== expectedMimeType) {
    throw new Error(
      `Image MIME type ${mimeType} does not match ${fileExtension} (${expectedMimeType}).`,
    );
  }

  if (
    args.byteSize !== undefined &&
    (!Number.isFinite(args.byteSize) ||
      args.byteSize <= 0 ||
      args.byteSize > args.maxImageBytes)
  ) {
    throw new Error(
      `Image is too large. Maximum allowed size is ${args.maxImageBytes} bytes.`,
    );
  }

  return { fileExtension, mimeType };
}

function encodeRfc3986(value: string): string {
  return encodeURIComponent(value).replace(/[!'()*]/g, (char) =>
    `%${char.charCodeAt(0).toString(16).toUpperCase()}`,
  );
}

function encodePath(path: string): string {
  return path.split("/").map(encodeRfc3986).join("/");
}

function safeObjectKeySegment(value: string): string {
  const sanitized = value.replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 128);
  return sanitized.length === 0 ? "asset" : sanitized;
}

function randomHex(byteLength: number): string {
  const cryptoApi = globalThis.crypto;
  if (cryptoApi === undefined) {
    throw new Error("Web Crypto is unavailable; cannot create R2 object key.");
  }
  const bytes = new Uint8Array(byteLength);
  cryptoApi.getRandomValues(bytes);
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
}

export function createR2ObjectKey(args: {
  strategyPublicId: string;
  assetPublicId: string;
  fileExtension: string;
}): string {
  const strategy = safeObjectKeySegment(args.strategyPublicId);
  const asset = safeObjectKeySegment(args.assetPublicId);
  return `strategies/${strategy}/images/${asset}/${Date.now()}-${randomHex(
    16,
  )}${args.fileExtension}`;
}

export function publicR2UrlForObjectKey(objectKey: string): string {
  return `${getR2PublicBaseUrl()}/${encodePath(objectKey)}`;
}

function toAmzDate(date: Date): { amzDate: string; dateStamp: string } {
  const iso = date.toISOString().replace(/[:-]|\.\d{3}/g, "");
  return {
    amzDate: iso,
    dateStamp: iso.slice(0, 8),
  };
}

function toHex(buffer: ArrayBuffer): string {
  return Array.from(new Uint8Array(buffer), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
}

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const buffer = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(buffer).set(bytes);
  return buffer;
}

function utf8(value: string): ArrayBuffer {
  return toArrayBuffer(new TextEncoder().encode(value));
}

async function hmacSha256(key: ArrayBuffer, data: string): Promise<ArrayBuffer> {
  const cryptoKey = await globalThis.crypto.subtle.importKey(
    "raw",
    key,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return await globalThis.crypto.subtle.sign(
    "HMAC",
    cryptoKey,
    utf8(data),
  );
}

async function signingKey(
  secretAccessKey: string,
  dateStamp: string,
): Promise<ArrayBuffer> {
  const dateKey = await hmacSha256(
    utf8(`AWS4${secretAccessKey}`),
    dateStamp,
  );
  const regionKey = await hmacSha256(dateKey, r2Region);
  const serviceKey = await hmacSha256(regionKey, r2Service);
  return await hmacSha256(serviceKey, "aws4_request");
}

function canonicalQueryString(params: Array<[string, string]>): string {
  return [...params]
    .sort(([leftName, leftValue], [rightName, rightValue]) => {
      if (leftName === rightName) {
        return leftValue.localeCompare(rightValue);
      }
      return leftName.localeCompare(rightName);
    })
    .map(([name, value]) => `${encodeRfc3986(name)}=${encodeRfc3986(value)}`)
    .join("&");
}

function objectUrl(config: R2Config, objectKey: string): URL {
  return new URL(
    `/${encodeRfc3986(config.bucket)}/${encodePath(objectKey)}`,
    config.endpoint,
  );
}

async function signatureForCanonicalRequest(args: {
  secretAccessKey: string;
  dateStamp: string;
  amzDate: string;
  canonicalRequest: string;
}): Promise<string> {
  const canonicalRequestHash = toHex(
    await globalThis.crypto.subtle.digest(
      "SHA-256",
      utf8(args.canonicalRequest),
    ),
  );
  const credentialScope = `${args.dateStamp}/${r2Region}/${r2Service}/aws4_request`;
  const stringToSign = [
    "AWS4-HMAC-SHA256",
    args.amzDate,
    credentialScope,
    canonicalRequestHash,
  ].join("\n");
  return toHex(
    await hmacSha256(
      await signingKey(args.secretAccessKey, args.dateStamp),
      stringToSign,
    ),
  );
}

export async function presignR2PutUrl(args: {
  config: R2Config;
  objectKey: string;
  mimeType: string;
  now?: Date;
}): Promise<{ uploadUrl: string; expiresAt: number; requiredHeaders: Record<string, string> }> {
  const now = args.now ?? new Date();
  const { amzDate, dateStamp } = toAmzDate(now);
  const url = objectUrl(args.config, args.objectKey);
  const credentialScope = `${dateStamp}/${r2Region}/${r2Service}/aws4_request`;
  const signedHeaders = "content-type;host";
  const queryParams: Array<[string, string]> = [
    ["X-Amz-Algorithm", "AWS4-HMAC-SHA256"],
    ["X-Amz-Content-Sha256", unsignedPayload],
    ["X-Amz-Credential", `${args.config.accessKeyId}/${credentialScope}`],
    ["X-Amz-Date", amzDate],
    ["X-Amz-Expires", String(args.config.uploadUrlExpiresSeconds)],
    ["X-Amz-SignedHeaders", signedHeaders],
  ];
  const canonicalRequest = [
    "PUT",
    url.pathname,
    canonicalQueryString(queryParams),
    `content-type:${args.mimeType}\nhost:${url.host}\n`,
    signedHeaders,
    unsignedPayload,
  ].join("\n");
  const signature = await signatureForCanonicalRequest({
    secretAccessKey: args.config.secretAccessKey,
    dateStamp,
    amzDate,
    canonicalRequest,
  });

  url.search = canonicalQueryString([
    ...queryParams,
    ["X-Amz-Signature", signature],
  ]);
  return {
    uploadUrl: url.toString(),
    expiresAt: now.getTime() + args.config.uploadUrlExpiresSeconds * 1000,
    requiredHeaders: {
      "Content-Type": args.mimeType,
    },
  };
}

async function signedR2Fetch(args: {
  config: R2Config;
  method: "HEAD" | "DELETE";
  objectKey: string;
}): Promise<Response> {
  const now = new Date();
  const { amzDate, dateStamp } = toAmzDate(now);
  const url = objectUrl(args.config, args.objectKey);
  const signedHeaders = "host;x-amz-content-sha256;x-amz-date";
  const credentialScope = `${dateStamp}/${r2Region}/${r2Service}/aws4_request`;
  const canonicalRequest = [
    args.method,
    url.pathname,
    "",
    `host:${url.host}\nx-amz-content-sha256:${emptyPayloadHash}\nx-amz-date:${amzDate}\n`,
    signedHeaders,
    emptyPayloadHash,
  ].join("\n");
  const signature = await signatureForCanonicalRequest({
    secretAccessKey: args.config.secretAccessKey,
    dateStamp,
    amzDate,
    canonicalRequest,
  });
  const authorization = [
    `AWS4-HMAC-SHA256 Credential=${args.config.accessKeyId}/${credentialScope}`,
    `SignedHeaders=${signedHeaders}`,
    `Signature=${signature}`,
  ].join(", ");

  return await fetch(url, {
    method: args.method,
    headers: {
      Authorization: authorization,
      "x-amz-content-sha256": emptyPayloadHash,
      "x-amz-date": amzDate,
    },
  });
}

export async function headR2Object(
  config: R2Config,
  objectKey: string,
): Promise<R2ObjectMetadata | null> {
  const response = await signedR2Fetch({ config, method: "HEAD", objectKey });
  if (response.status === 404) {
    return null;
  }
  if (!response.ok) {
    throw new Error(`R2 HEAD failed with ${response.status}.`);
  }
  const byteSize = Number.parseInt(response.headers.get("content-length") ?? "", 10);
  return {
    byteSize: Number.isFinite(byteSize) ? byteSize : null,
    mimeType: response.headers.get("content-type"),
    etag: response.headers.get("etag"),
  };
}

export async function deleteR2Object(
  config: R2Config,
  objectKey: string,
): Promise<void> {
  const response = await signedR2Fetch({ config, method: "DELETE", objectKey });
  if (response.status === 404) {
    return;
  }
  if (!response.ok) {
    throw new Error(`R2 DELETE failed with ${response.status}.`);
  }
}
