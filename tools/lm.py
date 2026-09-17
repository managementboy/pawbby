"""LogicMachine admin-session client used by deploy.sh and logs.sh.

usage: lm.py pull <id> <file>          fetch a script's source
       lm.py push <id> <file> [--force] save a script (skips if unchanged)
       lm.py logs [N] [filter] [--follow]    newest N log lines, oldest first
       lm.py errors [N] [filter] [--follow]  newest N error-log entries
         (env LM_SINCE=<unix time> drops older entries)
       lm.py toggle <id>                flip a script's enabled flag
       lm.py get <path>                 raw authenticated GET (debugging)

${NAME} placeholders in pushed files are filled from .env (see SECRETS).

<id> is the numeric script id (resident/event/scheduled) or 'user.<name>'
for a user library.

The LM's /scada-remote JSON API is disabled on this unit ("Remote services
are disabled"), so everything goes through the same cookie session the web
admin uses. Run via uv so nothing is installed globally:
    uv run --system-certs --no-project --with pynacl python tools/lm.py ...
"""
import base64
import http.cookiejar
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import nacl.public
import nacl.utils

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_env():
    path = os.path.join(ROOT, ".env")
    if not os.path.exists(path):
        sys.exit("missing .env (copy .env.example)")
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))
    for k in ("LM_HOST", "LM_USER", "LM_PASS"):
        if not os.environ.get(k):
            sys.exit(f"{k} not set in .env")


class LM:
    def __init__(self):
        load_env()
        self.base = "http://" + os.environ["LM_HOST"]
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.jar))

    def request(self, path, data=None, headers=None):
        if isinstance(data, dict):
            data = urllib.parse.urlencode(data).encode()
        # Without Origin/Referer the LM silently rejects POSTs (login just
        # re-renders the form, no error, no cookie).
        h = {"Origin": self.base, "Referer": self.base + "/scada-main/"}
        h.update(headers or {})
        req = urllib.request.Request(self.base + path, data=data, headers=h)
        try:
            with self.opener.open(req, timeout=30) as r:
                return r.status, r.geturl(), r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.geturl(), e.read()

    def ajax(self, module, action="main", params=None):
        """JSON endpoints under /scada-main/<module>/<action>. They answer
        404 unless X-Requested-With is set, which looks like a missing
        endpoint rather than a missing header."""
        st, _, body = self.request(f"/scada-main/{module}/{action}",
                                   params or {},
                                   {"X-Requested-With": "XMLHttpRequest"})
        if st != 200:
            sys.exit(f"{module}/{action}: HTTP {st}")
        return json.loads(body)

    def login(self):
        # login.js never posts the password: it seals "user:pass", zero-padded
        # to 64 bytes, in a NaCl box to the page's one-off server key.
        ref = "/scada-main/"
        _, _, body = self.request("/login?ref=" + urllib.parse.quote(ref, safe=""))
        m = re.search(rb'id="srvpubkey"[^>]*value="([^"]+)"', body)
        if not m:
            sys.exit("login page has no srvpubkey; login scheme changed?")
        srv = nacl.public.PublicKey(base64.b64decode(m.group(1)))
        eph = nacl.public.PrivateKey.generate()
        cred = (os.environ["LM_USER"] + ":" + os.environ["LM_PASS"]).encode()
        cred = cred.ljust(64, b"\0")
        nonce = nacl.utils.random(nacl.public.Box.NONCE_SIZE)
        # Box.encrypt prepends the nonce; tweetnacl's nacl.box does not.
        sealed = nacl.public.Box(eph, srv).encrypt(cred, nonce).ciphertext
        _, url, _ = self.request("/login", {
            "nonce": base64.b64encode(nonce).decode(),
            "pubkey": base64.b64encode(bytes(eph.public_key)).decode(),
            "encrypted": base64.b64encode(sealed).decode(),
            "ref": ref,
        })
        if "/login" in url:
            sys.exit("login failed (check LM_USER / LM_PASS)")
        return self

    def editor_state(self, script_id):
        """The editor page embeds the script as `$S = {...};` -- there is no
        separate JSON load endpoint."""
        path = "/scada-main/main/editor?id=" + urllib.parse.quote(str(script_id))
        _, url, body = self.request(path)
        m = re.search(r'^\$S = (.*);\s*$', body.decode("utf-8"), re.M)
        if not m:
            sys.exit(f"no $S in editor page for {script_id} ({url})")
        s = json.loads(m.group(1))
        if not s.get("success") or "script" not in s.get("data", {}):
            sys.exit(f"script {script_id} not found on LM")
        return s["data"]

    def save(self, script_id, source):
        """Mirrors the editor's Save button (scripting-editor.js submitForm
        with mode 'json'). The server compiles the Lua and rejects syntax
        errors with errors.script, leaving the stored script untouched."""
        sid = int(script_id) if str(script_id).isdigit() else script_id
        return self.ajax("scripting", "save", {
            "data": json.dumps({"id": sid, "script": None, "scriptonly": "true"}),
            "script": source,
        })

    def log_rows(self, module, n):
        return self.ajax(module, "main", {"limit": n, "start": 0}).get("data", [])


