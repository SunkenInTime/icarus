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
keeps it in a static pointer. Nothing released it before the process began to
exit, so its last release, and with it the compositor's whole teardown, ran
from this DLL's exit table after `ExitProcess` had begun. Registering the
plugin was enough: no web view had to be opened.

## The patch

One change in `windows/in_app_webview/in_app_webview_manager.cpp`: right after
the compositor is created, the plugin takes one more reference to it and
never gives it back. The static pointer's release at exit is then not the
last one, the compositor is never torn down by this process, and Windows
frees it with the process. This is the change upstream made in
0.7.0-beta.3, applied on its own to 0.6.0.

Releasing things earlier does not work. Measured on Windows 11, three closes
each, over four ways of ending a session (the video panel opened and
dismissed, the player still open, no web view ever shown, and the test
driver's own `exit`):

| Change | Dismissed | Open | No web view | Driver exit |
|---|---|---|---|---|
| None | crash | crash | crash | crash |
| Release the compositor in the manager's destructor | crash | crash | 0 | crash |
| Release the compositor, graphics context, dispatcher controller and WinRT helper there, in order | 0 | 0 | 0 | crash |
| One more reference to the compositor (this patch) | 0 | 0 | 0 | 0 |

## What the patch leaves behind

One COM reference to the compositor for the life of the process, taken once
when the plugin first sets itself up, not once per web view. Web views are
still disposed as before. The compositor and what it owns stay alive until
the process ends.

## When to remove this copy

Upstream's report is
[flutter_inappwebview #2733](https://github.com/pichillilorenzo/flutter_inappwebview/issues/2733).
Remove this copy and the override in `pubspec.yaml` when Icarus moves to a
stable release that carries the same change, and check it the way this was
checked: `tool/drive/release-close.ps1` on a release build, and the driver
scripts `close-with-video-open` and `close-after-video-dismissed` with the
exit judged.
