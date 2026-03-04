"use strict";
var __create = Object.create;
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __getProtoOf = Object.getPrototypeOf;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, { get: all[name], enumerable: true });
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
  // If the importer is in node compatibility mode or this is not an ESM
  // file that has been converted to a CommonJS file using a Babel-
  // compatible transform (i.e. "__esModule" has not been set), then set
  // "default" to the CommonJS "module.exports" for node compatibility.
  isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
  mod
));
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);
var prompts_exports = {};
__export(prompts_exports, {
  promptOptions: () => promptOptions,
  promptSearch: () => promptSearch,
  promptString: () => promptString,
  promptYesNo: () => promptYesNo
});
module.exports = __toCommonJS(prompts_exports);
var import_input = __toESM(require("@inquirer/input"), 1);
var import_select = __toESM(require("@inquirer/select"), 1);
var import_search = __toESM(require("@inquirer/search"), 1);
var import_confirm = __toESM(require("@inquirer/confirm"), 1);
var import_log = require("../../../bundler/log.js");
function handlePromptError(ctx) {
  return async (error) => {
    if (error instanceof Error && error.name === "ExitPromptError") {
      process.exit(130);
    }
    return ctx.crash({
      exitCode: 1,
      errorType: "fatal",
      printedMessage: `Unexpected prompt error: ${String(error)}`,
      errForSentry: error instanceof Error ? error : void 0
    });
  };
}
const promptString = async (ctx, options) => {
  if (process.stdin.isTTY) {
    return (0, import_input.default)({
      message: options.message,
      ...options.default !== void 0 ? { default: options.default } : {}
    }).catch(handlePromptError(ctx));
  } else {
    return ctx.crash({
      exitCode: 1,
      errorType: "fatal",
      printedMessage: `Cannot prompt for input in non-interactive terminals. (${options.message})`
    });
  }
};
const promptOptions = async (ctx, options) => {
  if (process.stdin.isTTY) {
    return (0, import_select.default)({
      message: options.message + (options.suffix ?? ""),
      choices: options.choices,
      ...options.default !== void 0 ? { default: options.default } : {},
      ...options.prefix !== void 0 ? { theme: { prefix: options.prefix } } : {}
    }).catch(handlePromptError(ctx));
  } else {
    return ctx.crash({
      exitCode: 1,
      errorType: "fatal",
      printedMessage: `Cannot prompt for input in non-interactive terminals. (${options.message})`
    });
  }
};
const promptSearch = async (ctx, options) => {
  if (process.stdin.isTTY) {
    return (0, import_search.default)({
      message: options.message,
      ...options.default !== void 0 ? { default: options.default } : {},
      source: (input2) => {
        if (!input2) return options.choices;
        const term = input2.toLowerCase();
        return options.choices.filter(
          (c) => c.name.toLowerCase().includes(term)
        );
      }
    }).catch(handlePromptError(ctx));
  } else {
    return ctx.crash({
      exitCode: 1,
      errorType: "fatal",
      printedMessage: `Cannot prompt for input in non-interactive terminals. (${options.message})`
    });
  }
};
const promptYesNo = async (ctx, options) => {
  if (process.stdin.isTTY) {
    return (0, import_confirm.default)({
      message: options.message,
      ...options.default !== void 0 ? { default: options.default } : {},
      ...options.prefix !== void 0 ? { theme: { prefix: options.prefix } } : {}
    }).catch(handlePromptError(ctx));
  } else {
    (0, import_log.logOutput)(options.message);
    return ctx.crash({
      exitCode: 1,
      errorType: "fatal",
      printedMessage: options.nonInteractiveError ?? `Cannot prompt for input in non-interactive terminals. (${options.message})`
    });
  }
};
//# sourceMappingURL=prompts.js.map
