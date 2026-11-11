# shadcn_ui (vendored)

Vendored into Icarus from
[shadcn_ui 0.40.6](https://pub.dev/packages/shadcn_ui/versions/0.40.6)
(MIT, see `LICENSE`). Everything except `example/`, `test/`, the Makefile,
CONTRIBUTING.md and analysis_options.yaml is copied as published. The one
change is in `lib/src/components/button.dart`, marked `ICARUS PATCH`.

## Why this is vendored

Every Icarus button shrinks a little while it's held down (DESIGN.md,
Motion). Most of them are `ShadButton` or `ShadIconButton`, about 200 call
sites, and shadcn_ui has no hook for wrapping a button: no builder in
`ShadButtonTheme`, and its state class is private. Up to 0.59.0 the changelog
adds none.

The patch adds `ShadButtonWrapper`, an inherited widget. When one is above a
`ShadButton`, the button's build output goes through its `wrap` function,
told whether the button can be pressed (enabled, with an `onPressed`).
Without one, the button builds exactly as published. Icarus puts one in
`ShadApp.builder` (`lib/main.dart`) that wraps each button in `PressScale`
(`lib/widgets/press_scale.dart`). Components built on `ShadButton` (icon
buttons, tabs, context menu items, the dialog close button) get it too.

## Upgrading

Copy the new version over this folder, keeping this file, and carry the
`ICARUS PATCH` block in `button.dart` across: the `final button =` in
`_ShadButtonState.build`, the `wrap` call after it, and `ShadButtonWrapper`
at the end of the file. Remove this copy if shadcn_ui gains its own way to
wrap every button.
