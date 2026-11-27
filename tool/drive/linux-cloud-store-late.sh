#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 4 ]; then
  echo "usage: $0 <exe dir> <new out dir> <account email> <script> [companion script <companion email>] [-- more linux.dart run options]" >&2
  exit 2
fi
exe=$1
out=$2
account=$3
script=$4
shift 4
companion=()
if [ $# -ge 2 ] && [ "$1" != "--" ]; then
  companion=(--companion "$(realpath "$1")" --companion-account "$2")
  shift 2
fi
if [ $# -ge 1 ] && [ "$1" = "--" ]; then shift; fi
exec "$(dirname "$0")/linux-cut-network.sh" "$exe" "$out" "$script" \
  --cloud-store send --account "$account" "${companion[@]}" "$@"
