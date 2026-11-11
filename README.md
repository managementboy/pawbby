# pawbby-lm

Cloud-free integration of a PAWBBY smart litter box into a LogicMachine LM5
KNX controller. Everything runs on the LM: a Tuya v3.4 client written in Lua,
talking to the box over the LAN, publishing to KNX objects under `32/3/*`.

No Pi, no MQTT broker, no vendor cloud. The Pawbby backend is dead (HTTP 502)
and this does not depend on it.

## Status

Working: local connection, full state read, weight, visit counting, litter
level, flatten, **clean now** and tare commands, Mosaic tiles in the entrance
room.

Built, waiting for real visits: per-cat weight and visits (Isma, Charlie),
learned automatically from the box's own visit weighing (DP 107). Names
appear after 6 weighed visits and only once the weights form two clusters.

Fault DP found (2026-11-11): DP 102 `fault_code`, from the Tuya data model;
not yet wired to the Fault object. See `docs/DATAPOINTS.md`.

## Layout

    src/tuya34.lua            Tuya v3.4 client; install as LM user library "tuya34"
    src/pawbby_resident.lua   Resident script, sleep 0 (1 s event loop); LM script id 64
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
| 32/3/12 | Command: clean now |
| 32/3/13 | Litter low |
| 32/3/14 | Cat name (last visit) |
| 32/3/15 | Fault |
| 32/3/16 | Isma weight (g, last visit) |
| 32/3/17 | Charlie weight (g, last visit) |
| 32/3/18 | Isma visits today |
| 32/3/19 | Charlie visits today |
| 32/3/20 | Health alert (bool) |
| 32/3/21 | Health note (short text) |
| 32/3/22 | Last visit: seconds in the box (DP 107) |
| 32/3/23 | Clean cycles today |
| 32/3/24 | Last clean cycle, seconds |
| 32/3/25 | Raw DP 115: name of the last setting changed (was read as deodorant) |
| 32/3/26 | Motor / drum status, raw DP 114 |
| 32/3/27 | Motor debug text, DP 117 |
| 32/3/28 | Device info, DP 108 |
| 32/3/29 | Connections made today (1 = no drop) |
| 32/3/30 | Command: tare, refused unless idle and the scale reads under 500 g |
| 32/3/31 | Alert text (the app notifies) |
| 32/3/32 | Alert number, +1 per alert, written last |
| 32/3/33 | Alert level: 1 info, 2 watch, 3 urgent |
| 32/3/34 | Command: test alert (info, app only) |

### Per cat: 32/5/x Isma, 32/6/x Charlie

| Sub | Object |
|---|---|
| 1 | Last visit (text, "Wed 04:24") |
| 2 | Minutes since the last counted visit |
| 3 | Last visit, seconds in the box |
| 4 | Last weight (g) |
| 5 | Weight, 7-day median of daily medians (g) |
| 6 | Weight change, 7 days against 30 days (%) |
| 7 | Visits today |
| 8 | Visits per day, 14-day median |
| 9 | Health text (OK, "No visit 20 h", "Many visits 2h", "wt -6%") |
| 10 | Health level: 0 OK, 1 watch, 2 urgent |

## Records and fast alerts (phase 3)

Every visit window becomes one record in storage `pawbby_visitlog` (newest
600): start, end, cat (counted visits), box weighing and seconds, scale peak,
deposit (tray weight after minus before), lid, an estimated cat for visits the
box did not count, and the clean that followed. Daily history keeps 400 days.

Alerts go to `32/3/31-33` (the app), the LM alert list and email (watch and
urgent only), each kind at most every 6 h:

- **Urgent:** one cat with 4 counted visits within 2 h; 8 visits in a day.
- **Watch:** no visit for longer than 1.25 x the cat's own 95th-percentile gap
  over 30 days, never under 18 h (on 11 Nov: Isma 18 h, Charlie 27 h); an
  uncounted visit whose weight matches the cat also counts as a sign of life.
  Box in a busy or lid state for 10 min, or a cat state for 30 min. Box offline
  for 15 min. The daily trend check (weight, no visit, visit spike).


