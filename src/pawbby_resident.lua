--[[
  Resident script "pawbby" -- sleep interval 5 s (as configured on the LM).
  Requires user library "tuya34".

  Local Tuya v3.4 link to the PAWBBY litter box. Publishes state to KNX
  objects under 32/3/* and accepts commands on 32/3/10 and 32/3/11.

  Objects are created automatically on first run.
--]]

--[[ Load the library. Clearing package.loaded on script start picks up library
     edits without an LM reboot, and also clears the sentinel Lua leaves behind
     after a failed load ("loop or previous error loading module"). ]]
if not pawbby then package.loaded['user.tuya34'] = nil end
local ok, tuya = pcall(require, 'user.tuya34')
if not ok then
  package.loaded['user.tuya34'] = nil
  ok, tuya = pcall(require, 'user.tuya34')
end
if not ok then
  log('pawbby: library load failed: ' .. tostring(tuya))
  return
end

local socket = require('socket')
require('encdec')

local CFG = {
  ip  = '192.168.51.162',
  id  = '${TUYA_ID}',
  key = '${TUYA_KEY}',
  debug = false,  -- set true to log every frame incl. the tx JSON
  -- id and key are filled in from .env by tools/deploy.sh; never commit them
}

------------------------------------------------------------------ objects ---

local GA = {
  weight   = '32/3/1',    -- filtered weight in grams        (9.x  2 byte float)
  state    = '32/3/2',    -- state machine as text           (16   string)
  cat      = '32/3/3',    -- cat present                     (1    bool)
  cleaning = '32/3/4',    -- drum running                    (1    bool)
  online   = '32/3/5',    -- local connection alive          (1    bool)
  visit    = '32/3/6',    -- pulse on a completed cat visit  (1    bool)
  visits   = '32/3/7',    -- visits today                    (5    uint8)
  catkg    = '32/3/9',    -- last measured cat weight in grams  (9.x  2 byte float)
  litterlow = '32/3/13',  -- box reports litter running low      (1    bool)
  catname  = '32/3/14',   -- which cat the last visit matched    (16   string)
  fault    = '32/3/15',   -- last fault reported by the box      (16   string)
  flatten  = '32/3/10',   -- command: level the litter       (1    bool)
  empty    = '32/3/11',   -- command: DUMP the tray          (1    bool)
}

local OBJECTS = {
  { ga = GA.weight,   dt = 9,  name = 'Pawbby Weight',        units = 'g' },
  { ga = GA.state,    dt = 16, name = 'Pawbby State' },
  { ga = GA.cat,      dt = 1,  name = 'Pawbby Cat Present' },
  { ga = GA.cleaning, dt = 1,  name = 'Pawbby Cleaning' },
  { ga = GA.online,   dt = 1,  name = 'Pawbby Online' },
  { ga = GA.visit,    dt = 1,  name = 'Pawbby Visit Trigger' },
  { ga = GA.visits,   dt = 5,  name = 'Pawbby Visits Today' },
  { ga = GA.catkg,    dt = 9,  name = 'Pawbby Cat Weight',      units = 'g' },
  { ga = GA.litterlow, dt = 1,  name = 'Pawbby Litter Low' },
  { ga = GA.catname,  dt = 16, name = 'Pawbby Cat Name' },
  { ga = GA.fault,    dt = 16, name = 'Pawbby Fault' },
  { ga = GA.flatten,  dt = 1,  name = 'Pawbby Flatten' },
  { ga = GA.empty,    dt = 1,  name = 'Pawbby Empty (DUMP)' },
}

-- create any object that does not exist yet; runs once per LM boot
local function ensureobjects()
  for _, o in ipairs(OBJECTS) do
    if not grp.find(o.ga) then
      local okc, err = pcall(grp.create, {
        address = o.ga, name = o.name, datatype = o.dt, units = o.units,
      })
      log('pawbby: create ' .. o.ga .. ' ' .. o.name .. ' -> ' .. tostring(okc and 'ok' or err))
    end
  end
end

-- write only when the value actually changed, to keep the bus and logs quiet
local function put(ga, value)
  local obj = grp.find(ga)
  if obj and obj.value == value then return end
  grp.write(ga, value)
end

-------------------------------------------------------------------- state ---

--[[ DP map, confirmed on this box:
       101 raw  work state echo       106 raw  command in (AQEAAQA= flatten)
       103 raw  composite status      107 raw  cat visit summary
       111 int  raw weight ADC        112 int  filtered weight, grams
       113 int  resets on cat leave   114 enum motor status
       116 enum state machine         117 str  motor debug string          ]]

local CMDS = {
  flatten = 'AQEAAQA=',   -- work_smooth
  empty   = 'AQIAAQA=',   -- work_empty, destructive
}

--[[ Presence. cat_near_leave is deliberately NOT in here: it is the state the
     box reports once the cat has gone, so counting it as present would leave
     32/3/3 stuck at 1 and would stop the visit weight capture from ever
     closing its measurement window. ]]
local CAT_STATES = {
  cat_near = true, cat_enter = true, cat_leave = true,
}

--[[ Cat identification by weight band. Empty on purpose: the bands are to be
     derived from real samples rather than guessed. Fill in once the logged
     visit weights cluster, e.g.
       { name = 'Isma',    weight = 5200, tol = 500 },
       { name = 'Charlie', weight = 3600, tol = 500 },
     Two cats closer together than their tolerances cannot be told apart by
     weight alone; keep tol below half the gap between them. ]]
local CATS = {
}

--[[ Datapoints we have already identified. Anything outside this set is new
     and gets logged once so it can be mapped -- that is how the fault code DP
     will be caught, since it only broadcasts when something is wrong. ]]
local KNOWN_DP = {
  ['101'] = true, ['103'] = true, ['106'] = true, ['107'] = true,
  ['111'] = true, ['112'] = true, ['113'] = true, ['114'] = true,
  ['115'] = true, ['116'] = true, ['117'] = true,
}

--[[ Seen but not decoded. They are normal traffic, not faults: 109/110 are
     the tare echo and calibration result, 102 arrived after an ordinary auto
     clean. Logged with their bytes so they can be decoded, but they must not
     raise an alert or land in the Fault object. ]]
local TRACE_DP = {
  ['102'] = true, ['109'] = true, ['110'] = true,
}

-- base64 DP payload -> "01 00 00 05" for the log, raw value if not base64
local function hexdump(b64)
  local okd, raw = pcall(encdec.base64dec, b64)
  if not okd or type(raw) ~= 'string' or #raw == 0 then return b64 end
  return (raw:gsub('.', function(c) return string.format('%02x ', c:byte()) end)):sub(1, -2)
end

local function identify(w)
  local best, bestdiff = nil, math.huge
  for _, c in ipairs(CATS) do
    local d = math.abs(w - c.weight)
    if d <= (c.tol or 400) and d < bestdiff then best, bestdiff = c.name, d end
  end
  return best or 'Unknown'
end

--[[ Lid states. Used to invalidate a weight measurement: with the lid open
     the box is being handled, so anything the scale reports is not a cat. ]]
local LID_STATES = {
  lid_open = true, lid_close = true,
}

local BUSY_STATES = {
  work_smooth = true, work_aclean = true, work_mclean = true,
  work_empty = true, work_dumping = true, work_resetting = true,
}

--[[ How long a visit stays open after the box reports the cat gone. Two
     reasons, both from the 2026-09-17 09:27 visit that measured 0 g:
       - the box went cat_enter -> cat_near_leave -> cat_near -> cat_leave
         within 30 s, one visit reported as two; a re-entry inside this
         window is merged instead of closing the measurement early
       - DP 112 is a filtered value and may lag the state change
     Well inside the ~70 s before the auto clean starts moving litter. ]]
local VISIT_SETTLE = 15

-- evaluate a finished visit: peak weight minus the baseline before entry
local function finishvisit()
  local delta = (pawbby.wmax or 0) - (pawbby.wbase or 0)
  local d = math.floor(delta + 0.5)
  pawbby.settle = nil
  if pawbby.lidseen then
    log('pawbby: sample discarded, lid was open (delta ' .. d .. ' g)')
  -- ignore noise and litter shifting; a cat is at least 800 g
  elseif delta >= 800 then
    local who = identify(delta)
    put(GA.catkg, delta)
    put(GA.catname, who)
    local samples = storage.get('pawbby_samples') or {}
    if type(samples) ~= 'table' then samples = {} end
    -- p107 kept alongside so the DP 107 payload can be checked against it
    samples[#samples + 1] = {
      t = os.time(), w = d, who = who, p107 = pawbby.visit107,
    }
    -- keep the log bounded; 300 visits is plenty for clustering
    while #samples > 300 do table.remove(samples, 1) end
    storage.set('pawbby_samples', samples)
    log('pawbby: cat weight ' .. d .. ' g (base '
        .. math.floor((pawbby.wbase or 0) + 0.5) .. ' peak '
        .. math.floor((pawbby.wmax or 0) + 0.5) .. ') sample #' .. #samples)
  else
    log('pawbby: visit ignored, delta ' .. d .. ' g')
  end
  pawbby.visit107 = nil
end

if not pawbby then
  -- extra parens: storage.get returns more than one value, tonumber would
  -- take the second as a numeric base and throw
  local n = (tonumber((storage.get('pawbby_starts'))) or 0) + 1
  storage.set('pawbby_starts', n)
  log('pawbby: script start #' .. n)
  ensureobjects()
  pawbby = {
    dev = tuya.new(CFG),
    nextbeat = 0,
    nextquery = 0,
    nextretry = 0,
    last = {},
    visits = (tonumber((storage.get('pawbby_visits'))) or 0),
  }
  -- earlier versions put the harmless DP 102 into the Fault object
  local f = grp.getvalue(GA.fault)
  if type(f) == 'string' and f:find('^102:') then
    grp.write(GA.fault, '')
    log('pawbby: cleared stale fault ' .. f)
  end
end

--[[ Cat Weight and Cat Name are only meaningful if they came from a stored
     sample. With no samples (history was wiped when the lid guard arrived,
     because the 2371 g "cat" was the litter refill) whatever the objects hold
     is a leftover, so blank them rather than show a wrong weight. ]]
local function resetcatobjects()
  local samples = storage.get('pawbby_samples')
  if type(samples) == 'table' and #samples > 0 then return end
  local kg = grp.getvalue(GA.catkg)
  if kg ~= nil and kg ~= 0 then
    grp.write(GA.catkg, 0)
    grp.write(GA.catname, '')
    log('pawbby: no visit samples, cleared leftover cat weight ' .. tostring(kg))
  end
end

local now = os.time()

-- one-shot: the samples taken before the lid guard included the litter refill
if not storage.get('pawbby_samples_v2') then
  storage.set('pawbby_samples', {})
  storage.set('pawbby_samples_v2', true)
  log('pawbby: sample history cleared, lid guard now active')
end

if not pawbby.catchecked then
  pawbby.catchecked = true
  resetcatobjects()
end

--[[ Clear the visit pulse two seconds after it fired. The fallback also
     recovers a pulse left stuck at 1 by an earlier restart. ]]
if grp.getvalue(GA.visit) == true then
  if not pawbby.visitclear then pawbby.visitclear = now + 2 end
  if now >= pawbby.visitclear then
    pawbby.visitclear = nil
    grp.write(GA.visit, false)
  end
end

--[[ Visits Today means today: roll the counter over at midnight. The day is
     kept in storage so a script restart does not reset it by accident. ]]
local today = os.date('%Y-%m-%d')
if (storage.get('pawbby_day')) ~= today then
  storage.set('pawbby_day', today)
  pawbby.visits = 0
  storage.set('pawbby_visits', 0)
  grp.write(GA.visits, 0)
  log('pawbby: new day ' .. today .. ', visit counter reset')
end
local dev = pawbby.dev

----------------------------------------------------------------- connect ----

if not dev:connected() then
  put(GA.online, false)
  if now >= pawbby.nextretry then
    local okc, err = dev:connect(5)
    if okc then
      log('pawbby: connected, session key established')
      pawbby.last = {}
      pawbby.nextbeat = now + 10
      pawbby.nextquery = 0
      put(GA.online, true)
    else
      log('pawbby: ' .. tostring(err))
      pawbby.nextretry = now + 15
    end
  end
  return
end

---------------------------------------------------------------- keepalive ---

-- the device drops idle connections after roughly 30 s
if now >= pawbby.nextbeat then
  dev:heartbeat()
  pawbby.nextbeat = now + 10
end

-- CONFIRMED: this box answers query variant 1 (DP_QUERY 0x0a) only.
-- During a visit, query every cycle: we do not know that the box broadcasts
-- DP 112 while a cat is inside, and a missed peak measures 0 g.
local visiting = pawbby.inbox or pawbby.settle
if now >= pawbby.nextquery or visiting then
  dev:query(1)
  pawbby.nextquery = now + 60
end

if pawbby.settle and not pawbby.inbox and now >= pawbby.settle then
  finishvisit()
end

----------------------------------------------------------------- commands ---

--[[ KNX command objects. Both are momentary: the script clears them again so
     the button in the visualisation always sends a fresh true. ]]
local function takecmd(ga)
  local obj = grp.find(ga)
  if obj and obj.value == true then
    grp.update(ga, false)
    return true
  end
  return false
end

if takecmd(GA.flatten) then
  dev:set({ ['106'] = CMDS.flatten })
  log('pawbby: flatten requested via ' .. GA.flatten)
end

if takecmd(GA.empty) then
  dev:set({ ['106'] = CMDS.empty })
  log('pawbby: EMPTY (dump) requested via ' .. GA.empty)
end

-- storage queue kept for scripting: storage.set('pawbby_cmd', 'raw:106:AQEAAQA=')
local cmd = (storage.get('pawbby_cmd'))
if cmd then
  storage.set('pawbby_cmd', nil)
  if CMDS[cmd] then
    dev:set({ ['106'] = CMDS[cmd] })
    log('pawbby: sent ' .. cmd)
  else
    local dp, value = cmd:match('^raw:([%w_]+):(.+)$')
    if dp then
      dev:set({ [dp] = value })
      log('pawbby: sent raw dp ' .. dp .. ' = ' .. value)
    else
      log('pawbby: unknown command ' .. tostring(cmd))
    end
  end
end

-------------------------------------------------------------------- poll ----

--[[ Drain pending frames, but stay well inside one cycle: a resident script
     that overruns gets killed and restarted by LM. Budget roughly 0.8 s. ]]
--[[ Human readable state labels for the KNX object. 32/3/2 is DPT 16, so
     every label must stay within 14 characters. Unknown states fall back to
     the raw enum so a firmware change stays visible rather than silent. ]]
local STATE_TEXT = {
  work_idle      = 'Idle',
  cat_near       = 'Cat nearby',
  cat_enter      = 'Cat inside',
  cat_leave      = 'Cat leaving',
  cat_near_leave = 'Cat left',
  work_smooth    = 'Levelling',
  work_aclean    = 'Auto cleaning',
  work_mclean    = 'Deep cleaning',
  work_empty     = 'Emptying',
  lid_open       = 'Lid open',
  lid_close      = 'Lid closed',
  cat_litter_little = 'Litter low',
  cat_litter_enough = 'Litter OK',
  roller_uninstall_ok = 'Drum removed',
}

local deadline = socket.gettime() + 0.8

while socket.gettime() < deadline do
  local dps, info, rcmd, rplain = dev:poll(0.1)

  if dps then
    for k, v in pairs(dps) do
      local key, s = tostring(k), tostring(v)

      --[[ DP 107 bypasses the change filter: two visits can carry the same
           payload. It is not part of query replies (a reconnect, which
           clears pawbby.last, never produced a phantom visit), so every
           frame is a visit; the 60 s guard only drops a retransmission. ]]
      if key == '107' then
        if s ~= pawbby.last107 or now >= (pawbby.last107t or 0) + 60 then
          pawbby.last107, pawbby.last107t = s, now
          pawbby.visit107 = s
          pawbby.visits = pawbby.visits + 1
          storage.set('pawbby_visits', pawbby.visits)
          put(GA.visits, pawbby.visits)
          grp.write(GA.visit, true)
          pawbby.visitclear = now + 2
          log('pawbby: CAT VISIT (dp 107 = ' .. s .. ' [' .. hexdump(s)
              .. ']) count ' .. pawbby.visits)
        end

      elseif pawbby.last[key] ~= s then
        pawbby.last[key] = s

        if key == '112' then
          local w = tonumber(v) or 0
          put(GA.weight, w)
          pawbby.w = w
          if pawbby.inbox or pawbby.settle then
            if w > (pawbby.wmax or -1e9) then pawbby.wmax = w end
            -- trace until the capture is confirmed on real visits
            log('pawbby: visit weight ' .. w)
          end

        elseif key == '116' then
          put(GA.state, STATE_TEXT[s] or s)
          put(GA.cat, CAT_STATES[s] or false)
          put(GA.cleaning, BUSY_STATES[s] or false)
          log('pawbby: state ' .. s)

          -- litter level, reported as a state pair
          if s == 'cat_litter_little' then put(GA.litterlow, true) end
          if s:find('cat_litter_eno') then put(GA.litterlow, false) end

          -- any lid activity invalidates a measurement in progress
          if LID_STATES[s] then pawbby.lidseen = true end

          --[[ Visit weight capture. The tray reading (DP 112) rises while a
               cat stands in the box, so peak minus the baseline taken just
               before entry is the cat. Leaving only arms a settle timer;
               finishvisit() runs once it expires without a re-entry. ]]
          local present = CAT_STATES[s] or false
          if present and not pawbby.inbox then
            pawbby.inbox = true
            if pawbby.settle then
              pawbby.settle = nil
              log('pawbby: cat back within ' .. VISIT_SETTLE .. ' s, same visit')
            else
              pawbby.lidseen = false
              pawbby.visit107 = nil
              pawbby.wbase = pawbby.w or 0
              pawbby.wmax  = pawbby.w or 0
            end
          elseif not present and pawbby.inbox then
            pawbby.inbox = false
            pawbby.settle = now + VISIT_SETTLE
          end

        elseif TRACE_DP[key] then
          log('pawbby: dp ' .. key .. ' = ' .. s .. ' [' .. hexdump(s) .. ']')

        elseif not KNOWN_DP[key] then
          --[[ Any datapoint we have not mapped yet. The fault code DP only
               broadcasts when something is actually wrong (the liner jam
               produced no state change), so this is how we catch it. ]]
          log('pawbby: NEW dp ' .. key .. ' = ' .. s .. ' [' .. hexdump(s) .. ']')
          alert('PAWBBY new datapoint ' .. key .. ' = ' .. s:sub(1, 60))
          put(GA.fault, (key .. ':' .. s):sub(1, 14))
        end
      end
    end

  elseif info == 'closed' then
    log('pawbby: connection closed, reconnecting')
    dev:close()
    put(GA.online, false)
    pawbby.nextretry = now + 5
    break

  elseif info == 'timeout' or info == 'empty' then
    -- timeout: nothing pending.  empty: heartbeat ack, no payload.
    if info == 'timeout' then break end

  elseif info == 'nodps' then
    log('pawbby: ack without dps (cmd ' .. tostring(rcmd) .. ')')

  else
    -- badjson / nojson carry the decrypted text so the frame can be read
    log('pawbby: ' .. tostring(info) .. ' (cmd ' .. tostring(rcmd) .. ')'
        .. (rplain and (' ' .. string.format('%q', rplain:sub(1, 200))) or ''))
  end
end
