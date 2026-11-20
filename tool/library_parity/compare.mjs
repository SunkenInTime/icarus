export function unsafeNumbers(value, path = "$") {
  if (typeof value === "number") {
    return Number.isFinite(value) && Math.abs(value) <= Number.MAX_SAFE_INTEGER
      ? []
      : [path];
  }
  if (Array.isArray(value)) {
    return value.flatMap((item, index) => unsafeNumbers(item, `${path}[${index}]`));
  }
  if (value !== null && typeof value === "object") {
    return Object.entries(value).flatMap(([key, item]) =>
      unsafeNumbers(item, `${path}.${key}`),
    );
  }
  return [];
}

export function canonical(value) {
  if (value === undefined) return "undefined";
  if (typeof value === "number" && !Number.isFinite(value)) return `#${value}`;
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  const keys = Object.keys(value)
    .filter((key) => value[key] !== undefined)
    .sort();
  return `{${keys.map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`;
}

const tables = [
  ["strategies", (row) => row.publicId],
  ["folders", (row) => row.publicId],
  ["pages", (row) => row.publicId],
  ["settings", (row) => row.pagePublicId],
  ["elements", (row) => row.publicId],
  ["lineupGroups", (row) => `${row.strategyPublicId}/${row.publicId}`],
];

export function keyedRows(rows) {
  const byKey = new Map();
  const duplicates = [];
  for (const [table, keyOf] of tables) {
    const list = rows[table];
    if (!Array.isArray(list)) {
      duplicates.push(`${table} is missing`);
      continue;
    }
    for (const row of list) {
      const key = `${table}:${keyOf(row)}`;
      if (byKey.has(key)) duplicates.push(key);
      byKey.set(key, canonical(row));
    }
  }
  return { byKey, duplicates };
}

export function rowDifferences(server, dart) {
  const ours = keyedRows(server);
  const theirs = keyedRows(dart);
  const differences = [
    ...ours.duplicates.map((key) => ({ key, problem: "the server holds this row twice" })),
    ...theirs.duplicates.map((key) => ({ key, problem: "applyOp holds this row twice" })),
  ];
  for (const key of new Set([...ours.byKey.keys(), ...theirs.byKey.keys()])) {
    const left = ours.byKey.get(key);
    const right = theirs.byKey.get(key);
    if (left !== right) differences.push({ key, server: left, dart: right });
  }
  return differences;
}

export function outcomeOf(result) {
  if (result.status === "rejected") return { status: "rejected", reason: result.reason };
  if (result.status === "failed") return { status: "failed", code: result.code };
  if (result.status === "applied") {
    return { status: "applied", appliedRevision: result.appliedRevision };
  }
  return { status: result.status };
}

export function answerProblems(op, answer) {
  const results = answer?.results;
  if (!Array.isArray(results) || results.length !== 1) {
    return [`the server answered ${Array.isArray(results) ? results.length : "no"} results for one op`];
  }
  if (results[0].opId !== op.opId) {
    return [`the server answered for op ${results[0].opId}, not ${op.opId}`];
  }
  return unsafeNumbers(answer).map((path) => `the server answered ${path}, a number JavaScript cannot compare`);
}

export function outcomeName(type, outcome) {
  return [type, outcome.status, outcome.reason ?? outcome.code]
    .filter((part) => part !== undefined)
    .join(" ");
}
