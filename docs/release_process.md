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

Stable desktop, Store, web beta, and production backend workflows all enter the
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
   `CONVEX_PRODUCTION_DEPLOY_KEY`. Deploy Server enters this environment on
   every server merge, and a stable release enters it three times, so a required
   reviewer means approving each of those, with a release held between its steps.
4. Add the public production URL and a stable client identifier, such as the
   identifier chosen for the shipped Icarus client, to the two GitHub repository
   variables in the previous section.
5. Configure the production deployment's required R2 environment values before
   testing cloud media. The backend reports the exact missing names if they are
   absent.

`Deploy Server` is the one way the backend reaches production. It runs on a
merge (see "Server deploy"), and by hand: run it from `main` and type
`deploy-production`. The workflow enters the GitHub `Production` environment,
requires a `prod:` deploy key, installs locked dependencies, runs TypeScript and
Convex tests, runs `npx convex deploy --typecheck enable`, then deploys the
presence Worker. Convex documents that `CONVEX_DEPLOY_KEY` selects the deployment
associated with that key. See the
[`convex deploy` reference](https://docs.convex.dev/cli/reference/deploy).

The production workflow never reads `CONVEX_PREVIEW_DEPLOY_KEY`. That secret is
only for the isolated contract deployment in CI.

Each `convex-contract` run creates one preview deployment named
`typed-wrapper-contract-<PR number or branch>` and deletes it in its last step,
through the Convex Management API (`POST /v1/deployments/<name>/delete`) with
the same preview deploy key. Right after creating it, the job also sets the
preview to expire in one hour, which covers runs that die before the delete
step. Previews count against the team's deployment quota (40), and when the
quota is full every PR fails with `DeploymentQuotaReached`. To clear leftovers
by hand, list the project's deployments with
`GET /v1/projects/<project id>/list_deployments` using the token in
`~/.convex/config.json`. Then delete only `preview` deployments whose PR is
closed. Never delete `majestic-eel-413` (dev) or the production deployment.

## Server deploy

A push to `main` that changes `convex/`, `presence/`, `package.json` or
`package-lock.json` runs `Deploy Server`, so production always matches `main`.
Markdown files don't count.
It always deploys the tip of `main`, whichever run or commit started it, so a
re-run of an old run or a slow release can't take production backwards.

Because production updates on merge and clients do not, a PR that changes the
Convex contract must stay compatible with the web build already live and with
every shipped desktop build (additive first; see the deploy order in each server
PR). A client change now waits for a release, so a server PR that depends on one
(say, it starts refusing callers that lack a new flag) must wait until a release
has carried the client half. Merging the client PR first is no longer enough.

## Web beta deploy

The web beta lives at `https://beta.icarusstrats.com`, served by the Cloudflare
Pages project `icarus-web` (also reachable at `https://icarus-web-a50.pages.dev`).
It runs against the **production** Convex deployment (`basic-dove-69`), because
it is public. The development deployment (`majestic-eel-413`) stays the place
to try server changes by hand; never test on production.

- A merge does not change the web beta. It ships in a stable `Release Desktop`
  run with `publish_pages` on, built from the version commit, so web and desktop
  report the same version. See "Releasing web and desktop together".
- For a hotfix or redeploy: `Actions` > `Deploy Web` > `Run workflow` on `main`.
  Leave `ref` empty to rebuild the latest `desktop-stable-v...` tag, or name a
  tag or commit. Run it from `main`; the ref must be a commit on `main` that
  contains the latest stable release. Naming a newer commit ships it to web ahead
  of desktop, so do that on purpose. The server deploys first, always from the
  tip of `main`.
- The run summary links the deployment and names the version. To roll back,
  promote an earlier deployment in the Cloudflare dashboard under the project's
  `Deployments`. It stays rolled back until the next release or manual run.

The workflow builds with the same flags as CI's `Build Web Client` step, but
with `ICARUS_CLOUD_ENVIRONMENT=production` and the production URL and client ID
from the repository variables, and uploads `build/web` with `wrangler pages deploy --branch=main`. `main` is the
Pages project's production branch, and the custom domain follows production.
Share links and the auth callback load because Pages serves `index.html` for
unknown paths whenever `build/web` has no top-level `404.html`, so never add
one. `web/_headers` makes browsers revalidate Flutter's unhashed entry
files, so testers get a new deploy on refresh.

Secrets, in the GitHub `Production` environment (step 3 of the one-time
production Convex setup above):

- `CLOUDFLARE_API_TOKEN`: the Cloudflare API token `icarus-web-pages-deploy`,
  scoped to the Icarus account with `Account` > `Cloudflare Pages` > `Edit`
  (the web build) and `Account` > `Workers Scripts` > `Edit` (the presence
  Worker, `presence/README.md`).
- `CLOUDFLARE_ACCOUNT_ID`: the account ID shown on the account's Workers & Pages
  overview.
- `CONVEX_PRODUCTION_DEPLOY_KEY`: a `prod:` deploy key for `basic-dove-69`
  (`npx convex deployment token create <name> --prod`).

The deploy job enters `Production`, so it also reads repository secrets, and an
environment secret overrides a repository secret with the same name ([GitHub's
secrets reference](https://docs.github.com/en/actions/reference/security/secrets)).
Copies kept at repository level therefore keep the deploy working while the
secrets move. Once `Production` has all three, delete the repository copies:
any workflow on any branch can read a repository secret.

GitHub repository variables: `ICARUS_PRODUCTION_CONVEX_DEPLOYMENT_URL`
(`https://basic-dove-69.convex.cloud`) and `ICARUS_PRODUCTION_CONVEX_CLIENT_ID`
(`prod:basic-dove-69`). The production deployment needs the same R2
environment values as development (`npx convex env list --prod`).

One-time Cloudflare setup:

1. Create the direct-upload project with production branch `main`:
   `npx wrangler pages project create icarus-web --production-branch=main`
   (after `npx wrangler login`). The dashboard path is `Workers & Pages` >
   `Create` > `Pages` > `Upload assets`, named `icarus-web`.
2. In the project, open `Custom domains` > `Set up a custom domain`, enter
   `beta.icarusstrats.com`, and activate it. Cloudflare adds the DNS record when
   `icarusstrats.com` is on the same account.

## Releasing web and desktop together

`Release Desktop` with `channel=stable` and `publish_pages=true` is the one
button. It runs, in order:

1. `build`: build, sign, and run the upgrade and rollback test. Upload the files
   to publish, then push the version commit. Everything that tends to fail comes
   first, and nothing is public until this job passes.
2. `web / server`: `Deploy Server`, from the tip of `main`. This changes nothing
   unless the deploy on merge failed.
3. `web / web`: the web build from the version commit, deployed to Pages.
4. `publish`: the GitHub Release and installer, then the updater manifest. This
   job starts as soon as a Windows runner is free after web goes live, and takes
   about two minutes, plus however long GitHub Pages takes to serve the manifest.

Web goes first because it is the easier one to roll back, and desktop reaches
users through the update feed. The version commit is pushed with `GITHUB_TOKEN`,
so it starts no workflow.

`channel=prerelease` and `publish_pages=false` never touch web. A
`publish_pages=false` run stops after `build` with no version commit.

### When a release fails

`Re-run failed jobs` is the fix for anything after `build`. It keeps the commit
and the signed files the run already made, and it works for 30 days. Don't use
`Re-run all jobs`: that rebuilds, and the version commit push is refused because
`main` already has it.

Only the newest release can be finished this way. Once a newer release is public,
re-running an older run stops at web or at `publish` without changing the web
build or the update feed. The server still deploys the tip of `main`, which is
harmless. Abandon the old run; the newer release replaced it. Don't re-run an old
run while another release is in progress, because the newer one isn't public yet
and web won't refuse.

| What failed | What users have | What to do |
| --- | --- | --- |
| `build`, before the version commit | Nothing changed | Fix it and start a new run. |
| Version commit push (`main` moved during the build) | Nothing changed | Start a new run. |
| `web / server`, or `web / web` | Usually nothing changed, except any server deploy that finished. `main` has the version commit. If the job failed after the Pages upload, web may be new. | Check `https://beta.icarusstrats.com/version.json`, then `Re-run failed jobs`. To abandon a run whose web never went live, do nothing: the next release skips this version number. If web did go live, treat it as the next row. |
| `publish`, before the installer went public | New web, old desktop | `Re-run failed jobs`. If that can't work, start a new run with `version_bump=none`: it rebuilds from the tip of `main`, keeps the version, and redeploys web so both match. |
| `publish`, after the installer went public (the manifest push failed) | New web, new installer download, but no update offered | `Re-run failed jobs` only. A new run with `version_bump=none` is refused at the start, because a rebuild can't match a public installer's bytes. |
| A run with `version_bump=none` refused as "already public" | Nothing changed | Re-run the failed run, or use a real version bump. |

If `publish` stays broken and web must not sit ahead of desktop, promote the
previous web deployment in Cloudflare (see "Web beta deploy"), and fix forward
with a new version.

Web ahead of desktop costs little: it is what a merge used to do. Server and
clients stay compatible either way, because of the rule in "Server deploy".

## Desktop Release Checklist

Use this when you want to publish the direct installer channel. On `stable` this
also ships the web beta.

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
10. Open `https://beta.icarusstrats.com/version.json` and confirm it reports the same version.
11. Install the direct desktop build on a test machine.
12. Confirm the app detects the new desktop update and can download/restart successfully.

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

- Web and desktop update:
  - Run `Release Desktop` on `stable`. There is no stable desktop release without web.
- Web-only hotfix:
  - Run `Deploy Web` with the commit as `ref`. Web then runs ahead of desktop until the next release.
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
