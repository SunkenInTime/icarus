// The backend's function log stream: one entry per function execution,
// with the usage it was billed for (usageStats), whether a query answered
// from the cache (cachedResult), and whether a mutation lost a write
// conflict and ran again (occInfo, willRetry). The dashboard and
// `npx convex logs --jsonl` read the same stream.

/// Collects every log entry from the moment it starts.
export class LogStream {
  constructor({ url, adminKey }) {
    this.url = url;
    this.adminKey = adminKey;
    this.entries = [];
    this.cursor = 0;
    this.stopped = false;
    this.error = null;
  }

  start() {
    this.loop = (async () => {
      while (!this.stopped) {
        try {
          const response = await fetch(`${this.url}/api/stream_function_logs?cursor=${this.cursor}`, {
            headers: { Authorization: `Convex ${this.adminKey}` },
          });
          if (!response.ok) throw new Error(`log stream: ${response.status} ${await response.text()}`);
          const { entries, newCursor } = await response.json();
          this.cursor = newCursor;
          this.entries.push(...entries);
        } catch (error) {
          if (this.stopped) return;
          this.error = error;
          await new Promise((resolve) => setTimeout(resolve, 500));
        }
      }
    })();
  }

  stop() {
    this.stopped = true;
  }

  /// Waits for an entry after index [from] that [match] accepts; returns
  /// its index.
  async waitFor(from, match, timeoutMs = 30_000) {
    const deadline = Date.now() + timeoutMs;
    while (true) {
      for (let i = from; i < this.entries.length; i++) {
        if (match(this.entries[i])) return i;
      }
      if (Date.now() > deadline) {
        throw new Error(`No matching log entry within ${timeoutMs} ms${this.error ? `: ${this.error.message}` : ""}`);
      }
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
  }
}

const MARKER = "health:ping";

/// Runs [work] and returns the log entries of every function it made the
/// backend run, live query re-runs included. The window is bounded by a
/// marker call before and after, so it holds exactly what ran in between:
/// the log stream lists executions in the order they finished, and every
/// re-run a mutation causes finishes before the client sees the mutation's
/// result (a Convex client resolves a mutation only once its live queries
/// reflect it).
export async function measure(logs, http, work) {
  const start = await mark(logs, http);
  const value = await work();
  const end = await mark(logs, http);
  // Crons run on the backend's own clock, not because of the flow: their
  // runs and what they call are left out. Anything the flow itself
  // schedules counts, if it finishes inside the window.
  // A call finishes, and is logged, before the action that made it.
  const fromCrons = new Set();
  for (let size = -1; size !== fromCrons.size; ) {
    size = fromCrons.size;
    for (const entry of logs.entries) {
      if (entry.caller === "Cron" || fromCrons.has(entry.parentExecutionId)) fromCrons.add(entry.executionId);
    }
  }
  const entries = logs.entries
    .slice(start + 1, end)
    .filter((entry) => entry.identifier !== MARKER && !fromCrons.has(entry.executionId));
  return { value, entries };
}

async function mark(logs, http) {
  const from = logs.entries.length;
  await http.query(MARKER, {});
  return await logs.waitFor(from, (entry) => entry.identifier === MARKER && entry.caller === "HttpApi");
}

/// Per-function totals of [entries].
export function summarize(entries) {
  const byFunction = new Map();
  const total = { runs: 0, cachedRuns: 0, readBytes: 0, writeBytes: 0, readDocuments: 0, writeDocuments: 0, conflictRetries: 0, failures: 0 };
  for (const entry of entries) {
    if (entry.kind !== "Completion") continue;
    const row = byFunction.get(entry.identifier) ?? {
      udfType: entry.udfType,
      runs: 0,
      cachedRuns: 0,
      readBytes: 0,
      writeBytes: 0,
      readDocuments: 0,
      writeDocuments: 0,
      conflictRetries: 0,
      failures: 0,
    };
    byFunction.set(entry.identifier, row);
    const usage = entry.usageStats ?? {};
    const add = (key, value) => {
      row[key] += value;
      total[key] += value;
    };
    if (entry.cachedResult) {
      add("cachedRuns", 1);
    } else {
      add("runs", 1);
    }
    add("readBytes", usage.databaseReadBytes ?? 0);
    add("writeBytes", usage.databaseWriteBytes ?? 0);
    add("readDocuments", usage.databaseReadDocuments ?? 0);
    add("writeDocuments", usage.databaseWriteDocuments ?? 0);
    // A mutation that lost a write conflict is logged with occInfo and
    // willRetry; the backend then runs it again.
    if (entry.occInfo != null || entry.willRetry) add("conflictRetries", 1);
    else if (entry.error) add("failures", 1);
  }
  return { total, byFunction };
}
