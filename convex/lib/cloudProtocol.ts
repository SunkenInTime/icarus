import { clientUpgradeRequiredError } from "./errors";
import { v } from "convex/values";

export const CURRENT_CLOUD_PROTOCOL_VERSION = 3;
export const MAX_CLOUD_OPERATION_BYTES = 900 * 1024;
export const MAX_CLOUD_ARRAY_ENTRIES = 8_000;
export const CLOUD_OPERATION_TOO_LARGE_MESSAGE =
  "This saved change is too large for cloud sync. It remains saved on this device.";

export const cloudProtocolArgs = {
  clientProtocolVersion: v.number(),
} as const;

export function assertSupportedCloudProtocol(clientProtocolVersion: number): void {
  if (clientProtocolVersion !== CURRENT_CLOUD_PROTOCOL_VERSION) {
    throw clientUpgradeRequiredError();
  }
}

export function serializedConvexValueUtf8Bytes(value: unknown): number {
  return new TextEncoder().encode(JSON.stringify(value)).byteLength;
}

export function cloudOperationExceedsPolicy(value: unknown): boolean {
  if (serializedConvexValueUtf8Bytes(value) > MAX_CLOUD_OPERATION_BYTES) {
    return true;
  }
  return valueExceedsArrayPolicy(value);
}

function valueExceedsArrayPolicy(value: unknown): boolean {
  if (Array.isArray(value)) {
    return (
      value.length > MAX_CLOUD_ARRAY_ENTRIES ||
      value.some(valueExceedsArrayPolicy)
    );
  }
  if (value !== null && typeof value === "object") {
    return Object.values(value).some(valueExceedsArrayPolicy);
  }
  return false;
}
