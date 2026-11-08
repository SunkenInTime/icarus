// node --test tool/check_convex_shipped_clients.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import {
  applyOptIns,
  checkOptIns,
  compareSpecs,
  decoderStrictness,
  explain,
} from "./check_convex_shipped_clients.mjs";

const strict = { typed: true, raw: true };
const lenient = { typed: false, raw: false };

const string = { type: "string" };
const number = { type: "number" };
const boolean = { type: "boolean" };
const literal = (value) => ({ type: "literal", value });
const union = (...value) => ({ type: "union", value });
const array = (value) => ({ type: "array", value });
const field = (fieldType, optional = false) => ({ fieldType, optional });
const object = (fields) => ({
  type: "object",
  value: Object.fromEntries(
    Object.entries(fields).map(([name, value]) =>
      [name, "fieldType" in value ? value : field(value)],
    ),
  ),
});

function spec(functions) {
  return {
    functions: Object.entries(functions).map(([identifier, { args = object({}), returns, type = "Query", visibility = "public" }]) => ({
      identifier,
      functionType: type,
      visibility: { kind: visibility },
      args,
      returns,
    })),
  };
}

function issues(before, after, strictness = strict) {
  return compareSpecs(spec(before), spec(after), strictness).map(
    (issue) => `${issue.function} ${issue.path.join("")}: ${explain(issue)}`,
  );
}

const card = object({ name: string, role: union(literal("owner"), literal("viewer")) });

test("an unchanged spec has no issues", () => {
  const functions = { "strategies.js:list": { returns: array(card) } };
  assert.deepEqual(issues(functions, functions), []);
});

test("a removed or internal function breaks old clients", () => {
  const before = { "a.js:gone": { returns: string }, "a.js:hidden": { returns: string } };
  const after = { "a.js:hidden": { returns: string, visibility: "internal" } };
  assert.deepEqual(issues(before, after), [
    "a:gone : removed or made internal; old clients still have it in their generated API and may call it",
    "a:hidden : removed or made internal; old clients still have it in their generated API and may call it",
  ]);
});

test("arguments: new required, removed, narrowed, now required", () => {
  const before = {
    "a.js:f": {
      args: object({ gone: string, kind: union(literal("x"), literal("y")), size: number, note: field(string, true) }),
      returns: string,
    },
  };
  const after = {
    "a.js:f": {
      args: object({ kind: literal("x"), size: string, note: string, added: boolean, extra: field(boolean, true) }),
      returns: string,
    },
  };
  assert.deepEqual(issues(before, after).sort(), [
    'a:f args.added: new required argument "added"; old clients don\'t send it',
    'a:f args.gone: argument "gone" is gone; old clients still send it and Convex rejects arguments it doesn\'t declare',
    'a:f args.kind: old clients may send "y", which the server no longer accepts (it accepts "x")',
    'a:f args.note: argument "note" is now required; old clients may leave it out',
    "a:f args.size: old clients send number, but the server now accepts only string",
  ]);
});

test("results: removed, optional, retyped, new enum value, new variant", () => {
  const status = (value, extra = {}) => object({ status: literal(value), ...extra });
  const before = {
    "a.js:f": {
      returns: object({
        gone: string,
        maybe: string,
        count: number,
        role: union(literal("owner"), literal("viewer")),
        result: union(status("applied"), status("rejected", { reason: string })),
      }),
    },
  };
  const after = {
    "a.js:f": {
      returns: object({
        maybe: field(string, true),
        count: string,
        role: union(literal("owner"), literal("viewer"), literal("coach")),
        result: union(status("applied"), status("rejected", { reason: string }), status("deferred")),
      }),
    },
  };
  assert.deepEqual(issues(before, after).sort(), [
    'a:f result.count: now string; old clients decode only number',
    'a:f result.gone: field "gone" is gone; old clients require it',
    'a:f result.maybe: field "maybe" can now be left out; old clients require it',
    'a:f result.result<status=deferred>: new variant status "deferred", which old clients don\'t know',
    'a:f result.role: can now be "coach", which old clients don\'t know (they know "owner", "viewer")',
  ]);
});

test("a result that can now be null breaks old clients", () => {
  const before = { "a.js:f": { returns: object({ name: string }) } };
  const after = { "a.js:f": { returns: object({ name: union(string, { type: "null" }) }) } };
  assert.deepEqual(issues(before, after), ["a:f result.name: now null; old clients decode only string"]);
});

