# PAWBBY datapoints

Device: PAWBBY Smart Automatic Cat Litter Box.
`product_id` `fetjzvf6o6dihnhq` — identical to the bundle id in the
Pawbby-Reborn research notes, so their map applies to this unit.

Protocol: Tuya local v3.4. Status query: `DP_QUERY` (0x0a) with the
gwId/devId envelope. `DP_QUERY_NEW` (0x10) is ignored by this firmware.

## Map

The full data model was read from the Tuya developer platform on
2026-11-11 (`docs/tuya-data-model-2026-11-11.json`, see "Tuya data model"
below). Codes and types in this table are Tuya's; meanings come from
observation here and from the platform's 7-day cloud log.

| DP | Tuya code | Type | Meaning |
|----|-----------|------|---------|
| 101 | `work_state` | raw | current and previous activity, `01 CC 00 01 PP` (see below) |
| 102 | `fault_code` | raw | **the fault DP.** `01 00 00 0b` + 11 fault bytes, all zero = no fault. Sent after every clean and on every fault change. Byte 12 = 1: drum not seated (see below) |
| 103 | `device_state` | raw | 21-byte status block: lid, waste drawer, cat inside / near, litter level, cat in too long, plus constant bytes that may be settings (see below) |
| 104 | `cat_info` | raw | cat profiles. Only value ever: `01 00 00 00` (empty), 16 Sep |
| 105 | `device_control` | raw | settings command (by its name). Never reported, payload unknown. **Do not write** |
| 106 | `clean_control` | raw | clean / level / dump commands. Write-only in practice |
| 107 | `toilet_data` | raw | cat visit summary; fires only on a real visit, ~70 s before auto-clean; not part of query replies. Layout `01 00 00 05 WW WW 00 SS 00`, **WW WW = cat weight in grams**, **SS = visit length in seconds** (see below) |
| 108 | `device_info` | raw | `01 00 00 12` + 18 ASCII chars, model and serial (`MGS104...`). Sent after power-up |
| 109 | `weight_cal` | raw | weight calibration / tare. **Write confirmed**, see below |
| 110 | `calibrat_result` | raw | calibration result. Never seen in 7 days |
| 111 | `debug_data_01` | int, ro | raw weight ADC (Tuya: "debug data", -2^31..2^31-1) |
| 112 | `debug_data_02` | int, ro | filtered weight, grams |
| 113 | `debug_data_03` | int, ro | resets when the cat leaves (0..2^31-1) |
| 114 | `data_flag_01` | enum, ro | hardware check results: `*_ok` / `*_err` pairs (list below). Not only the motor |
| 115 | `data_flag_02` | enum, ro | **name of the setting that last changed**, not a value. Only report ever: `deodorant_days`, 16 Sep 22:53, the setup evening |
| 116 | `data_flag_03` | enum, ro | state machine, 28 values (list below) |
| 117 | `motor_data` | string, ro | motor debug string, e.g. idle `cu=0 FG=9345 BRK=1 PWM=0 POWER=1`; `cu` (current) 100-250 while the drum turns |

Every raw DP has the same 4-byte head: `01` (version), a command or
activity byte, then a **2-byte length of the data that follows**: 107 has 5
data bytes (`00 05`), 102 has 11 (`00 0b`), 103 has 21 (`00 15`), 108 has 18
(`00 12`). The commands on DP 106 fit too: flatten `01 01 00 01 00` is
command 1 with one data byte, clean now `01 00 00 00` is command 0 with none.
So the "flag" in the app plugin's `createValue(ver, cmd, flag, data)` is the
data length.

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
`roller_uninstall_ok` belongs to DP 114, not 116. The complete list of
DP 116 values from the Tuya model is in the next section.

## Weight reference (this unit)

| Condition | DP 112 |
|-----------|--------|
| Empty drum, lid closed, after tare | ~0 g |
| Fresh litter charge | ~2360 g |
| Drum removed | about -3600 g (unreliable: readings freeze while the lid is open) |

A liner jam produced no DP 116 change. DP 102 is the fault DP (Tuya code
`fault_code`), but it was filed as a "clean result" and logged only, so
whether the jam showed there is not known. Unknown DPs are still logged and
raised as an LM alert.

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

## Tuya data model (read 2026-11-11)

Source: Tuya IoT platform, EU data centre, the user's Cloud project,
API Explorer "Query Things Data Model" (`GET /v2.0/cloud/thing/{id}/model`),
model id `000004sa7o`. Saved as `docs/tuya-data-model-2026-11-11.json`
(model only; device id, keys and account left out). Read only: no command
was sent and no setting changed on the platform.

