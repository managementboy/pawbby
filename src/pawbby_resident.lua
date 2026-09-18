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

local CFG = {
  ip  = '192.168.51.162',
  id  = '${TUYA_ID}',
  key = '${TUYA_KEY}',
  debug = false,  -- set true to log every frame incl. the tx JSON
  -- id and key are filled in from .env by tools/deploy.sh; never commit them
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
     biased to alert (a false alarm beats a missed problem). Urine vs stool is
     told apart by litter used per visit -- a pee clumps a lot of litter, a
     stool little -- measured as the tray-weight drop across the clean that
     follows a visit. The gram threshold is provisional; raw grams are logged
     so it can be calibrated. ]]
local HEALTH_MIN_DAYS    = 3     -- start trend alerts after only a few days
local HEALTH_BASE_DAYS   = 14    -- rolling baseline window (days)
local HEALTH_WEIGHT_DROP = 0.05  -- >= 5 % weight loss vs baseline alerts
local HEALTH_SPIKE       = 2.0   -- a daily count >= 2x its baseline alerts
local URINE_LITTER_MIN   = 60    -- g of litter used at/above which a visit is a pee (provisional)
local URINE_ACUTE_DAY    = 5     -- urinations in one day (one cat) -> same-day alert
local ALERT_EMAIL     = '${ALERT_EMAIL}'          -- recipient; '' = email off
local GMAIL_USER      = '${GMAIL_USER}'           -- gmail address (SMTP login + From)
local GMAIL_APP_PASS  = '${GMAIL_APP_PASSWORD}'   -- a Google App Password (from .env)
local ALERT_EMAIL_MIN = 300                       -- min seconds between emails (anti-storm)
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
}

--[[ Create any object that does not exist yet; runs on script start. A new
     object has no value at all until something writes it (the object list
     shows 0, but Mosaic will not offer it), so give it a neutral one. Text
     objects get visible text: Mosaic shows an empty string as no value. ]]
local INITIAL = { [1] = false, [5] = 0, [9] = 0, [16] = '-' }

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
     Byte 8 is unknown (11, 21, 34). Anything else returns nil, and every
     visit logs this weight next to the scale peak so it keeps being checked. ]]
