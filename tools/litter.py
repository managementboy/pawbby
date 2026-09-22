"""Read the pawbby_litter calibration history off the LM and summarise it, to
choose the urination threshold (URINE_LITTER_MIN in src/pawbby_resident.lua).

The LM has no HTTP way to read Lua storage, so this pushes a short read-only
dump script into a spare script slot (65, the disabled 'tuyafinder'), runs it,
reads the summary from the log, and restores the slot's original source. It
never writes to the device.

    uv run --system-certs --no-project --with pynacl python tools/litter.py
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lm as L  # noqa: E402

SLOT = 65  # disabled 'tuyafinder' capability-probe slot, reused for read-only dumps

DUMP = r"""
local d = storage.get('pawbby_litter')
if type(d) ~= 'table' or #d == 0 then log('LITCAL rows=0'); script.disable('tuyafinder'); return end
local used, per = {}, {}
for _, r in ipairs(d) do
  used[#used + 1] = r.used or 0
  local who = r.who or '?'
  per[who] = per[who] or {}
  per[who][#per[who] + 1] = r.used or 0
end
table.sort(used)
local function med(t) local s={} for i=1,#t do s[i]=t[i] end table.sort(s)
  return #s>0 and s[math.ceil(#s/2)] or 0 end
-- biggest gap in the sorted values = the valley between stool and pee clusters
local bestgap, cut = -1, nil
for i = 2, #used do local g = used[i] - used[i-1]
  if used[i-1] >= 0 and g > bestgap then bestgap = g; cut = (used[i] + used[i-1]) / 2 end end
local hist, keys = {}, {}
for _, u in ipairs(used) do local b = math.floor(u / 20) * 20; if not hist[b] then keys[#keys+1]=b end
  hist[b] = (hist[b] or 0) + 1 end
table.sort(keys)
local hs = {} for _, b in ipairs(keys) do hs[#hs + 1] = b .. 'g:' .. hist[b] end
log('LITCAL rows=' .. #used .. ' min=' .. used[1] .. ' med=' .. med(used) .. ' max=' .. used[#used])
log('LITCAL suggest=' .. math.floor((cut or 60) + 0.5) .. ' gap=' .. math.floor(bestgap + 0.5))
log('LITCAL hist ' .. table.concat(hs, ' '))
for who, list in pairs(per) do
  log('LITCAL cat ' .. who .. ' n=' .. #list .. ' med=' .. med(list))
end
script.disable('tuyafinder')
"""


def main():
    lm = L.LM().login()
    orig = lm.editor_state(SLOT)
    if orig.get("name") != "tuyafinder":
        sys.exit(f"slot {SLOT} is '{orig.get('name')}', not the expected spare; aborting")
    since = int(time.time())
    try:
        r = lm.save(SLOT, DUMP)
        if not r.get("success"):
            sys.exit(f"push failed: {json.dumps(r)}")
        lm.ajax("scripting", "status", {"data": json.dumps({"id": SLOT})})  # enable -> runs once
        time.sleep(9)
        rows = lm.log_rows("logs", 100)
    finally:
        lm.save(SLOT, orig["script"])  # restore original source (stays disabled)
    lines = [r["log"].replace("* string: ", "").strip()
             for r in rows if "LITCAL" in (r.get("log") or "") and r["logtime"] >= since]
    if not lines:
        print("no LITCAL output (slot restored). Try again in a moment.")
        return
    for line in reversed(lines):
        print(line)
    print("\nTo lock it in: set URINE_LITTER_MIN in src/pawbby_resident.lua near the"
          "\n'suggest=' value (the valley between the stool and pee humps), then"
          "\ntools/deploy.sh. Sanity: stool rows sit low, pee rows high.")


if __name__ == "__main__":
    main()
