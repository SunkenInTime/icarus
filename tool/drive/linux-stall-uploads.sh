#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 4 ]; then
  echo "usage: $0 <exe dir> <new out dir> <label> <account email>" >&2
  exit 2
fi
exe=$(realpath "$1")
out=$(realpath -m "$2")
label=$3
account=$4
repo=$(realpath "$(dirname "$0")/../..")
script=$repo/tool/drive/scripts/picture-upload-stalled.json
unit=icarus-stall-$label
chain=ICARUS_STALL_${label^^}
mark=0x3197
log=$(dirname "$out")/$label-harness.log
parent=$(dirname "$out")
mkdir -p "$parent"
: > "$log"
say() { echo "$(date +%T.%3N) $*" | tee -a "$log"; }

python3 - "$parent/first.png" <<'EOF'
import os, struct, sys, zlib
w = h = 256
raw = b''.join(b'\x00' + os.urandom(w * 3) for _ in range(h))
def chunk(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
open(sys.argv[1], 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))
EOF
say "first.png $(stat -c %s "$parent/first.png") bytes"

acct_before=$(sysctl -n net.netfilter.nf_conntrack_acct)
cg=""
rec_pid=""
input_rule=(INPUT -m connmark --mark $mark -m connbytes --connbytes 65536: --connbytes-dir original --connbytes-mode bytes -j DROP)

cleanup() {
  set +e
  [ -n "$rec_pid" ] && kill -INT "$rec_pid" 2>/dev/null && sleep 2
  [ -n "$cg" ] && sudo -n iptables -D OUTPUT -m cgroup --path "$cg" -j "$chain" 2>/dev/null
  sudo -n iptables -D "${input_rule[@]}" 2>/dev/null
  sudo -n iptables -F "$chain" 2>/dev/null
  sudo -n iptables -X "$chain" 2>/dev/null
  sudo -n sysctl -q -w net.netfilter.nf_conntrack_acct="$acct_before"
  say "cleanup done; rules left: $(sudo -n iptables -S | grep -c -i "$chain\|0x3197")"
}
trap cleanup EXIT

sudo -n iptables -N "$chain"
sudo -n iptables -A "$chain" -p tcp --dport 443 -m string --string r2.cloudflarestorage.com --algo bm -j CONNMARK --set-mark $mark
sudo -n iptables -A "$chain" -p tcp --dport 443 -m connmark --mark $mark -m connbytes --connbytes 65536: --connbytes-dir original --connbytes-mode bytes -j DROP

systemd-run --user --scope --unit="$unit" --quiet \
  dart "$repo/tool/drive/linux.dart" run --exe "$exe" --script "$script" \
  --account "$account" --out "$out" > "$parent/$label-run.log" 2>&1 &
run_pid=$!

for _ in $(seq 100); do
  cg=$(systemctl --user show -p ControlGroup --value "$unit.scope" 2>/dev/null || true)
  [ -n "$cg" ] && break
  sleep 0.1
done
cg=${cg#/}
say "scope cgroup $cg"

until [ -f "$out/signals/ready" ]; do
  kill -0 $run_pid 2>/dev/null || { say "run ended before ready"; wait $run_pid; exit 1; }
  sleep 0.5
done

sudo -n iptables -I OUTPUT -m cgroup --path "$cg" -j "$chain"
sudo -n iptables -I "${input_rule[@]}"
say "stall on: uploads to r2.cloudflarestorage.com from $unit go dark after 64 KB"

app=""
for p in $(cat /sys/fs/cgroup/$cg/cgroup.procs); do
  [ "$(readlink /proc/$p/exe 2>/dev/null)" = "$exe/icarus" ] && app=$p && break
done
display=$(tr '\0' '\n' < /proc/$app/environ | sed -n 's/^DISPLAY=//p')
size=$(DISPLAY=$display xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}')
say "app pid $app display $display size $size"
setsid ffmpeg -loglevel error -y -f x11grab -framerate 5 -video_size "${size:-1600x900}" -i "$display" \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p "$parent/$label.mp4" < /dev/null &
rec_pid=$!
touch "$out/signals/blocked"

until [ -f "$out/signals/release" ]; do
  kill -0 $run_pid 2>/dev/null || { say "run ended before release"; break; }
  sleep 0.5
done
sudo -n iptables -D OUTPUT -m cgroup --path "$cg" -j "$chain"
sudo -n iptables -D "${input_rule[@]}"
say "stall off"
touch "$out/signals/released"

set +e
wait $run_pid
status=$?
say "run exit $status"
exit $status
