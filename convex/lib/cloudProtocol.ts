import { clientUpgradeRequiredError } from "./errors";

export const CURRENT_CLOUD_PROTOCOL_VERSION = 3;

export function assertSupportedCloudProtocol(clientProtocolVersion: number): void {
  if (clientProtocolVersion !== CURRENT_CLOUD_PROTOCOL_VERSION) {
    throw clientUpgradeRequiredError();
  }
}
