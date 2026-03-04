"use strict";
import input from "@inquirer/input";
import select from "@inquirer/select";
import search from "@inquirer/search";
import confirm from "@inquirer/confirm";
import { logOutput } from "../../../bundler/log.js";
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
export const promptString = async (ctx, options) => {
  if (process.stdin.isTTY) {
    return input({
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
export const promptOptions = async (ctx, options) => {
  if (process.stdin.isTTY) {
    return select({
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
export const promptSearch = async (ctx, options) => {
  if (process.stdin.isTTY) {
    return search({
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
export const promptYesNo = async (ctx, options) => {
  if (process.stdin.isTTY) {
    return confirm({
      message: options.message,
      ...options.default !== void 0 ? { default: options.default } : {},
      ...options.prefix !== void 0 ? { theme: { prefix: options.prefix } } : {}
    }).catch(handlePromptError(ctx));
  } else {
    logOutput(options.message);
    return ctx.crash({
      exitCode: 1,
      errorType: "fatal",
      printedMessage: options.nonInteractiveError ?? `Cannot prompt for input in non-interactive terminals. (${options.message})`
    });
  }
};
//# sourceMappingURL=prompts.js.map
