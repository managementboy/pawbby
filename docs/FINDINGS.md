# Findings and dead ends

Written so the same ground is not covered twice.

## Protocol

- **The version header is mandatory for writes.** Bare JSON gets
  `data format error` on cmd 0x0d. Prefix `"3.4"` + 12 zero bytes. Three
  different JSON envelopes were tried and all failed for this reason alone —
  the envelope was never the problem.
- `cid` must be omitted. It is for gateway sub-devices.
- `encdec.hmacsha256` on the LM returns 64 hex characters, not raw bytes.
  Convert before use.
- The LM5 has no `aes` Lua module. AES-128-ECB comes from libcrypto via
  LuaJIT FFI (`ffi.load('crypto')`, OpenSSL 3.x), padding off, PKCS#7 done
  in Lua.
- The box accepts one TCP connection at a time. The vendor app must be
  closed while the LM is connected.

## LogicMachine quirks

- `storage.get()` returns more than one value. `tonumber(storage.get(k))`
  passes the second as a numeric base and throws. Wrap in parentheses.
- Resident scripts are killed and restarted if a cycle overruns. Budget the
  poll loop by wall clock, not iteration count. A climbing restart counter is
  the symptom.
- A failed `require` leaves a sentinel in `package.loaded`, so every later
  require fails with "loop or previous error". Clear it on script start.
- `grp.create` inside `pcall` returns pcall's success flag, not the object.
  Logging `ok` proves only that nothing threw.
- 32/x addresses are **virtual** objects. The standard-object dialog rejects
  them as out of KNX range.
- DPT 16 silently truncates to 14 characters.

## LogicMachine HTTP API (for tooling)

- `/scada-remote?m=json` answers "Remote services are disabled". The admin
  cookie session is used instead; see `tools/README.md`.
- `POST /login` without `Origin`/`Referer` is silently refused: the login
  page comes back with 200, no error text, no cookie. Looks exactly like a
  wrong password.
- `/scada-main/<module>/<action>` JSON endpoints return **404** unless
  `X-Requested-With: XMLHttpRequest` is set. Looks like a wrong URL.
- A save with a Lua syntax error is rejected with the compile message and
  the stored script is left as it was.
- Saving a user library does not restart anything. Saving script 64 restarts
  it (start counter +1, reconnect within ~5 s).
- Git Bash rewrites arguments like `/scada-main/` into `C:/Program Files/Git/...`.
  Tools export `MSYS_NO_PATHCONV=1`; any `/tmp` path passed to Python then
  breaks, so use relative paths.
- The office network intercepts TLS; `uv` needs `--system-certs` to reach PyPI.

## Wrong turns worth remembering

- **Stale views.** The object list and the widget pickers cache. An object
  was declared missing when it existed; a frozen weight reading was taken as
  a stable measurement. Reload before concluding anything.
- **Lid open freezes DP 112.** Identical readings across minutes meant the
  value was latched, not steady.
- **The first captured "cat weight" was the litter refill.** The measurement
  window opened on a human-triggered `cat_near` and closed after litter went
  in. Hence the lid guard.

## Open

- DP 107 bytes 4-5 are read as the cat weight (see DATAPOINTS.md). Three
  samples fit and one matches a DP 113 reading; each visit logs it against
  the scale peak. If the two disagree over several visits, revisit this.
- DP 102 is the clean result: sent at the end of the 09:30 auto clean and
  the 10:51 manual clean, identical both times. It had been raising an
  alert and overwriting the Fault object (`102:AQAACwAAAA`); it is now logged
  with its bytes only, and the stale Fault value is cleared on start.
- The same visit logged `visit ignored, delta 0 g` twice. Two causes are
  visible in the log: the box reported one visit as
  `cat_enter -> cat_near_leave -> cat_near -> cat_leave` within 30 s, so the
  window closed after 5 s; and DP 112 was not seen changing at all. Object
  logging is off, so whether the box broadcasts DP 112 during a visit is
  **unknown**. Changed in response (unconfirmed until a real visit):
  leaving arms a 15 s settle window that a re-entry merges into, the script
  queries every cycle while a visit is open, and every weight change during
  a visit is logged as `visit weight N`. Check those lines after the next
  visit before trusting `Cat Weight`.
- `Cat Weight` held 2371.84 g (the litter refill) with no stored sample
  behind it. On start the script now blanks Cat Weight / Cat Name when
  `pawbby_samples` is empty; done 2026-09-17 10:13, both now 0 / empty.
- A visit whose DP 107 payload was identical to the previous one was not
  counted (it went through the change filter). Fixed; `tests/replay_visit.lua`
  covers it.
- Script 64 runs with a **5 s** sleep interval on the LM; the docs said 1 s.
  Docs now follow the LM. Commands on 32/3/10 and 32/3/11 can take up to 5 s.
- `badjson (cmd 8)` logged once (09:38:10). The frame text is now included
  in that log line so it can be read next time.
- Event script 63 "Pawbby" on the LM is a leftover capability probe
  (hmac/aes/socket checks), triggered by the `Pawbby` tag. **Disabled**
  2026-09-17 (source unchanged); delete it once nobody needs it.
- Fault-code DP unidentified; the liner jam was invisible to every mapped DP.
- Mosaic does not offer newly created objects in its widget pickers. Reload,
  "Save project", localStorage clear and seeding a value all failed to
  refresh it. Cache location unknown.
- Per-cat bands are learned, not configured: once 6 DP 107 weights exist,
  a two-cluster split of the newest 60 names the heavier cluster Isma and the
  lighter Charlie, if the clusters are at least 400 g and 4 standard
  deviations apart. Until then, or if the cats weigh too alike, the name is
  `Unknown` and the log says why. Unconfirmed until real visits accumulate.

## Pee vs stool: not calibrated yet

The weekly report splits eliminations into urinations and stools by litter used
per visit (tray-weight drop across the clean that follows). The threshold
`URINE_LITTER_MIN` (60 g) is a **guess** -- early reports showed ~0 stools,
which is a threshold/coverage artifact, not reality. Every clean-based
measurement is now persisted to `pawbby_litter` in storage (time, cat, weight,
grams). Once a week or two of real rows exist, read them, look at the
distribution, set the threshold, and check whether both cats' visits actually
produce a measurement (a visit with no auto-clean yields none). Until then,
treat the pee/stool counts as provisional.

## Clean now

- Pawbby-Reborn concluded the manual clean could not be triggered remotely:
  every DP 106 command byte 01-30, DPs 1-66, 101, 105, 107-150 and the Tuya
  cloud were tried. Byte 00 was never tried. Their own APK analysis of the
  app plugin lists `startClear` = `01000000` on topic 106, and the app did
  have "clean now".
- Sent as DP 106 `AQAAAA==` on 2026-09-17 10:49:32 with the box idle:
  `work_mclean` in the same second, `work_idle` + DP 102 at 10:51:31.
- The script refuses it unless DP 116 is known and not a cat, busy or lid
  state and no visit window is open. The box has its own cat detection;
  the interlock does not rely on it.

## Credit

The DP map, the state machine and the `106` payloads come from the
Pawbby-Reborn project (github.com/larsjarred9/Pawbby-Reborn), AGPL-3.0.
The tare payload, the working clean-now payload (`AQAAAA==`, from their
own APK notes), the DP 107 weight layout, the `lid_*` and `cat_litter_*` states and the
`deodorant_days` identification were established here and should be sent
back to them.