# Secrets stay out of src/: the repo holds ${NAME} placeholders, the LM holds
# the real values. push fills them in from .env, pull turns them back.
SECRETS = ("TUYA_KEY", "TUYA_ID")


def render(src):
    for name in SECRETS:
        token = "${" + name + "}"
        if token in src:
            if not os.environ.get(name):
                sys.exit(f"{token} used in source but {name} not set in .env")
            src = src.replace(token, os.environ[name])
    return src


def unrender(text):
    for name in SECRETS:
        value = os.environ.get(name)
        if value and len(value) >= 8:
            text = text.replace(value, "${" + name + "}")
    return text


def read_src(path):
    with open(path, encoding="utf-8", newline="") as f:
        return render(f.read())


def fmt_time(t):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(int(t)))


def main():
    args = sys.argv[1:]
    force = "--force" in args
    args = [a for a in args if a not in ("--force", "--follow")]
    if not args:
        sys.exit(__doc__)
    cmd = args.pop(0)
    lm = LM().login()

    if cmd == "pull" and len(args) == 2:
        data = lm.editor_state(args[0])
        # newline="" keeps the LM's \n endings on Windows.
        with open(args[1], "w", encoding="utf-8", newline="") as f:
            f.write(unrender(data["script"]))
        print(f"pulled {args[0]} -> {args[1]} ({len(data['script'])} chars)")

    elif cmd == "push" and len(args) == 2:
        sid, path = args
        src = read_src(path)
        if "\r" in src:
            sys.exit(f"{path} has CR line endings; the LM stores LF only")
        if lm.editor_state(sid)["script"] == src and not force:
            print(f"{sid}: unchanged, not saved")
            return
        res = lm.save(sid, src)
        if not res.get("success"):
            err = (res.get("errors") or {}).get("script") or json.dumps(res)
            sys.exit(f"{sid}: save REJECTED: {err}")
        if lm.editor_state(sid)["script"] != src:
            sys.exit(f"{sid}: saved but read-back differs from {path}")
        print(f"{sid}: saved {path} ({len(src)} chars), read-back verified")

    elif cmd == "toggle" and len(args) == 1:
        # Same as the editor's enable/disable button; it flips, so report.
        res = lm.ajax("scripting", "status", {"data": json.dumps(
            {"id": int(args[0]) if args[0].isdigit() else args[0]})})
        print(f"{args[0]}: active={res.get('active')}")

    elif cmd in ("logs", "errors") and len(args) <= 2:
        n = int(args[0]) if args else 50
        flt = args[1].lower() if len(args) > 1 else None
        module, text, when = (("logs", "log", "logtime") if cmd == "logs"
                              else ("errorlog", "errortext", "errortime"))
        since = float(os.environ.get("LM_SINCE", "0"))
        seen = set()

        def emit(rows):
            if flt:
                rows = [r for r in rows if flt in (r.get("scriptname") or "").lower()
                        or flt in (r.get(text) or "").lower()]
            for r in reversed(rows):
                if r["id"] in seen or r[when] < since:
                    continue
                seen.add(r["id"])
                msg = (r.get(text) or "").rstrip("\n")
                # log() prefixes each value with its type, e.g. "* string: "
                msg = re.sub(r"^\* string: ", "", msg)
                print(f"{fmt_time(r[when])}  {r.get('scriptname')}  {msg}", flush=True)

        emit(lm.log_rows(module, n))
        while "--follow" in sys.argv:
            time.sleep(3)
            # other scripts log too; fetch enough rows not to miss ours
            emit(lm.log_rows(module, 100))

    elif cmd == "get" and len(args) == 1:
        sys.stdout.buffer.write(lm.request(args[0])[2])

    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
