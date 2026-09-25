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

1. Check the branch. Stable desktop and every Store build must run from
   `main`. The release scripts stop before a version bump or build on any other
   branch. The scripts still build an unsigned desktop prerelease from a
   feature branch for local testing, but the signed `Release Desktop` workflow
   runs only from `main`.
2. Run the focused validation locally:
   - `fvm flutter test test/update_checker_test.dart`
   - `fvm flutter test test/cloud_build_config_test.dart`
   - `powershell -ExecutionPolicy Bypass -File scripts/test_release_safety.ps1`
   - `fvm flutter analyze`
3. Check `pubspec.yaml` and confirm the version you want to release.
4. Create or update the matching release metadata file in `release/metadata/`.
5. Write player-facing release notes in that metadata file.

## Cloud build configuration

Icarus has one named development Convex configuration in source. Local
development, CI, and desktop prerelease builds select it with
`ICARUS_CLOUD_ENVIRONMENT=development`.

An ordinary debug run defaults to development. A release-mode app with no
`ICARUS_CLOUD_ENVIRONMENT` stops during startup, so any new release entry point
must choose `development` or `production` deliberately.

Stable desktop and Store builds select `production` and require both of these
GitHub repository variables:

- `ICARUS_PRODUCTION_CONVEX_DEPLOYMENT_URL`
- `ICARUS_PRODUCTION_CONVEX_CLIENT_ID`

The production URL and client ID are public build inputs, not deploy keys. The
release scripts pass them to Flutter through a temporary Dart-defines file and
delete that file after the build. A missing value, invalid URL, or the known
development deployment stops the release before Flutter runs.