local function weight107(b64)
  local okd, raw = pcall(encdec.base64dec, b64)
  if not okd or type(raw) ~= 'string' or #raw ~= 9 then return nil end
  local b = { raw:byte(1, 9) }
  if b[1] ~= 1 or b[2] ~= 0 or b[3] ~= 0 or b[4] ~= 5 then return nil end
  local w = b[5] * 256 + b[6]
  if w < 1000 or w > 12000 then return nil end
  return w
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
local function recordcat(w, payload)
  local samples = storage.get('pawbby_samples')
  if type(samples) ~= 'table' then samples = {} end
  samples[#samples + 1] = { t = os.time(), w = w, src = '107', p107 = payload }
  -- keep storage bounded; learning only looks at the newest LEARN_WINDOW
  while #samples > 300 do table.remove(samples, 1) end
  local bands, why = learncats(samples)
  local idx = identify(w, bands)
  local who = idx and CAT_NAMES[idx] or 'Unknown'
  samples[#samples].who = who
  storage.set('pawbby_samples', samples)
  put(GA.catkg, w)
  put(GA.catname, who)
  if idx then
    -- grp.write, not put: the object timestamp should show this visit
    grp.write(CAT_KG[idx], w)
    local cv = storage.get('pawbby_catvisits')
    if type(cv) ~= 'table' then cv = {} end
    cv[who] = (cv[who] or 0) + 1
    storage.set('pawbby_catvisits', cv)
    put(CAT_VISITS[idx], cv[who])
  end
  log('pawbby: cat ' .. who .. ' ' .. w .. ' g ('
      .. (bands and ('bands ' .. math.floor(bands[1] + 0.5) .. '/'
                     .. math.floor(bands[2] + 0.5) .. ' g') or why)
      .. ') sample #' .. #samples)
  -- remember this visit so the following clean's litter drop can be attributed
  pawbby.lastvisit = { who = who, wbase = pawbby.wbase or 0, t = os.time(), done = false }
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

--[[ Count a finished elimination as pee or stool by litter used, and raise a
     same-day alert if one cat urinates suspiciously often. This needs no
     baseline -- it is the acute urinary / blockage catch (a blocked male cat
     is an emergency). ]]
local function tally_elim(who, used)
  local e = storage.get('pawbby_elim')
  if type(e) ~= 'table' then e = {} end
  local c = e[who] or { pee = 0, stool = 0 }
  local kind = used >= URINE_LITTER_MIN and 'urine' or 'stool'
  if kind == 'urine' then c.pee = c.pee + 1 else c.stool = c.stool + 1 end
  e[who] = c
  storage.set('pawbby_elim', e)
  log('pawbby: ' .. who .. ' ' .. kind .. ', litter used ' .. used
      .. ' g (today pee=' .. c.pee .. ' stool=' .. c.stool .. ')')
  if c.pee >= URINE_ACUTE_DAY then
    put(GA.healthbad, true)
    put(GA.healthmsg, (who .. ' pees ' .. c.pee):sub(1, 14))
    alert('PAWBBY health: ' .. who .. ' urinated ' .. c.pee
          .. 'x today, possible urinary problem -- check with a vet')
    queue_email('PAWBBY: ' .. who .. ' urinating a lot',
      who .. ' urinated ' .. c.pee .. ' times today. Frequent urination can mean a'
      .. ' urinary problem' .. (who == CAT_NAMES[1]
         and ', and in a male cat a blockage is an emergency' or '')
      .. '. Please check ' .. who .. ' and consider a vet.')
  end
end

--[[ Compare each cat's recent use and weight against its own rolling baseline
     and flag a change. Biased to alert. Sets the health objects; the full text
     also goes to the log and an LM alert. ]]
local function healthcheck(daily)
  local issues = {}
  local function base(series)
    local b = {}
    for k = math.max(1, #series - HEALTH_BASE_DAYS), #series - 1 do b[#b + 1] = series[k] end
    return median(b)
  end
  for _, name in ipairs(CAT_NAMES) do
    local vis, pees, wts, y = {}, {}, {}, nil
    for _, d in ipairs(daily) do
      local c = d[name]
      if c then
        vis[#vis + 1] = c.v or 0
        pees[#pees + 1] = c.pee or 0
        if c.w and c.w > 0 then wts[#wts + 1] = c.w end
        y = c
      end
    end
    if #vis >= HEALTH_MIN_DAYS and y then
      local mv = base(vis)
      if mv and mv >= 1 and (y.v or 0) == 0 then
        issues[#issues + 1] = name .. ' no visit'
      end
      local mp = base(pees)
      if mp and mp >= 1 and (y.pee or 0) >= mp * HEALTH_SPIKE then
        issues[#issues + 1] = name .. ' pees ' .. (y.pee or 0) .. '/' .. math.floor(mp + 0.5)
      end
    end
    if #wts >= HEALTH_MIN_DAYS then
      local mw = base(wts)
      local now_w = wts[#wts]
      if mw and now_w <= mw * (1 - HEALTH_WEIGHT_DROP) then
        issues[#issues + 1] = name .. ' wt -' .. math.floor((1 - now_w / mw) * 100 + 0.5) .. '%'
      end
    end
  end
  if #issues > 0 then
    local full = table.concat(issues, '; ')
    put(GA.healthbad, true)
    put(GA.healthmsg, full:sub(1, 14))
    log('pawbby: HEALTH ' .. full)
    alert('PAWBBY health: ' .. full .. ' -- check the cat(s) with a vet')
    queue_email('PAWBBY health alert',
      'The litter box flagged a change: ' .. full .. '.\n\nThis is an early '
      .. 'warning from the box, not a diagnosis. Please check the cat(s) and '
      .. 'consider a vet.')
  else
    put(GA.healthbad, false)
    put(GA.healthmsg, 'OK')
  end
end

--[[ Record the day that just ended (per-cat visits, pees, stools, last weight)
     and run the trend check. Called once at the midnight rollover. ]]
local function healthrollup(day)
  local daily = storage.get('pawbby_daily')
  if type(daily) ~= 'table' then daily = {} end
  local cv = storage.get('pawbby_catvisits'); if type(cv) ~= 'table' then cv = {} end
  local el = storage.get('pawbby_elim');      if type(el) ~= 'table' then el = {} end
  local rec = { d = day }
  for i, name in ipairs(CAT_NAMES) do
    local e = el[name] or {}
    rec[name] = { v = cv[name] or 0, pee = e.pee or 0, stool = e.stool or 0,
                  w = tonumber(grp.getvalue(CAT_KG[i])) or 0 }
  end
  daily[#daily + 1] = rec
  while #daily > 30 do table.remove(daily, 1) end
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
      out[#out + 1] = string.format(
        '  Litter box: %.1f visits/day, ~%.1f urinations/day, ~%.1f stools/day',
        avg('v', thisw), avg('pee', thisw), avg('stool', thisw))
      local novisit = 0
      for _, r in ipairs(thisw) do if (r.v or 0) == 0 then novisit = novisit + 1 end end
      out[#out + 1] = string.format('  Used the box on %d of %d days', #thisw - novisit, #thisw)
      local notes = {}
      if wnow and wprev and wprev > 0 and (wnow - wprev) / wprev <= -0.03 then
        notes[#notes + 1] = 'weight trending down, worth watching'
      end
      if #lastw > 0 and avg('pee', thisw) >= avg('pee', lastw) * 1.5 and avg('pee', thisw) >= 2 then
        notes[#notes + 1] = 'urinating more than the week before'
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

-- states that finish by removing a clump; the tray-weight drop across one of
-- these (never work_empty, which dumps everything) measures litter used
local CLEAN_STATES = {
  work_aclean = true, work_smooth = true, work_mclean = true,
}

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
  pawbby.visit107, pawbby.visit107w = nil, nil
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
  storage.set('pawbby_elim', {})
  for _, ga in ipairs(CAT_VISITS) do grp.write(ga, 0) end
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
          local w = weight107(s)
          if w then
            pawbby.visit107w = w
            recordcat(w, s)
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
          put(GA.state, STATE_TEXT[s] or s)
          put(GA.cat, CAT_STATES[s] or false)
          put(GA.cleaning, BUSY_STATES[s] or false)
          log('pawbby: state ' .. s)
          if pawbby.cleansent then
            log('pawbby: clean command -> ' .. s .. ' after '
                .. (now - pawbby.cleansent) .. ' s')
            if BUSY_STATES[s] then pawbby.cleansent = nil end
          end

          --[[ Litter-use capture: when a clean finishes, the drop in tray
               weight since before the last visit approximates the litter the
               cat used, which tells a pee (lots of litter) from a stool
               (little). Threshold URINE_LITTER_MIN; raw grams are logged. ]]
          if CLEAN_STATES[pawbby.laststate or ''] and s == 'work_idle'
             and pawbby.lastvisit and not pawbby.lastvisit.done
             and now - (pawbby.lastvisit.t or 0) < 300 then
            pawbby.lastvisit.done = true
            local used = math.floor((pawbby.lastvisit.wbase or 0) - (pawbby.w or 0) + 0.5)
            if used >= 10 and pawbby.lastvisit.who and pawbby.lastvisit.who ~= 'Unknown' then
              tally_elim(pawbby.lastvisit.who, used)
            else
              log('pawbby: post-clean litter delta ' .. used .. ' g ('
                  .. tostring(pawbby.lastvisit.who) .. '), not tallied')
            end
          end
          pawbby.laststate = s

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
              pawbby.visit107, pawbby.visit107w = nil, nil
              pawbby.wbase = pawbby.w or 0
              pawbby.wmax  = pawbby.w or 0
            end
          elseif not present and pawbby.inbox then
            pawbby.inbox = false
            pawbby.settle = now + VISIT_SETTLE
          end

        elseif key == '113' then
          -- possibly the box's own cat weight (see weight107); trace in visits
          if pawbby.inbox or pawbby.settle then
            log('pawbby: visit dp 113 = ' .. s)
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
