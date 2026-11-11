# PAWBBY datapoints

Device: PAWBBY Smart Automatic Cat Litter Box.
`product_id` `fetjzvf6o6dihnhq` — identical to the bundle id in the
Pawbby-Reborn research notes, so their map applies to this unit.

Protocol: Tuya local v3.4. Status query: `DP_QUERY` (0x0a) with the
gwId/devId envelope. `DP_QUERY_NEW` (0x10) is ignored by this firmware.

## Map

| DP | Type | Meaning |
|----|------|---------|
| 101 | raw | work state echo |
| 102 | raw | clean result, sent when a clean ends (auto and manual seen): `01 00 00 0b` + 11 zero bytes both times, so byte 3 is **not** a cycle counter. Logged, not alerted |
| 103 | raw | composite status blob |
| 106 | raw | command in |
| 107 | raw | cat visit summary; fires only on a real visit, ~70 s before auto-clean; not part of query replies. Layout `01 00 00 05 WW WW 00 SS 00`, **WW WW = cat weight in grams**, **SS = visit length in seconds** (see below) |
| 109 | raw | weight calibration / tare. **Write confirmed**, see below |
| 110 | raw | calibration result |
| 111 | int | raw weight ADC |
| 112 | int | filtered weight, grams |
| 113 | int | resets when the cat leaves |
| 114 | enum | motor / drum status; `motor_ok` when idle (2026-11-11) |
| 115 | enum | deodorant cartridge life (`deodorant_days`) |
| 116 | enum | state machine |
| 117 | str | motor debug string, e.g. idle `cu=0 FG=9345 BRK=1 PWM=0 POWER=1` (2026-11-11) |

## Confirmed write payloads

| Action | DP | Base64 | Notes |
|--------|----|--------|-------|
| Flatten / level litter | 106 | `AQEAAQA=` | safe, use this for testing |
| Empty / dump tray | 106 | `AQIAAQA=` | destructive |
| Tare (zero the scale) | 109 | `AQEAAA==` | 4-byte `01 01 00 00`; device replies with an empty ack on cmd 0x0d |
| Clean now (manual clean) | 106 | `AQAAAA==` | 4-byte `01 00 00 00`, the app's `startClear`. Confirmed 2026-09-17: `work_mclean` at once, idle after 119 s, DP 102 sent |

The app's device plugin builds these as `createValue(ver, cmd, flag, data)`
= ver (1 byte), cmd (1 byte), flag (2 bytes), data. Tare is
`resetWeight` = (1, 1, 0) and clean now is `startClear` = (1, 0, 0), which
is why the clean payload was trusted enough to test. Also in the plugin,
**not tested here**: `startFP` fixed-point clean `01 01 00 00` and
`cancelClear` `01 03 00 00` on DP 106, `takeOutLitterBox` `01 00 00 00` on
DP 109 (source: Pawbby-Reborn VALUES.md, APK analysis).

## DP 107 cat weight

| Source | Payload | Bytes 4-5 | Byte 7 |
|--------|---------|-----------|--------|
| this box, 2026-09-17 09:27 | `AQAABRCYAAsA` | 4248 g | 11 |
| Pawbby-Reborn | `AQAABRBQABUA` | 4176 g | 21 |
| Pawbby-Reborn | `AQAABQ/RACIA` | 4049 g | 34 |

4049 is also the DP 111/113 value in Reborn's status capture. The script
uses bytes 4-5 as the cat weight and logs it next to the scale peak delta
on every visit (`visit check: dp 107 N g, scale peak delta M g`) so the
hypothesis keeps being tested. At 09:27 the two were 4248 vs 4258 g.
Byte 7 is unknown.

Writes require the 15-byte version header (`"3.4"` plus 12 zero bytes)
before the JSON, and must **not** include `cid` — that field is for gateway
sub-devices and makes the box answer `data format error`.

## State machine (DP 116)

| State | Meaning |
|-------|---------|
| `work_idle` | idle |
| `cat_near`, `cat_enter`, `cat_leave` | cat present |
| `cat_near_leave` | cat has gone. **Not** a presence state |
| `work_smooth` | levelling |
| `work_aclean`, `work_mclean` | auto / manual clean |
| `work_empty` | dumping |
| `lid_open`, `lid_close` | lid handling; halts the machine and freezes DP 112 |
| `cat_litter_little`, `cat_litter_enough` | litter level |
| `roller_uninstall_ok` | drum removed (seen on DP 114) |

The last four rows are not in the Pawbby-Reborn notes: new findings.

## Weight reference (this unit)

| Condition | DP 112 |
|-----------|--------|
| Empty drum, lid closed, after tare | ~0 g |
| Fresh litter charge | ~2360 g |
| Drum removed | about -3600 g (unreliable: readings freeze while the lid is open) |

A liner jam produced no DP 116 change and no fault on any mapped DP, so the
fault-code datapoint is still unidentified. Unknown DPs are logged and raised
as an LM alert to catch it next time.

## DP 107 byte 7: visit length in seconds (2026-11-11)

On every visit the box also sends DP 113 three times as the cat leaves: `0`,
then a small number, then the cat weight. The small number equals byte 7 of
the DP 107 payload (0-based; `SS` above). Against the logged states it is the
time from `cat_enter` to `cat_leave` minus 17-21 s:

| Visit | cat_enter -> cat_leave | Byte 7 |
|---|---|---|
| 9 Nov 15:36 Charlie | 37 s | 16 |
| 10 Nov 20:06 Charlie | 32 s | 15 |
| 10 Nov 21:11 Isma | 84 s | 64 |
| 11 Nov 04:22 Isma | 131 s | 112 |
| 11 Nov 04:36 Charlie | 31 s | 12 |

So it is the box's own count of seconds the cat spent in the box (probably
from when its weight settled). Published on `32/3/22` and stored with each
sample (`s`). Over the 204 stored visits it ranges 10-137 s, median 34-37 s.
This is the main input for telling pee from poo (plan phase 4).
