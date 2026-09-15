// Independent SVG raster check, in addition to Figma's own PNG comparison.
// npm install --prefix artifacts/svg-render --no-save --ignore-scripts @resvg/resvg-js
// node scripts/figma_map_cleanup/verify_exports.cjs <backup exports directory>
const fs = require("node:fs");
const path = require("node:path");
const assert = require("node:assert/strict");
const { Resvg } = require(
  path.resolve(
    __dirname,
    "../../artifacts/svg-render/node_modules/@resvg/resvg-js",
  ),
);
const directory = path.resolve(process.argv[2]);
const report = JSON.parse(
  fs.readFileSync(path.join(directory, "cleanup-report.json")),
);
assert.equal(report.complete, true);
assert.equal(report.assets.length, 79);
const results = [];
for (const asset of report.assets) {
  const stem = asset.id.replace(":", "-") + "_" + asset.name;
  const before = fs.readFileSync(path.join(directory, stem + ".before.svg"));
  const after = fs.readFileSync(path.join(directory, stem + ".after.svg"));
  const options = {
    fitTo: { mode: "zoom", value: 2 },
    font: { loadSystemFonts: false },
  };
  const a = new Resvg(before, options).render();
  const b = new Resvg(after, options).render();
  assert.equal(a.width, b.width, stem);
  assert.equal(a.height, b.height, stem);
  const identical = a.pixels.equals(b.pixels);
  results.push({
    asset: asset.name,
    nodeId: asset.id,
    width: a.width,
    height: a.height,
    identical,
  });
  assert.ok(identical, "SVG render changed: " + stem);
}
fs.writeFileSync(
  path.join(directory, "independent-svg-verification.json"),
  JSON.stringify(results, null, 2) + "\n",
);
console.log(
  `${results.length} SVG pairs render pixel-identically at 2x in resvg.`,
);
