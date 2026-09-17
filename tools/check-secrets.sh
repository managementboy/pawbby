#!/usr/bin/env bash
# Refuse to commit anything that contains a secret value from .env (LM
# password, Tuya key and device id). LM_HOST and LM_USER are not secret (a
# private LAN address and "admin", both in the docs).
#
# Install once per clone:
#   cp tools/pre-commit .git/hooks/pre-commit
#
# By hand: `tools/check-secrets.sh` checks what is staged, `--all` scans
# every tracked and untracked file.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

if [[ ! -f .env ]]; then
  echo "check-secrets: no .env, nothing to compare against" >&2
  exit 0
fi

if [[ "${1:-}" == "--all" ]]; then
  mode=all
else
  mode=staged
fi

exec python tools/check_secrets.py "$mode" </dev/null
