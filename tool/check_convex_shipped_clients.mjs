// Fails when the Convex function spec in the working tree would break a
// client we already shipped.
//
// Every shipped build is a `desktop-stable-v*` tag (web deploys from the
// latest one), and each tag holds the function spec its generated Dart client
// was built from. For each tag this asks two questions:
//
//   - Would the server accept every argument that build sends?
//   - Would that build's generated decoders accept every result the server
//     can now return?
//
// A build whose decoders reject unknown object fields breaks on any new result
// field. A new optional field is still safe when the server sends it only to
// clients that ask for it with an optional argument. The spec can't show that,
// so such fields are declared in tool/convex_opt_in_results.json, and this
// check confirms the argument exists and that the old build can't send it.
//
// Usage:
//   node tool/check_convex_shipped_clients.mjs
//     [--spec <function_spec.json>]   spec to check (default: the working tree's)
//     [--client <git ref>]...         compare against these refs, not the tags
//     [--opt-ins <file>]              opt-in declarations to use

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const toolDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(toolDirectory, "..");
const specPathInRepo = "convex/function_spec.json";
const modelsPathInRepo = "lib/collab/generated/convex_models.dart";
const defaultOptInsPath = resolve(toolDirectory, "convex_opt_in_results.json");
const shippedTagPattern = "desktop-stable-v*";

// The generator's discriminator preference (tool/icarus_convex_codegen mapper).
const discriminatorNames = ["type", "status", "kind", "targetType", "provider"];

// --- Validators --------------------------------------------------------------

const hashes = new WeakMap();

// A structural hash, so identical subtrees compare in O(1).
function hashOf(validator) {
  if (validator === null || typeof validator !== "object") {
    return JSON.stringify(validator);
  }
  const cached = hashes.get(validator);
  if (cached !== undefined) return cached;
  const hash = createHash("sha1");
  if (Array.isArray(validator)) {
    hash.update("[");
    for (const item of validator) hash.update(hashOf(item)).update(",");
  } else {
    hash.update("{");
    for (const key of Object.keys(validator).sort()) {
      hash.update(JSON.stringify(key)).update(":").update(hashOf(validator[key])).update(",");
    }
  }
  const digest = hash.digest("base64");
  hashes.set(validator, digest);
  return digest;
}

function unionMembers(validator) {
  if (validator.type !== "union") return [validator];
  return validator.value.flatMap(unionMembers);
}

function isNull(validator) {
  return (
    validator.type === "null" ||
    (validator.type === "literal" && validator.value === null)
  );
}

function isStringLiteral(validator) {
  return validator.type === "literal" && typeof validator.value === "string";
}

function objectFields(validator) {
  return validator.type === "object" ? validator.value : {};
}

function isPayloadObject(validator) {
  const { kind, payloadVersion, data } = objectFields(validator);
  return (
    kind?.optional === false &&
    payloadVersion?.optional === false &&
    data?.optional === false &&
    isStringLiteral(kind.fieldType) &&
    payloadVersion.fieldType.type === "number" &&
    data.fieldType.type === "record"
  );
}

function discriminatorOf(objects) {
  for (const name of discriminatorNames) {
    const values = new Set();
    const valid = objects.every((object) => {
      const field = objectFields(object)[name];
      if (!field || field.optional || !isStringLiteral(field.fieldType)) return false;
      if (values.has(field.fieldType.value)) return false;
      values.add(field.fieldType.value);
      return true;
    });
    if (valid) return name;
  }
  return null;
}

// Whether the generator turned this union into a raw predicate instead of an
// enum, a payload union, or a discriminated union (mapper.dart `_mapUnion`).
function isRawUnion(validator) {
  const members = validator.value;
  const withoutNull = members.filter((member) => !isNull(member));
  if (withoutNull.length === 1 && withoutNull.length !== members.length) return false;
  if (withoutNull.every(isStringLiteral)) return false;
  if (withoutNull.every((member) => member.type === "object")) {
    if (withoutNull.every(isPayloadObject)) return false;
    if (discriminatorOf(withoutNull) !== null) return false;
  }
  return true;
}

// The variant a discriminated object names itself by, e.g. `type: "page"`.
function variantTag(validator) {
  const fields = objectFields(validator);
  for (const name of discriminatorNames) {
    const field = fields[name];
    if (field && !field.optional && isStringLiteral(field.fieldType)) {
      return { name, value: field.fieldType.value };
    }
  }
  return null;
}

