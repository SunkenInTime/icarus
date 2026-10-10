import { v, type Infer } from "convex/values";
import { valuesEqual } from "./canonicalValues";
import { cloudJsonValueValidator } from "./payloadValidators";

/// How a patch from a client that merges by field says what it changed (see
/// docs/collaborative-editing.md). The op still carries the item's whole
/// payload as the client has it; only [fields] of it are written, each onto
/// the stored row as it is now, so a teammate's change to another field
/// stays. With [base] (work that waited offline), the op is refused instead
/// when a field it changes has changed on the server since the client last
/// saw it.
///
/// An element's fields are top-level keys of its payload's `data`. A lineup
/// group's are its items: `origins/<id>`, `landings/<id>` or `links/<id>`.
/// A base entry without a value means the field was absent.
export const fieldMergeValidator = v.object({
  fields: v.array(v.string()),
  base: v.optional(
    v.array(
      v.object({
        field: v.string(),
        value: v.optional(cloudJsonValueValidator),
      }),
    ),
  ),
});

export type FieldMerge = Infer<typeof fieldMergeValidator>;

/// The most fields one op may name. A lineup group edit names each item it
/// adds, changes or removes, so this is generous.
export const MAX_MERGE_FIELDS = 512;

export type MergeOutcome<T> =
  /// The fields written onto the stored value.
  | { status: "merged"; value: T }
  /// The op cannot be merged by field (a different payload version or
  /// subtype, or a field that names identity): it is applied as a whole,
  /// revision-checked write instead.
  | { status: "whole" }
  /// A field the offline op changes was changed on the server meanwhile.
  | { status: "conflict" };

