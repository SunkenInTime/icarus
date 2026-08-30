# Anonymous analytics

Icarus sends a deliberately small set of anonymous product events to PostHog.
Analytics is enabled by default, can be disabled under **Settings > Privacy**, and
is inactive in builds that do not include a PostHog project token.

## Build configuration

Set `POSTHOG_PROJECT_TOKEN` before running `scripts/build_desktop_release.ps1`.
The script passes it to Flutter through a temporary Dart-defines file. For an
EU PostHog project, also set `POSTHOG_HOST=https://eu.i.posthog.com`; the default
is the US host.

The `release-desktop.yml` and `release-store.yml` GitHub Actions workflows read
the token from the `POSTHOG_PROJECT_TOKEN` repository secret. The build scripts
place it in a temporary Dart-defines file so it is not printed in Actions logs,
then delete the file immediately after the build.

The project token is a public ingestion token, not a private API key. Never use
a PostHog personal API key here.

For local development:

```powershell
fvm flutter run -d windows --dart-define=POSTHOG_PROJECT_TOKEN=phc_your_project_token
```

## Event schema

| Event | Properties | Purpose |
| --- | --- | --- |
| `app_opened` | Common properties only | Anonymous active-user and retention counts |
| `strategy_created` | Common properties only | Core activation |
| `strategy_imported` | Common properties only | Import adoption |
| `lineup_created` | `has_video`, `has_notes`, `has_images` | Lineup feature adoption without collecting content |
| `content_exported` | `content_type` (`strategy`, `folder`, or `library`) | Export and backup adoption |

Every event has a random installation ID, app version, build number, release
channel, and platform. Events set `$process_person_profile` to `false` and
`$geoip_disable` to `true`. Icarus does not collect names, file paths, strategy
content, URLs, notes, images, screen views, recordings, errors, or device details.
The PostHog project must also keep **Settings > Privacy > Discard client IP
data** enabled so the transport IP is removed after ingestion. This is enabled
for the production Icarus project.

Development smoke tests should set
`ICARUS_ANALYTICS_ENVIRONMENT=development`. Production builds default to
`analytics_environment=production`, making test events easy to exclude from
insights.
