#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 3 ] || [ $# -gt 6 ]; then
  echo "usage: $0 <exe dir> <new out dir> <account email> [script] [send] [store to start on]" >&2
  exit 2
fi
exe=$(realpath "$1")
out=$(realpath -m "$2")
account=$3
repo=$(realpath "$(dirname "$0")/../..")
script=$(realpath "${4:-$repo/tool/drive/scripts/cloud-store-send-offline.json}")
mode=${5:-send}
seed=()
if [ $# -ge 6 ]; then seed=(--hive-store "$(realpath "$6")"); fi
unit=icarus-cloud-store-offline-$$
table=icarus_cloud_store_offline_$$
parent=$(dirname "$out")
mkdir -p "$parent"
log=$parent/$(basename "$out")-harness.log
: > "$log"
say() { echo "$(date +%T.%3N) $*" | tee -a "$log"; }

run_pid=""
cleanup() {
  status=$?
  set +e
  sudo -n nft delete table inet "$table" 2>/dev/null
  if [ -n "$run_pid" ] && kill -0 "$run_pid" 2>/dev/null; then
    say "stopping the run"
    systemctl --user stop "$unit.scope"
    wait "$run_pid"
  fi
  say "cleanup done; tables left: $(sudo -n nft list tables | grep -c "$table")"
  exit "$status"
}
trap cleanup EXIT

systemd-run --user --scope --unit="$unit" --quiet \
  dart "$repo/tool/drive/linux.dart" run --exe "$exe" --script "$script" \
  --cloud-store "$mode" --account "$account" --out "$out" "${seed[@]}" \
  > "$parent/$(basename "$out")-run.log" 2>&1 &
run_pid=$!

signal() { cat "$out/run-id" > "$out/signals/$1"; }
wait_for() {
  until [ -f "$out/signals/$1" ]; do
    kill -0 $run_pid 2>/dev/null || { say "run ended before $1"; wait $run_pid; exit 1; }
    sleep 0.5
  done
}

wait_for ready
cg=$(systemctl --user show -p ControlGroup --value "$unit.scope")
cg=${cg#/}
sudo -n nft add table inet "$table"
sudo -n nft add chain inet "$table" input '{ type filter hook input priority -10; policy accept; }'
sudo -n nft add rule inet "$table" input socket cgroupv2 level 5 "\"$cg\"" drop
say "cut: nothing comes back to $unit"
signal cut

wait_for edited-offline
sleep 5
sudo -n nft delete table inet "$table"
say "restored"
signal restored

status=0
wait $run_pid || status=$?
say "run exited $status"
exit $status
