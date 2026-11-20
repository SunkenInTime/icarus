import assert from "node:assert/strict";
import test from "node:test";
import { canonical, rowDifferences, unsafeNumbers } from "./compare.mjs";
import { corpusProblems, missingCoverage, mustReach, reportProblems } from "./run.mjs";

const rows = () => ({
  strategies: [{ publicId: "s1", name: "Retake", mapData: "ascent", revision: 1 }],
  folders: [],
  pages: [{ publicId: "p0", strategyPublicId: "s1", name: "Page 1", sortIndex: 0, isAttack: true, revision: 1, deleted: false }],
  settings: [{ pagePublicId: "p0", revision: 1 }],
  elements: [],
  lineupGroups: [],
});

test("identical rows have no differences", () => {
  assert.deepEqual(rowDifferences(rows(), rows()), []);
});

test("a page the server gave two settings rows is a difference", () => {
  const server = rows();
  server.settings.push({ pagePublicId: "p0", revision: 1 });
  assert.deepEqual(
    rowDifferences(server, rows()).map((difference) => difference.problem),
    ["the server holds this row twice"],
  );
});

test("a row applyOp lists twice is a difference", () => {
  const dart = rows();
  dart.pages.push(dart.pages[0]);
  assert.equal(rowDifferences(rows(), dart).length, 1);
});

test("a strategy moved out of its folder is a difference", () => {
  const dart = rows();
  dart.strategies[0].folderPublicId = "f-root";
  assert.equal(rowDifferences(rows(), dart).length, 1);
});

test("numbers JavaScript cannot hold are refused, not rounded", () => {
  const parsed = JSON.parse('{"data":{"x":9007199254740993},"ok":9007199254740991}');
  assert.deepEqual(unsafeNumbers(parsed), ["$.data.x"]);
});

test("the comparison does not depend on key order but does on types", () => {
  assert.equal(canonical({ a: 1, b: [2, { c: 3 }] }), canonical({ b: [2, { c: 3 }], a: 1 }));
  assert.notEqual(canonical({ a: 1 }), canonical({ a: "1" }));
  assert.equal(canonical({ a: 1, b: undefined }), canonical({ a: 1 }));
});

test("a generator that drops a sequence or shortens one fails", () => {
  const scenario = (seed, length) => ({ seed, ops: Array(length), predicted: Array(length) });
  assert.deepEqual(corpusProblems([0, 1], 3, [scenario(0, 3), scenario(1, 3)]), []);
  assert.equal(corpusProblems([0, 1], 3, [scenario(0, 3)]).length, 1);
  assert.equal(corpusProblems([0, 1], 3, [scenario(0, 3), scenario(1, 2)]).length, 1);
});

test("a server run that skips a sequence or stops early fails", () => {
  assert.deepEqual(reportProblems([0, 1], 3, [{ seed: 0, compared: 3 }, { seed: 1, compared: 3 }]), []);
  assert.equal(reportProblems([0, 1], 3, [{ seed: 0, compared: 3 }]).length, 1);
  assert.equal(reportProblems([0, 1], 3, [{ seed: 0, compared: 3 }, { seed: 1, compared: 1 }]).length, 1);
});

test("reaching each required outcome once is not enough coverage", () => {
  const once = Object.fromEntries(Object.keys(mustReach).map((outcome) => [outcome, 1]));
  assert.equal(missingCoverage(once).length, Object.keys(mustReach).length);
});
