"use strict";
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
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
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);
var typecheck_exports = {};
__export(typecheck_exports, {
  typecheck: () => typecheck
});
module.exports = __toCommonJS(typecheck_exports);
var import_chalk = require("chalk");
var import_utils = require("./lib/utils/utils.js");
var import_extra_typings = require("@commander-js/extra-typings");
var import_config = require("./lib/config.js");
var import_typecheck = require("./lib/typecheck.js");
var import_context = require("../bundler/context.js");
var import_log = require("../bundler/log.js");
const typecheck = new import_extra_typings.Command("typecheck").description(
  "Run TypeScript typechecking on your Convex functions with `tsc --noEmit`."
).allowExcessArguments(false).addOption(
  new import_extra_typings.Option(
    "--typescript-compiler <compiler>",
    "TypeScript compiler to use for typechecking (`@typescript/native-preview` must be installed to use `tsgo`)"
  ).choices(["tsc", "tsgo"])
).action(async (cmdOptions) => {
  const ctx = await (0, import_context.oneoffContext)({
    url: void 0,
    adminKey: void 0,
    envFile: void 0
  });
  const typescriptCompiler = await (0, import_typecheck.resolveTypescriptCompiler)(
    ctx,
    cmdOptions.typescriptCompiler
  );
  const { configPath, config: localConfig } = await (0, import_config.readConfig)(ctx, false);
  await (0, import_utils.ensureHasConvexDependency)(ctx, "typecheck");
  await (0, import_typecheck.typeCheckFunctions)(
    ctx,
    typescriptCompiler,
    (0, import_utils.functionsDir)(configPath, localConfig.projectConfig),
    async (typecheckResult, logSpecificError, runOnError) => {
      logSpecificError?.();
      if (typecheckResult === "typecheckFailed") {
        (0, import_log.logMessage)(import_chalk.chalkStderr.gray("Typecheck failed"));
        try {
          await runOnError?.();
        } catch {
        }
        return await ctx.crash({
          exitCode: 1,
          errorType: "invalid filesystem data",
          printedMessage: null
        });
      } else if (typecheckResult === "cantTypeCheck") {
        (0, import_log.logMessage)(
          import_chalk.chalkStderr.gray("Unable to typecheck; is TypeScript installed?")
        );
        return await ctx.crash({
          exitCode: 1,
          errorType: "invalid filesystem data",
          printedMessage: null
        });
      } else {
        (0, import_log.logFinishedStep)(
          `Typecheck passed: \`${typescriptCompiler} --noEmit\` completed with exit code 0.`
        );
        return await ctx.flushAndExit(0);
      }
    }
  );
});
//# sourceMappingURL=typecheck.js.map
