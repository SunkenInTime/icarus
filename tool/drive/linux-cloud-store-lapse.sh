#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <store dir> <days>" >&2
  exit 2
fi
db=$1/library_store/library.sqlite
days=$2
if [ ! -f "$db" ]; then
  echo "no store at $db" >&2
  exit 2
fi
back=$((days * 86400000))
changed=$(sqlite3 "$db" "update rows set value = json_set(value, '\$.knownSince', json_extract(value, '\$.knownSince') - $back) where key = 'cloud' and json_extract(value, '\$.knownSince') is not null; select changes();")
if [ "$changed" = 0 ]; then
  echo "no cloud strategy in $db holds a full read to move back" >&2
  exit 1
fi
echo "moved the last full read of $changed cloud strategies back $days days"
