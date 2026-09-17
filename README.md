# pawbby-lm

Cloud-free integration of a PAWBBY smart litter box into a LogicMachine LM5
KNX controller. Everything runs on the LM: a Tuya v3.4 client written in Lua,
talking to the box over the LAN, publishing to KNX objects under `32/3/*`.

No Pi, no MQTT broker, no vendor cloud. The Pawbby backend is dead (HTTP 502)
and this does not depend on it.

## Status

Working: local connection, full state read, weight, visit counting, litter
level, flatten and tare commands, Mosaic tiles in the entrance room.

Open: DP 107 visit payload undecoded, fault-code DP unidentified, per-cat
weight bands not yet populated. See `docs/FINDINGS.md`.

## Layout

    src/tuya34.lua            Tuya v3.4 client; install as LM user library "tuya34"
    src/pawbby_resident.lua   Resident script, 5 s interval; LM script id 64
    docs/                     DP map, protocol notes, findings
    tools/                    Deploy and log helpers

## KNX objects

| Address | Object |
|---------|--------|
| 32/3/1 | Weight (g) |
| 32/3/2 | State (text) |
| 32/3/3 | Cat present |
| 32/3/4 | Cleaning |
| 32/3/5 | Online |
| 32/3/6 | Visit trigger |
| 32/3/7 | Visits today |
| 32/3/9 | Cat weight (g) |
| 32/3/10 | Command: flatten |
| 32/3/11 | Command: empty (DUMP) |
| 32/3/13 | Litter low |
| 32/3/14 | Cat name |
| 32/3/15 | Fault |

All are **virtual** objects — 32/x is outside the KNX standard range.

## Configuration

Copy `.env.example` to `.env` (git-ignored) and fill in the LM login and the
Tuya device id and local key. The repo only holds `${TUYA_ID}`/`${TUYA_KEY}`
placeholders; `tools/deploy.sh` fills them in when it saves to the LM. The
box IP is at the top of `src/pawbby_resident.lua`. Before the first commit
in a clone: `cp tools/pre-commit .git/hooks/pre-commit`.

The local key is obtained once from the Tuya developer platform
(Cloud project, linked app account, Query Device Details in Bulk).

## Credit

Datapoint map and `106` payloads from
[Pawbby-Reborn](https://github.com/larsjarred9/Pawbby-Reborn) (AGPL-3.0).