type Envelope = {
  kind: string;
  payloadVersion: number;
  data: Record<string, unknown>;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/// Whether [key] is present on [record]: an own property that is not
/// undefined.
function has(record: Record<string, unknown>, key: string): boolean {
  return (
    Object.prototype.hasOwnProperty.call(record, key) &&
    record[key] !== undefined
  );
}

/// Whether two possibly absent values are the same: both absent, or both
/// present and equal.
function same(
  leftPresent: boolean,
  left: unknown,
  rightPresent: boolean,
  right: unknown,
): boolean {
  if (!leftPresent || !rightPresent) return leftPresent === rightPresent;
  return valuesEqual(left, right);
}

/// A field name that cannot be used as a key on a plain object safely.
function unsafeKey(key: string): boolean {
  return key === "__proto__" || key === "constructor" || key === "prototype";
}

/// Keys of an element's data that say what it is rather than how it is
/// drawn. A merge never writes them, and is only possible while the client
/// and the server agree on them: a client that turned an agent into a view
/// cone, or drew on a payload version the server has moved past, writes the
/// whole item instead.
const ELEMENT_IDENTITY_KEYS = ["id", "elementType", "kind", "type", "data"];

/// [merge]'s fields of [desired] written onto [current] (both element
/// payloads).
export function mergeElementPayload(
  current: Envelope,
  desired: Envelope,
  merge: FieldMerge,
): MergeOutcome<Envelope> {
  if (
    current.kind !== desired.kind ||
    current.payloadVersion !== desired.payloadVersion ||
    !isRecord(current.data) ||
    !isRecord(desired.data)
  ) {
    return { status: "whole" };
  }
  for (const key of ELEMENT_IDENTITY_KEYS) {
    if (
      merge.fields.includes(key) ||
      !same(
        has(current.data, key),
        current.data[key],
        has(desired.data, key),
        desired.data[key],
      )
    ) {
      return { status: "whole" };
    }
  }
  if (merge.fields.some(unsafeKey)) return { status: "whole" };

  const read = (record: Record<string, unknown>, field: string) => ({
    present: has(record, field),
    value: record[field],
  });
  if (
    baseChanged(merge, (field) => read(current.data, field), (field) =>
      read(desired.data, field),
    )
  ) {
    return { status: "conflict" };
  }

  const data: Record<string, unknown> = { ...current.data };
  for (const field of merge.fields) {
    if (has(desired.data, field)) {
      data[field] = desired.data[field];
    } else {
      delete data[field];
    }
  }
  return {
    status: "merged",
    value: {
      kind: current.kind,
      payloadVersion: current.payloadVersion,
      data,
    },
  };
}

const LINEUP_COLLECTIONS = ["origins", "landings", "links"] as const;
type LineupCollection = (typeof LINEUP_COLLECTIONS)[number];

/// The collection and id a lineup group field names, or null when it names
/// neither.
function lineupField(
  field: string,
): { collection: LineupCollection; id: string } | null {
  const slash = field.indexOf("/");
  if (slash <= 0) return null;
  const collection = field.slice(0, slash);
  const id = field.slice(slash + 1);
  if (id.length === 0) return null;
  for (const known of LINEUP_COLLECTIONS) {
    if (known === collection) return { collection: known, id };
  }
  return null;
}

function itemsOf(
  data: Record<string, unknown>,
  collection: LineupCollection,
): Array<Record<string, unknown>> {
  const items = data[collection];
  return Array.isArray(items) ? items.filter(isRecord) : [];
}

function itemById(
  data: Record<string, unknown>,
  collection: LineupCollection,
  id: string,
): Record<string, unknown> | undefined {
  return itemsOf(data, collection).find((item) => item.id === id);
}

/// [merge]'s items of [desired] written onto [current] (both lineup group
/// payloads): each named item replaced, added at the end of its list, or
/// removed. Spots no lineup uses afterwards are dropped, as clients drop
/// them when they build a group. The result is not validated here; the
/// caller checks it as it checks any group before storing it.
export function mergeLineupPayload(
  current: Envelope,
  desired: Envelope,
  merge: FieldMerge,
): MergeOutcome<Envelope> {
  if (
    current.kind !== desired.kind ||
    current.payloadVersion !== desired.payloadVersion ||
    !isRecord(current.data) ||
    !isRecord(desired.data) ||
    !valuesEqual(current.data.id, desired.data.id)
  ) {
    return { status: "whole" };
  }
  const named = merge.fields.map(lineupField);
  if (named.some((entry) => entry === null)) return { status: "whole" };
  const items = named as Array<{ collection: LineupCollection; id: string }>;

  const read =
    (data: Record<string, unknown>) =>
    (field: string): { present: boolean; value: unknown } => {
      const target = lineupField(field);
      const item =
        target === null
          ? undefined
          : itemById(data, target.collection, target.id);
      return { present: item !== undefined, value: item };
    };
  if (baseChanged(merge, read(current.data), read(desired.data))) {
    return { status: "conflict" };
  }

  const lists: Record<LineupCollection, Array<Record<string, unknown>>> = {
    origins: [...itemsOf(current.data, "origins")],
    landings: [...itemsOf(current.data, "landings")],
    links: [...itemsOf(current.data, "links")],
  };
  for (const { collection, id } of items) {
    const list = lists[collection];
    const index = list.findIndex((item) => item.id === id);
    const wanted = itemById(desired.data, collection, id);
    if (wanted === undefined) {
      if (index >= 0) list.splice(index, 1);
    } else if (index >= 0) {
      list[index] = wanted;
    } else {
      list.push(wanted);
    }
  }
  const usedOrigins = new Set(lists.links.map((link) => link.originId));
  const usedLandings = new Set(lists.links.map((link) => link.landingId));
  return {
    status: "merged",
    value: {
      kind: current.kind,
      payloadVersion: current.payloadVersion,
      data: {
        ...current.data,
        origins: lists.origins.filter((origin) => usedOrigins.has(origin.id)),
        landings: lists.landings.filter((landing) =>
          usedLandings.has(landing.id),
        ),
        links: lists.links,
      },
    },
  };
}

/// Whether, for an op with a base, a field it changes has changed on the
/// server since that base: the stored value is neither the base nor what the
/// op writes. (A field already holding the op's value is no collision.)
function baseChanged(
  merge: FieldMerge,
  current: (field: string) => { present: boolean; value: unknown },
  desired: (field: string) => { present: boolean; value: unknown },
): boolean {
  if (merge.base === undefined) return false;
  for (const entry of merge.base) {
    if (!merge.fields.includes(entry.field)) continue;
    const now = current(entry.field);
    const wanted = desired(entry.field);
    const basePresent = entry.value !== undefined;
    if (
      !same(now.present, now.value, basePresent, entry.value) &&
      !same(now.present, now.value, wanted.present, wanted.value)
    ) {
      return true;
    }
  }
  return false;
}
