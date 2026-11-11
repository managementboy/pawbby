--[[
  Resident script "pawbby" -- sleep interval 5 s (as configured on the LM).
  Requires user library "tuya34".

  Local Tuya v3.4 link to the PAWBBY litter box. Publishes state to KNX
  objects under 32/3/* and accepts commands on 32/3/10 (flatten), 32/3/11
  (empty) and 32/3/12 (clean now).

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

--[[ Secrets live in LM storage, never in this script (it is in a public repo,
     and LM backups and exports carry script bodies):
       pawbby_tuya = { id = <Tuya device id>, key = <Tuya local key> }
       pawbby_mail = { to = <alert recipient>, user = <Gmail address>,
                       pass = <Google App Password> }   -- absent = email off
     Set them with tools/set_secrets.sh. ]]
local CFG = {
  ip  = '192.168.51.162',
  debug = false,  -- set true to log every frame incl. the tx JSON
}

-------------------------------------------------------------------- cats ----

--[[ The two cats, heaviest first. Names are handed out by weight rank once
     the DP 107 visit weights form two clusters (see learncats), so no gram
     values are hard-coded. Isma is the larger male, Charlie the smaller
     female. ]]
local CAT_NAMES = { 'Isma', 'Charlie' }
local CAT_SEX   = { 'male', 'female' }  -- parallel to CAT_NAMES; the male matters for blockage risk
local LEARN_MIN    = 6     -- DP 107 samples needed before names are given
local LEARN_WINDOW = 60    -- newest samples used, so the bands follow weight drift
local LEARN_GAP    = 400   -- g; closer clusters cannot be told apart safely
local MATCH_DEV    = 700   -- g; further than this from both cats -> Unknown

--[[ Health monitoring. Decision-support, NOT a diagnosis: it flags a change
     from each cat's own baseline so the owner checks with a vet, and it is
     biased to alert (a false alarm beats a missed problem). It tracks litter-
     box VISIT FREQUENCY and WEIGHT per cat -- both measured reliably.
     (Telling urine from stool by litter used was tried and abandoned: over 200
     real measurements the tray-weight drop was noise centred on 0 g, with half
     the readings corrupted by the cat's own weight; see FINDINGS.md.) A cat
     with a urinary problem or blockage makes many trips to the box, so visit
     frequency is the signal that matters. ]]
local HEALTH_MIN_DAYS    = 3     -- start trend alerts after only a few days
local HEALTH_BASE_DAYS   = 14    -- rolling baseline window (days)
local HEALTH_WEIGHT_DROP = 0.05  -- >= 5 % weight loss vs baseline alerts
local HEALTH_SPIKE       = 2.0   -- a daily count >= 2x its baseline alerts
local ACUTE_VISITS       = 8     -- visits in one day (one cat) -> same-day alert (no baseline)
local HEALTH_LOW_DAYS   = 2     -- weight alert needs this many low days in a row
-- email settings from storage (see CFG above); any field missing = email off
local MAIL = storage.get('pawbby_mail')
if type(MAIL) ~= 'table' then MAIL = {} end
local ALERT_EMAIL     = MAIL.to or ''     -- recipient
local GMAIL_USER      = MAIL.user or ''   -- gmail address (SMTP login + From)
local GMAIL_APP_PASS  = MAIL.pass or ''   -- a Google App Password
local ALERT_EMAIL_MIN = 300               -- min seconds between emails (anti-storm)

-- Fast alerts (phase 3). Thresholds checked against 30 Sep - 11 Nov 2026:
-- at most 3 counted visits in 2 h (Charlie), gaps between counted visits
-- up to 54 h (Charlie) and 40 h (Isma).
local FREQ_WINDOW   = 7200    -- s
local FREQ_VISITS   = 4       -- counted visits by one cat within FREQ_WINDOW -> urgent
local GAP_MIN_H     = 18      -- no-visit alert never earlier than this
local GAP_FACTOR    = 1.25    -- ... and not before 1.25 x the cat's own 95th percentile gap
local STUCK_S       = 600     -- box in a busy or lid state this long -> watch
local STUCK_CAT_S   = 1800    -- a cat state this long -> watch
local OFFLINE_S     = 900     -- box offline this long -> watch
local ALERT_REPEAT_S = 6 * 3600  -- the same alert at most every 6 h
local VISITLOG_MAX  = 600     -- visit records kept in storage (~2 months)
local WEEKLY_DAY  = 1    -- weekday to email the weekly report (0=Sun..6=Sat); 1=Mon
local WEEKLY_HOUR = 8    -- send after this hour, local time

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
  cat1kg   = '32/3/16',   -- CAT_NAMES[1] weight at their last visit (9.x)
  cat2kg   = '32/3/17',   -- CAT_NAMES[2] weight at their last visit (9.x)
  cat1visits = '32/3/18', -- CAT_NAMES[1] visits today           (5    uint8)
  cat2visits = '32/3/19', -- CAT_NAMES[2] visits today           (5    uint8)
  healthbad  = '32/3/20',  -- health: a change worth a vet check          (1    bool)
  healthmsg  = '32/3/21',  -- health: short reason, 14 char               (16   string)
  flatten  = '32/3/10',   -- command: level the litter       (1    bool)
  clean    = '32/3/12',   -- command: clean now              (1    bool)
  empty    = '32/3/11',   -- command: DUMP the tray          (1    bool)
  -- diagnostics (2026-11-11, phase 2)
  visitsecs  = '32/3/22',  -- last visit: seconds in the box, from DP 107 byte 8 (7 uint16)
  cleans     = '32/3/23',  -- clean cycles today                  (5    uint8)
  cleansecs  = '32/3/24',  -- last clean cycle, seconds           (7    uint16)
  deodorant  = '32/3/25',  -- DP 115 deodorant cartridge, raw     (16   string)
  motor      = '32/3/26',  -- DP 114 motor / drum status, raw     (16   string)
  motordbg   = '32/3/27',  -- DP 117 motor debug text             (255  text)
  device     = '32/3/28',  -- DP 108 device info, decoded text    (255  text)
  connects   = '32/3/29',  -- connections made today (1 = no drop) (7  uint16)
  tare       = '32/3/30',  -- command: zero the scale, EMPTY drum only (1 bool)
  -- alerts for the app (phase 3): the app notifies when alertno changes
  alerttext  = '32/3/31',  -- last alert text                    (255  text)
  alertno    = '32/3/32',  -- alert number, +1 per alert          (7    uint16)
  alertlevel = '32/3/33',  -- 1 info, 2 watch, 3 urgent           (5    uint8)
  testalert  = '32/3/34',  -- command: send a test alert          (1    bool)
}

local CAT_KG     = { GA.cat1kg, GA.cat2kg }
local CAT_VISITS = { GA.cat1visits, GA.cat2visits }

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
  { ga = GA.catname,  dt = 16, name = 'Pawbby Cat Name',  init = 'Unknown' },
  { ga = GA.fault,    dt = 16, name = 'Pawbby Fault',     init = 'None' },
  { ga = GA.cat1kg,   dt = 9,  name = 'Pawbby ' .. CAT_NAMES[1] .. ' Weight', units = 'g' },
  { ga = GA.cat2kg,   dt = 9,  name = 'Pawbby ' .. CAT_NAMES[2] .. ' Weight', units = 'g' },
  { ga = GA.cat1visits, dt = 5, name = 'Pawbby ' .. CAT_NAMES[1] .. ' Visits Today' },
  { ga = GA.cat2visits, dt = 5, name = 'Pawbby ' .. CAT_NAMES[2] .. ' Visits Today' },
  { ga = GA.healthbad, dt = 1,  name = 'Pawbby Health Alert' },
  { ga = GA.healthmsg, dt = 16, name = 'Pawbby Health Note', init = 'OK' },
  { ga = GA.flatten,  dt = 1,  name = 'Pawbby Flatten' },
  { ga = GA.clean,    dt = 1,  name = 'Pawbby Clean Now' },
  { ga = GA.empty,    dt = 1,  name = 'Pawbby Empty (DUMP)' },
  { ga = GA.visitsecs, dt = 7,  name = 'Pawbby Last Visit Seconds', units = 's' },
  { ga = GA.cleans,    dt = 5,  name = 'Pawbby Cleans Today' },
  { ga = GA.cleansecs, dt = 7,  name = 'Pawbby Last Clean Seconds', units = 's' },
  { ga = GA.deodorant, dt = 16, name = 'Pawbby Deodorant (DP115)' },
  { ga = GA.motor,     dt = 16, name = 'Pawbby Motor Status (DP114)' },
  { ga = GA.motordbg,  dt = 255, name = 'Pawbby Motor Debug (DP117)' },
  { ga = GA.device,    dt = 255, name = 'Pawbby Device Info (DP108)' },
  { ga = GA.connects,  dt = 7,  name = 'Pawbby Connections Today' },
  { ga = GA.tare,      dt = 1,  name = 'Pawbby Tare (empty drum only)' },
  { ga = GA.alerttext,  dt = 255, name = 'Pawbby Alert Text', init = 'None' },
  { ga = GA.alertno,    dt = 7,   name = 'Pawbby Alert Number' },
  { ga = GA.alertlevel, dt = 5,   name = 'Pawbby Alert Level' },
  { ga = GA.testalert,  dt = 1,   name = 'Pawbby Test Alert' },
}

--[[ One block of objects per cat (phase 3): 32/5/x Isma, 32/6/x Charlie.
     The older 32/3/16-19 stay as they are for Mosaic. ]]
local CATGA = {}
for i, name in ipairs(CAT_NAMES) do
  local m = '32/' .. (4 + i) .. '/'
  local c = {
    last = m .. '1', since = m .. '2', secs = m .. '3', w = m .. '4', w7 = m .. '5',
    wchg = m .. '6', visits = m .. '7', vday = m .. '8', health = m .. '9', level = m .. '10',
    limit = m .. '11',
  }
  CATGA[name] = c
  local P = 'Pawbby ' .. name .. ' '
  for _, o in ipairs({
    { c.last,   16, 'Last Visit', nil, '-' },
    { c.since,  7,  'Minutes Since Visit', 'min' },
    { c.secs,   7,  'Last Visit Seconds', 's' },
    { c.w,      9,  'Last Weight', 'g' },
    { c.w7,     9,  'Weight 7d Median', 'g' },
    { c.wchg,   9,  'Weight Change 7d vs 30d', '%' },
    { c.visits, 5,  'Visits Today' },
    { c.vday,   9,  'Visits per Day 14d' },
    { c.health, 16, 'Health', nil, 'All good' },
    { c.level,  5,  'Health Level' },
    { c.limit,  7,  'No-Visit Alert After', 'h' },
  }) do
    OBJECTS[#OBJECTS + 1] = { ga = o[1], dt = o[2], name = P .. o[3], units = o[4], init = o[5] }
  end
end

--[[ Create any object that does not exist yet; runs on script start. A new
     object has no value at all until something writes it (the object list
     shows 0, but Mosaic will not offer it), so give it a neutral one. Text
     objects get visible text: Mosaic shows an empty string as no value. ]]
local INITIAL = { [1] = false, [5] = 0, [7] = 0, [9] = 0, [16] = '-', [255] = '-' }

local function ensureobjects()
  for _, o in ipairs(OBJECTS) do
    if not grp.find(o.ga) then
      local okc, err = pcall(grp.create, {
        address = o.ga, name = o.name, datatype = o.dt, units = o.units,
      })
      local init = o.init or INITIAL[o.dt]
      if okc and init ~= nil then grp.write(o.ga, init) end
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

--[[ DP 106 payloads. flatten and empty are confirmed on this box. clean is
     the app's "clean now" (startClear) from the official app's device plugin,
     as analysed by Pawbby-Reborn: createValue(ver 1, cmd 0, flag 0) = 01 00
     00 00. The same encoding gives the tare payload confirmed here
     (resetWeight, 01 01 00 00 on DP 109), and Reborn's DP 106 sweep never
     tried command byte 00. CONFIRMED 2026-09-17 10:49: work_mclean within
     the same second, idle again after 119 s, DP 102 result sent. The
     reaction is still logged on every use (see CLEAN_WATCH). ]]
local CMDS = {
  flatten = 'AQEAAQA=',   -- work_smooth
  empty   = 'AQIAAQA=',   -- work_empty, destructive
  clean   = 'AQAAAA==',   -- startClear -> work_mclean
}

-- seconds to wait for the box to react to a clean command before logging
-- that it did not
local CLEAN_WATCH = 30

--[[ Presence. cat_near_leave is deliberately NOT in here: it is the state the
     box reports once the cat has gone, so counting it as present would leave
     32/3/3 stuck at 1 and would stop the visit weight capture from ever
     closing its measurement window. ]]
local CAT_STATES = {
  cat_near = true, cat_enter = true, cat_leave = true,
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
     the tare echo and calibration result, 102 is the clean-cycle result the
     box sends when a clean finishes (seen here after an auto clean,
     Pawbby-Reborn saw it after manual cleans). Logged with their bytes so they can be decoded, but they must not
     raise an alert or land in the Fault object. ]]
local TRACE_DP = {
  ['102'] = true, ['108'] = true, ['109'] = true, ['110'] = true,
}

-- base64 DP payload -> "01 00 00 05" for the log, raw value if not base64
local function hexdump(b64)
  local okd, raw = pcall(encdec.base64dec, b64)
  if not okd or type(raw) ~= 'string' or #raw == 0 then return b64 end
  return (raw:gsub('.', function(c) return string.format('%02x ', c:byte()) end)):sub(1, -2)
end

--[[ DP 107 carries the box's own weighing of the cat. Layout
       01 00 00 05 | WW WW | 00 | xx | 00      WW WW = grams, big endian
     Evidence, not a spec: all three samples known (one here, two in the
     Pawbby-Reborn notes) share that header and hold 4248, 4176 and 4049 g,
     and 4049 is also the DP 111/113 reading in the Reborn status capture.
     Byte 8 (second return value) is the visit length in seconds: on five
     logged visits (9-11 Nov 2026) it was 12, 15, 16, 64, 112, each the time
     from cat_enter to cat_leave minus 17-21 s. Anything else returns nil, and
     every visit logs this weight next to the scale peak so it keeps being
     checked. ]]
local function weight107(b64)
  local okd, raw = pcall(encdec.base64dec, b64)
  if not okd or type(raw) ~= 'string' or #raw ~= 9 then return nil end
  local b = { raw:byte(1, 9) }
  if b[1] ~= 1 or b[2] ~= 0 or b[3] ~= 0 or b[4] ~= 5 then return nil end
  local w = b[5] * 256 + b[6]
  if w < 1000 or w > 12000 then return nil end
  return w, b[8]
end

--[[ Two-cluster split of the recent DP 107 weights. For sorted 1-D data the
     best 2-means split is one of the n-1 cut points, so all are tried.
     Returns { heavy mean, light mean }, or nil and the reason. One cat alone
     splits into two halves less than two standard deviations apart, which
     the gap test rejects. ]]
local function learncats(samples)
  local ws = {}
  for i = #samples, 1, -1 do
    if samples[i].src == '107' then ws[#ws + 1] = samples[i].w end
    if #ws >= LEARN_WINDOW then break end
  end
  if #ws < LEARN_MIN then
    return nil, 'learning ' .. #ws .. '/' .. LEARN_MIN
  end
  table.sort(ws)
  local n, total, sq = #ws, 0, 0
  for _, w in ipairs(ws) do total = total + w; sq = sq + w * w end
  local best, cut, lsum, lsq = math.huge, nil, 0, 0
  for i = 1, n - 1 do
    lsum = lsum + ws[i]
    lsq = lsq + ws[i] * ws[i]
    local rn = n - i
    local rsum, rsq = total - lsum, sq - lsq
    local sse = (lsq - lsum * lsum / i) + (rsq - rsum * rsum / rn)
    if i >= 2 and rn >= 2 and sse < best then best, cut = sse, i end
  end
  if not cut then return nil, 'need 2 samples per cat' end
  local lo, hi = 0, 0
  for i = 1, cut do lo = lo + ws[i] end
  for i = cut + 1, n do hi = hi + ws[i] end
  lo, hi = lo / cut, hi / (n - cut)
  local sd = math.sqrt(math.max(best, 0) / n)
  if hi - lo < math.max(LEARN_GAP, 4 * sd) then
    return nil, 'one cluster (' .. math.floor(lo + 0.5) .. '/'
        .. math.floor(hi + 0.5) .. ' g too close)'
  end
  return { hi, lo }
end

-- index into CAT_NAMES, or nil when the bands are unknown or nothing is close
local function identify(w, bands)
  if not bands then return nil end
  local idx = math.abs(w - bands[1]) <= math.abs(w - bands[2]) and 1 or 2
  if math.abs(w - bands[idx]) > MATCH_DEV then return nil end
  return idx
end

-- a visit weighed by the box: store the sample, name the cat, publish
local function recordcat(w, payload, secs)
  local samples = storage.get('pawbby_samples')
  if type(samples) ~= 'table' then samples = {} end
  samples[#samples + 1] = { t = os.time(), w = w, src = '107', p107 = payload, s = secs }
  -- keep storage bounded; learning only looks at the newest LEARN_WINDOW
  while #samples > 300 do table.remove(samples, 1) end
  local bands, why = learncats(samples)
  local idx = identify(w, bands)
  local who = idx and CAT_NAMES[idx] or 'Unknown'
  samples[#samples].who = who
  storage.set('pawbby_samples', samples)
  put(GA.catkg, w)
  put(GA.catname, who)
  if secs then grp.write(GA.visitsecs, secs) end
  if idx then
    -- grp.write, not put: the object timestamp should show this visit
    grp.write(CAT_KG[idx], w)
    -- every weighing of the day, so the daily weight can be their median
    local dw = storage.get('pawbby_dayweights')
    if type(dw) ~= 'table' then dw = {} end
    dw[who] = dw[who] or {}
    table.insert(dw[who], w)
    storage.set('pawbby_dayweights', dw)
    local cv = storage.get('pawbby_catvisits')
    if type(cv) ~= 'table' then cv = {} end
    cv[who] = (cv[who] or 0) + 1
    storage.set('pawbby_catvisits', cv)
    put(CAT_VISITS[idx], cv[who])
  end
  log('pawbby: cat ' .. who .. ' ' .. w .. ' g, ' .. tostring(secs) .. ' s ('
      .. (bands and ('bands ' .. math.floor(bands[1] + 0.5) .. '/'
                     .. math.floor(bands[2] + 0.5) .. ' g') or why)
      .. ') sample #' .. #samples)
  return who
end

local function median(t)
  local n = #t
  if n == 0 then return nil end
  local x = {}
  for i = 1, n do x[i] = t[i] end
  table.sort(x)
  if n % 2 == 1 then return x[(n + 1) / 2] end
  return (x[n / 2] + x[n / 2 + 1]) / 2
end

-- queue a health email; the main loop sends it (mail() can block, so it is
-- never called from the poll loop). Empty recipient disables it.
local function queue_email(subject, body)
  if ALERT_EMAIL == '' or GMAIL_USER == '' or GMAIL_APP_PASS == '' then return end
  local q = storage.get('pawbby_email')
  if type(q) ~= 'table' or q.s then q = {} end  -- migrate old single-slot form
  q[#q + 1] = { s = subject, b = body }
  while #q > 10 do table.remove(q, 1) end
  storage.set('pawbby_email', q)
end

--[[ One alert, for the app, the LM and email. The app notifies when
     32/3/32 (alert number) changes, so that is written last. key = an alert
     that may repeat (e.g. 'gap:Isma'); it is sent at most every
     ALERT_REPEAT_S. Level 1 (info, e.g. the test) goes to the app only. ]]
local LEVELTXT = { 'Info', 'Watch', 'Urgent' }
--[[ Alerts go through the LM's shared alert library (user.alerts, plan item 5,
     2026-11-11) into the app's feeds: 'general' (every family phone) for the
     cats, 'system' (Elkin's Pixel only, with a technical detail) for the box and
     for tests. If the library is missing, the old litter-box feed 32/3/31-33 is
     written instead, so an alert is never lost. ]]
local okal = pcall(require, 'user.alerts')
local HAVE_ALERTS = okal and type(alerts) == 'table' and type(alerts.send) == 'function'

local function raisealert(level, key, text, feed, detail)
  local t = os.time()
  feed = feed or 'general'
  if key then
    local keys = storage.get('pawbby_alertkeys')
    if type(keys) ~= 'table' then keys = {} end
    if keys[key] and t - keys[key] < ALERT_REPEAT_S then return false end
    for k, v in pairs(keys) do if t - v > 86400 then keys[k] = nil end end
    keys[key] = t
    storage.set('pawbby_alertkeys', keys)
  end
  local n = (tonumber((storage.get('pawbby_alertno'))) or 0) + 1
  storage.set('pawbby_alertno', n)
  if HAVE_ALERTS then
    alerts.send(feed, level, feed == 'system' and 'Litter box' or 'Cats', text, detail)
  else
    grp.write(GA.alerttext, text:sub(1, 250))
    grp.write(GA.alertlevel, level)
    grp.write(GA.alertno, n)
  end
  log('pawbby: ALERT #' .. n .. ' [' .. LEVELTXT[level] .. '] (' .. feed .. ') ' .. text)
  if level >= 2 then
    alert('PAWBBY ' .. LEVELTXT[level] .. ': ' .. text)
    queue_email('PAWBBY ' .. LEVELTXT[level] .. ': ' .. text:sub(1, 60),
      text .. '\n\nAutomated message from the litter box, not a diagnosis.')
  end
  return true
end

--[[ Send one email straight to Gmail's SMTP over implicit SSL (port 465) with
     an App Password. This firmware has no mailer UI, so mail() has nothing to
     relay through and we do it ourselves. Blocking, so the caller runs it
     outside the poll loop and rate-limits it. Returns ok, err. ]]
local function send_email(to, subject, body)
  -- test seam: the offline harness intercepts here and never opens a socket
  local hook = rawget(_G, '__testmail')
  if hook then hook(to, subject, body); return true end
  local smtp = require('socket.smtp')
  local ssl = require('ssl')
  local params = { mode = 'client', protocol = 'tlsv1_2', verify = 'none', options = 'all' }
  local function create()
    local sock = socket.tcp()
    sock:settimeout(10)
    return setmetatable({
      connect = function(_, host, port)
        local r, e = sock:connect(host, port)
        if not r then return nil, e end
        sock = ssl.wrap(sock, params)
        sock:settimeout(10)
        return sock:dohandshake()
      end,
    }, { __index = function(_, k) return function(_, ...) return sock[k](sock, ...) end end })
  end
  return smtp.send({
    from = '<' .. GMAIL_USER .. '>',
    rcpt = '<' .. to .. '>',
    user = GMAIL_USER, password = GMAIL_APP_PASS,
    server = 'smtp.gmail.com', port = 465, create = create,
    source = smtp.message({
      headers = { from = GMAIL_USER, to = to, subject = subject },
      body = body,
    }),
  })
end

--[[ Compare each cat's recent use and weight against its own rolling baseline
     and flag a change. Biased to alert. Sets the health objects; the full text
     also goes to the log and an LM alert. ]]
-- quiet = re-evaluate and set the objects only: no LM alert, no email
local function healthcheck(daily, quiet)
  local issues = {}
  local function base(series)
    local b = {}
    for k = math.max(1, #series - HEALTH_BASE_DAYS), #series - 1 do b[#b + 1] = series[k] end
    return median(b)
  end
  for _, name in ipairs(CAT_NAMES) do
    local vis, wts, y = {}, {}, nil
    for _, d in ipairs(daily) do
      local c = d[name]
      if c then
        vis[#vis + 1] = c.v or 0
        if c.w and c.w > 0 then wts[#wts + 1] = c.w end
        y = c
      end
    end
    if #vis >= HEALTH_MIN_DAYS and y then
      local mv = base(vis)
      if mv and mv >= 1 and (y.v or 0) == 0 then
        issues[#issues + 1] = name .. ' no visit'
      end
      if mv and mv >= 2 and (y.v or 0) >= mv * HEALTH_SPIKE then
        issues[#issues + 1] = name .. ' visits ' .. (y.v or 0) .. '/' .. math.floor(mv + 0.5)
      end
    end
    --[[ Weight: a cat's weighings swing by 100-150 g from day to day, so one
         low day is noise (Charlie, 10 Nov 2026: one 4186 g weighing against
         a 4430 g median raised a false alarm). Alert only when the last
         HEALTH_LOW_DAYS daily weights are all low against the baseline of
         the days before them. ]]
    if #wts >= HEALTH_MIN_DAYS + HEALTH_LOW_DAYS - 1 then
      local b = {}
      for k = math.max(1, #wts - HEALTH_LOW_DAYS - HEALTH_BASE_DAYS + 1), #wts - HEALTH_LOW_DAYS do
        b[#b + 1] = wts[k]
      end
      local mw = median(b)
      local low, sum = true, 0
      for k = #wts - HEALTH_LOW_DAYS + 1, #wts do
        sum = sum + wts[k]
        if not mw or wts[k] > mw * (1 - HEALTH_WEIGHT_DROP) then low = false end
      end
      if low then
        local avg = sum / HEALTH_LOW_DAYS
        issues[#issues + 1] = name .. ' wt -' .. math.floor((1 - avg / mw) * 100 + 0.5) .. '%'
      end
    end
  end
  -- per cat, for the cat health objects
  local per = {}
  for _, name in ipairs(CAT_NAMES) do
    for _, txt in ipairs(issues) do
      if txt:sub(1, #name) == name then per[name] = per[name] or txt end
    end
  end
  storage.set('pawbby_catissues', per)
  if #issues > 0 and quiet then
    local full = table.concat(issues, '; ')
    put(GA.healthbad, true)
    put(GA.healthmsg, full:sub(1, 14))
    log('pawbby: HEALTH (re-check, no new alert) ' .. full)
  elseif #issues > 0 then
    local full = table.concat(issues, '; ')
    put(GA.healthbad, true)
    put(GA.healthmsg, full:sub(1, 14))
    log('pawbby: HEALTH ' .. full)
    raisealert(2, 'daily:' .. os.date('%Y-%m-%d'), 'Daily check: ' .. full
      .. '. An early warning from the box, not a diagnosis: check the cat(s) and consider a vet.')
  else
    put(GA.healthbad, false)
    put(GA.healthmsg, 'OK')
  end
end

--[[ Record the day that just ended (per-cat visits and the median of that
     day's weighings; 0 = not weighed) and run the trend check. Called once at
     the midnight rollover. ]]
local function healthrollup(day)
  local daily = storage.get('pawbby_daily')
  if type(daily) ~= 'table' then daily = {} end
  local cv = storage.get('pawbby_catvisits'); if type(cv) ~= 'table' then cv = {} end
  local dw = storage.get('pawbby_dayweights'); if type(dw) ~= 'table' then dw = {} end
  local rec = { d = day }
  for _, name in ipairs(CAT_NAMES) do
    rec[name] = { v = cv[name] or 0, w = median(dw[name] or {}) or 0 }
  end
  daily[#daily + 1] = rec
  while #daily > 400 do table.remove(daily, 1) end
  storage.set('pawbby_daily', daily)
  healthcheck(daily)
end

local function fmtkg(g) return string.format('%.2f kg', (g or 0) / 1000) end

--[[ A plain-language per-cat summary of the last 7 days (with a comparison to
     the week before), for the weekly status email. Reads the daily history. ]]
local function weekly_report(daily)
  local out = { 'PAWBBY weekly cat health report (' .. os.date('%Y-%m-%d') .. ')', '' }
  for i, name in ipairs(CAT_NAMES) do
    local recs = {}
    for _, d in ipairs(daily) do if d[name] then recs[#recs + 1] = d[name] end end
    local n = #recs
    local function slice(a, b)
      local t = {}
      for k = math.max(1, a), math.min(n, b) do t[#t + 1] = recs[k] end
      return t
    end
    local thisw, lastw = slice(n - 6, n), slice(n - 13, n - 7)
    local function avg(field, w)
      local sum = 0
      for _, r in ipairs(w) do sum = sum + (r[field] or 0) end
      return sum / math.max(#w, 1)
    end
    local function lastweight(w)
      for k = #w, 1, -1 do if (w[k].w or 0) > 0 then return w[k].w end end
    end
    out[#out + 1] = name .. ' (' .. (CAT_SEX[i] or '') .. ')'
    if #thisw == 0 then
      out[#out + 1] = '  No data yet.'
    else
      local wnow = lastweight(thisw)
      local wprev = lastweight(lastw)
      if wnow then
        local line = '  Weight: ' .. fmtkg(wnow)
        if wprev and wprev > 0 and wprev ~= wnow then
          line = line .. string.format(' (%s%.1f%% vs the week before)',
            (wnow >= wprev) and '+' or '', (wnow - wprev) / wprev * 100)
        end
        out[#out + 1] = line
      end
      out[#out + 1] = string.format('  Litter box: %.1f visits/day', avg('v', thisw))
      local novisit = 0
      for _, r in ipairs(thisw) do if (r.v or 0) == 0 then novisit = novisit + 1 end end
      out[#out + 1] = string.format('  Used the box on %d of %d days', #thisw - novisit, #thisw)
      local notes = {}
      if wnow and wprev and wprev > 0 and (wnow - wprev) / wprev <= -0.03 then
        notes[#notes + 1] = 'weight trending down, worth watching'
      end
      if #lastw > 0 and avg('v', thisw) >= avg('v', lastw) * 1.5 and avg('v', thisw) >= 2 then
        notes[#notes + 1] = 'using the box more than the week before'
      end
      if novisit >= 2 then notes[#notes + 1] = novisit .. ' days with no visit' end
      out[#out + 1] = '  Notes: ' .. (#notes > 0 and table.concat(notes, '; ')
                       or 'nothing unusual this week')
    end
    out[#out + 1] = ''
  end
  out[#out + 1] = 'Automated summary from the litter box, not a vet assessment.'
  return table.concat(out, '\n')
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


-------------------------------------------- cats and fast alerts (phase 3) ---

local function sexof(name)
  for i, n in ipairs(CAT_NAMES) do if n == name then return CAT_SEX[i] end end
end

-- per-cat state kept across restarts: { [name] = { last = t, secs = s, w = g } }
local function catstate()
  local cs = storage.get('pawbby_cats')
  if type(cs) ~= 'table' then cs = {} end
  return cs
end

--[[ How long a cat may go without a counted visit before it is worth a look:
     1.25 x its own 95th percentile gap over the last 30 days, never under
     GAP_MIN_H. Charlie often goes 24 h between counted visits, Isma rarely
     15 h, so one fixed number would be wrong for one of them. ]]
local function gapthreshold(name)
  local samples = storage.get('pawbby_samples')
  local ts = {}
  if type(samples) == 'table' then
    local since = os.time() - 30 * 86400
    for _, x in ipairs(samples) do
      if x.src == '107' and x.who == name and x.t >= since then ts[#ts + 1] = x.t end
    end
  end
  table.sort(ts)
  local gaps = {}
  for i = 2, #ts do gaps[#gaps + 1] = ts[i] - ts[i - 1] end
  table.sort(gaps)
  local p95 = #gaps >= 10 and gaps[math.max(1, math.floor(#gaps * 0.95))] or 0
  return math.max(GAP_MIN_H * 3600, GAP_FACTOR * p95)
end

-- weight over 7 days, its change against 30 days, visits per day over 14 days
local function catstats()
  local daily = storage.get('pawbby_daily')
  if type(daily) ~= 'table' then return end
  for _, name in ipairs(CAT_NAMES) do
    local w7, w30, v14 = {}, {}, {}
    for k = #daily, 1, -1 do
      local c, age = daily[k][name], #daily - k
      if c then
        if c.w and c.w > 0 then
          if age < 7 then w7[#w7 + 1] = c.w end
          if age < 30 then w30[#w30 + 1] = c.w end
        end
        if age < 14 then v14[#v14 + 1] = c.v or 0 end
      end
    end
    local g = CATGA[name]
    local m7, m30, mv = median(w7), median(w30), median(v14)
    if m7 then put(g.w7, m7) end
    if m7 and m30 and m30 > 0 then put(g.wchg, math.floor((m7 / m30 - 1) * 1000 + 0.5) / 10) end
    if mv then put(g.vday, mv) end
  end
end

-- a counted, named visit: per-cat objects, then the frequent-trips check
local function catvisit(who, w, secs, nvisits)
  local t = os.time()
  local cs = catstate()
  cs[who] = { last = t, secs = secs, w = w, seen = t }
  storage.set('pawbby_cats', cs)
  local g = CATGA[who]
  grp.write(g.last, os.date('%a %H:%M', t))
  put(g.since, 0)
  if secs then grp.write(g.secs, secs) end
  grp.write(g.w, w)
  put(g.visits, nvisits or 0)
  local samples, n = storage.get('pawbby_samples'), 0
  if type(samples) == 'table' then
    for _, x in ipairs(samples) do
      if x.src == '107' and x.who == who and t - x.t <= FREQ_WINDOW then n = n + 1 end
    end
  end
  if n >= FREQ_VISITS then
    pawbby.freq[who], pawbby.freqn[who] = t, n
    raisealert(3, 'freq:' .. who, who .. ' used the litter box ' .. n
      .. ' times in the last 2 hours. Frequent trips can mean a urinary problem'
      .. (sexof(who) == 'male' and '; in a male cat a blockage is an emergency' or '')
      .. '. Check ' .. who .. ' now.')
  end
end

-- per-cat health objects: the worst of the daily check, a long gap, frequent trips
local function cathealth(t)
  local per = storage.get('pawbby_catissues')
  if type(per) ~= 'table' then per = {} end
  local cs = catstate()
  local today = os.date('%Y-%m-%d', t)
  for _, name in ipairs(CAT_NAMES) do
    --[[ Health in words, at most 14 characters (DPT 16), for the app's tile:
         'All good', 'Weight -8%', 'No visit 20 h', 'Many visits', '4 visits in 2h',
         '8 visits today'. ]]
    local level, text = 0, 'All good'
    local issue = per[name] and per[name]:gsub('^' .. name .. ' ', '')
    if issue then
      level = 1
      if issue:find('^wt ') then text = 'Weight ' .. issue:sub(4)
      elseif issue == 'no visit' then text = 'No visit (day)'
      else text = 'Many visits' end
    end
    local c = cs[name]
    local last = c and math.max(c.last or 0, c.seen or 0)
    if last and last > 0 and t - last > (pawbby.gapthr[name] or math.huge) then
      level, text = 1, 'No visit ' .. math.floor((t - last) / 3600) .. ' h'
    end
    if pawbby.acute[name] == today then level, text = 2, ACUTE_VISITS .. ' visits today' end
    if pawbby.freq[name] and t - pawbby.freq[name] < FREQ_WINDOW then
      local n = pawbby.freqn[name] or FREQ_VISITS
      level, text = 2, n < 10 and (n .. ' visits in 2h') or 'Many visits 2h'
    end
    put(CATGA[name].level, level)
    put(CATGA[name].health, text:sub(1, 14))
  end
end

-- once a minute, connected or not
local function minutetick(t)
  local cs = catstate()
  for _, name in ipairs(CAT_NAMES) do
    local c = cs[name]
    if c and c.last then
      put(CATGA[name].since, math.min(math.floor((t - c.last) / 60), 65535))
      local thr, last = pawbby.gapthr[name], math.max(c.last, c.seen or 0)
      if thr and t - last > thr then
        raisealert(2, 'gap:' .. name, name .. ' has not used the litter box for '
          .. math.floor((t - last) / 3600) .. ' hours (alert limit '
          .. math.floor(thr / 3600 + 0.5) .. ' h, from ' .. name .. "'s own last 30 days).")
      end
    end
  end
  local st, since = pawbby.last['116'], pawbby.statesince
  if st and since then
    local lim = (CAT_STATES[st] and STUCK_CAT_S)
             or ((BUSY_STATES[st] or LID_STATES[st]) and STUCK_S)
    if lim and t - since > lim then
      raisealert(2, 'stuck:' .. st, 'The litter box has been in state ' .. st .. ' for '
        .. math.floor((t - since) / 60) .. ' minutes. Check that it is not jammed.', 'system',
        'DP 116 = ' .. st .. ' since ' .. os.date('%H:%M', since) .. '; DP 114 = '
        .. tostring(pawbby.last['114']) .. '; DP 117 = ' .. tostring(pawbby.last['117']))
    end
  end
  if pawbby.offsince and t - pawbby.offsince > OFFLINE_S then
    raisealert(2, 'offline', 'The litter box has been offline for '
      .. math.floor((t - pawbby.offsince) / 60) .. ' minutes.', 'system',
      'no Tuya session to ' .. CFG.ip .. ':6668 since ' .. os.date('%H:%M', pawbby.offsince)
      .. '; last error: ' .. tostring(pawbby.lasterr))
  end
  cathealth(t)
end

--[[ One record per visit window, counted by the box or not: the base for
     statistics, the pee/poo work (phase 4) and later the camera link.
       t0, t1  window start (cat seen) and cat gone     cat   name (counted)
       w, s    box weighing and seconds (DP 107)         peak  scale delta, g
       dep     tray weight after leaving minus before entry, g (deposit, noisy)
       est     cat guessed from the peak, uncounted visits only
       clean, wclean  the clean that followed: seconds, tray weight after ]]
local function logvisit(rec)
  local vl = storage.get('pawbby_visitlog')
  if type(vl) ~= 'table' then vl = {} end
  vl[#vl + 1] = rec
  while #vl > VISITLOG_MAX do table.remove(vl, 1) end
  storage.set('pawbby_visitlog', vl)
end

--[[ How long a visit stays open after the box reports the cat gone. Two
     reasons, both from the 2026-09-17 09:27 visit that measured 0 g:
       - the box went cat_enter -> cat_near_leave -> cat_near -> cat_leave
         within 30 s, one visit reported as two; a re-entry inside this
         window is merged instead of closing the measurement early
       - DP 112 is a filtered value and may lag the state change
     Well inside the ~70 s before the auto clean starts moving litter. ]]
local VISIT_SETTLE = 15

--[[ A visit window closed. With a DP 107 weight the box already weighed the
     cat and recordcat has run; the scale peak is only logged next to it as a
     cross-check. Without DP 107 the box did not count a visit (a peek), so
     the peak is kept as a 'peak' sample for reference but names nothing. ]]
local function finishvisit()
  local delta = (pawbby.wmax or 0) - (pawbby.wbase or 0)
  local d = math.floor(delta + 0.5)
  pawbby.settle = nil
  if pawbby.visit107w then
    log('pawbby: visit check: dp 107 ' .. pawbby.visit107w .. ' g, scale peak delta '
        .. d .. ' g' .. (pawbby.lidseen and ' (lid was open)' or ''))
  elseif pawbby.lidseen then
    log('pawbby: sample discarded, lid was open (delta ' .. d .. ' g)')
  -- ignore noise and litter shifting; a cat is at least 800 g
  elseif delta >= 800 then
    local samples = storage.get('pawbby_samples')
    if type(samples) ~= 'table' then samples = {} end
    samples[#samples + 1] = { t = os.time(), w = d, src = 'peak', p107 = pawbby.visit107 }
    while #samples > 300 do table.remove(samples, 1) end
    storage.set('pawbby_samples', samples)
    log('pawbby: ' .. (pawbby.visit107 and 'dp 107 not decoded' or 'no dp 107')
        .. ', scale delta ' .. d .. ' g (base '
        .. math.floor((pawbby.wbase or 0) + 0.5) .. ' peak '
        .. math.floor((pawbby.wmax or 0) + 0.5) .. ') kept as peak sample #' .. #samples)
  else
    log('pawbby: visit ignored, delta ' .. d .. ' g')
  end
  local rec = {
    t0 = pawbby.vstart, t1 = pawbby.vend, cat = pawbby.visitwho,
    w = pawbby.visit107w, s = pawbby.visitsecs, peak = d,
    dep = (pawbby.w and pawbby.wbase) and math.floor(pawbby.w - pawbby.wbase + 0.5) or nil,
    lid = pawbby.lidseen or nil,
  }
  if not rec.w and not pawbby.lidseen and d >= 800 then
    local idx = identify(d, (learncats(storage.get('pawbby_samples') or {})))
    rec.est = idx and CAT_NAMES[idx] or nil
    --[[ The box did not count it, but the scale says which cat was in: that
         is still a sign of life for the no-visit alert (Charlie often goes
         24 h between counted visits). Display stays on counted visits. ]]
    if rec.est then
      local cs = catstate()
      if cs[rec.est] then
        cs[rec.est].seen = rec.t1 or os.time()
        storage.set('pawbby_cats', cs)
      end
    end
  end
  logvisit(rec)
  pawbby.visit107, pawbby.visit107w = nil, nil
  pawbby.visitwho, pawbby.visitsecs = nil, nil
end

--[[ One-off (2026-11-11): the daily history used to hold each cat's LAST
     weighing of the day. Rebuild it from the stored samples as the median of
     the day's weighings, and seed today's weighings, so the new weight rule
     starts from comparable numbers. Days without samples keep their value. ]]
local function rebuilddaily()
  local samples = storage.get('pawbby_samples')
  if type(samples) ~= 'table' then samples = {} end
  local byday = {}
  for _, s in ipairs(samples) do
    if s.src == '107' and s.who and s.who ~= 'Unknown' then
      local d = os.date('%Y-%m-%d', s.t)
      byday[d] = byday[d] or {}
      byday[d][s.who] = byday[d][s.who] or {}
      table.insert(byday[d][s.who], s.w)
    end
  end
  local daily = storage.get('pawbby_daily')
  if type(daily) ~= 'table' then daily = {} end
  local changed = 0
  for _, rec in ipairs(daily) do
    for _, name in ipairs(CAT_NAMES) do
      local ws = byday[rec.d] and byday[rec.d][name]
      if rec[name] and ws then rec[name].w = median(ws); changed = changed + 1 end
    end
  end
  storage.set('pawbby_daily', daily)
  storage.set('pawbby_dayweights', byday[os.date('%Y-%m-%d')] or {})
  storage.set('pawbby_daily_median', true)
  log('pawbby: daily weights rebuilt as medians (' .. changed .. ' cat-days)')
end

if not pawbby then
  local tk = storage.get('pawbby_tuya')
  if type(tk) ~= 'table' or not tk.id or not tk.key then
    -- log once per LM start, not every cycle
    if not PAWBBY_NOKEYS then
      PAWBBY_NOKEYS = true
      log('pawbby: no Tuya id/key in storage (pawbby_tuya), not connecting')
    end
    socket.sleep(5)   -- the resident runs with sleep 0: do not spin
    return
  end
  CFG.id, CFG.key = tk.id, tk.key
  -- extra parens: storage.get returns more than one value, tonumber would
  -- take the second as a numeric base and throw
  local n = (tonumber((storage.get('pawbby_starts'))) or 0) + 1
  storage.set('pawbby_starts', n)
  log('pawbby: script start #' .. n)
  ensureobjects()
  if not storage.get('pawbby_daily_median') then
    rebuilddaily()
    -- re-evaluate the health objects under the new rule, without alerting.
    -- Only here: on a normal restart it would clear today's acute alert.
    local daily = storage.get('pawbby_daily')
    if type(daily) == 'table' and #daily > 0 then healthcheck(daily, true) end
  end
  pawbby = {
    dev = tuya.new(CFG),
    nextbeat = 0,
    nextquery = 0,
    nextretry = 0,
    last = {},
    visits = (tonumber((storage.get('pawbby_visits'))) or 0),
    -- datapoint inventory, persisted to storage every 10 min (not per frame:
    -- the LM's SD card failed once already)
    dps = (type(storage.get('pawbby_dps')) == 'table' and storage.get('pawbby_dps')) or {},
    nextdps = 0,
    freq = {}, freqn = {}, acute = {}, gapthr = {},   -- fast alert state (phase 3)
  }
  -- per-cat state: seed from the stored samples the first time
  local cs = catstate()
  local samples = storage.get('pawbby_samples')
  if type(samples) == 'table' then
    for _, x in ipairs(samples) do
      if x.src == '107' and CATGA[x.who or ''] and (not cs[x.who] or cs[x.who].last <= x.t) then
        -- samples before phase 2 have no s: read it from the stored DP 107
        local secs = x.s or (x.p107 and select(2, weight107(x.p107)))
        cs[x.who] = { last = x.t, secs = secs, w = x.w, seen = cs[x.who] and cs[x.who].seen }
      end
    end
    storage.set('pawbby_cats', cs)
  end
  for _, name in ipairs(CAT_NAMES) do
    pawbby.gapthr[name] = gapthreshold(name)
    put(CATGA[name].limit, math.floor(pawbby.gapthr[name] / 3600 + 0.5))
    local c = cs[name]
    if c then
      put(CATGA[name].last, os.date('%a %H:%M', c.last))
      if c.secs then put(CATGA[name].secs, c.secs) end
      if c.w then put(CATGA[name].w, c.w) end
    end
  end
  local cv = storage.get('pawbby_catvisits')
  for _, name in ipairs(CAT_NAMES) do
    put(CATGA[name].visits, (type(cv) == 'table' and cv[name]) or 0)
  end
  catstats()
  log('pawbby: no-visit alert after ' .. math.floor(pawbby.gapthr[CAT_NAMES[1]] / 3600 + 0.5) .. ' h ('
      .. CAT_NAMES[1] .. ') / ' .. math.floor(pawbby.gapthr[CAT_NAMES[2]] / 3600 + 0.5) .. ' h ('
      .. CAT_NAMES[2] .. ')')
  -- earlier versions parked harmless trace DPs (102, 108, ...) in the Fault
  -- object. Clear any such leftover, and an empty string (Mosaic shows '' as
  -- no value).
  local f = grp.getvalue(GA.fault)
  local dp = type(f) == 'string' and f:match('^(%d+):') or nil
  if f == '' or (dp and TRACE_DP[dp]) then
    grp.write(GA.fault, 'None')
    log('pawbby: cleared stale fault "' .. f .. '"')
  end
end

--[[ Cat Weight and Cat Name are only meaningful if they came from a DP 107
     sample. Without one (history was wiped when the lid guard arrived,
     because the 2371 g "cat" was the litter refill) whatever the objects hold
     is a leftover, so blank them rather than show a wrong weight. ]]
local function resetcatobjects()
  local samples = storage.get('pawbby_samples')
  if type(samples) == 'table' then
    for _, x in ipairs(samples) do
      if x.src == '107' then return end
    end
  end
  local kg = grp.getvalue(GA.catkg)
  if type(kg) == 'number' and kg ~= 0 then
    grp.write(GA.catkg, 0)
    grp.write(GA.catname, 'Unknown')
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
local prevday = (storage.get('pawbby_day'))
if prevday ~= today then
  storage.set('pawbby_day', today)
  -- record the day that just ended and run the health trend check first,
  -- while yesterday's counts are still in storage
  if type(prevday) == 'string' then healthrollup(prevday) end
  pawbby.visits = 0
  storage.set('pawbby_visits', 0)
  grp.write(GA.visits, 0)
  storage.set('pawbby_catvisits', {})
  storage.set('pawbby_dayweights', {})
  storage.set('pawbby_elim', {})
  storage.set('pawbby_cleans', 0)
  storage.set('pawbby_connects', 0)
  grp.write(GA.cleans, 0)
  grp.write(GA.connects, 0)
  for _, ga in ipairs(CAT_VISITS) do grp.write(ga, 0) end
  for _, name in ipairs(CAT_NAMES) do
    grp.write(CATGA[name].visits, 0)
    pawbby.gapthr[name] = gapthreshold(name)
    put(CATGA[name].limit, math.floor(pawbby.gapthr[name] / 3600 + 0.5))
  end
  catstats()
  log('pawbby: new day ' .. today .. ', visit counters reset')
end

--[[ Send a queued health email. mail() can take a couple of seconds, so it is
     done here -- once per cycle, rate-limited -- and never inside the poll
     loop. It runs before the connect/return below so mail still goes out when
     the box is offline. ]]
if ALERT_EMAIL ~= '' and GMAIL_USER ~= '' and GMAIL_APP_PASS ~= '' then
  -- weekly report: once a week, after WEEKLY_HOUR on WEEKLY_DAY
  if tonumber(os.date('%w')) == WEEKLY_DAY and tonumber(os.date('%H')) >= WEEKLY_HOUR
     and (storage.get('pawbby_weekly_sent')) ~= today then
    storage.set('pawbby_weekly_sent', today)
    local daily = storage.get('pawbby_daily')
    if type(daily) == 'table' and #daily > 0 then
      queue_email('PAWBBY weekly cat health report', weekly_report(daily))
      log('pawbby: weekly report queued')
    end
  end
  -- send one queued email per cycle, rate-limited, never in the poll loop
  local q = storage.get('pawbby_email')
  if type(q) == 'table' and #q > 0 and now >= (pawbby.nextemail or 0) then
    pawbby.nextemail = now + ALERT_EMAIL_MIN
    local msg = table.remove(q, 1)
    storage.set('pawbby_email', q)
    local pok, sok, serr = pcall(send_email, ALERT_EMAIL, msg.s, msg.b)
    local good = pok and sok
    log('pawbby: email ' .. (good and ('sent to ' .. ALERT_EMAIL)
        or ('FAILED: ' .. tostring((not pok and sok) or serr))))
  end
end

if now >= (pawbby.nexttick or 0) then
  pawbby.nexttick = now + 60
  minutetick(now)
end

local dev = pawbby.dev

----------------------------------------------------------------- connect ----

if not dev:connected() then
  put(GA.online, false)
  pawbby.offsince = pawbby.offsince or now
  if now >= pawbby.nextretry then
    local okc, err = dev:connect(5)
    if okc then
      local n = (tonumber((storage.get('pawbby_connects'))) or 0) + 1
      storage.set('pawbby_connects', n)
      put(GA.connects, n)
      log('pawbby: connected, session key established (connection ' .. n .. ' today)')
      pawbby.offsince = nil
      pawbby.last = {}
      pawbby.nextbeat = now + 10
      pawbby.nextquery = 0
      put(GA.online, true)
    else
      log('pawbby: ' .. tostring(err))
      pawbby.lasterr = tostring(err)
      pawbby.nextretry = now + 15
    end
  end
  socket.sleep(1)   -- the resident runs with sleep 0: do not spin while offline
  return
end

---------------------------------------------------------------- keepalive ---

-- the device drops idle connections after roughly 30 s
if now >= pawbby.nextbeat then
  dev:heartbeat()
  pawbby.nextbeat = now + 10
end

-- CONFIRMED: this box answers query variant 1 (DP_QUERY 0x0a) only.
-- During a visit, query every 5 s: we do not know that the box broadcasts
-- DP 112 while a cat is inside, and a missed peak measures 0 g.
local visiting = pawbby.inbox or pawbby.settle
if now >= pawbby.nextquery or (visiting and now >= (pawbby.nextvquery or 0)) then
  dev:query(1)
  pawbby.nextquery = now + 60
  pawbby.nextvquery = now + 5
end

if now >= pawbby.nextdps then
  pawbby.nextdps = now + 600
  storage.set('pawbby_dps', pawbby.dps)
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

--[[ A clean turns the drum, so it is only sent when the box is known to be
     idle: state reported and not a cat, busy or lid state, and no visit
     window open (a cat that just left may be back within VISIT_SETTLE). The
     box has its own cat sensor, but this does not rely on it. ]]
local function cleanblocked()
  local st = pawbby.last['116']
  if not st then return 'state not known yet' end
  if CAT_STATES[st] or BUSY_STATES[st] or LID_STATES[st] then return 'state ' .. st end
  if pawbby.inbox or pawbby.settle then return 'visit in progress' end
  return nil
end

local function sendclean(via)
  local why = cleanblocked()
  if why then
    log('pawbby: clean REFUSED (' .. why .. ') via ' .. via)
    return
  end
  dev:set({ ['106'] = CMDS.clean })
  pawbby.cleansent = now
  log('pawbby: clean requested via ' .. via)
end

if takecmd(GA.clean) then sendclean(GA.clean) end

if pawbby.cleansent and now >= pawbby.cleansent + CLEAN_WATCH then
  pawbby.cleansent = nil
  log('pawbby: clean command: no clean state within ' .. CLEAN_WATCH .. ' s')
end

--[[ Tare zeroes the scale (DP 109 01 01 00 00, confirmed 2026-09-17). Done
     with litter in, it would make the litter read as 0 g and spoil the cat
     weights, so it is only sent when the box is idle and the scale reads
     under TARE_MAX_G: an empty drum. ]]
local TARE_MAX_G = 500
if takecmd(GA.tare) then
  local why = cleanblocked()
  if not why and math.abs(pawbby.w or 1e9) >= TARE_MAX_G then
    why = 'scale reads ' .. tostring(pawbby.w) .. ' g, drum not empty'
  end
  if why then
    log('pawbby: tare REFUSED (' .. why .. ')')
  else
    dev:set({ ['109'] = 'AQEAAA==' })
    log('pawbby: tare sent (scale was ' .. pawbby.w .. ' g)')
  end
end

if takecmd(GA.testalert) then
  raisealert(1, nil, 'Test alert from the litter box, sent at ' .. os.date('%H:%M') .. '. Nothing is wrong.',
    'system', 'pawbby: 32/3/34 pressed; system feed, admin phone only')
end

if takecmd(GA.empty) then
  dev:set({ ['106'] = CMDS.empty })
  log('pawbby: EMPTY (dump) requested via ' .. GA.empty)
end

-- storage queue kept for scripting: storage.set('pawbby_cmd', 'raw:106:AQEAAQA=')
local cmd = (storage.get('pawbby_cmd'))
if cmd then
  storage.set('pawbby_cmd', nil)
  if cmd == 'clean' then
    sendclean('storage')
  elseif CMDS[cmd] then
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
  work_idle      = 'Ready',
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

--[[ Event loop: the resident runs with sleep 0, and each pass waits on the
     socket for up to POLL_S, so a frame from the box is handled the moment it
     arrives and the KNX command objects are looked at about once a second.
     (Before 2026-11-11: sleep 5 and 0.8 s of polling, i.e. up to 5 s late.) ]]
local POLL_S = 1.0
local deadline = socket.gettime() + POLL_S

while socket.gettime() < deadline do
  local dps, info, rcmd, rplain = dev:poll(math.max(0.05, deadline - socket.gettime()))

  if dps then
    for k, v in pairs(dps) do
      local key, s = tostring(k), tostring(v)
      -- inventory of every datapoint the box sends: last value, time, count
      local e = pawbby.dps[key] or { n = 0 }
      e.v, e.t, e.n = s:sub(1, 120), now, e.n + 1
      pawbby.dps[key] = e

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
          local w, secs = weight107(s)
          if w then
            pawbby.visit107w = w
            local who = recordcat(w, s, secs)
            pawbby.visitwho, pawbby.visitsecs = who ~= 'Unknown' and who or nil, secs
            if who ~= 'Unknown' then
              local cvc = storage.get('pawbby_catvisits')
              catvisit(who, w, secs, type(cvc) == 'table' and cvc[who] or 0)
            end
            --[[ Acute: an unusually busy day of litter-box visits can mean a
                 urinary problem or blockage (more so in a male cat). Alert
                 once, when the per-cat daily count first crosses ACUTE_VISITS;
                 catvisits resets at midnight so this fires at most once a day. ]]
            if who and who ~= 'Unknown' then
              local cvv = storage.get('pawbby_catvisits')
              local nvis = (type(cvv) == 'table' and cvv[who]) or 0
              if nvis == ACUTE_VISITS then
                put(GA.healthbad, true)
                put(GA.healthmsg, (who .. ' ' .. nvis .. ' visits'):sub(1, 14))
                pawbby.acute[who] = os.date('%Y-%m-%d')
                raisealert(3, 'acute:' .. who, who .. ' used the litter box ' .. nvis
                  .. ' times today. Frequent trips can mean a urinary problem'
                  .. (sexof(who) == 'male' and ', and in a male cat a blockage is an emergency' or '')
                  .. '. Please check ' .. who .. ' and consider a vet.')
              end
            end
          else
            log('pawbby: dp 107 layout not recognised, no cat weight')
          end
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
          pawbby.statesince = now
          put(GA.state, STATE_TEXT[s] or s)
          put(GA.cat, CAT_STATES[s] or false)
          put(GA.cleaning, BUSY_STATES[s] or false)
          log('pawbby: state ' .. s)
          if pawbby.cleansent then
            log('pawbby: clean command -> ' .. s .. ' after '
                .. (now - pawbby.cleansent) .. ' s')
            if BUSY_STATES[s] then pawbby.cleansent = nil end
          end

          --[[ Clean cycle statistics: count and duration of every auto or
               manual clean, from entering a clean state to the next state
               that is not busy. ]]
          if (s == 'work_aclean' or s == 'work_mclean') and not pawbby.cleanstart then
            pawbby.cleanstart = now
          elseif pawbby.cleanstart and not BUSY_STATES[s] then
            local secs = now - pawbby.cleanstart
            pawbby.cleanstart = nil
            local n = (tonumber((storage.get('pawbby_cleans'))) or 0) + 1
            storage.set('pawbby_cleans', n)
            put(GA.cleans, n)
            grp.write(GA.cleansecs, secs)
            log('pawbby: clean #' .. n .. ' today took ' .. secs .. ' s')
            -- attach to the visit it followed (within 15 min)
            local vl = storage.get('pawbby_visitlog')
            local last = type(vl) == 'table' and vl[#vl]
            if last and last.t1 and now - secs - last.t1 < 900 and not last.clean then
              last.clean, last.wclean = secs, pawbby.w
              storage.set('pawbby_visitlog', vl)
            end
          end

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
              pawbby.vstart, pawbby.vend = now, nil
              pawbby.visit107, pawbby.visit107w = nil, nil
              pawbby.visitwho, pawbby.visitsecs = nil, nil
              pawbby.wbase = pawbby.w or 0
              pawbby.wmax  = pawbby.w or 0
            end
          elseif not present and pawbby.inbox then
            pawbby.inbox = false
            pawbby.vend = now
            pawbby.settle = now + VISIT_SETTLE
          end

        elseif key == '114' then
          put(GA.motor, s:sub(1, 14))
          log('pawbby: dp 114 (motor) = ' .. s)
          if s ~= 'motor_ok' then
            raisealert(2, 'motor:' .. s, 'The litter box reports a motor problem (' .. s .. ').',
              'system', 'DP 114 = ' .. s .. '; DP 116 = ' .. tostring(pawbby.last['116'])
              .. '; DP 117 = ' .. tostring(pawbby.last['117']))
          end

        elseif key == '115' then
          put(GA.deodorant, s:sub(1, 14))
          log('pawbby: dp 115 (deodorant) = ' .. s)

        elseif key == '117' then
          -- changes often while the drum turns: object only, no log line
          put(GA.motordbg, s:sub(1, 250))

        elseif key == '113' then
          -- possibly the box's own cat weight (see weight107); trace in visits
          if pawbby.inbox or pawbby.settle then
            log('pawbby: visit dp 113 = ' .. s)
          end

        elseif TRACE_DP[key] then
          log('pawbby: dp ' .. key .. ' = ' .. s .. ' [' .. hexdump(s) .. ']')
          if key == '108' then
            -- 01 00 00 <len> <ascii>: keep the printable part (model/serial)
            local okd, raw = pcall(encdec.base64dec, s)
            local txt = okd and type(raw) == 'string' and raw:sub(5):gsub('[^%w%p ]', '') or ''
            if txt ~= '' then put(GA.device, txt:sub(1, 250)) end
          end

        elseif not KNOWN_DP[key] then
          --[[ Any datapoint we have not mapped yet. The fault code DP only
               broadcasts when something is actually wrong (the liner jam
               produced no state change), so this is how we catch it. ]]
          log('pawbby: NEW dp ' .. key .. ' = ' .. s .. ' [' .. hexdump(s) .. ']')
          alert('PAWBBY new datapoint ' .. key .. ' = ' .. s:sub(1, 60))
          raisealert(2, 'newdp:' .. key, 'The litter box sent an unknown message, possibly a fault.',
            'system', 'DP ' .. key .. ' = ' .. s:sub(1, 120) .. ' [' .. hexdump(s):sub(1, 100) .. ']')
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

