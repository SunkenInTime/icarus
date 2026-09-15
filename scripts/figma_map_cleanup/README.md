This local development plugin cleans the map assets in `Icarus Maps Latest One`. It is pinned to that document's page and node IDs. It does not discover or modify arbitrary Figma files.

The September 4, 2026 run covered 79 assets on Map Assets. That includes 27 base maps, 26 callout overlays, 13 spawn-wall overlays, and 13 ultimate-orb overlays. The duplicate Split defense asset is retained.

Before running it, save a local `.fig` copy through Figma's File menu. Start the receiver with a dedicated backup directory, import `manifest.json` through Figma's development-plugin menu, and use the plugin's button.

```powershell
python scripts/figma_map_cleanup/receive.py '<backup directory>/exports'
```

The plugin exports every original SVG and a 2x PNG before editing. It also clones the page contents into a hidden, locked group on the same page. This avoids adding a fourth page to the free-plan document. The full `.fig` copy remains the recovery source for the original document.

The cleanup names layers and groups contiguous siblings. It keeps source paths, boolean operations, masks, instances, paint order, sizing shapes, and export-root names. The legacy `sunsent_map` spelling remains stable. Nothing is flattened or deleted.

Each asset must retain its width, height, position, and byte-identical Figma PNG. The geometry tolerance is 0.001 Figma units to accommodate grouping arithmetic. The actual largest change was 0.00003052 units, on one Bind defense detail. All asset dimensions remained exactly equal. Each completed asset has its own undo step.

The receiver binds only to loopback, accepts simple filenames, and refuses to overwrite evidence with different bytes. On Windows, stop the receiver's Python process when finished; interrupting its parent shell may leave Python running. Do not leave multiple receivers on the same port.

The plugin can resume after an interrupted export transport. It reads the saved originals, checks completed assets against them, and continues from the first missing result. A failed visual comparison requires inspection and undo of the last asset before any continuation. Do not dismiss a visual failure by widening the geometry tolerance.

Run the independent SVG render check after completion:

```powershell
npm install --prefix artifacts/svg-render --no-save --ignore-scripts @resvg/resvg-js
node scripts/figma_map_cleanup/verify_exports.cjs '<backup directory>/exports'
```

The renderer installation lives in the ignored artifacts directory. The plugin does not update repository map SVGs or Icarus runtime constants.
