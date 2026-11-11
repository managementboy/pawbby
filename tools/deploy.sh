#!/usr/bin/env bash
# Push src/*.lua to the LogicMachine and confirm the resident script came
# back up exactly once.
#
#   tools/deploy.sh            deploy whatever changed
#   tools/deploy.sh --dry-run  only show which files differ from the LM
#
# Credentials come from .env (LM_HOST, LM_USER, LM_PASS). See tools/lm.py for
# how the LM's admin API is driven.
set -euo pipefail

cd "$(dirname "$0")/.."
# Git Bash would otherwise rewrite /scada-main/... arguments into C:\ paths.
export MSYS_NO_PATHCONV=1

LIB_ID=user.tuya34
LIB_SRC=src/tuya34.lua
RES_ID=64
RES_SRC=src/pawbby_resident.lua

lm() { uv run --quiet --system-certs --no-project --with pynacl python tools/lm.py "$@"; }

if [[ "${1:-}" == "--dry-run" ]]; then
  # relative: with path conversion off, Windows Python cannot resolve /tmp
  tmp=$(mktemp -d .deploy.XXXXXX)
  trap 'rm -rf "$tmp"' EXIT
  for pair in "$LIB_ID:$LIB_SRC" "$RES_ID:$RES_SRC"; do
    id=${pair%%:*}; src=${pair#*:}
    lm pull "$id" "$tmp/remote.lua" >/dev/null
    if cmp -s "$tmp/remote.lua" "$src"; then
      echo "$id: unchanged"
    else
      echo "$id: differs from $src"
      diff -u --label "LM:$id" --label "$src" "$tmp/remote.lua" "$src" || true
    fi
  done
  exit 0
fi

start=$(date +%s)

lib_out=$(lm push "$LIB_ID" "$LIB_SRC")
echo "$lib_out"

# The resident script only re-requires the library when its global state is
# fresh, i.e. on restart. Saving script 64 is what restarts it, so a library
# change forces a resident save even if the script itself is unchanged.
if [[ "$lib_out" == *"saved"* && "$lib_out" != *"not saved"* ]]; then
  res_out=$(lm push "$RES_ID" "$RES_SRC" --force)
else
  res_out=$(lm push "$RES_ID" "$RES_SRC")
fi
echo "$res_out"

if [[ "$res_out" == *"not saved"* ]]; then
  echo "nothing restarted"
  exit 0
fi

# Starts are logged within a cycle; wait long enough to catch a crash loop
# (a climbing start counter) as well as the reconnect.
echo "watching log for 20 s ..."
sleep 20
LM_SINCE=$start lm logs 100 pawbby
errs=$(LM_SINCE=$start lm errors 20 pawbby)
starts=$(LM_SINCE=$start lm logs 100 "script start" | grep -c "script start" || true)

if [[ -n "$errs" ]]; then
  echo "--- NEW ERRORS ---"
  echo "$errs"
  exit 1
fi
if [[ "$starts" -ne 1 ]]; then
  echo "expected exactly 1 script start, saw $starts"
  exit 1
fi
echo "OK: one start, no errors"