Use the deployment's canonical `https://<deployment>.convex.cloud` client URL.
The release validator does not accept custom domains, and `.convex.site` is the
HTTP Actions URL rather than the client deployment URL. See Convex's
[deployment URL guide](https://docs.convex.dev/client/react/deployment-urls)
and [system environment URL definitions](https://docs.convex.dev/production/environment-variables).

Stable desktop, Store, and production backend workflows all enter the protected
GitHub `Production` environment before they can build or publish. Desktop
prerelease skips that environment.

For a local stable build, set the same two environment variables in the shell
before running `scripts/release_desktop.ps1`. Never put a Convex deploy key in a
Dart define or repository variable.

## One-time production Convex setup

No production deployment or key is checked into this repository. Before the
first production release:

1. Create or select the Icarus production deployment in Convex. Record its
   `.convex.cloud` client URL in the repository variable above.
2. Create a deployment-scoped production deploy key with only the permissions
   needed to deploy. Convex supports this in the deployment settings or with
   `npx convex deployment token create github-production --deployment prod`.
   See the [Convex deploy-key documentation](https://docs.convex.dev/cli/deploy-key-types).
3. Create a GitHub environment named `Production`. Restrict its deployment
   branches to `main`, add any required reviewers, and add the secret
   `CONVEX_PRODUCTION_DEPLOY_KEY`.
4. Add the public production URL and a stable client identifier, such as the
   identifier chosen for the shipped Icarus client, to the two GitHub repository
   variables in the previous section.
5. Configure the production deployment's required R2 environment values before
   testing cloud media. The backend reports the exact missing names if they are
   absent.

Run the manual `Deploy Convex Production` workflow from `main` and type
`deploy-production`. The workflow enters the GitHub `Production` environment,
requires a `prod:` deploy key, installs locked dependencies, runs TypeScript and
Convex tests, then runs `npx convex deploy --typecheck enable`. Convex documents
that `CONVEX_DEPLOY_KEY` selects the deployment associated with that key. See
the [`convex deploy` reference](https://docs.convex.dev/cli/reference/deploy).

The production workflow never reads `CONVEX_PREVIEW_DEPLOY_KEY`. That secret is
only for the isolated contract deployment in CI.

## Web beta deploy

The web beta lives at `https://beta.icarusstrats.com`, served by the Cloudflare
Pages project `icarus-web` (also reachable at `https://icarus-web-a50.pages.dev`).
It uses the development Convex deployment, like every non-stable build.

- A push to `icarus-cloud` that changes `lib/`, `web/`, `assets/`, `shaders/`,
  a path package (`packages/`, `third_party/convex_flutter/`), `pubspec.yaml`,
  `pubspec.lock`, or `.fvmrc` deploys automatically.
- To redeploy by hand: `Actions` > `Deploy Web` > `Run workflow` on
  `icarus-cloud`. GitHub only shows that button once the workflow is on the
  default branch; until then, re-run the latest `Deploy Web` run.
- The run summary links the deployment. To roll back, promote an earlier
  deployment in the Cloudflare dashboard under the project's `Deployments`.

The workflow builds with the same command as CI's `Build Web Client` step and
uploads `build/web` with `wrangler pages deploy --branch=main`. `main` is the
Pages project's production branch, and the custom domain follows production.
Share links and the auth callback load because Pages serves `index.html` for
unknown paths whenever `build/web` has no top-level `404.html`, so never add
one. `web/_headers` makes browsers revalidate Flutter's unhashed entry
files, so testers get a new deploy on refresh.

GitHub repository secrets:

- `CLOUDFLARE_API_TOKEN`: a Cloudflare API token with one permission,
  `Account` > `Cloudflare Pages` > `Edit`, scoped to the Icarus account.
- `CLOUDFLARE_ACCOUNT_ID`: the account ID shown on the account's Workers & Pages
  overview.

One-time Cloudflare setup:

1. Create the direct-upload project with production branch `main`:
   `npx wrangler pages project create icarus-web --production-branch=main`
   (after `npx wrangler login`). The dashboard path is `Workers & Pages` >
   `Create` > `Pages` > `Upload assets`, named `icarus-web`.
2. In the project, open `Custom domains` > `Set up a custom domain`, enter
   `beta.icarusstrats.com`, and activate it. Cloudflare adds the DNS record when
   `icarusstrats.com` is on the same account.

## Desktop Release Checklist

Use this when you want to publish the direct installer channel.

1. Go to `Actions` in GitHub.
2. Open `Release Desktop`.
3. Confirm the selected branch is `main`, then click `Run workflow`.
4. Choose:
   - `version_bump`: `none` if the version is already correct, otherwise `patch`, `minor`, or `major`
   - `channel`: `stable`
   - `mandatory`: `false` unless you want to force the update
   - `publish_pages`: `true`
5. Wait for the workflow to finish.
6. Verify the desktop installer artifact was uploaded.
7. Verify the updater manifest and GitHub Release installer are published:
   - `https://sunkenintime.github.io/icarus/updates/windows/stable/app-archive.json`
   - `https://github.com/SunkenInTime/icarus/releases/latest/download/icarus-setup.exe`
8. Open the published `app-archive.json` and confirm it contains the expected version and notes.
9. Open the stable installer URL and confirm it downloads the current desktop installer.
10. Install the direct desktop build on a test machine.
11. Confirm the app detects the new desktop update and can download/restart successfully.

## Desktop Prerelease Checklist

Use this to validate updater behavior before publishing to the stable channel.
Signed releases run from `main`, matching the Azure federated credential.

1. Merge the reviewed changes into `main`.
2. Select `main` as the workflow branch.
3. Go to `Actions` in GitHub.
4. Open `Release Desktop`.
5. Click `Run workflow`.
6. Choose:
   - `version_bump`: `none` if the version is already correct, otherwise `patch`, `minor`, or `major`
   - `channel`: `prerelease`
   - `mandatory`: `false` unless you want to force the update
   - `publish_pages`: `true`
7. Wait for the workflow to finish.
8. Verify GitHub Pages published the updater and a GitHub prerelease contains the installer:
   - `https://sunkenintime.github.io/icarus/updates/windows/prerelease/app-archive.json`
   - `https://github.com/SunkenInTime/icarus/releases/download/desktop-prerelease-v<VERSION+BUILD>/icarus-setup.exe`
9. Install an older prerelease desktop build on a test machine and confirm:
   - update prompt appears
   - update downloads fully
   - app exits for restart
   - relaunched app is the new version
   - second cold launch still shows the new version
10. After validation, publish stable from `main`.

## Store Release Checklist

Use this when you want to publish the Microsoft Store channel.

1. Go to `Actions` in GitHub.
2. Open `Release Store`.
3. Confirm the selected branch is `main`, then click `Run workflow`.
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
  - Use branch `main`.
  - Run `Release Desktop` with `channel=prerelease`.
  - After validation, rerun desktop release on `main` with `channel=stable`.
- Store-only update:
  - Run `Release Store` only.
- Both channels on the same version:
  - Use the same app version and matching metadata, then run both workflows.

## Notes

- Installers are GitHub Release assets because they exceed Git's 100 MiB blob limit. The stable download link follows the latest stable GitHub Release; prereleases use their exact tag.
- Existing desktop users still update through the same Pages manifest and per-file payload. Moving the installer does not require reinstalling Icarus.
- The signed installer is published before the updater manifest. The new payload and manifest are pushed together, preserving earlier payload folders for downloads already in progress.
- Never reuse a publicly published build number. If publication fails after an updater went live, increment the build number before rebuilding.
- The `publish_pages` workflow input controls both GitHub Release and Pages publication. With it disabled, all output stays in workflow artifacts.
- Local prerelease publish:
  - `scripts/publish_prerelease_local.ps1` cannot publish an unsigned build. Use `Release Desktop` on `main` with `channel=prerelease` for signing and publication.
  - The shared scripts verify EXE and DLL signatures before packaging, staging, and pushing Pages content. Manual phased releases require signing between build and package, then signing the installer before stage.
  - GitHub Pages should be configured to serve `gh-pages` from `/ (root)`.
  - No extra Pages deploy workflow is needed for prerelease testing.
- `release/metadata/4.6.1+97.json` is prerelease-only while the online beta
  checks remain open. Do not add `stable` to its channels to make a stable
  manifest build pass.
- Direct desktop installs now use a per-user install path and per-user registry registration.
- Store installs should continue to use the Microsoft Store update path only.
- The metadata file should not be a generic `template.json` in the live metadata folder, because the manifest generator treats every JSON file there as a real release entry.

## Azure signing setup and first verification

GitHub repository secrets: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and
`AZURE_SUBSCRIPTION_ID`. Repository variables:
`AZURE_ARTIFACT_SIGNING_ENDPOINT`, `AZURE_ARTIFACT_SIGNING_ACCOUNT`, and
`AZURE_ARTIFACT_SIGNING_PROFILE`.

The Azure application needs a federated credential with issuer
`https://token.actions.githubusercontent.com`, audience
`api://AzureADTokenExchange`, and subject
`repo:SunkenInTime@76637177/icarus@890026480:ref:refs/heads/main`.
This repository uses GitHub's immutable OIDC subject format. Check it with
`gh api repos/SunkenInTime/icarus/actions/oidc/customization/sub`:
`use_immutable_subject` must be `true`, and `sub_claim_prefix` must match the
repository portion of the Azure subject. A legacy subject without the numeric
IDs does not match this credential and causes Azure login error `AADSTS700213`.
See [GitHub's OIDC reference](https://docs.github.com/en/actions/reference/security/oidc#immutable-subject-claims).

Assign its service principal the
Artifact Signing Certificate Profile Signer role on the signing profile.
The public trust identity validation and certificate profile must be active.

After merging the signing workflow, first run it on `main` with
`version_bump=none`, `channel=prerelease`, and `publish_pages=false`.
This signs and verifies artifacts without publishing Pages or committing
version/metadata changes. Download the installer artifact, check its expected
publisher in Windows, and test installation and launch. Then publish a
prerelease and test updating an older prerelease installation before stable.

A green PR check validates code and the signature rejection gates. It does not
prove Azure login, signing permissions, or an end-to-end signed release works.
