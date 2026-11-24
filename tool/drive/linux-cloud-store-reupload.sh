#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 6 ]; then
  echo "usage: $0 <exe dir> <new out dir> <account email> <preview name> <pc ssh host> <pc checkout>" >&2
  exit 2
fi
exe=$(realpath "$1")
out=$(realpath -m "$2")
account=$3
preview=$4
pc=$5
checkout=$6
repo=$(realpath "$(dirname "$0")/../..")
script=$repo/tool/drive/scripts/cloud-store-reupload.json
parent=$(dirname "$out")
mkdir -p "$parent"
log=$parent/$(basename "$out")-harness.log
: > "$log"
say() { echo "$(date +%T.%3N) $*" | tee -a "$log"; }

dart "$repo/tool/drive/linux.dart" run --exe "$exe" --script "$script" \
  --cloud-store send --account "$account" --out "$out" \
  > "$parent/$(basename "$out")-run.log" 2>&1 &
run_pid=$!
trap 'kill $run_pid 2>/dev/null || true' EXIT

signal() { cat "$out/run-id" > "$out/signals/$1"; }
wait_for() {
  until [ -f "$out/signals/$1" ]; do
    kill -0 $run_pid 2>/dev/null || { say "run ended before $1"; wait $run_pid; exit 1; }
    sleep 0.5
  done
}

wait_for ready
name="Reupload $(cat "$out/run-id")"
say "deleting \"$name\" on $preview and uploading it again under the same ids"
ssh -o BatchMode=yes "$pc" "cd /d $checkout && powershell -NoProfile -ExecutionPolicy Bypass -File tool\\drive\\preview-reupload.ps1 -Name $preview -Strategy \"$name\"" \
  2>/dev/null | grep '^{' > "$parent/$(basename "$out")-server.jsonl"
say "uploaded again"
signal reuploaded

status=0
wait $run_pid || status=$?
trap - EXIT
say "run exited $status"
ssh -o BatchMode=yes "$pc" "cd /d $checkout && powershell -NoProfile -ExecutionPolicy Bypass -File tool\\drive\\preview-reupload.ps1 -Name $preview -Strategy \"$name\" -Show" \
  2>/dev/null | grep '^{' >> "$parent/$(basename "$out")-server.jsonl"
say "the server's rows are in $(basename "$out")-server.jsonl"
exit $status
