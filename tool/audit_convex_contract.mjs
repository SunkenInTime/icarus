import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const toolDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(toolDirectory, "..");
const functionSpec = JSON.parse(
  readFileSync(resolve(repositoryRoot, "convex/function_spec.json"), "utf8"),
);
const snapshottedErrorCodes = JSON.parse(
  readFileSync(resolve(repositoryRoot, "convex/error_codes.json"), "utf8"),
);
const errorsSource = readFileSync(
  resolve(repositoryRoot, "convex/lib/errors.ts"),
  "utf8",
);

const failures = [];
const supportedValidatorTypes = new Set([
  "array",
  "bigint",
  "boolean",
  "bytes",
  "id",
  "literal",
  "null",
  "number",
  "object",
  "record",
  "string",
  "union",
]);
const allowedPublicIds = new Set([
  "images.js:completeUpload.args.storageId:_storage",
]);

function fail(message) {
  failures.push(message);
}

function auditValidator(validator, path, identifier) {
  if (validator === null || typeof validator !== "object") {
    fail(`${identifier}.${path.join(".")} is not a validator object`);
    return;
  }
  if (!supportedValidatorTypes.has(validator.type)) {
    fail(
      `${identifier}.${path.join(".")} uses unsupported validator ${String(validator.type)}`,
    );
    return;
  }

  switch (validator.type) {
    case "array":
      auditValidator(validator.value, [...path, "item"], identifier);
      break;
    case "object":
      for (const [fieldName, field] of Object.entries(validator.value)) {
        if (
          field === null ||
          typeof field !== "object" ||
          typeof field.optional !== "boolean" ||
          field.fieldType === undefined
        ) {
          fail(`${identifier}.${[...path, fieldName].join(".")} has an invalid field`);
          continue;
        }
        auditValidator(field.fieldType, [...path, fieldName], identifier);
      }
      break;
    case "record":
      auditValidator(validator.keys, [...path, "key"], identifier);
      if (
        validator.values === null ||
        typeof validator.values !== "object" ||
        validator.values.optional !== false ||
        validator.values.fieldType === undefined
      ) {
        fail(`${identifier}.${path.join(".")} has invalid record values`);
      } else {
        auditValidator(
          validator.values.fieldType,
          [...path, "value"],
          identifier,
        );
      }
      break;
    case "union":
      if (!Array.isArray(validator.value) || validator.value.length === 0) {
        fail(`${identifier}.${path.join(".")} has an empty union`);
      } else {
        validator.value.forEach((member, index) =>
          auditValidator(member, [...path, `union${index}`], identifier),
        );
      }
      break;
    case "id": {
      const key = `${identifier}.${path.join(".")}:${validator.tableName}`;
      if (!allowedPublicIds.has(key)) {
        fail(`${identifier}.${path.join(".")} exposes Convex id ${validator.tableName}`);
      }
      break;
    }
  }
}

if (
  functionSpec === null ||
  typeof functionSpec !== "object" ||
  !Array.isArray(functionSpec.functions) ||
  Object.keys(functionSpec).some((key) => key !== "functions")
) {
  fail("function_spec.json must contain only a functions array");
} else {
  const identifiers = new Set();
  for (const functionSpecEntry of functionSpec.functions) {
    if (identifiers.has(functionSpecEntry.identifier)) {
      fail(`duplicate function identifier ${functionSpecEntry.identifier}`);
    }
    identifiers.add(functionSpecEntry.identifier);
    if (functionSpecEntry.visibility?.kind !== "public") {
      continue;
    }
    if (functionSpecEntry.args === null) {
      fail(`${functionSpecEntry.identifier} is missing an args validator`);
    } else {
      auditValidator(functionSpecEntry.args, ["args"], functionSpecEntry.identifier);
      if (functionSpecEntry.functionType === "Mutation") {
        const protocolField = functionSpecEntry.args.value?.clientProtocolVersion;
        if (
          functionSpecEntry.args.type !== "object" ||
          protocolField?.optional !== false ||
          protocolField?.fieldType?.type !== "number"
        ) {
          fail(
            `${functionSpecEntry.identifier} must require numeric clientProtocolVersion`,
          );
        }
      }
    }
    if (functionSpecEntry.returns === null) {
      fail(`${functionSpecEntry.identifier} is missing a return validator`);
    } else {
      auditValidator(
        functionSpecEntry.returns,
        ["returns"],
        functionSpecEntry.identifier,
      );
    }
  }
}

const errorCodesDeclaration = errorsSource.match(
  /export const errorCodes\s*=\s*\[([\s\S]*?)\]\s*as const/,
);
if (errorCodesDeclaration === null) {
  fail("convex/lib/errors.ts does not export errorCodes as a const array");
} else {
  const sourceCodes = [
    ...errorCodesDeclaration[1].matchAll(/"([A-Z][A-Z0-9_]*)"/g),
  ].map((match) => match[1]);
  const sortedSourceCodes = [...new Set(sourceCodes)].sort();
  if (sourceCodes.length !== sortedSourceCodes.length) {
    fail("errorCodes contains duplicate values");
  }
  if (JSON.stringify(sourceCodes) !== JSON.stringify(sortedSourceCodes)) {
    fail("errorCodes must be sorted");
  }
  if (
    JSON.stringify(snapshottedErrorCodes) !== JSON.stringify(sortedSourceCodes)
  ) {
    fail("error_codes.json does not match convex/lib/errors.ts");
  }
}

if (failures.length > 0) {
  console.error(failures.map((failure) => `- ${failure}`).join("\n"));
  process.exitCode = 1;
} else {
  const publicFunctionCount = functionSpec.functions.filter(
    (entry) => entry.visibility?.kind === "public",
  ).length;
  console.log(
    `Convex contract audit passed: ${publicFunctionCount} public functions, ${snapshottedErrorCodes.length} error codes.`,
  );
}
