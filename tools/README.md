# Tools

Needs `uv` (PyNaCl is pulled into a throwaway env, nothing is installed
globally) and a `.env` in the repo root — copy `.env.example`. `.env` is
git-ignored; never commit it.

Secrets are not in `src/` and not in the script on the LM: they live in LM
storage (`pawbby_tuya`, `pawbby_mail`), put there by `set_secrets.sh` over SSH.
(Until 2026-11-11 `lm.py push` filled `${...}` placeholders into the script;
there are none left, so that step is a no-op.)

The GitHub repo is **public**. `tools/check-secrets.sh` refuses a commit that
contains any secret value from `.env`; install it in every clone with
`cp tools/pre-commit .git/hooks/pre-commit`. `--all` scans the working tree.

| Script | What it does |
|--------|--------------|
| `set_secrets.sh` | `--from-env`: copy the Tuya id/key and mail settings from `.env` into LM storage. `--mail-pass`: hidden prompt for a rotated App Password. `--mail-off`: email off. Over SSH (key `~/.ssh/lm_litzow`), values on stdin only. |
| `deploy.sh` | Push `src/tuya34.lua` → user library `tuya34`, `src/pawbby_resident.lua` → script 64. Skips unchanged files, verifies by read-back, then watches the log for 20 s and fails unless there is exactly one `script start` and no new error-log entry. |
| `deploy.sh --dry-run` | Diff local `src/` against what is on the LM. No writes. |
| `logs.sh [N] [filter]` | Last N lines of the LM script log matching `filter` (default `pawbby`). `-f` follows, `-e` reads the error log. |
| `../tests/run.sh` | Offline: LuaJIT syntax check of `src/*.lua` and a replay of real visit sequences through the resident script. Run before every deploy. |
| `lm.py` | The client both wrap. `pull <id> <file>` fetches any script; `press <ga>` sets a command object true like the object list does (refuses 32/3/11, the dump); `get <path>` is a raw authenticated GET for poking at the admin UI. |

Pull the LM's current copy back into the repo (e.g. after someone edited in
the browser):

    MSYS_NO_PATHCONV=1 uv run --system-certs --no-project --with pynacl \
      python tools/lm.py pull 64 src/pawbby_resident.lua

A library change alone does nothing until script 64 restarts (it only
re-requires on a fresh global state), so `deploy.sh` force-saves script 64
whenever the library was saved. Saving a script is what restarts it.

## How the LM HTTP API was driven

Established against firmware 20251204. See `docs/FINDINGS.md` for the gotchas.

- `/scada-remote` is **disabled** on this LM. Not used; enabling it would be
  a system setting change.
- Login: `GET /login` → form with `srvpubkey`. `POST /login` with `nonce`,
  `pubkey`, `encrypted` = `nacl.box("user:pass" zero-padded to 64 B, nonce,
  srvpubkey, ephemeral key)`, `ref`. Session is the `x-login`/`x-session` cookies.
- Read a script: `GET /scada-main/main/editor?id=<id>`; the source is in the
  embedded `$S = {...};`. Ids: numeric for resident/event, `user.<name>` for
  libraries.
- Save: `POST /scada-main/scripting/save`, fields
  `data={"id":<id>,"script":null,"scriptonly":"true"}` and `script=<source>`.
  Reply `{"success":true}`; the server compiles the Lua and rejects syntax
  errors with `errors.script` and keeps the stored script unchanged. Confirmed
  2026-09-17 on the disabled script 63: `[string "userscript"]:2: ')' expected`
  came back, read-back showed the original. `lm.py push` exits non-zero on it.
- Logs: `POST /scada-main/logs/main` and `/scada-main/errorlog/main` with
  `limit`, `start`.
- Set an object: `POST /scada-main/objects/setvalue`,
  `data={"value":"true","type":"bool","datatype":1,"address":"32/3/12"}`
  (value JSON-encoded as a string).

## Still to write

Per-cat clustering is no longer a separate tool: it runs live inside
`src/pawbby_resident.lua` (`learncats`), which splits the recent DP 107 weights
into two bands and names the cats. Confirmed on real visits 2026-09-18
(Isma ~4.73 kg, Charlie ~4.11 kg).

Optional, not yet written:

- `samples.py` — export the `pawbby_samples` history out of LM storage to CSV
  for offline analysis (the resident script already keeps up to 300, each with
  timestamp, weight, cat and raw DP 107 payload).

## Deploying over SSH (no web login)

When the LM web login is not available, the same result over SSH as root:
copy `src/pawbby_resident.lua` to `/tmp`, `loadstring` it to check syntax,
`db:update('scripting', {script = src}, {id = 64})`, read it back, then
`lmscripting.reloadsingle(db:getrow('SELECT * FROM scripting WHERE id=64'))`.
`reloadsingle` takes the **row**, not the id (`reloadsingle(64)` throws
"attempt to index a number value"). Then check the log for exactly one
`script start` and the error table for nothing new, as `deploy.sh` does.
Used for the 2026-11-11 deploy.