test("widening what the server accepts and narrowing what it returns are safe", () => {
  const before = {
    "a.js:f": {
      args: object({ kind: literal("x") }),
      returns: object({ role: union(literal("owner"), literal("viewer")), note: field(string, true) }),
    },
  };
  const after = {
    "a.js:f": {
      args: object({ kind: union(literal("x"), literal("y")), more: field(string, true) }),
      returns: object({ role: literal("owner") }),
    },
  };
  assert.deepEqual(issues(before, after), []);
});

test("a new result field breaks strict decoders only", () => {
  const before = { "a.js:f": { returns: array(card) } };
  const after = {
    "a.js:f": {
      returns: array(object({ ...card.value, agentTypes: field(array(string), true) })),
    },
  };
  assert.deepEqual(issues(before, after, strict), [
    'a:f result[].agentTypes: new optional field "agentTypes"; old clients reject result fields they don\'t know',
  ]);
  assert.deepEqual(issues(before, after, lenient), []);
});

test("raw-union objects follow the raw strictness, typed models the typed one", () => {
  // No shared discriminator, so the generator emits a raw predicate.
  const raw = (extra = {}) =>
    union(object({ ok: literal(true), ...extra }), object({ ok: literal(true), reused: boolean }));
  const typed = (extra = {}) => object({ name: string, ...extra });
  const before = { "a.js:raw": { returns: raw() }, "a.js:typed": { returns: typed() } };
  const after = {
    "a.js:raw": { returns: raw({ added: field(string, true) }) },
    "a.js:typed": { returns: typed({ added: field(string, true) }) },
  };
  assert.deepEqual(issues(before, after, { typed: false, raw: true }), [
    'a:raw result.added: new optional field "added"; old clients reject result fields they don\'t know',
  ]);
  assert.deepEqual(issues(before, after, { typed: true, raw: false }), [
    'a:typed result.added: new optional field "added"; old clients reject result fields they don\'t know',
  ]);
});

test("builds that differ only in raw strictness get their own answers", () => {
  const raw = (extra = {}) =>
    union(object({ ok: literal(true), ...extra }), object({ ok: literal(true), reused: boolean }));
  const before = { "a.js:f": { returns: object({ outcome: raw() }) } };
  const after = { "a.js:f": { returns: object({ outcome: raw({ added: field(string, true) }) }) } };
  assert.equal(issues(before, after, { typed: true, raw: true }).length, 1);
  assert.equal(issues(before, after, { typed: true, raw: false }).length, 0);
});

test("a field named like an Object property still counts as new", () => {
  const before = { "a.js:f": { returns: object({ name: string }) } };
  const after = { "a.js:f": { returns: object({ name: string, toString: field(string, true) }) } };
  assert.deepEqual(issues(before, after), [
    'a:f result.toString: new optional field "toString"; old clients reject result fields they don\'t know',
  ]);
});

test("payload envelopes are judged the way the payload codec reads them", () => {
  const data = { type: "record", keys: string, values: field(string) };
  const payload = (kind, extra = {}) =>
    object({ kind: literal(kind), payloadVersion: number, data, ...extra });
  const before = { "a.js:f": { returns: object({ payload: union(payload("agent"), payload("text")) }) } };
  // The codec ignores envelope keys it doesn't use, and takes any map as data.
  const extraKey = {
    "a.js:f": {
      returns: object({
        payload: union(
          payload("agent", { metadata: string }),
          object({ kind: literal("text"), payloadVersion: literal(2), data: object({ body: string }) }),
        ),
      }),
    },
  };
  assert.deepEqual(issues(before, extraKey), []);
  // It still needs a kind it knows, a number, and a map.
  const broken = {
    "a.js:f": {
      returns: object({
        payload: union(
          payload("agent", { payloadVersion: string }),
          payload("text", { data: string }),
          payload("image"),
        ),
      }),
    },
  };
  assert.deepEqual(issues(before, broken).sort(), [
    "a:f result.payload<kind=agent>.payloadVersion: now string; old clients decode only number",
    'a:f result.payload<kind=image>: new variant kind "image", which old clients don\'t know',
    "a:f result.payload<kind=text>.data: now string; old clients decode only record<any>",
  ]);
});

const optInBefore = { "a.js:f": { args: object({}), returns: array(card) } };
const optInAfter = {
  "a.js:f": {
    args: object({ includeAgents: field(boolean, true) }),
    returns: array(object({ ...card.value, agentTypes: field(array(string), true) })),
  },
};
const agentsOptIn = { function: "a:f", path: "result[].agentTypes", sentOnlyWith: ["args.includeAgents"] };

