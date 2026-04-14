# Release Checklist

This project has two Windows release channels:

- Direct desktop installer: updates in-app with `desktop_updater`
- Microsoft Store: updates through the Store

Keep them separate. Run the workflow for the channel you actually want to publish.

## Versioning

- The current app version comes from `pubspec.yaml`.
- The release metadata filename should match the full app version, including the build number.
- Example:
  - `version: 3.2.5+44` in `pubspec.yaml`
  - metadata file: `release/metadata/3.2.5+44.json`
- If you bump first and the app becomes `3.2.6+45`, create or update:
  - `release/metadata/3.2.6+45.json`

## Before Any Release

1. Make sure the branch contains the changes you want to ship.
2. Run the focused validation locally:
   - `fvm flutter test test/update_checker_test.dart`
   - `fvm flutter analyze`
3. Check `pubspec.yaml` and confirm the version you want to release.
4. Create or update the matching release metadata file in `release/metadata/`.
5. Write player-facing release notes in that metadata file.

## Desktop Release Checklist

Use this when you want to publish the direct installer channel.

1. Go to `Actions` in GitHub.
2. Open `Release Desktop`.
3. Click `Run workflow`.
4. Choose:
   - `version_bump`: `none` if the version is already correct, otherwise `patch`, `minor`, or `major`
   - `channel`: `stable`
   - `mandatory`: `false` unless you want to force the update
   - `publish_pages`: `true`
5. Wait for the workflow to finish.
6. Verify the desktop installer artifact was uploaded.
7. Verify GitHub Pages published:
   - `https://sunkenintime.github.io/icarus/updates/windows/stable/app-archive.json`
   - `https://sunkenintime.github.io/icarus/downloads/windows/stable/icarus-setup-latest.exe`
8. Open the published `app-archive.json` and confirm it contains the expected version and notes.
9. Open the stable installer URL and confirm it downloads the current desktop installer.
10. Install the direct desktop build on a test machine.
11. Confirm the app detects the new desktop update and can download/restart successfully.

## Desktop Prerelease Checklist

Use this when you want to validate updater behavior before shipping to `main`.

1. Checkout branch `update/prerelease`.
2. Push the updater changes you want to validate.
3. Go to `Actions` in GitHub.
4. Open `Release Desktop`.
5. Click `Run workflow`.
6. Choose:
   - `version_bump`: `none` if the version is already correct, otherwise `patch`, `minor`, or `major`
   - `channel`: `prerelease`
   - `mandatory`: `false` unless you want to force the update
   - `publish_pages`: `true`
7. Wait for the workflow to finish.
8. Verify GitHub Pages published:
   - `https://sunkenintime.github.io/icarus/updates/windows/prerelease/app-archive.json`
   - `https://sunkenintime.github.io/icarus/downloads/windows/prerelease/icarus-setup-latest.exe`
9. Install an older prerelease desktop build on a test machine and confirm:
   - update prompt appears
   - update downloads fully
   - app exits for restart
   - relaunched app is the new version
   - second cold launch still shows the new version
10. After validation, merge/fix as needed and publish stable from `main`.

## Store Release Checklist

Use this when you want to publish the Microsoft Store channel.

1. Go to `Actions` in GitHub.
2. Open `Release Store`.
3. Click `Run workflow`.
4. Choose:
   - `version_bump`: `none` if the version is already correct, otherwise `patch`, `minor`, or `major`
   - `publish_to_store`: `false` for a dry run, `true` when you are ready to submit
5. Wait for the workflow to finish.
6. Verify the Store package artifact was uploaded.
7. If this was a dry run, download and inspect the artifact.
8. If this was a real publish, confirm the submission appears in Partner Center.
9. Test the Store update path on a machine with an older Store-installed build.

## Common Release Patterns

- Desktop-only update:
  - Run `Release Desktop` only.
- Desktop prerelease validation:
  - Use branch `update/prerelease`.
  - Run `Release Desktop` with `channel=prerelease`.
  - After validation, rerun desktop release on `main` with `channel=stable`.
- Store-only update:
  - Run `Release Store` only.
- Both channels on the same version:
  - Use the same app version and matching metadata, then run both workflows.

## Notes

- Local prerelease publish:
  - `scripts/publish_prerelease_local.ps1` pushes the staged site content to `gh-pages`.
  - GitHub Pages should be configured to serve `gh-pages` from `/ (root)`.
  - No extra Pages deploy workflow is needed for prerelease testing.
- Direct desktop installs now use a per-user install path and per-user registry registration.
- Store installs should continue to use the Microsoft Store update path only.
- The metadata file should not be a generic `template.json` in the live metadata folder, because the manifest generator treats every JSON file there as a real release entry.
