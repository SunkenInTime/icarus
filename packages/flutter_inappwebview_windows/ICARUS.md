# flutter_inappwebview_windows (vendored)

Vendored into Icarus from
[flutter_inappwebview_windows 0.6.0](https://pub.dev/packages/flutter_inappwebview_windows/versions/0.6.0)
(Apache 2.0, see `LICENSE`), the Windows half of `flutter_inappwebview` 6.1.5.
Everything except `example/` is copied as published; the one change is marked
`ICARUS PATCH`.

## Why this is vendored

Icarus crashed every time it closed on Windows
([#865](https://github.com/SunkenInTime/icarus/issues/865)). The window was
already gone, so nobody saw it, but the process ended in a crash instead of
exiting, on every close of every build since at least 5.0.2.

The plugin creates a Windows composition compositor when it registers and
keeps it in a static pointer. `~InAppWebViewManager()` cleared the web views
and left the compositor, so its last release happened from this DLL's exit
table, after `ExitProcess` had begun and the dispatcher it belongs to was
gone. Registering the plugin was enough: no web view had to be opened.

The patch is one line in
`windows/in_app_webview/in_app_webview_manager.cpp`: the destructor releases
the compositor right after it clears the web views, while the app is still
shutting down in order.

## What the patch assumes

The compositor is shared by every `InAppWebViewManager` in the process, and
it is created only once. Icarus has one Flutter engine and so one manager. An
app with two engines would lose the compositor for the second when the first
one's manager went away.

## When to remove this copy

Upstream's report is
[flutter_inappwebview #2733](https://github.com/pichillilorenzo/flutter_inappwebview/issues/2733),
still open when this was vendored, with stable at 0.6.0. Remove this copy and
the override in `pubspec.yaml` when Icarus moves to a release that exits
cleanly: build a release, close its window, and check the exit code with
`tool/drive/release-close.ps1`.
