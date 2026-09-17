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
| 102 | raw | unmapped. Seen after an auto clean finished: `01 00 00 0b` + 11 zero bytes. Logged, not alerted |
| 103 | raw | composite status blob |
| 106 | raw | command in |
| 107 | raw | cat visit summary; fires only on a real visit, ~70 s before auto-clean; not part of query replies. **Payload not yet decoded**, one sample `01 00 00 05 10 98 00 0b 00` |
| 109 | raw | weight calibration / tare. **Write confirmed**, see below |
| 110 | raw | calibration result |
| 111 | int | raw weight ADC |
| 112 | int | filtered weight, grams |
| 113 | int | resets when the cat leaves |
| 114 | enum | motor / drum status |
| 115 | enum | deodorant cartridge life (`deodorant_days`) |
| 116 | enum | state machine |
| 117 | str | motor debug string `cu= FG= BRK= PWM= POWER=` |

## Confirmed write payloads

| Action | DP | Base64 | Notes |
|--------|----|--------|-------|
| Flatten / level litter | 106 | `AQEAAQA=` | safe, use this for testing |
| Empty / dump tray | 106 | `AQIAAQA=` | destructive |
| Tare (zero the scale) | 109 | `AQEAAA==` | 4-byte `01 01 00 00`; device replies with an empty ack on cmd 0x0d |

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
