#!/bin/sh

set -eu

: "${PROFILE_OUTPUT_DIR:?Set PROFILE_OUTPUT_DIR to an empty output directory}"
: "${SUPABASE_URL:?Set SUPABASE_URL}"
: "${SUPABASE_KEY:?Set SUPABASE_KEY to the public anon key}"
: "${TEST_EMAIL:?Set TEST_EMAIL to the disposable account}"
: "${TEST_PASSWORD:?Set TEST_PASSWORD to the disposable account}"
: "${CONVEX_SELF_HOSTED_ADMIN_KEY:?Set CONVEX_SELF_HOSTED_ADMIN_KEY for the isolated deployment}"

profile_tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
runtime_dir=$(CDPATH= cd -- "$profile_tool_dir/.." && pwd)
repo_dir=$(CDPATH= cd -- "$runtime_dir/../../.." && pwd)
app_dir="$runtime_dir/app"
profile_binary="$app_dir/build/macos/Build/Products/Profile/icarus_convex_runtime_runner.app/Contents/MacOS/icarus_convex_runtime_runner"
trial_count=${TRIALS:-10}
convex_url=${CONVEX_URL:-http://127.0.0.1:3210}

if [ ! -x "$profile_binary" ]; then
  printf 'Missing profile runner: %s\n' "$profile_binary" >&2
  exit 2
fi

mkdir -p "$PROFILE_OUTPUT_DIR"
printf 'trial\tposition\tadapter\treport\ttime\n' > "$PROFILE_OUTPUT_DIR/order.tsv"

run_candidate() {
  trial=$1
  position=$2
  adapter=$3
  report_name="profile-trial-$(printf '%02d' "$trial")-$position-$adapter"
  log_file="$PROFILE_OUTPUT_DIR/$report_name.log"
  time_file="$PROFILE_OUTPUT_DIR/$report_name.time"

  (
    cd "$repo_dir"
    CONVEX_DEPLOYMENT= \
      CONVEX_SELF_HOSTED_URL="$convex_url" \
      npx convex import --replace-all --table users \
        "$runtime_dir/fixtures/empty.json" -y >/dev/null 2>&1
  )

  if ! (
    cd "$app_dir"
    export CONVEX_URL="$convex_url"
    export ADAPTER="$adapter"
    export SEED_COUNT=1
    export ALLOW_CHECKPOINT=0
    export RESET_PROGRESS=1
    export REPORT_NAME="$report_name"
    export GIT_COMMIT
    GIT_COMMIT=$(git -C "$repo_dir" rev-parse HEAD)
    /usr/bin/time -lp "$profile_binary" > "$log_file"
  ) 2> "$time_file"; then
    tail -40 "$log_file" >&2
    tail -40 "$time_file" >&2
    exit 1
  fi

  report_path=$(sed -n 's/^GAUNTLET_RESULT://p' "$log_file" | tail -1 | jq -r .reportPath)
  if [ ! -f "$report_path" ]; then
    printf 'Missing report for trial %s, adapter %s\n' "$trial" "$adapter" >&2
    exit 1
  fi
  cp "$report_path" "$PROFILE_OUTPUT_DIR/$report_name.json"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$trial" "$position" "$adapter" "$report_name.json" "$report_name.time" \
    >> "$PROFILE_OUTPUT_DIR/order.tsv"
  printf 'trial=%s position=%s adapter=%s passed\n' "$trial" "$position" "$adapter"
}

trial=1
while [ "$trial" -le "$trial_count" ]; do
  if [ $((trial % 2)) -eq 1 ]; then
    first=dartvex
    second=convex_flutter
  else
    first=convex_flutter
    second=dartvex
  fi
  run_candidate "$trial" first "$first"
  run_candidate "$trial" second "$second"
  trial=$((trial + 1))
done
