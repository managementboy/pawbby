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

Open: fault-code DP unidentified. See `docs/FINDINGS.md`.

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

Command objects are momentary: write true, the script sends the command and
resets the object. Clean now is refused (and logged) unless the box is idle
with no cat, visit or lid activity. Per-cat objects stay at 0 until the cats
can be told apart.

All are **virtual** objects — 32/x is outside the KNX standard range.

## Health monitoring

The box weighs each cat and cleans after each visit, which is enough to watch
for changes in toilet habits -- an early warning to see a vet, **not** a
diagnosis. It is biased to alert: a false alarm beats a missed problem.

- **Urine vs stool** is told apart by litter used per visit (tray-weight drop
  across the following clean): a pee clumps a lot of litter, a stool little.
  The gram threshold (`URINE_LITTER_MIN`) is provisional; raw grams are logged
  so it can be calibrated from real visits.
- **Acute** (same day, no baseline): one cat urinating unusually often raises
  an alert immediately -- the urinary-blockage catch, which for a male cat
  (Isma) is an emergency.
- **Trend** (daily): each cat's visits, urinations and weight are compared to
  its own rolling baseline; a weight drop, a day with no visit, or a urination
  spike raises an alert.
- Surfaced on `32/3/20` (Health alert, bool) and `32/3/21` (Health note, short
  text), plus the LM log and an LM alert. History accrues in LM storage
  (`pawbby_daily`).

Not a substitute for a vet; thresholds are in the config block of the resident
script and will want tuning against real data.

### Email alerts (Gmail)

A health alert also emails, if enabled. Sending uses the LM's built-in `mail()`
and happens outside the poll loop (rate-limited), so a slow SMTP call cannot
overrun the resident. Setup:

1. In Gmail, create an **App Password** (Google account -> Security -> 2-Step
   Verification -> App passwords). The normal password will not work.
2. In the LM's mailer/SMTP settings, configure Gmail:
   `smtp.gmail.com`, port `465`, SSL on, username = your Gmail address,
   password = the App Password, from = your Gmail address.
3. Put the recipient in `.env` as `ALERT_EMAIL=you@example.com`, then
   `tools/deploy.sh`. Leave it blank to keep email off.

The Gmail App Password lives only in the LM mailer config; the repo only ever
holds the `${ALERT_EMAIL}` placeholder (recipient is filled from `.env`).

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
