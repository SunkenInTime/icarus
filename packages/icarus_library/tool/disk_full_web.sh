#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
firefox="${FIREFOX_EXECUTABLE:-firefox}"
leave_kib="${1:-512}"
out=build/disk_full_web
mkdir -p "$out"
dart compile js -O4 -o "$out/main.js" tool/disk_full_web.dart >/dev/null
printf '<!doctype html><meta charset="utf-8"><script defer src="main.js"></script>\n' > "$out/index.html"
rm -f "$out/go"
disk=$(mktemp -d)
sudo mount -t tmpfs -o size=64m,uid="$(id -u)" tmpfs "$disk"
port=$((20000 + RANDOM % 20000))
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$out" >/dev/null 2>&1 &
server=$!
browser=
cleanup() {
  [ -n "$browser" ] && kill "$browser" 2>/dev/null
  wait "$browser" 2>/dev/null || true
  kill "$server" 2>/dev/null || true
  sudo umount "$disk"
  rmdir "$disk"
}
trap cleanup EXIT
mkdir "$disk/profile"
cat > "$disk/profile/user.js" <<'PREFS'
user_pref("devtools.console.stdout.content", true);
user_pref("browser.shell.checkDefaultBrowser", false);
PREFS
sleep 1
log="$out/console.log"
"$firefox" --headless --no-remote --profile "$disk/profile" \
  "http://127.0.0.1:$port/index.html" >"$log" 2>&1 &
browser=$!
for _ in $(seq 1 120); do
  if grep -q 'icarus: ready' "$log"; then break; fi
  sleep 1
done
free_kib=$(df --output=avail -k "$disk" | tail -1)
fallocate -l "$(( (free_kib - leave_kib) * 1024 ))" "$disk/filler"
echo "disk: $(df --output=avail -k "$disk" | tail -1) KiB left"
touch "$out/go"
for _ in $(seq 1 120); do
  if grep -q 'icarus: done' "$log"; then break; fi
  sleep 1
done
grep -o 'icarus: .*' "$log" | sed 's/^icarus: //; s/"$//'
