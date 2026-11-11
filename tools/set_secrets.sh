#!/usr/bin/env bash
# Put the Pawbby secrets into LM storage, where src/pawbby_resident.lua reads them.
#
#   tools/set_secrets.sh --from-env    copy TUYA_ID, TUYA_KEY, ALERT_EMAIL, GMAIL_USER,
#                                      GMAIL_APP_PASSWORD from .env into LM storage
#   tools/set_secrets.sh --mail-pass   ask for a new Google App Password at a hidden
#                                      prompt and store it (after rotating it in Google)
#   tools/set_secrets.sh --mail-off    remove the mail settings (email off)
#
# Values go over SSH stdin: never echoed, never on a command line, never in a file
# on the LM other than its storage. The script picks them up on its next start
# (Tuya keys) or next cycle (mail). LM backups contain the storage.
#
#   pawbby_tuya = { id, key }      pawbby_mail = { to, user, pass }
set -euo pipefail
cd "$(dirname "$0")/.."

LM=${LM_SSH:-root@192.168.51.10}
SSH=(ssh -i "$HOME/.ssh/lm_litzow" -o BatchMode=yes "$LM")
# Lua run on the LM: reads one JSON object from stdin and merges it into storage
STORE='require("genohm-scada"); db=require("dbenv"):new(); local json=require("json"); local t=json.pdecode(io.read("*a") or ""); if type(t)~="table" then print("nothing stored: bad input") os.exit(1) end; for k,v in pairs(t) do if v==false then storage.delete(k) print(k.." removed") else local cur=storage.get(k); if type(cur)~="table" then cur={} end; for f,x in pairs(v) do cur[f]=x end; storage.set(k,cur); local n=0; for _ in pairs(cur) do n=n+1 end; print(k.." stored ("..n.." fields)") end end'

send() { "${SSH[@]}" "lua -e '$STORE'"; }

case "${1:-}" in
  --from-env)
    python3 - <<'PY' | send
import json
env = {}
for line in open('.env'):
    line = line.strip()
    if line and not line.startswith('#') and '=' in line:
        k, v = line.split('=', 1)
        env[k.strip()] = v.strip().strip('"').strip("'")
out = {}
if env.get('TUYA_ID') and env.get('TUYA_KEY'):
    out['pawbby_tuya'] = {'id': env['TUYA_ID'], 'key': env['TUYA_KEY']}
mail = {'to': env.get('ALERT_EMAIL', ''), 'user': env.get('GMAIL_USER', ''),
        'pass': env.get('GMAIL_APP_PASSWORD', '')}
if all(mail.values()):
    out['pawbby_mail'] = mail
print(json.dumps(out))
PY
    ;;
  --mail-pass)
    read -rsp 'Paste the new Google App Password (spaces are removed), then Enter: ' P; echo
    P=${P// /}
    if [ ${#P} -lt 16 ]; then echo 'That looks too short. Nothing stored.'; exit 1; fi
    python3 -c 'import json,sys; print(json.dumps({"pawbby_mail": {"pass": sys.stdin.read().strip()}}))' <<<"$P" | send
    unset P
    ;;
  --mail-off)
    echo '{"pawbby_mail": false}' | send
    ;;
  *)
    sed -n '2,13p' "$0"; exit 1 ;;
esac
