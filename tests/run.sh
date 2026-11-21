#!/usr/bin/env bash
# Offline checks: LuaJIT syntax of src/*.lua, a visit replay through the
# resident script and the tuya34 frame reader (tests/tuya34_frames.lua).
# Nothing here talks to the LM or the box.
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
# tuya34 frame reader (code review 2026-11-18, T3-PAWBBY #a4 #a5 #a9), fresh state
rt2 = luajit21.LuaRuntime()
rt2.execute(open("tests/tuya34_frames.lua", encoding="utf-8").read(),
            open("src/tuya34.lua", encoding="utf-8").read())
PY
