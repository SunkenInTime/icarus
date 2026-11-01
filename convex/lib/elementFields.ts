import { v } from "convex/values";
import type { Doc } from "../_generated/dataModel";

type ElementPayload = Doc<"elements">["payload"];

/// Every element kind that is a placed item: all but drawings.
const PLACED_KINDS: readonly string[] = [
  "agent",
  "ability",
  "text",
  "image",
  "utility",
];

/// Element fields added after clients shipped, with the level that added them
/// and the kinds that have them. A build decodes an item into the fields it
/// knows, so one that was sent a later field drops it, sees a change it never
/// made, and its next page save deletes the field for everyone. So a client
/// reads a later field only once its level says it keeps it, and a write that
/// leaves one out never removes it.
///
/// A field in this table is cleared by writing an empty value. An absent field
/// means the writer doesn't know about it.
export const LATER_ELEMENT_FIELDS = [
  { field: "caption", level: 1, kinds: PLACED_KINDS },
];

/// Set by clients that keep later element fields: the highest level they know
/// (see LATER_ELEMENT_FIELDS). Older clients send nothing and read as level 0.
export const elementFieldLevelArg = v.optional(v.number());

/// [payload] as a client at [level] holds it, without the fields it doesn't
/// know.
export function withoutLaterFields(
  payload: ElementPayload,
  level: number | undefined,
): ElementPayload {
  const hidden = LATER_ELEMENT_FIELDS.filter(
    (entry) =>
      entry.level > (level ?? 0) &&
      entry.kinds.includes(payload.kind) &&
      entry.field in payload.data,
  );
  if (hidden.length === 0) return payload;
  const data = { ...payload.data };
  for (const { field } of hidden) delete data[field];
  return { ...payload, data };
}

/// [next] keeping the later fields [current] holds that it leaves out. This
/// needs no level: an op written by an old build can be sent after the build
/// updates, and a client that means to clear a field writes it empty.
export function keepLaterFields(
  current: ElementPayload,
  next: ElementPayload,
): ElementPayload {
  const kept = LATER_ELEMENT_FIELDS.filter(
    ({ field, kinds }) =>
      kinds.includes(next.kind) && field in current.data && !(field in next.data),
  );
  if (kept.length === 0) return next;
  const data = { ...next.data };
  for (const { field } of kept) data[field] = current.data[field];
  return { ...next, data };
}