function describe(validator, depth = 0) {
  switch (validator.type) {
    case "literal":
      return JSON.stringify(validator.value);
    case "id":
      return `id<${validator.tableName}>`;
    case "array":
      return `array<${describe(validator.value, depth + 1)}>`;
    case "record":
      return `record<${describe(validator.values.fieldType, depth + 1)}>`;
    case "object": {
      const tag = variantTag(validator);
      if (tag) return `{${tag.name}: "${tag.value}", ...}`;
      if (depth > 0) return "object";
      const keys = Object.keys(validator.value);
      const shown = keys.slice(0, 4).join(", ");
      return `{${shown}${keys.length > 4 ? ", ..." : ""}}`;
    }
    case "union": {
      const text = unionMembers(validator)
        .map((member) => describe(member, depth + 1))
        .join(" | ");
      return text.length > 90 ? `${text.slice(0, 87)}...` : text;
    }
    default:
      return validator.type;
  }
}

// --- Comparison --------------------------------------------------------------
//
// compare(judge, sent) lists every way a value matching `sent` can be refused
// by `judge`. For arguments the judge is the new server's validator and `sent`
// is what the old client sends; for results the judge is the old client's
// decoder and `sent` is what the new server returns.
//
// `strict` is whether the judge refuses object fields it doesn't declare.
// Convex argument validators always do. A generated decoder does if that
// build's generator made it do so; `rawStrict` covers the raw-union
// predicates, which a generator may treat differently from typed models.
//
// Issues carry paths relative to the compared pair, so results memoize.

const memo = new Map();

function compare(judge, sent, mode) {
  const key = `${hashOf(judge)}|${hashOf(sent)}|${mode.key}`;
  const cached = memo.get(key);
  if (cached !== undefined) return cached;
  const issues = hashOf(judge) === hashOf(sent) ? [] : compareUncached(judge, sent, mode);
  memo.set(key, issues);
  return issues;
}

function within(segment, issues) {
  return issues.map((issue) => ({ ...issue, path: [segment, ...issue.path] }));
}

function compareUncached(judge, sent, mode) {
  if (sent.type === "union") {
    return unionMembers(sent).flatMap((member) => {
      const tag = member.type === "object" ? variantTag(member) : null;
      const issues = compare(judge, member, mode);
      return tag ? within(`<${tag.name}=${tag.value}>`, issues) : issues;
    });
  }
  if (judge.type === "union") {
    const inner = mode.decoder && isRawUnion(judge) ? mode.raw : mode;
    return compareWithUnion(unionMembers(judge), sent, inner);
  }
  return compareSingle(judge, sent, mode);
}

function compareWithUnion(judges, sent, mode) {
  let closest = null;
  for (const judge of judges) {
    const issues = compare(judge, sent, mode);
    if (issues.length === 0) return [];
    if (sameKind(judge, sent) && (closest === null || issues.length < closest.length)) {
      closest = issues;
    }
  }
  if (closest !== null) return closest;
  if (isStringLiteral(sent) && judges.some(isStringLiteral)) {
    return [
      {
        path: [],
        kind: "literal",
        value: sent.value,
        known: judges.filter(isStringLiteral).map((judge) => judge.value),
      },
    ];
  }
  const tag = sent.type === "object" ? variantTag(sent) : null;
  if (tag && judges.some((judge) => variantTag(judge)?.name === tag.name)) {
    return [{ path: [], kind: "variant", field: tag.name, value: tag.value }];
  }
  return [
    {
      path: [],
      kind: "type",
      judge: judges.map((judge) => describe(judge, 1)).join(" | "),
      sent: describe(sent),
    },
  ];
}

function sameKind(judge, sent) {
  if (judge.type !== sent.type) return false;
  if (judge.type === "literal") return false;
  if (judge.type === "object") {
    const judgeTag = variantTag(judge);
    const sentTag = variantTag(sent);
    if (judgeTag && sentTag) {
      return judgeTag.name === sentTag.name && judgeTag.value === sentTag.value;
    }
  }
  return true;
}