test("an opt-in covers a new field the old client can't ask for", () => {
  const found = compareSpecs(spec(optInBefore), spec(optInAfter), strict);
  const { valid, problems } = checkOptIns([agentsOptIn], spec(optInAfter));
  assert.deepEqual(problems, []);
  const { hit, covered } = applyOptIns(found, valid, spec(optInBefore));
  assert.equal(hit.length, 0);
  assert.equal(covered.length, 1);
});

test("an opt-in doesn't cover a client that already sends the argument", () => {
  const before = { "a.js:f": { args: object({ includeAgents: field(boolean, true) }), returns: array(card) } };
  const found = compareSpecs(spec(before), spec(optInAfter), strict);
  const { hit, covered } = applyOptIns(found, [agentsOptIn], spec(before));
  assert.equal(covered.length, 0);
  assert.match(explain(hit[0]), /declared as sent only with args\.includeAgents, but old clients can send that too/);
});

test("an opt-in can name an argument inside an op", () => {
  const op = (type, extra = {}) => object({ type: literal(type), ...extra });
  const reason = (...values) => object({ results: array(object({ reason: union(...values.map(literal)) })) });
  const before = { "ops.js:apply": { args: object({ ops: array(union(op("a.patch"), op("a.add"))) }), returns: reason("gone") } };
  const after = {
    "ops.js:apply": {
      args: object({ ops: array(union(op("a.patch", { merge: field(string, true) }), op("a.add"))) }),
      returns: reason("gone", "field_conflict"),
    },
  };
  const optIn = { function: "ops:apply", path: "result.results[].reason", sentOnlyWith: ["args.ops[]<type=a.patch>.merge"] };
  const { valid, problems } = checkOptIns([optIn], spec(after));
  assert.deepEqual(problems, []);
  const found = compareSpecs(spec(before), spec(after), strict);
  assert.equal(found.length, 1);
  const { hit } = applyOptIns(found, valid, spec(before));
  assert.deepEqual(hit, []);
});

test("bad opt-in declarations are reported and cover nothing", () => {
  const required = {
    "a.js:f": { ...optInAfter["a.js:f"], args: object({ includeAgents: boolean }) },
  };
  assert.deepEqual(checkOptIns([agentsOptIn], spec(required)).problems, [
    "a:f result[].agentTypes: args.includeAgents is required, so it doesn't tell clients that ask apart from clients that don't",
  ]);
  const { problems, valid } = checkOptIns(
    [
      { ...agentsOptIn, sentOnlyWith: ["args.includeAgent"] },
      { ...agentsOptIn, path: "result[].agentType" },
      { ...agentsOptIn, function: "a:g" },
    ],
    spec(optInAfter),
  );
  assert.deepEqual(valid, []);
  assert.deepEqual(problems, [
    "a:f result[].agentTypes: a:f has no argument at args.includeAgent",
    "a:f result[].agentType: the result has nothing at this path",
    "a:g result[].agentTypes: no public function a:g",
  ]);
});

test("an opt-in doesn't excuse a removed field", () => {
  const before = { "a.js:f": { returns: object({ name: string }) } };
  const after = { "a.js:f": { args: object({ x: field(boolean, true) }), returns: object({}) } };
  const found = compareSpecs(spec(before), spec(after), strict);
  const { hit } = applyOptIns(found, [{ function: "a:f", path: "result.name", sentOnlyWith: ["args.x"] }], spec(before));
  assert.equal(hit.length, 1);
});

test("strictness is read from the build's generated decoders", () => {
  const strictSource = `
void _checkObjectFields(ConvexObject object, String path, Set<String> allowed) {
  for (final field in object.value.keys) {
    if (!allowed.contains(field)) {
      throw ConvexDecodingException('$path.$field', 'unexpected field');
    }
  }
}
bool _matchesRaw0(ConvexValue value) =>
    value is ConvexObject &&
    value.value.keys.every(const {'ok'}.contains) &&
    (value.value['ok'] != null && _matchesRaw1(value.value['ok']!));`;
  assert.deepEqual(decoderStrictness(strictSource), strict);
  assert.deepEqual(decoderStrictness("bool _matchesRaw0(ConvexValue value) => value is ConvexObject;"), lenient);
});
