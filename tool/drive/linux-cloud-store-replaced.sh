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
python3 - "$base-calls.jsonl" "$base-server.jsonl" "$out/main.log" "$(cat "$out/run-id")" <<'PY' | tee -a "$log"
import json, re, sys
calls_path, server_path, main_log, run = sys.argv[1:5]
calls = [json.loads(line) for line in open(calls_path) if line.startswith("{")]
refused = [
    call for call in calls
    if call.get("identifier") == "ops:applyBatch"
    and "STRATEGY_REPLACED" in json.dumps(call.get("error"))
]
events = []
for line in open(server_path):
    row = json.loads(line)
    events = row.get("events", events)
log = open(main_log).read()
moved = dict(re.findall(r"CLOUDSTORE committed ([0-9a-f-]{36}): ((?:o1|o2|t3)-%s) of " % run, log))
problems = []
if len(refused) != 1:
    problems.append(f"{len(refused)} batches were refused as STRATEGY_REPLACED, not one")
third = [op for op, item in moved.items() if item.startswith("t3-")]
old = [op for op, item in moved.items() if not item.startswith("t3-")]
if len(third) != 1 or len(old) != 2:
    problems.append(f"the teammate's log names moves {moved}, not two old ones and one third")
landed = [e for e in events if e["opId"] in third and e["status"] == "applied"]
if not landed:
    problems.append("the server holds no applied event for the teammate's third move")
resent = [e for e in events if e["opId"] in old]
if resent:
    problems.append(f"the server holds events for the set-aside moves: {resent}")
for problem in problems:
    print(f"CHECK FAILED {problem}")
if problems:
    sys.exit(1)
print(f"CHECK the server refused one batch as STRATEGY_REPLACED, applied the third move {third[0]} "
      f"from client {landed[0]['clientId']}, and holds nothing for the set-aside moves {old}")
PY
check=${PIPESTATUS[0]}
if [ "$check" -ne 0 ]; then
  say "the server's log and rows do not show what this run claims"
  exit 1
fi
exit $status
