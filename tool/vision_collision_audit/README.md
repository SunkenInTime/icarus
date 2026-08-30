# Vision collision audit

This local tool maps a missing collision boundary once and applies it to every
vision elevation. A `shared` boundary is also mirrored onto the defense map;
side- or elevation-specific exceptions remain available when the artwork truly
differs.

From the repository root:

```powershell
dart run tool/vision_collision_audit/serve.dart
```

Open `http://127.0.0.1:14317`, choose a map, then either trace a visible SVG
shape or draw an open/closed boundary. **Save manifest** writes the validated
result to `assets/maps/vision_boundary_additions.json`.

The app loads that asset at runtime. Additions use normalized SVG coordinates,
so they remain stable if the rendered map size changes. Omit
`activeElevations` (the tool's default) to enable a boundary on every layer.