function compareSingle(judge, sent, mode) {
  const mismatch = () => [
    { path: [], kind: "type", judge: describe(judge), sent: describe(sent) },
  ];
  switch (judge.type) {
    // Only the payload comparison makes these: the codec takes any value.
    case "any":
      return [];
    case "literal":
      if (sent.type === "literal" && sent.value === judge.value) return [];
      if (isStringLiteral(sent) && isStringLiteral(judge)) {
        return [{ path: [], kind: "literal", value: sent.value, known: [judge.value] }];
      }
      return mismatch();
    case "null":
      return isNull(sent) ? [] : mismatch();
    case "string":
      return sent.type === "string" || sent.type === "id" || isStringLiteral(sent)
        ? []
        : mismatch();
    case "number":
      return sent.type === "number" ||
        (sent.type === "literal" && typeof sent.value === "number")
        ? []
        : mismatch();
    case "boolean":
      return sent.type === "boolean" ||
        (sent.type === "literal" && typeof sent.value === "boolean")
        ? []
        : mismatch();
    case "bigint":
    case "bytes":
      return sent.type === judge.type ? [] : mismatch();
    case "id":
      return sent.type === "id" && sent.tableName === judge.tableName ? [] : mismatch();
    case "array":
      return sent.type === "array"
        ? within("[]", compare(judge.value, sent.value, mode))
        : mismatch();
    case "record":
      if (sent.type === "record") {
        return [
          ...compare(judge.keys, sent.keys, mode),
          ...within("{}", compare(judge.values.fieldType, sent.values.fieldType, mode)),
        ];
      }
      if (sent.type === "object") {
        return Object.entries(sent.value).flatMap(([name, field]) =>
          within(`.${name}`, compare(judge.values.fieldType, field.fieldType, mode)),
        );
      }
      return mismatch();
    case "object":
      if (sent.type !== "object") return mismatch();
      return mode.decoder && isPayloadObject(judge)
        ? comparePayloads(judge, sent, mode)
        : compareObjects(judge, sent, mode);
    default:
      return mismatch();
  }
}

function compareObjects(judge, sent, mode) {
  const issues = [];
  for (const [name, judgeField] of Object.entries(judge.value)) {
    const sentField = Object.hasOwn(sent.value, name) ? sent.value[name] : undefined;
    if (sentField === undefined) {
      if (!judgeField.optional) issues.push({ path: [`.${name}`], kind: "missing" });
      continue;
    }
    if (sentField.optional && !judgeField.optional) {
      issues.push({ path: [`.${name}`], kind: "optional" });
    }
    issues.push(...within(`.${name}`, compare(judgeField.fieldType, sentField.fieldType, mode)));
  }
  if (mode.strict) {
    for (const [name, sentField] of Object.entries(sent.value)) {
      if (!Object.hasOwn(judge.value, name)) {
        issues.push({ path: [`.${name}`], kind: "extra", optional: sentField.optional });
      }
    }
  }
  return issues;
}

// A payload envelope goes to the build's hand-written codec, not a generated
// model. The codec (lib/collab/convex_payload_codecs.dart) checks the kind, a
// numeric payloadVersion, and a map for data, and ignores other keys. What is
// inside data is the codec's business, which the spec can't describe.
function comparePayloads(judge, sent, mode) {
  const envelope = {
    type: "object",
    value: {
      kind: judge.value.kind,
      payloadVersion: asField({ type: "number" }),
      data: asField({ type: "record", keys: { type: "string" }, values: asField({ type: "any" }) }),
    },
  };
  const shape = {
    type: "object",
    value: {
      kind: sent.value.kind,
      payloadVersion: sent.value.payloadVersion,
      data: sent.value.data && asField(anyMap(sent.value.data.fieldType), sent.value.data.optional),
    },
  };
  return compareObjects(envelope, shape, { ...mode, strict: false, key: `${mode.key}/payload` });
}

function asField(fieldType, optional = false) {
  return { fieldType, optional };
}

// Any map-shaped data, as the codec sees it.
function anyMap(validator) {
  return unionMembers(validator).every((member) => member.type === "record" || member.type === "object")
    ? { type: "record", keys: { type: "string" }, values: asField({ type: "any" }) }
    : validator;
}

