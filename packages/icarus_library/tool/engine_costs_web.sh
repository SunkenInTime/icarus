#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
out=build/engine_costs_web
mkdir -p "$out"
dart compile js -O4 -o "$out/main.js" "${1:-tool/engine_costs_web.dart}" >/dev/null
printf '<!doctype html><meta charset="utf-8"><script defer src="main.js"></script>\n' > "$out/index.html"
port=$((20000 + RANDOM % 20000))
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$out" >/dev/null 2>&1 &
server=$!
profile=$(mktemp -d)
trap 'kill "$server" 2>/dev/null; rm -rf "$profile"' EXIT
sleep 1
log="$out/console.log"
google-chrome --headless=new --user-data-dir="$profile" --enable-logging=stderr --v=0 \
  "http://127.0.0.1:$port/index.html" 2>"$log" &
chrome=$!
for _ in $(seq 1 600); do
  if grep -q 'done"' "$log"; then break; fi
  sleep 1
done
kill "$chrome" 2>/dev/null || true
wait "$chrome" 2>/dev/null || true
grep -o 'CONSOLE:[0-9]*\] "[^"]*"' "$log" | sed 's/^CONSOLE:[0-9]*\] "//; s/"$//'
