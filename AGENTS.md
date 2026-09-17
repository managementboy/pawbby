# Agent instructions

## What this is

A local (cloud-free) integration between a PAWBBY smart litter box and a
LogicMachine LM5 Lite KNX controller. The box speaks the Tuya v3.4 local
protocol; the LM speaks Lua and KNX. All code runs on the LM itself — there
is no Pi, no broker, no vendor cloud in the path.

## Ground rules

1. **The LM is live hardware in a home.** Two cats depend on the litter box
   working. Never send the `empty` / DUMP command while testing; it dumps the
   tray. `flatten` is the safe write for verification.
2. **Never guess a datapoint payload and fire it.** DP semantics were
   established by observation; see `docs/DATAPOINTS.md`. Unknown DPs get
   logged, not written.
3. **Stale views lie.** The LM object list and Mosaic both cache. Always
   reload before concluding an object is missing or a value is stuck. This
   has already caused two wrong diagnoses.
4. **Read `docs/FINDINGS.md` before changing protocol code.** It records
   what was tried and what failed, including the mistakes.

## Layout

    src/tuya34.lua            Tuya v3.4 client (user library on the LM)
    src/pawbby_resident.lua   Resident script, 5 s interval (LM setting)
    docs/DATAPOINTS.md        DP map, confirmed payloads, state machine
    docs/PROTOCOL.md          Frame format, handshake, crypto notes
    tests/run.sh              Offline syntax check + visit replay (no LM)
    docs/FINDINGS.md          What we learned, including dead ends
    tools/                    Deploy and log helpers

## Deploying

The LM is at `192.168.51.10`. `src/tuya34.lua` is the user library named
`tuya34`; `src/pawbby_resident.lua` is resident script id 64. After any
change: run `tools/deploy.sh` (see `tools/README.md`), which watches the
log for `script start #N` and confirms N
increments exactly once. A climbing N means the script is crashing.

## Verifying a change

A change is not done until it has been observed on the box:

- object values updated with a fresh timestamp (reload the list first)
- no new entries in the LM error log
- for protocol changes, the device's reply logged with `debug = true`,
  then `debug` set back to false

## Style

Lua 5.1 / LuaJIT 2.0. Comments explain *why*, not *what* — the reader is
assumed to know Lua but not this device's quirks. Keep labels written to
`32/3/2` at 14 characters or fewer; DPT 16 truncates silently.
