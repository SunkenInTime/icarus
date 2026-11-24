#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 4 ]; then
  echo "usage: $0 <exe dir> <new out dir> <account email> <script> [companion script <companion email>] [-- more linux.dart run options]" >&2
  exit 2
fi
exe=$(realpath "$1")
out=$(realpath -m "$2")
account=$3
script=$(realpath "$4")
shift 4
companion=()
if [ $# -ge 2 ] && [ "$1" != "--" ]; then
  companion=(--companion "$(realpath "$1")" --companion-account "$2")
  shift 2
fi
if [ $# -ge 1 ] && [ "$1" = "--" ]; then shift; fi
repo=$(realpath "$(dirname "$0")/../..")
unit=icarus-cloud-store-late-$$
table=icarus_cloud_store_late_$$
parent=$(dirname "$out")
mkdir -p "$parent"
log=$parent/$(basename "$out")-harness.log
: > "$log"
say() { echo "$(date +%T.%3N) $*" | tee -a "$log"; }

cleanup() {
  status=$?
  set +e
  sudo -n nft delete table inet "$table" 2>/dev/null
  say "cleanup done; tables left: $(sudo -n nft list tables | grep -c "$table")"
  exit "$status"
}
trap cleanup EXIT

dart "$repo/tool/drive/linux.dart" run --exe "$exe" --script "$script" \
  --cloud-store send --account "$account" --out "$out" --main-scope "$unit" \
  "${companion[@]}" "$@" > "$parent/$(basename "$out")-run.log" 2>&1 &
run_pid=$!

ends_killed=false
if tail -n 3 "$script" | grep -q '"killNow"'; then ends_killed=true; fi

ended() {
  local status=0
  wait $run_pid || status=$?
  if $ends_killed && grep -q 'KILLED by the script' "$out/main.log" 2>/dev/null &&
    ! grep -q ' FAIL ' "$out/main.log"; then
    say "the run ended where its script kills the app, with no step failed"
    exit 0
  fi
  say "run ended before $1"
  exit $status
}

signal() { cat "$out/run-id" > "$out/signals/$1"; }
wait_for() {
  until [ -f "$out/signals/$1" ]; do
    kill -0 $run_pid 2>/dev/null || ended "$1"
    sleep 0.2
  done
}

wait_for ready
cg=$(systemctl --user show -p ControlGroup --value "$unit.scope")
cg=${cg#/}
level=$(($(tr -cd / <<< "$cg" | wc -c) + 1))
sudo -n nft add table inet "$table"
sudo -n nft add chain inet "$table" input '{ type filter hook input priority -10; policy accept; }'
sudo -n nft add chain inet "$table" output '{ type filter hook output priority -10; policy accept; }'
sudo -n nft add rule inet "$table" input socket cgroupv2 level "$level" "\"$cg\"" drop
sudo -n nft add rule inet "$table" output socket cgroupv2 level "$level" "\"$cg\"" drop
say "cut: nothing leaves or reaches the main instance ($unit)"
signal cut

wait_for restore
sudo -n nft delete table inet "$table"
say "restored"
signal restored

status=0
wait $run_pid || status=$?
say "run exited $status"
exit $status
