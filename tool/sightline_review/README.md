# Sightline review

A browser workbench for moving cones and annotating map contacts. Height selection
and cone queries run through the production `SvgHeightVisibility` model and native
SVG engine. The browser displays the bundled artwork, clips cones to its floor
fill, and adds review marks. It does not reproduce Flutter's overlay styling.

Run from PowerShell:

```powershell
./tool/sightline_review/start.ps1
```

The default address is `http://127.0.0.1:8770`. The launcher accepts `-Flutter`,
`-NativeLibrary`, `-Port`, and `-OutputDirectory`. It uses `flutter test` as the
host because the production model imports `dart:ui`. The server test is skipped
unless its review output environment variable is supplied.

To expose this server on Tailscale, choose an unused HTTPS port:

```powershell
tailscale serve --bg --https=8444 http://127.0.0.1:8770
```

Use `tailscale serve status` to obtain the private address. Do not reset other
Serve routes. Stop this route with `tailscale serve --https=8444 off`.

Drag the round handle to move a cone, or click the map with Move cone selected.
Drag the diamond to change direction and range. Select a standing surface after
placing the observer over it. Scroll to zoom, or hold Space while dragging to pan.

Save review writes a new JSON scene and annotated PNG to the output directory.
The scene includes model, artwork, and native library hashes, selected surfaces,
annotations, notes, and computed cone polygons. Each save has a replay link.
Drafts stay in browser storage by map and side; save them before clearing browser
data. These review files are separate from the Icarus library.