Command objects are momentary: write true, the script sends the command and
resets the object. Clean now is refused (and logged) unless the box is idle
with no cat, visit or lid activity. Per-cat objects stay at 0 until the cats
can be told apart.

All are **virtual** objects — 32/x is outside the KNX standard range.

## Health monitoring

The box weighs each cat and cleans after each visit, which is enough to watch
for changes in toilet habits -- an early warning to see a vet, **not** a
diagnosis. It is biased to alert: a false alarm beats a missed problem.

It tracks per-cat **litter-box visit frequency** and **weight** -- both
measured reliably. (Telling urine from stool by litter used was tried and
abandoned; see `docs/FINDINGS.md`.)

- **Acute** (same day, no baseline): a cat making an unusually high number of
  visits in a day raises an alert immediately -- the urinary-blockage catch,
  which for a male cat (Isma) is an emergency. Threshold `ACUTE_VISITS`.
- **Trend** (daily): each cat's daily visits and weight are compared to its own
  rolling baseline; a day with no visit or a visit-frequency spike raises an
  alert. The daily weight is the **median of that day's weighings**, and a
  weight alert needs `HEALTH_LOW_DAYS` (2) low days in a row: single weighings
  swing 100-150 g, and one low day gave a false alarm on 10 Nov 2026.
- Surfaced on `32/3/20` (Health alert, bool) and `32/3/21` (Health note, short
  text), plus the LM log and an LM alert. History accrues in LM storage
  (`pawbby_daily`).
- **Weekly report** (Monday, after 08:00): an email with a per-cat summary of
  the last 7 days -- weight and trend, visits per day, days used, and any
  concerns. Schedule is `WEEKLY_DAY`/`WEEKLY_HOUR` in the config.

Not a substitute for a vet; thresholds are in the config block of the resident
script and will want tuning against real data.

### Email alerts (Gmail)

A health alert also emails, if enabled. This LM firmware has **no mailer UI**,
so the script sends directly to Gmail's SMTP over SSL (port 465) using a Google
**App Password**. Sending happens outside the poll loop and is rate-limited, so
a slow SMTP call cannot overrun the resident. Setup is entirely in `.env`:

1. In Gmail, turn on 2-Step Verification, then create an **App Password**
   (Google account -> Security -> App passwords). Your normal password will not
   work for SMTP.
2. In `.env` set:
   ```
   ALERT_EMAIL=you@example.com          # where alerts go
   GMAIL_USER=youraccount@gmail.com     # the sending Gmail account
   GMAIL_APP_PASSWORD=the16charapppass  # the App Password, no spaces
   ```
3. `tools/set_secrets.sh --from-env` copies them into LM storage. Leave any of
   the three blank to keep email off. After rotating the App Password in Google:
   `tools/set_secrets.sh --mail-pass` (hidden prompt).

The App Password never enters the script or the repo: the resident reads it from
LM storage (`pawbby_mail`) on every cycle. `tools/check-secrets.sh` refuses a
commit that contains a value from `.env`.

## Configuration

Copy `.env.example` to `.env` (git-ignored) and fill in the LM login, the
Tuya device id and local key, and the mail settings. Then
`tools/set_secrets.sh --from-env` puts the secrets into LM storage
(`pawbby_tuya`, `pawbby_mail`); the script reads them from there and holds none
itself (since 2026-11-11). Without `pawbby_tuya` it logs once and does not
connect. The box IP is at the top of `src/pawbby_resident.lua`. Before the first
commit in a clone: `cp tools/pre-commit .git/hooks/pre-commit`.

The local key is obtained once from the Tuya developer platform
(Cloud project, linked app account, Query Device Details in Bulk).

## Credit

Datapoint map and `106` payloads from
[Pawbby-Reborn](https://github.com/larsjarred9/Pawbby-Reborn) (AGPL-3.0).