The model has 17 properties (101-117), no actions, no events. Every raw DP
is marked `rw` and every enum/int `ro`; the raw `rw` says nothing about what
the box accepts. There are **no separate settings DPs**: settings go in
through DP 105 and the box announces a change on DP 115.

The box is still online to the Tuya cloud and uploads every DP report
there (only the Pawbby backend is dead). The platform keeps 7 days of these
reports ("Device Logs"); the decoding below comes from that log, 4-11 Nov
2026. Times are CET.

### What was new against the old map

| DP | Before | Now |
|----|--------|-----|
| 102 | "clean result", logged only | `fault_code`: the fault DP |
| 103 | composite blob, undecoded | 21 status bytes, 6 decoded |
| 104 | not seen | `cat_info`, empty |
| 105 | not seen | `device_control`, the settings write |
| 108 | trace | `device_info`, model + serial |
| 114 | motor status | all hardware checks (12 `_err` values) |
| 115 | deodorant life | name of the last setting changed |
| 116 | 15 states | 28 states |

### DP 102 `fault_code`

`01 00 00 0b` + 11 data bytes. In 7 days only one non-zero byte was seen:
payload byte 12 (data byte 8) = `01`, always together with DP 114
`roller_uninstall_err` and cleared with `roller_uninstall_ok`:

| When (CET) | DP 102 byte 12 | DP 114 | Around it |
|---|---|---|---|
| 7 Nov 09:01-09:31 | 1 | `roller_uninstall_err` | `lid_open`, `work_init` |
| 7 Nov 09:35, 11 s | 1 | `roller_uninstall_err` | |
| 9 Nov 19:08-19:47 | 1 | `roller_uninstall_err` | `cat_litter_none`, `cat_enter_too_long_time` |

So byte 12 means "drum not seated / taken out". Which fault the other 10
bytes stand for is not known; DP 114 has 12 `_err` values, so most likely
one byte per fault, and a non-zero byte together with the matching DP 114
`_err` names it. Any non-zero byte is a fault.

### DP 101 `work_state`

`01 CC 00 01 PP`: CC = what the box is doing now, PP = what it did last.

| Code | Seen with DP 116 |
|---|---|
| `00` | `work_idle` |
| `01` | `work_mclean` (manual clean) |
| `02` | `work_aclean` (auto clean) |
| `04` | `work_smooth` (levelling) |
| `05` | `work_init` (after lid / drum handling) |
| `21` | during `work_init` with the lid open after `cat_litter_none` (9 Nov) |
| `26` | `power_off` (9 Nov) |

A normal auto clean is `01 02 00 01 00` at the start and `01 00 00 01 02`
at the end, followed by DP 102.

### DP 103 `device_state`

`01 00 00 15` + 21 data bytes. Byte numbers are payload offsets, as for
DP 107. Usual idle value:
`01 00 00 15 00 00 00 00 16 00 00 00 08 1e 01 00 00 00 00 00 01 02 00 00 00`.

| Byte | Values seen | Meaning (from the DP 116 events at the same second) |
|---|---|---|
| 5 | 0 / 1 | 1 from `collect_install` to `collect_uninstall` (waste drawer handling; 4 s to 10 min, a person at the box, 6 times in 7 days) |
| 6 | 0 / 1 | lid open (`lid_open` / `lid_close`) |
| 10 | 0 / 1 | cat inside (`cat_enter` / `cat_leave`) |
| 11 | 0 / 1 | something near (`cat_near` / `cat_near_leave`) |
| 21 | 2 / 0 | litter level: 2 `cat_litter_enough`, 0 `cat_litter_none` (1 is probably `cat_litter_little`, not seen) |
| 24 | 0 / 1 | `cat_enter_too_long_time` / `cat_enter_time_normal` |
| 8, 12, 13, 14, 20 | `16`, `08`, `1e`, `01`, `01` | never changed in 7 days. **Unconfirmed guess:** settings. `16 .. 08` would be quiet hours 22:00-08:00, `1e` = 30 the deodorant days, the `01`s auto clean / litter type. Needs a setting change to prove |
| 4, 7, 9, 15-19, 22, 23 | `00` | never changed |

### DP 114 `data_flag_01` values

`door_pir_err/ok`, `biology_err/ok`, `collect_pir_err/ok`,
`door_air_err/ok`, `flash_err/ok`, `motor_err/ok`,
`sensor_weight_err/ok`, `dump_err/ok`, `block_err/ok`,
`roller_overweight_err/ok`, `roller_install_err/ok`,
`roller_uninstall_err/ok`, `deodorant_reset`.

Seen in 7 days: `motor_ok`, `roller_uninstall_err`, `roller_uninstall_ok`.
`block_err` is the obvious candidate for a jam.

