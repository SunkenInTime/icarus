import { clientUpgradeRequiredError } from "./errors";

export const CURRENT_CLOUD_PROTOCOL_VERSION = 1;
export const MIN_CLOUD_PROTOCOL_VERSION = 1;

export function assertSupportedCloudProtocol(clientProtocolVersion: number): void {
  if (clientProtocolVersion < MIN_CLOUD_PROTOCOL_VERSION) {
    throw clientUpgradeRequiredError();
  }
}

