import { vi } from "vitest";
import type { DatabaseWriter, MutationCtx } from "./_generated/server";

export const guardedTables = ["elements", "lineups"] as const;

export const digestedFields = [
  "pageId",
  "sortIndex",
  "deleted",
  "elementType",
  "payloadKind",
  "payload",
] as const;

type Row = Record<string, unknown>;
type Handler = (ctx: MutationCtx, args: unknown) => unknown;
type Definition = Handler | { handler: Handler };

export class ContentChangedWithoutRevision extends Error {}

function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value !== null && typeof value === "object") {
    const entries = Object.entries(value as Row)
      .filter(([, inner]) => inner !== undefined)
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    return `{${entries.map(([key, inner]) => `${JSON.stringify(key)}:${canonical(inner)}`).join(",")}}`;
  }
  return JSON.stringify(value) ?? "undefined";
}

export function changedWithoutRevision(before: Row, after: Row): string[] {
  const from = before.revision as number;
  const to = after.revision as number;
  if (to < from) return ["revision"];
  if (to > from || after.createdAt !== before.createdAt) return [];
  return digestedFields.filter(
    (field) => canonical(before[field]) !== canonical(after[field]),
  );
}

function tableOf(raw: DatabaseWriter, id: unknown): string | undefined {
  if (typeof id !== "string") return undefined;
  return guardedTables.find((table) => raw.normalizeId(table, id) !== null);
}

function guardedDb(raw: DatabaseWriter): DatabaseWriter {
  const write =
    (method: "patch" | "replace") =>
    async (...args: unknown[]) => {
      const named = args.length === 3;
      const id = named ? args[1] : args[0];
      const table = named ? (args[0] as string) : tableOf(raw, id);
      const watched =
        table !== undefined &&
        (guardedTables as readonly string[]).includes(table);
      const before = watched
        ? ((await raw.get(id as never)) as Row | null)
        : null;
      const result = await (raw[method] as (...a: unknown[]) => unknown)(
        ...args,
      );
      if (before !== null) {
        const after = (await raw.get(id as never)) as Row;
        const fields = changedWithoutRevision(before, after);
        if (fields.length > 0) {
          throw new ContentChangedWithoutRevision(
            fields.includes("revision")
              ? `${table} ${String(before.publicId)} lowered its revision from ${String(before.revision)} to ${String(after.revision)}`
              : `${table} ${String(before.publicId)} changed ${fields.join(", ")} at revision ${String(after.revision)} without raising it`,
          );
        }
      }
      return result;
    };
  const methods: Record<string, unknown> = {
    patch: write("patch"),
    replace: write("replace"),
    table: (table: string) => {
      type Method = (...a: unknown[]) => unknown;
      const inner = (
        raw as unknown as {
          table: (name: string) => {
            get: Method;
            query: Method;
            insert: Method;
            delete: Method;
          };
        }
      ).table(table);
      return {
        get: (id: unknown) => inner.get(id),
        query: () => inner.query(),
        insert: (value: unknown) => inner.insert(value),
        delete: (id: unknown) => inner.delete(id),
        patch: (id: unknown, value: unknown) =>
          write("patch")(table, id, value),
        replace: (id: unknown, value: unknown) =>
          write("replace")(table, id, value),
      };
    },
  };
  return new Proxy(raw, {
    get(target, property, receiver) {
      if (typeof property === "string" && Object.hasOwn(methods, property)) {
        return methods[property];
      }
      const value = Reflect.get(target, property, receiver);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
}

export function guardingRevisions(definition: Definition): Definition {
  const handler =
    typeof definition === "function" ? definition : definition.handler;
  const guarded: Handler = (ctx, args) =>
    handler({ ...ctx, db: guardedDb(ctx.db) }, args);
  return typeof definition === "function"
    ? guarded
    : { ...definition, handler: guarded };
}

vi.mock("./lib/functions", async (importOriginal) => {
  const original = await importOriginal<typeof import("./lib/functions")>();
  const wrap =
    (builder: typeof original.mutation) => (definition: Definition) =>
      builder(guardingRevisions(definition) as never);
  return {
    ...original,
    mutation: wrap(original.mutation),
    internalMutation: wrap(original.internalMutation as never),
  };
});
