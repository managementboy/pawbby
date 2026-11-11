# PAWBBY help and error texts (for the app)

Source: the PAWBBY self-cleaning litter box user manual (model MG-CLB001, manuals.plus page
"B1MjzV8K7kL", published 2023-08-09), saved by Elkin on 2026-11-11. Written here in our own
words, short, for help and error screens in Centralita. The DP mapping comes from
`DATAPOINTS.md` (Tuya data model of 2026-11-11). **"Likely"** means the manual and the DP
names fit, but the pairing hasn't been seen on our box yet.

## Error codes on the box's display

| Display | Meaning | What to do | Our DP (likely) |
|---|---|---|---|
| W00 | The box is tilted or has fallen over | Put it on clean, flat, hard ground with nothing underneath | not mapped yet |
| W01 | The drum doesn't turn, or turns stiffly | Take the drum out, clean it and the area around the motor gear, put it back; unplug for 3 s; update the firmware | `block_err` or `motor_err` (DP 114) |
| W03 | The drum is overweight | Calibrate the scale: menu "Empty cat litter", wait until the drum is empty and back at its start position | `roller_overweight_err` (DP 114) |
| E01, E02, E04, E05, E06, E09 | A part has failed | Contact PAWBBY support; nothing to fix at home | `door_pir_err`, `collect_pir_err`, `door_air_err`, `flash_err`, `sensor_weight_err`, `dump_err` (DP 114): which code is which isn't known |

## Status messages and the orange light

| On the box | Meaning | What to do | Our DP |
|---|---|---|---|
| Orange light flashing or on | It can't clean normally because of a fault, or a cat goes too often or too rarely | Check the other messages; look at the cat | DP 102 any byte ≠ 0 |
| Waste compartment full (orange flashing) | The waste drawer is full | Empty it and put in a new bag. One cat: about every 14 days, in hot weather every 7 | DP 103 / state (to confirm) |
| Lid not closed | The top lid isn't seated | Put the lid on properly | `lid_open` (DP 116), DP 103 byte |
| Waste compartment removed | The waste drawer is out or not seated | Push it back in properly | DP 103 byte 5 |
| Drum not installed / installation error | The drum isn't seated | Put it back and rock it left and right: it's seated when it no longer rolls | `roller_uninstall_err` / `roller_install_err` (DP 114), DP 102 byte 12 |
| Litter low / empty | Not enough litter | Add clumping litter (under 2 mm grains) up to the MAX mark, then "Flatten" | `cat_litter_little`, `cat_litter_none` (DP 116) |
| Cat nearby / inside | Cleaning pauses while a cat is near or inside, and resumes after it has left | Nothing; it's normal | DP 116 cat states |
| Cat inside too long | A cat has stayed in the box unusually long | Check the cat | `cat_enter_too_long_time` |

## Calibrating the scale (after moving the box, or with W03)

Menu "Empty cat litter", confirm. Calibration is done when the drum is empty and back at its
start position. Then refill the litter and "Flatten". (Our LM's Tare command does the same
zeroing over the network, but only with an empty drum.)

## Care

- **Waste bag:** one cat about every 14 days (two cats: correspondingly more often), in summer
  every 7 days. Smooth the bag's edges flat, or the full-sensor misreads.
- **Monthly clean:** empty the litter, unplug, take off the lid, drum and waste drawer, wash
  them with water, let them dry, put them back in that order. Wipe the body only with a damp
  cloth (no alcohol). Wipe the infrared sensors at the entrance and the litter port regularly.
- **Deodoriser pod:** remove the foil before fitting it. The beads may turn yellow over time,
  which is normal. Keep away from children and pets.
- **Litter:** clumping litter with grains under 2 mm (bentonite, tofu, mixed), never above MAX.

## Safety (for an info screen)

- For cats older than 6 months weighing 1.5 to 8 kg. Not for pregnant or nursing cats.
- Nothing heavier than 10 kg on the lid; nothing but a litter mat within 25 cm of the entrance.
- Use indoors, 4–40 °C, 30–70 % humidity. Unplug before cleaning.

## Not in the manual

The meaning of each E code (only "component failure"), settings ranges (auto-clean delay, quiet
hours: these are in the app, not in the manual), and the waste-full sensor's DP.
