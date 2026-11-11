#!/usr/bin/env bash
# Offline checks: LuaJIT syntax of src/*.lua and a visit replay through the
# resident script. Nothing here talks to the LM or the box.
# Uses a local `pip install lupa` if present, otherwise pulls it in via uv.
set -euo pipefail
cd "$(dirname "$0")/.."

if python -c "import lupa.luajit21" 2>/dev/null; then
  py=(python)
else
  py=(uv run --quiet --system-certs --no-project --with lupa python)
fi

exec "${py[@]}" - <<'PY'
from lupa import luajit21
rt = luajit21.LuaRuntime()
for f in ("src/tuya34.lua", "src/pawbby_resident.lua"):
    err = rt.execute("local fn, err = loadstring(..., '=x'); return err", open(f, encoding="utf-8").read())
    if err:
        raise SystemExit(f"{f}: {err}")
    print(f"{f}: syntax ok")
src = open("src/pawbby_resident.lua", encoding="utf-8").read()
rt.execute(open("tests/replay_visit.lua", encoding="utf-8").read(), src)
PY
