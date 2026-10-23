import {
  internalMutation as generatedInternalMutation,
  mutation as generatedMutation,
} from "../_generated/server";
import type { DatabaseWriter, MutationCtx } from "../_generated/server";
import type { Id } from "../_generated/dataModel";

/// Every mutation is defined here, not with the generated builders: these
/// record each strategy's content writes (see lib/contentVersions.ts), so
/// a device can tell whether its offline copy of a strategy is still
/// current (strategy:listContentVersions) without reading it whole.
/// convex/contentVersions.test.ts fails on a module that uses the
/// generated builders directly.
export const mutation = ((definition: MutationDefinition) =>
  generatedMutation(
    countingContentWrites(definition) as Parameters<typeof generatedMutation>[0],
  )) as typeof generatedMutation;

export const internalMutation = ((definition: MutationDefinition) =>
  generatedInternalMutation(
    countingContentWrites(definition) as Parameters<
      typeof generatedInternalMutation
    >[0],
  )) as typeof generatedInternalMutation;

/// The tables a full read of a strategy (strategy:getFullSnapshot) is made
/// of, besides the strategy row: listContentVersions hands out the strategy
/// row itself, with the reader's role, to compare.
const CONTENT_TABLES = [
  "pages",
  "pageContents",
  "elements",
  "lineups",
  "imageAssets",
] as const;
type ContentTable = (typeof CONTENT_TABLES)[number];

type Handler = (ctx: MutationCtx, args: unknown) => unknown;
type MutationDefinition = Handler | { handler: Handler };

function countingContentWrites(definition: MutationDefinition) {
  const handler =
    typeof definition === "function" ? definition : definition.handler;
  const counted: Handler = async (ctx, args) => {
    const writes = new ContentWrites(ctx.db);
    const result = await handler({ ...ctx, db: writes.db }, args);
    await writes.record();
    return result;
  };
  return typeof definition === "function"
    ? counted
    : { ...definition, handler: counted };
}

/// Notes which strategies a transaction writes content of, through a
/// database that is otherwise the transaction's own.
class ContentWrites {
  readonly db: DatabaseWriter;
  private readonly strategies = new Set<Id<"strategies">>();
  /// Pages this transaction wrote, so contents written after their page
  /// was deleted still find their strategy.
  private readonly pageStrategies = new Map<Id<"pages">, Id<"strategies">>();

  constructor(private readonly raw: DatabaseWriter) {
    const writes = this;
    const methods: Record<string, unknown> = {
      insert: (table: string, value: Record<string, unknown>) =>
        writes.insert(table, value),
      patch: (...args: unknown[]) => writes.change("patch", args),
      replace: (...args: unknown[]) => writes.change("replace", args),
      delete: (...args: unknown[]) => writes.change("delete", args),
    };
    this.db = new Proxy(raw, {
      get(target, property, receiver) {
        if (typeof property === "string" && property in methods) {
          return methods[property];
        }
        const value = Reflect.get(target, property, receiver);
        return typeof value === "function" ? value.bind(target) : value;
      },
    });
  }

  private async insert(table: string, value: Record<string, unknown>) {
    const id = await (
      this.raw.insert as (t: string, v: unknown) => Promise<string>
    )(table, value);
    if (isContentTable(table)) {
      await this.note(table, { ...value, _id: id });
    }
    return id;
  }

  /// patch, replace and delete, with or without the table name first.
  private async change(method: "patch" | "replace" | "delete", args: unknown[]) {
    const named = args.length === (method === "delete" ? 2 : 3);
    const id = (named ? args[1] : args[0]) as string;
    const table = named
      ? (args[0] as string)
      : CONTENT_TABLES.find((name) => this.raw.normalizeId(name, id) !== null);
    if (table !== undefined && isContentTable(table)) {
      // Read before the write: a deleted row can't say whose it was.
      const row = await this.raw.get(id as Id<ContentTable>);
      if (row !== null) await this.note(table, row);
    }
    return await (this.raw[method] as (...a: unknown[]) => Promise<void>)(
      ...args,
    );
  }

  private async note(table: ContentTable, row: Record<string, unknown>) {
    if (table === "pages") {
      const strategyId = row.strategyId as Id<"strategies">;
      this.pageStrategies.set(row._id as Id<"pages">, strategyId);
      this.strategies.add(strategyId);
      return;
    }
    if (table === "pageContents") {
      const pageId = row.pageId as Id<"pages">;
      const page = await this.raw.get(pageId);
      const strategyId = page?.strategyId ?? this.pageStrategies.get(pageId);
      // Contents left behind by a page deleted earlier show in no read.
      if (strategyId !== undefined) this.strategies.add(strategyId);
      return;
    }
    this.strategies.add(row.strategyId as Id<"strategies">);
  }

  /// One change row for each strategy written, in the same transaction as
  /// the writes. Only an insert: reading anything here would make edits to
  /// one strategy from two devices collide.
  async record() {
    for (const strategyId of this.strategies) {
      await this.raw.insert("strategyContentChanges", { strategyId });
    }
  }
}

function isContentTable(table: string): table is ContentTable {
  return (CONTENT_TABLES as readonly string[]).includes(table);
}
