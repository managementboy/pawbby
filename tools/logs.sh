#!/usr/bin/env bash
# Read the LM log without a browser.
#
#   tools/logs.sh                 last 50 pawbby lines
#   tools/logs.sh 200             last 200 lines, filtered to pawbby
#   tools/logs.sh 200 "dp 107"    filter on script name or message text
#   tools/logs.sh -f              follow (polls every 3 s)
#   tools/logs.sh -e              error log instead of the script log
#
# The filter is applied to the newest N entries of the whole LM log, which
# other scripts also write to; raise N if pawbby lines seem missing.
set -euo pipefail

cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1

kind=logs
follow=()
pos=()
for a in "$@"; do
  case "$a" in
    -e|--errors) kind=errors ;;
    -f|--follow) follow=(--follow) ;;
    *) pos+=("$a") ;;
  esac
done

n=${pos[0]:-50}
filter=${pos[1]:-pawbby}

exec uv run --quiet --system-certs --no-project --with pynacl \
  python tools/lm.py "$kind" "$n" "$filter" "${follow[@]}"
