#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
firefox="${FIREFOX_EXECUTABLE:-firefox}"
entry="$1"
limit="${2:-}"
out=build/firefox_page
mkdir -p "$out"
dart compile js -O4 -o "$out/main.js" "$entry" >/dev/null
printf '<!doctype html><meta charset="utf-8"><script defer src="main.js"></script>\n' > "$out/index.html"
port=$((20000 + RANDOM % 20000))
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$out" >/dev/null 2>&1 &
server=$!
profile=$(mktemp -d)
trap 'kill "$server" 2>/dev/null; rm -rf "$profile"' EXIT
cat > "$profile/user.js" <<'PREFS'
user_pref("devtools.console.stdout.content", true);
user_pref("browser.shell.checkDefaultBrowser", false);
PREFS
if [ -n "$limit" ]; then
  echo "user_pref(\"dom.quotaManager.temporaryStorage.fixedLimit\", $limit);" >> "$profile/user.js"
fi
sleep 1
log="$out/console.log"
"$firefox" --headless --no-remote --profile "$profile" \
  "http://127.0.0.1:$port/index.html" >"$log" 2>&1 &
browser=$!
for _ in $(seq 1 600); do
  if grep -q 'icarus: done' "$log"; then break; fi
  sleep 1
done
kill "$browser" 2>/dev/null || true
wait "$browser" 2>/dev/null || true
grep -o 'icarus: .*' "$log" | sed 's/^icarus: //; s/"$//'