function decoderModes(strictness) {
  const raw = { decoder: true, strict: strictness.raw, key: `raw:${strictness.raw}` };
  raw.raw = raw;
  return {
    decoder: true,
    strict: strictness.typed,
    // Typed models can contain raw unions, so both settings shape the result.
    key: `typed:${strictness.typed}/raw:${strictness.raw}`,
    raw,
  };
}

const argumentMode = { decoder: false, strict: true, key: "args" };

// --- Whole specs -------------------------------------------------------------

export function displayName(identifier) {
  return identifier.replace(/\.js:/, ":");
}

function publicFunctions(spec) {
  return new Map(
    spec.functions
      .filter((entry) => entry.visibility?.kind === "public")
      .map((entry) => [displayName(entry.identifier), entry]),
  );
}

// Every incompatibility a client built from `oldSpec`, whose decoders have
// `strictness`, hits against a server whose contract is `newSpec`.
export function compareSpecs(oldSpec, newSpec, strictness) {
  const before = publicFunctions(oldSpec);
  const after = publicFunctions(newSpec);
  const results = decoderModes(strictness);
  const issues = [];
  for (const [name, old] of before) {
    const current = after.get(name);
    if (current === undefined) {
      issues.push({ function: name, side: "function", path: [], kind: "removed" });
      continue;
    }
    if (current.functionType !== old.functionType) {
      issues.push({
        function: name,
        side: "function",
        path: [],
        kind: "function-type",
        judge: current.functionType,
        sent: old.functionType,
      });
      continue;
    }
    for (const issue of compare(current.args, old.args, argumentMode)) {
      issues.push({ ...issue, function: name, side: "args", path: ["args", ...issue.path] });
    }
    for (const issue of compare(old.returns, current.returns, results)) {
      issues.push({ ...issue, function: name, side: "result", path: ["result", ...issue.path] });
    }
  }
  return issues;
}

// --- Opt-in result values ----------------------------------------------------
//
// A declaration names a result path, as this check prints it, and the
// argument paths that make the server send a value there:
//
//   { "function": "strategies:listForFolder",
//     "path": "result[].agentTypes",
//     "sentOnlyWith": ["args.includeAgentTypes"] }
//
// An argument path can reach into an op, e.g.
// "args.ops[]<type=element.patch>.merge". Each one must be optional in the
// spec being checked, and a build that has it in its own spec isn't covered:
// it can send it, so it can receive the value.

export function readOptIns(path) {
  const parsed = JSON.parse(readFileSync(path, "utf8"));
  if (!Array.isArray(parsed.optIns)) {
    throw new Error(`${path} must have an "optIns" array`);
  }
  for (const entry of parsed.optIns) {
    const valid =
      typeof entry.function === "string" &&
      typeof entry.path === "string" &&
      Array.isArray(entry.sentOnlyWith) &&
      entry.sentOnlyWith.length > 0 &&
      entry.sentOnlyWith.every((arg) => typeof arg === "string");
    if (!valid) {
      throw new Error(
        `${path}: every opt-in needs "function", "path", and a non-empty "sentOnlyWith" list of argument paths`,
      );
    }
  }
  return parsed.optIns;
}

