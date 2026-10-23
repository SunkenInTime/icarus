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
    countingContentWrites(definition) as Parameters<
      typeof generatedMutation
    >[0],
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

/// Exported for tests, which run handlers through it directly.
export function countingContentWrites(definition: MutationDefinition) {
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
  /// Whose each content row this transaction has seen is: the strategy, or
  /// for page contents the page. A row changes hands only through a write
  /// that names its new owner, which counts for both (see [change]), so a
  /// write to a row the handler already read needs no second read.
  private readonly owners = new Map<string, string>();

  constructor(private readonly raw: DatabaseWriter) {
    const writes = this;
    const methods: Record<string, unknown> = {
      get: (...args: unknown[]) => writes.get(args),
      query: (table: string) => writes.query(table),
      insert: (table: string, value: Record<string, unknown>) =>
        writes.insert(table, value),
      patch: (...args: unknown[]) => writes.change("patch", args),
      replace: (...args: unknown[]) => writes.change("replace", args),
      delete: (...args: unknown[]) => writes.change("delete", args),
      // ctx.db.table(name).insert(...) and friends: the same methods, with
      // the table named first.
      table: (table: string) => ({
        get: (id: unknown) => writes.get([table, id]),
        query: () => writes.query(table),
        insert: (value: Record<string, unknown>) => writes.insert(table, value),
        patch: (id: unknown, value: unknown) =>
          writes.change("patch", [table, id, value]),
        replace: (id: unknown, value: unknown) =>
          writes.change("replace", [table, id, value]),
        delete: (id: unknown) => writes.change("delete", [table, id]),
      }),
    };
    this.db = new Proxy(raw, {
      get(target, property, receiver) {
        if (typeof property === "string" && Object.hasOwn(methods, property)) {
          return methods[property];
        }
        const value = Reflect.get(target, property, receiver);
        return typeof value === "function" ? value.bind(target) : value;
      },
    });
  }

  private async get(args: unknown[]) {
    const row = await (this.raw.get as (...a: unknown[]) => Promise<unknown>)(
      ...args,
    );
    const table =
      args.length === 2 ? (args[0] as string) : this.tableOf(args[0]);
    if (table !== undefined) this.remember(table, row);
    return row;
  }

  /// The query, with whatever content rows it returns remembered.
  private query(table: string) {
    const query = (this.raw.query as (t: string) => object)(table);
    return isContentTable(table) ? this.watch(table, query) : query;
  }

  private watch(table: ContentTable, target: object): object {
    const writes = this;
    return new Proxy(target, {
      get(target, property, receiver) {
        const value = Reflect.get(target, property, receiver);
        if (typeof value !== "function") return value;
        return (...args: unknown[]) => {
          const result = value.apply(target, args);
          if (result instanceof Promise) {
            return result.then((answer) => {
              writes.remember(table, answer);
              return answer;
            });
          }
          return result !== null && typeof result === "object"
            ? writes.watch(table, result)
            : result;
        };
      },
    });
  }

  /// Rows, lists of rows, pages of rows and iterator steps alike.
  private remember(table: string, answer: unknown): void {
    if (
      !isContentTable(table) ||
      answer === null ||
      typeof answer !== "object"
    ) {
      return;
    }
    if (Array.isArray(answer)) {
      for (const row of answer) this.remember(table, row);
      return;
    }
    const value = answer as Record<string, unknown>;
    if (Array.isArray(value.page)) return this.remember(table, value.page);
    if ("done" in value && "value" in value) {
      return this.remember(table, value.value);
    }
    const owner = table === "pageContents" ? value.pageId : value.strategyId;
    if (typeof value._id === "string" && typeof owner === "string") {
      this.owners.set(value._id, owner);
    }
  }

  private async insert(table: string, value: Record<string, unknown>) {
    const id = await (
      this.raw.insert as (t: string, v: unknown) => Promise<string>
    )(table, value);
    if (isContentTable(table)) {
      this.remember(table, { ...value, _id: id });
      await this.note(table, id);
    }
    return id;
  }

  /// patch, replace and delete, with or without the table name first.
  private async change(
    method: "patch" | "replace" | "delete",
    args: unknown[],
  ) {
    const named = args.length === (method === "delete" ? 2 : 3);
    const id = (named ? args[1] : args[0]) as string;
    const table = named ? (args[0] as string) : this.tableOf(id);
    if (table === undefined || !isContentTable(table)) {
      return await (this.raw[method] as (...a: unknown[]) => Promise<void>)(
        ...args,
      );
    }
    // Before the write: a deleted row can't say whose it was.
    await this.note(table, id);
    await (this.raw[method] as (...a: unknown[]) => Promise<void>)(...args);
    // A write that gives the row a new owner counts for that one too.
    const value = (named ? args[2] : args[1]) as
      | Record<string, unknown>
      | undefined;
    const newOwner =
      table === "pageContents" ? value?.pageId : value?.strategyId;
    if (typeof newOwner === "string" && newOwner !== this.owners.get(id)) {
      this.owners.set(id, newOwner);
      await this.note(table, id);
    }
  }

  private tableOf(id: unknown): ContentTable | undefined {
    if (typeof id !== "string") return undefined;
    return CONTENT_TABLES.find(
      (name) => this.raw.normalizeId(name, id) !== null,
    );
  }

  /// Notes the strategy that content row [id] of [table] belongs to.
  private async note(table: ContentTable, id: string) {
    let owner = this.owners.get(id);
    if (owner === undefined) {
      this.remember(table, await this.raw.get(id as Id<ContentTable>));
      owner = this.owners.get(id);
    }
    if (owner === undefined) return;
    if (table !== "pageContents") {
      this.strategies.add(owner as Id<"strategies">);
      return;
    }
    // A page deleted earlier in this transaction is remembered here.
    let strategyId = this.owners.get(owner);
    if (strategyId === undefined) {
      this.remember("pages", await this.raw.get(owner as Id<"pages">));
      strategyId = this.owners.get(owner);
    }
    // Contents left behind by a page deleted earlier show in no read.
    if (strategyId !== undefined) {
      this.strategies.add(strategyId as Id<"strategies">);
    }
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
