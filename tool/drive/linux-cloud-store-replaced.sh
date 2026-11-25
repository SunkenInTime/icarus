#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 7 ]; then
  echo "usage: $0 <exe dir> <new out dir> <teammate email> <owner email> <preview name> <pc ssh host> <pc checkout>" >&2
  exit 2
fi
exe=$(realpath "$1")
out=$(realpath -m "$2")
teammate=$3
owner=$4
preview=$5
pc=$6
checkout=$7
replace="powershell -NoProfile -ExecutionPolicy Bypass -File tool\\drive\\preview-replace.ps1 -Name $preview"
repo=$(realpath "$(dirname "$0")/../..")
scripts=$repo/tool/drive/scripts
parent=$(dirname "$out")
mkdir -p "$parent"
base=$parent/$(basename "$out")
log=$base-harness.log
: > "$log"
say() { echo "$(date +%T.%3N) $*" | tee -a "$log"; }

dart "$repo/tool/drive/linux.dart" run --exe "$exe" \
  --script "$scripts/cloud-store-replaced.json" --account "$teammate" \
  --companion "$scripts/cloud-store-replaced-owner.json" \
  --companion-account "$owner" \
  --cloud-store send --out "$out" > "$base-run.log" 2>&1 &
run_pid=$!
trap 'kill $run_pid 2>/dev/null || true' EXIT

wait_for() {
  until [ -f "$out/signals/$1" ]; do
    kill -0 $run_pid 2>/dev/null || { say "run ended before $1"; wait $run_pid; exit 1; }
    sleep 0.5
  done
}

wait_for ready
subject=$(grep -oE 'for SignedInAs\([^)]+\)' "$out/main.log" | head -1 | sed -E 's/for SignedInAs\((.*)\)/\1/')
name="Replaced $(cat "$out/run-id")"
say "the teammate is $subject; recording the server's calls for 150 s"
ssh -o BatchMode=yes "$pc" "cd /d $checkout && $replace logs 150" \
  2> "$base-calls.err" > "$base-calls.jsonl" &
logs_pid=$!
sleep 5
say "deleting \"$name\" on the preview and making it again under the same ids, then sharing it with the teammate again"
ssh -o BatchMode=yes "$pc" "cd /d $checkout && $replace \"$name\" $subject" \
  2>/dev/null | grep '^{' > "$base-server.jsonl"
say "made again"
cat "$out/run-id" > "$out/signals/replaced"

status=0
wait $run_pid || status=$?
trap - EXIT
logs_status=0
wait $logs_pid || logs_status=$?
say "run exited $status"
ssh -o BatchMode=yes "$pc" "cd /d $checkout && $replace \"$name\" $subject show" \
  2>/dev/null | grep '^{' >> "$base-server.jsonl"
if [ "$logs_status" -ne 0 ]; then
  say "the server's log capture failed (exit $logs_status), so this run proves nothing about what was sent:"
  tee -a "$log" < "$base-calls.err"
  exit 1
fi
client_calls=$(grep -cE '"identifier":"(ops:applyBatch|strategy:getPageList)"' "$base-calls.jsonl" || true)
if [ "$client_calls" -eq 0 ]; then
  say "the server's log holds no ops:applyBatch and no page list read, so this run proves nothing about what was sent"
  exit 1
fi
say "the server's log holds $client_calls batches and page list reads"
exit $status