const segmentPattern = /\.[^.[{<]+|\[\]|\{\}|<[^=>]+=[^>]+>/g;

function parsePath(path, root) {
  if (!path.startsWith(root)) return null;
  const rest = path.slice(root.length);
  const segments = rest.match(segmentPattern) ?? [];
  return segments.join("") === rest ? segments : null;
}

// The field a path names, as { fieldType, optional }, or null when the spec
// has nothing there. Unions are searched member by member.
function resolvePath(validator, segments) {
  let current = { fieldType: validator, optional: false };
  for (const segment of segments) {
    const members = unionMembers(current.fieldType);
    let next = null;
    if (segment === "[]") {
      const array = members.find((member) => member.type === "array");
      if (array) next = { fieldType: array.value, optional: false };
    } else if (segment === "{}") {
      const record = members.find((member) => member.type === "record");
      if (record) next = { fieldType: record.values.fieldType, optional: false };
    } else if (segment.startsWith("<")) {
      const [name, value] = segment.slice(1, -1).split("=");
      const variant = members.find((member) => {
        const tag = member.type === "object" ? variantTag(member) : null;
        return tag?.name === name && tag.value === value;
      });
      if (variant) next = { fieldType: variant, optional: false };
    } else {
      const name = segment.slice(1);
      const object = members.find(
        (member) => member.type === "object" && Object.hasOwn(member.value, name),
      );
      if (object) next = object.value[name];
    }
    if (next === null) return null;
    current = next;
  }
  return current;
}

// Problems with the declarations themselves, against the spec being checked.
// A declaration with a problem covers nothing.
export function checkOptIns(optIns, newSpec) {
  const after = publicFunctions(newSpec);
  const problems = [];
  const valid = [];
  for (const entry of optIns) {
    const label = `${entry.function} ${entry.path}`;
    const before = problems.length;
    const current = after.get(entry.function);
    if (current === undefined) {
      problems.push(`${label}: no public function ${entry.function}`);
      continue;
    }
    const resultSegments = parsePath(entry.path, "result");
    if (resultSegments === null || resolvePath(current.returns, resultSegments) === null) {
      problems.push(`${label}: the result has nothing at this path`);
    }
    for (const arg of entry.sentOnlyWith) {
      const argSegments = parsePath(arg, "args");
      const field = argSegments && argSegments.length > 0 ? resolvePath(current.args, argSegments) : null;
      if (field === null) {
        problems.push(`${label}: ${entry.function} has no argument at ${arg}`);
      } else if (!field.optional) {
        problems.push(
          `${label}: ${arg} is required, so it doesn't tell clients that ask apart from clients that don't`,
        );
      }
    }
    if (problems.length === before) valid.push(entry);
  }
  return { problems, valid };
}

// Splits a build's issues into the ones it hits and the ones an opt-in covers:
// a new value at a declared path, which the server sends only with arguments
// this build can't send.
export function applyOptIns(issues, optIns, oldSpec) {
  const before = publicFunctions(oldSpec);
  const hit = [];
  const covered = [];
  for (const issue of issues) {
    const path = issue.path.join("");
    const entry = optIns.find(
      (optIn) => optIn.function === issue.function && optIn.path === path,
    );
    const gateable =
      issue.side === "result" &&
      ((issue.kind === "extra" && issue.optional) ||
        issue.kind === "literal" ||
        issue.kind === "variant");
    if (entry === undefined || !gateable) {
      hit.push(issue);
      continue;
    }
    const oldArgs = before.get(issue.function).args;
    const sendable = entry.sentOnlyWith.filter(
      (arg) => resolvePath(oldArgs, parsePath(arg, "args")) !== null,
    );
    if (sendable.length > 0) {
      hit.push({ ...issue, optInSentByOldClient: sendable.join(", ") });
    } else {
      covered.push({ ...issue, optIn: entry.sentOnlyWith.join(" or ") });
    }
  }
  return { hit, covered };
}

// --- Messages ----------------------------------------------------------------

export function explain(issue) {
  const field = issue.path.at(-1)?.replace(/^\./, "");
  if (issue.side === "function") {
    if (issue.kind === "removed") {
      return "removed or made internal; old clients still have it in their generated API and may call it";
    }
    return `changed from ${issue.sent} to ${issue.judge}; old clients call it as a ${issue.sent}`;
  }
  if (issue.side === "args") {
    switch (issue.kind) {
      case "missing":
        return `new required argument "${field}"; old clients don't send it`;
      case "optional":
        return `argument "${field}" is now required; old clients may leave it out`;
      case "extra":
        return `argument "${field}" is gone; old clients still send it and Convex rejects arguments it doesn't declare`;
      case "literal":
        return `old clients may send "${issue.value}", which the server no longer accepts (it accepts ${issue.known.map((value) => `"${value}"`).join(", ")})`;
      case "variant":
        return `old clients may send ${issue.field} "${issue.value}", which the server no longer accepts`;
      default:
        return `old clients send ${issue.sent}, but the server now accepts only ${issue.judge}`;
    }
  }
  const base = explainResult(issue, field);
  return issue.optInSentByOldClient
    ? `${base}. It is declared as sent only with ${issue.optInSentByOldClient}, but old clients can send that too`
    : base;
}

function explainResult(issue, field) {
  switch (issue.kind) {
    case "missing":
      return `field "${field}" is gone; old clients require it`;
    case "optional":
      return `field "${field}" can now be left out; old clients require it`;
    case "extra":
      return `${issue.optional ? "new optional field" : "new field"} "${field}"; old clients reject result fields they don't know`;
    case "literal":
      return `can now be "${issue.value}", which old clients don't know (they know ${issue.known.map((value) => `"${value}"`).join(", ")})`;
    case "variant":
      return `new variant ${issue.field} "${issue.value}", which old clients don't know`;
    default:
      return `now ${issue.sent}; old clients decode only ${issue.judge}`;
  }
}

const advice = {
  function:
    "Keep a function public until no shipped build calls it. A function that must stop working can throw a structured error the old client already handles.",
  args:
    "Keep accepting what shipped clients send: add new arguments as optional, and keep removed ones as optional arguments the server ignores.",
  result:
    "Keep results readable by shipped clients. To add a field, add an optional argument that new clients send (like includeAgentTypes in #343), send the field only when it is set, and declare it in tool/convex_opt_in_results.json: {\"function\", \"path\" as printed above, \"sentOnlyWith\": [\"args.<argument>\"]}. A new enum value or union variant needs the same opt-in.",
};

// --- Shipped clients from git ------------------------------------------------

function git(args, options = {}) {
  return execFileSync("git", args, {
    cwd: repositoryRoot,
    encoding: "utf8",
    maxBuffer: 256 * 1024 * 1024,
    stdio: ["ignore", "pipe", "pipe"],
    ...options,
  });
}

function blobId(ref, path) {
  try {
    return git(["rev-parse", "--verify", "--quiet", `${ref}:${path}`]).trim();
  } catch {
    return null;
  }
}

function buildNumber(tag) {
  const match = tag.match(/v(\d+)\.(\d+)\.(\d+)\+(\d+)$/);
  return match ? match.slice(1).map(Number) : [0, 0, 0, 0];
}

function shippedTags() {
  const tags = git(["tag", "--list", shippedTagPattern]).split("\n").filter(Boolean);
  return tags.sort((left, right) => {
    const a = buildNumber(left);
    const b = buildNumber(right);
    for (let index = 0; index < a.length; index += 1) {
      if (a[index] !== b[index]) return a[index] - b[index];
    }
    return left.localeCompare(right);
  });
}

// How a build's generated decoders treat object fields they don't declare,
// read from that build's own generated code.
export function decoderStrictness(modelsSource) {
  return {
    // `_checkObjectFields` throwing 'unexpected field' in typed models.
    typed: modelsSource.includes("'unexpected field'"),
    // Raw-union predicates requiring `value.keys.every(const {...}.contains)`.
    raw: /\.value\.keys\.every\(const \{/.test(modelsSource),
  };
}

// Shipped clients, grouped by identical spec and decoder strictness.
function loadClients(refs) {
  const groups = new Map();
  const skipped = [];
  for (const ref of refs) {
    const specBlob = blobId(ref, specPathInRepo);
    const modelsBlob = blobId(ref, modelsPathInRepo);
    if (specBlob === null || modelsBlob === null) {
      skipped.push(ref);
      continue;
    }
    const key = `${specBlob}:${modelsBlob}`;
    if (!groups.has(key)) groups.set(key, { specBlob, modelsBlob, refs: [] });
    groups.get(key).refs.push(ref);
  }
  const blobs = new Map();
  const read = (id) => {
    if (!blobs.has(id)) blobs.set(id, git(["cat-file", "blob", id]));
    return blobs.get(id);
  };
  const clients = [...groups.values()].map((group) => ({
    refs: group.refs,
    spec: JSON.parse(read(group.specBlob)),
    strictness: decoderStrictness(read(group.modelsBlob)),
  }));
  return { clients, skipped };
}

// --- Main --------------------------------------------------------------------

function repoLabel(path) {
  const inRepo = relative(repositoryRoot, path);
  return inRepo.startsWith("..") ? path : inRepo.replaceAll("\\", "/");
}

function shortRef(ref) {
  return ref.replace(/^desktop-stable-v/, "");
}

function parseArgs(argv) {
  const options = { spec: resolve(repositoryRoot, specPathInRepo), clients: [], optIns: defaultOptInsPath };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (value === undefined) throw new Error(`${flag} needs a value`);
    index += 1;
    if (flag === "--spec") options.spec = resolve(value);
    else if (flag === "--client") options.clients.push(value);
    else if (flag === "--opt-ins") options.optIns = resolve(value);
    else throw new Error(`unknown option ${flag}`);
  }
  return options;
}

function main() {
  const started = Date.now();
  const options = parseArgs(process.argv.slice(2));
  const newSpec = JSON.parse(readFileSync(options.spec, "utf8"));
  const optIns = readOptIns(options.optIns);
  const specLabel = repoLabel(options.spec);

  const refs = options.clients.length > 0 ? options.clients : shippedTags();
  if (refs.length === 0) {
    console.error(
      `No ${shippedTagPattern} tags in this checkout, so there is nothing to check against. Fetch them:\n` +
        `  git fetch --depth=1 origin '+refs/tags/${shippedTagPattern}:refs/tags/${shippedTagPattern}'`,
    );
    process.exit(2);
  }
  const { clients, skipped } = loadClients(refs);
  if (clients.length === 0) {
    console.error(`None of ${refs.join(", ")} has ${specPathInRepo} and a generated client.`);
    process.exit(2);
  }

  const { problems: optInProblems, valid: validOptIns } = checkOptIns(optIns, newSpec);

  // function -> path -> explanation -> refs
  const findings = new Map();
  const coveredByOptIn = new Map();
  for (const client of clients) {
    const { hit, covered } = applyOptIns(
      compareSpecs(client.spec, newSpec, client.strictness),
      validOptIns,
      client.spec,
    );
    for (const issue of hit) {
      const perFunction = findings.get(issue.function) ?? new Map();
      findings.set(issue.function, perFunction);
      const line = `${issue.path.join("") || "(function)"}: ${explain(issue)}`;
      const entry = perFunction.get(line) ?? { side: issue.side, refs: new Set() };
      for (const ref of client.refs) entry.refs.add(ref);
      perFunction.set(line, entry);
    }
    for (const issue of covered) {
      const line = `${issue.function} ${issue.path.join("")} (sent only with ${issue.optIn})`;
      const refs = coveredByOptIn.get(line) ?? new Set();
      for (const ref of client.refs) refs.add(ref);
      coveredByOptIn.set(line, refs);
    }
  }

  const totalRefs = clients.flatMap((client) => client.refs);
  const refList = (refs) => {
    const list = [...refs];
    return list.length === totalRefs.length && totalRefs.length > 1
      ? `all ${list.length} (${list.map(shortRef).join(", ")})`
      : list.map(shortRef).join(", ");
  };

  console.log(`Checked ${specLabel} against ${totalRefs.length} shipped client(s):`);
  for (const client of clients) {
    const strict = client.strictness.typed || client.strictness.raw;
    console.log(
      `  ${client.refs.map(shortRef).join(", ")}: ${strict ? "rejects" : "ignores"} result fields it doesn't know`,
    );
  }
  if (skipped.length > 0) {
    console.log(`  (skipped ${skipped.map(shortRef).join(", ")}: no cloud client)`);
  }

  for (const [line, list] of coveredByOptIn) {
    console.log(`  ok: ${line}, for ${refList(list)}`);
  }

  let count = 0;
  const sides = new Set();
  for (const [name, perFunction] of [...findings].sort(([a], [b]) => a.localeCompare(b))) {
    console.log(`\n${name}`);
    for (const [line, entry] of perFunction) {
      count += 1;
      sides.add(entry.side);
      console.log(`  ${line}\n    breaks ${refList(entry.refs)}`);
    }
  }

  if (optInProblems.length > 0) {
    console.log(`\n${repoLabel(options.optIns)}:`);
    for (const problem of optInProblems) console.log(`  ${problem}`);
  }

  const seconds = ((Date.now() - started) / 1000).toFixed(1);
  if (count === 0 && optInProblems.length === 0) {
    console.log(`\nNo incompatibilities with shipped clients (${seconds} s).`);
    return;
  }
  console.log(
    `\n${count} incompatibilit${count === 1 ? "y" : "ies"} with shipped clients` +
      `${optInProblems.length > 0 ? `, ${optInProblems.length} bad opt-in declaration(s)` : ""} (${seconds} s).`,
  );
  for (const side of ["function", "args", "result"]) {
    if (sides.has(side)) console.log(`- ${advice[side]}`);
  }
  process.exitCode = 1;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    console.error(error.message);
    process.exit(2);
  }
}
