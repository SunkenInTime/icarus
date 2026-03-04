"use strict";
var __defProp = Object.defineProperty;
var __defNormalProp = (obj, key, value) => key in obj ? __defProp(obj, key, { enumerable: true, configurable: true, writable: true, value }) : obj[key] = value;
var __publicField = (obj, key, value) => __defNormalProp(obj, typeof key !== "symbol" ? key + "" : key, value);
import { nodeFs } from "../../../bundler/fs.js";
import {
  deploymentSelectionWithinProjectSchema
} from "../api.js";
import { z } from "zod";
export class RequestContext {
  constructor(options) {
    this.options = options;
    __publicField(this, "fs");
    __publicField(this, "deprecationMessagePrinted", false);
    __publicField(this, "spinner");
    __publicField(this, "_cleanupFns", {});
    __publicField(this, "_bigBrainAuth", null);
    this.fs = nodeFs;
    this.deprecationMessagePrinted = false;
  }
  async crash(args) {
    const cleanupFns = this._cleanupFns;
    this._cleanupFns = {};
    for (const fn of Object.values(cleanupFns)) {
      await fn(args.exitCode, args.errForSentry);
    }
    throw new RequestCrash(args.exitCode, args.errorType, args.printedMessage);
  }
  flushAndExit() {
    throw new Error("Not implemented");
  }
  registerCleanup(fn) {
    const handle = crypto.randomUUID();
    this._cleanupFns[handle] = fn;
    return handle;
  }
  removeCleanup(handle) {
    const value = this._cleanupFns[handle];
    delete this._cleanupFns[handle];
    return value ?? null;
  }
  bigBrainAuth() {
    return this._bigBrainAuth;
  }
  _updateBigBrainAuth(auth) {
    this._bigBrainAuth = auth;
  }
  async decodeDeploymentSelector(encoded) {
    const { projectDir, deployment } = decodeDeploymentSelector(encoded);
    if (deployment.kind === "prod" && !this.options.dangerouslyEnableProductionDeployments) {
      return await this.crash({
        exitCode: 1,
        errorType: "fatal",
        printedMessage: "This tool cannot be used with production deployments. Use a read-only tool like `insights` instead, or enable production access with --dangerously-enable-production-deployments."
      });
    }
    return { projectDir, deployment };
  }
  /** Decode a deployment selector without checking the production guard. Use for read-only tools that don't expose PII (e.g. insights). */
  decodeDeploymentSelectorUnchecked(encoded) {
    return decodeDeploymentSelector(encoded);
  }
  /** Decode a deployment selector for read-only tools that may expose PII (e.g. data, logs, queries). Requires --cautiously-allow-production-pii. */
  async decodeDeploymentSelectorReadOnly(encoded) {
    const { projectDir, deployment } = decodeDeploymentSelector(encoded);
    if (deployment.kind === "prod" && !this.options.dangerouslyEnableProductionDeployments && !this.options.cautiouslyAllowProductionPii) {
      return await this.crash({
        exitCode: 1,
        errorType: "fatal",
        printedMessage: "This read-only tool may expose PII from production. Enable with --cautiously-allow-production-pii, or use --dangerously-enable-production-deployments for full access."
      });
    }
    return { projectDir, deployment };
  }
  get productionDeploymentsDisabled() {
    return !this.options.dangerouslyEnableProductionDeployments;
  }
  get productionPiiAllowed() {
    return this.options.dangerouslyEnableProductionDeployments || this.options.cautiouslyAllowProductionPii;
  }
}
export class RequestCrash {
  constructor(exitCode, errorType, printedMessage) {
    this.exitCode = exitCode;
    this.errorType = errorType;
    __publicField(this, "printedMessage");
    this.printedMessage = printedMessage ?? "Unknown error";
  }
  toString() {
    return this.printedMessage;
  }
}
export function encodeDeploymentSelector(projectDir, deployment) {
  const payload = {
    projectDir,
    deployment
  };
  return `${deployment.kind}:${btoa(JSON.stringify(payload))}`;
}
const payloadSchema = z.object({
  projectDir: z.string(),
  deployment: deploymentSelectionWithinProjectSchema
});
function decodeDeploymentSelector(encoded) {
  const [_, serializedPayload] = encoded.split(":");
  return payloadSchema.parse(JSON.parse(atob(serializedPayload)));
}
//# sourceMappingURL=requestContext.js.map