### DP 115 `data_flag_02` values

`auto_clean_enable/disable`, `stool_mode_enable/disable`,
`nodisturb_mode_enable/disable`, `auto_screen_enable/disable`,
`child_lock_enable/disable`, `cat_litter_pawbby/tofe/bentonite/mix`,
`time_zone`, `deodorant_days`, `nodisturb_time`.

These are the box's settings: auto clean, stool mode, do-not-disturb and
its hours, screen auto-off, child lock, litter type, time zone, deodorant
interval. For on/off settings the value names the new state; for
`time_zone`, `deodorant_days` and `nodisturb_time` only the name comes, so
the value must live elsewhere (DP 103's constant bytes are the candidate).

### DP 116 `data_flag_03` values

`cat_enter`, `cat_leave`, `work_idle`, `work_mclean`, `work_aclean`,
`work_empty`, `work_smooth`, `work_init`, `work_update`, `dev_reset_wifi`,
`dev_reset`, `lid_open`, `lid_close`, `cat_near`, `cat_near_leave`,
`collect_full`, `collect_normal`, `collect_install`, `collect_uninstall`,
`toilet_much`, `toilet_little`, `cat_litter_little`, `cat_litter_enough`,
`cat_litter_none`, `cat_enter_too_long_time`, `cat_enter_time_normal`,
`power_off`, `power_on`.

Counts over 7 days: `cat_near` and `cat_near_leave` 205 each, `work_idle`
188, `cat_leave` 44, `cat_enter` 39, `work_aclean` 34, `work_smooth` 7,
`collect_install` / `collect_uninstall` 6 each, `work_init` 6, `lid_open` 5,
`lid_close` 3, `cat_litter_enough` 3, `work_mclean` 2, and once each
`cat_litter_none`, `cat_enter_too_long_time`, `cat_enter_time_normal`,
`power_off`. Never seen: `collect_full`, `toilet_much/little`,
`work_update`, `dev_reset*`, `power_on`.

## Proposed LM objects and commands

Read-only first; nothing here moves the drum. Items 1-3 were built on
2026-11-11 (objects 32/3/35-37, alert texts from `docs/HELP.md`); a drum or
unknown DP 102 fault alerts after 15 min, other DP 114 `*_err` at once.
DP 116 flags (`collect_*`, `toilet_*`, `cat_litter_*`, `cat_enter_*_time`)
no longer change the state text or presence. Items 4-7 are open.

1. **Fault from DP 102** (low risk). Stop treating 102 as trace. Any
   non-zero data byte: write a short text to `32/3/15` (byte 12 ->
   "Drum out"), raise an alert if it lasts 15 min (both drum-out events in
   the log were someone servicing the box); all zero clears it. Log the
   bytes so the other 10 get named the first time they appear.
2. **DP 114 alert fix** (low risk, a bug today). The script alerts "motor
   problem" on anything but `motor_ok`, so `roller_uninstall_ok` and
   `deodorant_reset` raise false alarms. Alert only on `*_err`, with the
   part named (drum out, jam, weight sensor, ...); `*_ok` clears.
3. **New DP 116 states** (low risk). `collect_full` -> watch alert "waste
   drawer full"; `cat_litter_none` -> watch alert if it lasts 15 min (it
   showed briefly during a refill), next to the existing Litter low; `cat_enter_too_long_time` -> watch
   alert, a cat staying very long can be straining (fits the health
   monitoring); `power_off` / `power_on`, `work_update`, `dev_reset*` -> info
   alerts.
4. **DP 103 booleans** (low risk): waste drawer out (byte 5), lid open
   (6), litter level 0/1/2 (21), cat in too long (24). Log any change of the
   constant bytes 8/12/13/14/20, which is how their meaning gets confirmed
   (for example after a setting is changed on the box's own panel).
5. **Rename `32/3/25`** from "Deodorant cartridge" to "Setting changed",
   and log every DP 115 report. Label stays under 14 characters.
6. **Settings through DP 105: no, not yet.** The payload format is unknown,
   the box has never reported it, and a wrong write could switch auto clean
   off or set quiet hours across the day; the cats would then use a box
   that does not clean. Only after the app plugin's encoding for 105 is
   found (Pawbby-Reborn's APK notes are the place to look), and then one
   harmless setting first (screen auto-off), with the box watched.
7. **Commands that move the drum stay as they are.** `cancelClear`
   (`01 03 00 00` on 106) would be a useful stop button but is untested;
   test it only with someone at the box, during a manual clean, never with a
   cat near. `work_empty` (DUMP) remains test-forbidden.
