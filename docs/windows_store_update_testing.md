# Windows Store update testing checklist

Use this checklist to validate the Windows Store signal in both local and real Store scenarios.

## 1) Local deterministic tests

- Run `flutter test test/update_checker_test.dart`.
- Confirm all mocked paths pass:
  - Windows native update available.
  - Windows native unsupported fallback to remote version file.
  - Invalid remote payload branch.
  - Provider wiring branch.

## 2) Local desktop manual smoke test (non-Store install)

- Run the app normally via `flutter run -d windows`.
- Confirm the app starts and does not crash during startup update check.
- Confirm update prompt behavior still works when remote version indicates update.
- Expected behavior: Windows Store native path is typically unsupported in unpackaged local runs, so fallback logic should be used.

## 3) Real Microsoft Store validation (release confidence)

- Publish a newer package version to a private audience/flight in Partner Center.
- Install an older Store version of the app on a test machine/account.
- Launch the app and verify:
  - Native store update check reports `isSupported: true`.
  - Update signal is marked available when update exists.
  - Update prompt opens Store product page and update can be applied.
- Relaunch after updating and verify update signal is no longer available.

## 4) Regression checks

- Confirm non-Windows behavior remains unchanged.
- Confirm web/other platforms continue to use remote version check.
