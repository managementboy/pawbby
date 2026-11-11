--[[ Offline replay of pawbby_resident.lua against mocked LM globals and a fake
     device. Frames are fed per 5 s script cycle. Run: tests/run.sh ]]
local SRC = ...
local T0 = 1789630000   -- 2026-09-17, morning
local clock, logs, objects, store, alerts, queries, inbox, writes, mails

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local function b64enc(raw)
  return ((raw:gsub('.', function(x)
    local r, b = '', x:byte()
    for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and '1' or '0') end
    return r
  end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
    if #x < 6 then return '' end
    local c = 0
    for i = 1, 6 do c = c + (x:sub(i, i) == '1' and 2 ^ (6 - i) or 0) end
    return B64:sub(c + 1, c + 1)
  end) .. ({ '', '==', '=' })[#raw % 3 + 1])
end

local function b64dec(s)
  s = s:gsub('[^' .. B64 .. '=]', '')
  return (s:gsub('.', function(x)
    if x == '=' then return '' end
    local r, f = '', (B64:find(x, 1, true) - 1)
    for i = 6, 1, -1 do r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and '1' or '0') end
    return r
  end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
    if #x ~= 8 then return '' end
    local c = 0
    for i = 1, 8 do c = c + (x:sub(i, i) == '1' and 2 ^ (8 - i) or 0) end
    return string.char(c)
  end))
end

-- DP 107 payload in the observed layout 01 00 00 05 WW WW 00 0b 00
local function p107(w)
  return b64enc(string.char(1, 0, 0, 5, math.floor(w / 256), w % 256, 0, 11, 0))
end

local dev = {
  connected = function() return true end,
  heartbeat = function() end,
  query = function() queries = queries + 1 end,
  set = function(_, dps) writes[#writes + 1] = dps end,
  poll = function()
    local f = table.remove(inbox, 1)
    if f then return f end
    return nil, 'timeout'
  end,
}

os.time = function() return clock end
local realdate = os.date
os.date = function(f, t) return realdate(f, t or clock) end
function log(s) logs[#logs + 1] = string.format('%6d %s', clock - T0, s) end
function alert(s) alerts[#alerts + 1] = s end
-- send_email() in the script calls this hook instead of opening a real socket
function __testmail(to, subj, body) mails[#mails + 1] = { to = to, s = subj, b = body } end
grp = {
  find = function(ga) return objects[ga] ~= nil and { value = objects[ga] } or nil end,
  getvalue = function(ga) return objects[ga] end,
  write = function(ga, v) objects[ga] = v end,
  update = function(ga, v) objects[ga] = v end,
  create = function(o) end,   -- like the LM: a created object has no value
}
storage = { get = function(k) return store[k], 'x' end,  -- 2nd value like LM
            set = function(k, v) store[k] = v end }
encdec = { base64dec = b64dec }
package.preload['user.tuya34'] = function() return { new = function() return dev end } end
package.preload['socket'] = function() return { gettime = function() return clock end, sleep = function() end } end
package.preload['encdec'] = function() return encdec end

local chunk = assert(loadstring(SRC, '=pawbby_resident'))

local function world()
  pawbby = nil
  clock, logs, objects, store, alerts, queries, inbox, writes, mails = T0, {}, {}, {}, {}, 0, {}, {}, {}
  -- secrets come from LM storage now; fake ones here
  store.pawbby_tuya = { id = 'testdevice', key = '0123456789abcdef' }
  store.pawbby_mail = { to = 'alerts@example.invalid', user = 'box@example.invalid', pass = 'x' }
  store.pawbby_daily_median = true   -- skip the one-off rebuild (tested in 10)
end

-- one entry per 5 s cycle: list of dps tables arriving in that cycle
local function run(cycles)
  for _, frames in ipairs(cycles) do
    for _, d in ipairs(frames) do inbox[#inbox + 1] = d end
    chunk()
    clock = clock + 5
  end
end

local idle = {}
local function visit(w, base)
  base = base or 2342
  run({
    { { ['116'] = 'cat_enter' } }, { { ['112'] = base + w } },
    { { ['107'] = p107(w) } }, { { ['112'] = base } },
    { { ['116'] = 'cat_near_leave' } }, idle, idle, idle, idle,
    { { ['116'] = 'work_idle' } }, idle,
  })
end

local function check(c, m) if not c then error('FAIL: ' .. m, 0) end end
local function logged(text)
  return table.concat(logs, '\n'):find(text, 1, true) ~= nil
end
local function samples(src)
  local n = {}
  for _, s in ipairs(store.pawbby_samples or {}) do
    if not src or s.src == src then n[#n + 1] = s end
  end
  return n
end
local function dump(title)
  print('== ' .. title)
  for _, l in ipairs(logs) do print(l) end
end

------------------------------------------------ 1. the real 09:27 visit ---
world()
objects['32/3/15'] = '102:AQAACwAAAA'   -- the stale fault seen on the LM
objects['32/3/9'] = 2371.84             -- litter refill left in Cat Weight
run({
  { { ['112'] = 2342, ['116'] = 'work_idle' } },
  { { ['116'] = 'cat_near' } },                         -- 09:26:56
  idle,
  { { ['116'] = 'cat_enter' } },                        -- 09:27:12
  { { ['116'] = 'cat_near_leave' } },                   -- 09:27:17 split
  { { ['116'] = 'cat_near' }, { ['112'] = 6590 } },     -- 09:27:22 re-entry
  { { ['112'] = 6600 }, { ['113'] = 4248 } },
  { { ['116'] = 'cat_leave' } },                        -- 09:27:37
  { { ['107'] = 'AQAABRCYAAsA' } },                     -- 09:27:38
  { { ['112'] = 2350 } },
  { { ['116'] = 'cat_near_leave' } },                   -- 09:27:48
  idle, idle, idle, idle,
  { { ['116'] = 'work_aclean' } },
  { { ['116'] = 'work_idle' }, { ['102'] = 'AQAACwAAAAAAAAAAAAAA' } },
  { { ['108'] = 'AQAAEk1HUzEwNDA0MjUwNDE4MDA0NA==' } },   -- device info, not a fault
  idle,
  -- same payload again, more than 60 s later: a second visit
  { { ['116'] = 'cat_enter' } }, { { ['112'] = 6500 } },
  { { ['107'] = 'AQAABRCYAAsA' } }, { { ['112'] = 2350 } },
  { { ['116'] = 'cat_near_leave' } }, idle, idle, idle, idle,
  -- a peek: weight rises, no DP 107
  { { ['116'] = 'cat_near' } }, { { ['112'] = 5500 } }, { { ['112'] = 2350 } },
  { { ['116'] = 'cat_near_leave' } }, idle, idle, idle, idle,
  -- a lid-open visit must be discarded
  { { ['116'] = 'cat_near' } }, { { ['116'] = 'lid_open' } }, { { ['112'] = 9000 } },
  idle, idle, idle, idle,
})
dump('real visit')
check(#writes == 0, 'no device writes without a command')
check(#alerts == 0, 'trace DPs (102, 108) must not alert')
check(objects['32/3/15'] == 'None', 'stale 102 fault cleared, 108 not parked as fault')
check(logged('dp 108 = '), 'DP 108 logged as a trace DP')
check(logged('cleared leftover cat weight 2371.84'), 'leftover cat weight cleared')
check(logged('cat back within 15 s, same visit'), 'split visit merged')
check(logged('visit dp 113 = 4248'), 'DP 113 traced during a visit')
check(#samples('107') == 2 and samples('107')[1].w == 4248, 'DP 107 weight decoded twice')
check(samples('107')[1].who == 'Unknown', 'no name while learning')
check(logged('visit check: dp 107 4248 g, scale peak delta 4258 g'), 'peak cross-check logged')
check(#samples('peak') == 1 and samples('peak')[1].w == 3150, 'peek kept as peak sample')
check(logged('sample discarded, lid was open'), 'lid visit discarded')
check(objects['32/3/7'] == 2, 'identical 107 payload counted twice')
check(objects['32/3/9'] == 4248 and objects['32/3/14'] == 'Unknown', 'last cat objects')
check((objects['32/3/16'] or 0) == 0 and (objects['32/3/18'] or 0) == 0, 'no per-cat values while learning')

------------------------------------------------------- 2. two cats ------
world()
run({ { { ['112'] = 2342, ['116'] = 'work_idle' } } })
local isma    = { 5310, 5280, 5350, 5240, 5330, 5290, 5320 }
local charlie = { 4210, 4260, 4190, 4240, 4230, 4250, 4220 }
for i = 1, #isma do visit(isma[i]); visit(charlie[i]) end
dump('two cats')
local named = samples('107')
check(#named == 14, '14 samples')
for i = 1, 5 do check(named[i].who == 'Unknown', 'sample ' .. i .. ' before learning') end
for i = 6, 14 do
  local want = named[i].w > 4800 and 'Isma' or 'Charlie'
  check(named[i].who == want, 'sample ' .. i .. ' named ' .. want .. ', got ' .. named[i].who)
end
check(objects['32/3/16'] == isma[#isma], 'Isma weight object = his last visit')
check(objects['32/3/17'] == charlie[#charlie], 'Charlie weight object = last visit')
check(objects['32/3/14'] == 'Charlie', 'Cat Name shows the last visitor')
check(objects['32/3/18'] == 4 and objects['32/3/19'] == 5,
  'per-cat visits count named visits (got ' .. tostring(objects['32/3/18'])
  .. '/' .. tostring(objects['32/3/19']) .. ')')
check(objects['32/3/7'] == 14, 'total visits')
-- midnight: per-cat counters go back to zero
clock = clock + 86400
run({ idle })
check(objects['32/3/18'] == 0 and objects['32/3/19'] == 0 and objects['32/3/7'] == 0,
  'visit counters reset at midnight')

-------------------------------------------------- 3. only one cat -------
world()
run({ { { ['112'] = 2342, ['116'] = 'work_idle' } } })
for _, w in ipairs({ 4210, 4260, 4150, 4300, 4230, 4190, 4270, 4120, 4240, 4200 }) do
  visit(w)
end
dump('one cat')
for i, s in ipairs(samples('107')) do
  check(s.who == 'Unknown', 'single cat sample ' .. i .. ' must stay Unknown')
end
check(logged('too close'), 'reason logged for not splitting one cat')
check((objects['32/3/16'] or 0) == 0 and (objects['32/3/17'] or 0) == 0, 'no per-cat weights for one cat')

check(#writes == 0, 'no device writes in the one-cat run')

---------------------------------------------------- 4. clean now -------
world()
-- pressed before any state is known: refused
objects['32/3/12'] = true
run({ idle })
check(#writes == 0 and logged('clean REFUSED (state not known yet)'), 'no clean before state known')
check(objects['32/3/12'] == false, 'button object cleared')
-- idle: sent once, reaction logged
run({ { { ['112'] = 2342, ['116'] = 'work_idle' } } })
objects['32/3/12'] = true
run({ idle, { { ['116'] = 'work_mclean' } }, idle })
check(#writes == 1 and writes[1]['106'] == 'AQAAAA==', 'clean sends DP 106 AQAAAA==')
check(logged('clean command -> work_mclean after 5 s'), 'reaction logged')
run({ { { ['116'] = 'work_idle' } }, idle, idle, idle, idle, idle, idle, idle })
check(not logged('no clean state within'), 'no timeout message after a reaction')
-- cat inside: refused
run({ { { ['116'] = 'cat_enter' } } })
objects['32/3/12'] = true
run({ idle })
check(#writes == 1 and logged('clean REFUSED (state cat_enter)'), 'no clean with a cat inside')
-- cat just left, visit window still open: refused
run({ { { ['116'] = 'cat_near_leave' } } })
store.pawbby_cmd = 'clean'
run({ idle })
check(#writes == 1 and logged('clean REFUSED (visit in progress)'), 'no clean during settle window')
-- box ignores the command: timeout logged
run({ idle, idle, idle, idle, { { ['116'] = 'work_idle' } } })
objects['32/3/12'] = true
run({ idle, idle, idle, idle, idle, idle, idle, idle })
check(#writes == 2 and logged('clean command: no clean state within 30 s'), 'no-reaction logged')
dump('clean now')

-------------------------------------------- 5. new objects get a value --
world()
run({ idle })
for _, ga in ipairs({ '32/3/1', '32/3/2', '32/3/7', '32/3/12', '32/3/16', '32/3/18' }) do
  check(objects[ga] ~= nil, ga .. ' has an initial value')
end
check(objects['32/3/16'] == 0 and objects['32/3/18'] == 0 and objects['32/3/2'] == '-'
  and objects['32/3/15'] == 'None' and objects['32/3/14'] == 'Unknown',
  'initial values match the datatype')

-------------------------------------- 6. acute visit-frequency alert ----
world()
run({ { { ['112'] = 2342, ['116'] = 'work_idle' } } })
-- seed named samples so visits identify as Isma
store.pawbby_samples = {}
for _, w in ipairs({ 5300, 5280, 5320 }) do
  store.pawbby_samples[#store.pawbby_samples + 1] = { t = T0, w = w, src = '107', who = 'Isma' }
end
for _, w in ipairs({ 4100, 4120, 4090 }) do
  store.pawbby_samples[#store.pawbby_samples + 1] = { t = T0, w = w, src = '107', who = 'Charlie' }
end
-- 8 Isma visits in one day (weights vary so the payloads differ, not retransmits)
for i = 1, 8 do visit(5300 + i * 3) end
dump('acute visits')
check((store.pawbby_catvisits or {}).Isma == 8,
  'Isma visits counted (' .. tostring((store.pawbby_catvisits or {}).Isma) .. ')')
check(objects['32/3/20'] == true, 'acute visit frequency raises health alert')
check(objects['32/3/21'] == 'Isma 8 visits', 'acute note set on the KNX object')
check(table.concat(alerts, ' '):find('used the litter box 8 times today', 1, true) ~= nil,
  'acute raises an LM alert')
check(table.concat(alerts, ' '):find('4 times in the last 2 hours', 1, true) ~= nil,
  'frequent trips (4 in 2 h) raise an urgent alert before the daily count does')
check(objects['32/3/33'] == 3 and objects['32/5/10'] == 2, 'urgent alert level and Isma health level 2')
check(objects['32/5/9'] == 'Many visits 2h', 'health in words, within 14 characters (got ' .. tostring(objects['32/5/9']) .. ')')
local emailed = false
for _, m in ipairs(mails) do if m.b:find('used the litter box 8', 1, true) then emailed = true end end
check(emailed, 'acute sends an email')

-------------------------------------- 7. trend: weight loss + no visit --
world()
run({ { { ['112'] = 2342, ['116'] = 'work_idle' } } })
store.pawbby_daily = {}
for d = 1, 6 do
  store.pawbby_daily[d] = {
    d = 'day' .. d,
    Isma    = { v = 2, w = 5300 },
    Charlie = { v = 2, w = 4100 },
  }
end
-- the day before yesterday was already low for Isma
store.pawbby_daily[7] = { d = 'day7', Isma = { v = 2, w = 4880 }, Charlie = { v = 2, w = 4100 } }
-- yesterday: Isma weighed 4900 and 4920 g (median 4910; with 4880 the day before, -8% on average), Charlie did not visit
store.pawbby_dayweights = { Isma = { 4900, 4920 } }
store.pawbby_catvisits = { Isma = 2 }
clock = clock + 86400
run({ idle })
dump('trend')
check(objects['32/3/20'] == true, 'trend change raises health alert')
check(logged('HEALTH'), 'health summary logged')
check(logged('Isma wt -8%'), 'Isma weight loss over two low days flagged')
check(logged('Charlie no visit'), 'Charlie zero-visit flagged')
check(store.pawbby_daily[#store.pawbby_daily].Isma.w == 4910, 'daily weight is the median of the day')
check(next(store.pawbby_dayweights) == nil, 'day weighings reset at midnight')

-------------------------- 7b. one low day is not enough (Charlie, 10 Nov) --
world()
run({ { { ['112'] = 2342, ['116'] = 'work_idle' } } })
store.pawbby_daily = {}
for d = 1, 14 do
  store.pawbby_daily[d] = { d = 'day' .. d, Isma = { v = 3, w = 5050 }, Charlie = { v = 2, w = 4430 } }
end
store.pawbby_dayweights = { Isma = { 5040 }, Charlie = { 4186 } }
store.pawbby_catvisits = { Isma = 3, Charlie = 2 }
clock = clock + 86400
run({ idle })
dump('one low day')
check(not logged('wt -'), 'a single low weighing day raises no weight alert')
check(objects['32/3/20'] == false and objects['32/3/21'] == 'OK', 'health stays OK')
check(#alerts == 0 and #mails == 0, 'no alert, no email')

-------------------------------------------- 8. weekly report ------------
world()
run({ { { ['112'] = 2342, ['116'] = 'work_idle' } } })
store.pawbby_daily = {}
for d = 1, 10 do
  store.pawbby_daily[d] = {
    d = 'day' .. d,
    Isma    = { v = 2, w = 5300 },
    Charlie = { v = 3, w = 4100 },
  }
end
-- jump to a Monday 08:xx (runner's local time) so the weekly trigger fires;
-- pre-set the day so the midnight rollover does not also fire
local c = T0
while not (os.date('%w', c) == '1' and os.date('%H', c) == '08') do c = c + 3600 end
store.pawbby_day = os.date('%Y-%m-%d', c)
clock = c
run({ idle })
dump('weekly')
local wr = nil
for _, m in ipairs(mails) do if m.s and m.s:find('weekly', 1, true) then wr = m end end
check(wr ~= nil, 'weekly report emailed')
check(wr.b:find('Isma', 1, true) and wr.b:find('Charlie', 1, true), 'both cats in the report')
check(wr.b:find('kg', 1, true) ~= nil, 'weight in the report')
check(wr.b:find('visits/day', 1, true) ~= nil, 'visit frequency in the report')
check(wr.b:find('urinations', 1, true) == nil, 'no unreliable urination claim in the report')
check(logged('weekly report queued'), 'weekly send logged')

------------------------------------------ 9. no keys in storage --------
world()
store.pawbby_tuya = nil
run({ idle, idle })
dump('no keys')
check(pawbby == nil, 'nothing started without keys')
check(logged('no Tuya id/key in storage'), 'missing keys logged')
check(queries == 0 and #writes == 0, 'no device traffic without keys')
PAWBBY_NOKEYS = nil

------------------------------- 10. one-off rebuild of the daily weights --
world()
store.pawbby_daily_median = nil
local function day(k) return os.date('%Y-%m-%d', T0 - k * 86400) end
store.pawbby_daily = {}
for k = 15, 1, -1 do
  store.pawbby_daily[#store.pawbby_daily + 1] =
    { d = day(k), Isma = { v = 3, w = 9999 }, Charlie = { v = 2, w = 9999 } }
end
store.pawbby_samples = {}
for k = 15, 1, -1 do
  for _, w in ipairs({ 5000, 5100, 5050 }) do
    store.pawbby_samples[#store.pawbby_samples + 1] = { t = T0 - k * 86400 + 3600, w = w, src = '107', who = 'Isma' }
  end
  local cw = (k <= 2) and 4100 or 4430   -- Charlie low on the last two days
  store.pawbby_samples[#store.pawbby_samples + 1] = { t = T0 - k * 86400 + 7200, w = cw, src = '107', who = 'Charlie' }
end
store.pawbby_samples[#store.pawbby_samples + 1] = { t = T0, w = 5070, src = '107', who = 'Isma' }   -- today
store.pawbby_day = os.date('%Y-%m-%d', T0)   -- as on the LM: no midnight rollover on this start
run({ { { ['112'] = 2342, ['116'] = 'work_idle' } } })
dump('rebuild')
check(store.pawbby_daily_median == true, 'rebuild runs once and is marked')
check(store.pawbby_daily[1].Isma.w == 5050, 'past day = median of its weighings')
check(store.pawbby_dayweights.Isma[1] == 5070, "today's weighings seeded")
check(logged('rebuilt as medians (30 cat-days)'), 'rebuild logged')
check(objects['32/3/20'] == true and logged('re-check, no new alert'), 'quiet re-check sets the objects')
check(#alerts == 0 and #mails == 0, 'the re-check neither alerts nor emails')
local before = #logs
pawbby = nil
run({ idle })
check(not table.concat(logs, '\n', before + 1):find('rebuilt', 1, true), 'no second rebuild on restart')

---------------------------------------- 11. phase 2 diagnostics -------
world()
run({ { { ['112'] = 2342, ['116'] = 'work_idle' } } })
check(objects['32/3/22'] == 0 and objects['32/3/23'] == 0 and objects['32/3/27'] == '-',
  'diagnostic objects created with initial values')
visit(4300)
check(objects['32/3/22'] == 11, 'visit seconds from DP 107 byte 8 (got ' .. tostring(objects['32/3/22']) .. ')')
check(samples('107')[1].s == 11, 'visit seconds stored with the sample')
-- an auto clean of 125 s (25 cycles of 5 s)
local cyc = { { { ['116'] = 'work_aclean' } } }
for i = 1, 24 do cyc[#cyc + 1] = idle end
cyc[#cyc + 1] = { { ['116'] = 'work_idle' } }
run(cyc)
check(objects['32/3/23'] == 1 and objects['32/3/24'] == 125,
  'clean counted with its duration (got ' .. tostring(objects['32/3/23']) .. ', ' .. tostring(objects['32/3/24']) .. ')')
run({ { { ['114'] = 'motor_ok', ['115'] = 'day_30', ['117'] = 'cu=12 FG=3 BRK=0 PWM=80 POWER=1' } } })
check(objects['32/3/26'] == 'motor_ok' and objects['32/3/25'] == 'day_30', 'DP 114/115 on their objects')
check(objects['32/3/27'] == 'cu=12 FG=3 BRK=0 PWM=80 POWER=1', 'DP 117 motor debug on its object')
run({ { { ['108'] = 'AQAAEk1HUzEwNDA0MjUwNDE4MDA0NA==' } } })
check(objects['32/3/28'] == 'MGS104042504180044', 'DP 108 decoded (got ' .. tostring(objects['32/3/28']) .. ')')
check(pawbby.dps['112'].n >= 1 and pawbby.dps['108'] ~= nil, 'datapoint inventory kept')
check(#alerts == 0, 'no alerts from the diagnostic DPs')
-- tare: refused with litter in, sent with an empty drum
objects['32/3/30'] = true
run({ idle })
check(#writes == 0 and logged('tare REFUSED (scale reads 2342 g'), 'no tare with litter in the drum')
check(objects['32/3/30'] == false, 'tare button cleared')
run({ { { ['112'] = 12 } } })
objects['32/3/30'] = true
run({ idle })
check(#writes == 1 and writes[1]['109'] == 'AQEAAA==' and logged('tare sent'), 'tare sent on an empty drum')
run({ { { ['116'] = 'cat_enter' } } })
objects['32/3/30'] = true
run({ idle })
check(#writes == 1 and logged('tare REFUSED (state cat_enter)'), 'no tare with a cat inside')
-- midnight resets the day counters
clock = clock + 86400
run({ idle })
check(objects['32/3/23'] == 0 and objects['32/3/29'] == 0, 'cleans and connections reset at midnight')
dump('diagnostics')

---------------------------------- 12. phase 3: records, cats, alerts ----
world()
-- history: Isma and Charlie named, Isma's visits every ~8 h
store.pawbby_samples = {}
for k = 20, 1, -1 do
  store.pawbby_samples[#store.pawbby_samples + 1] = { t = T0 - k * 8 * 3600, w = 5300, src = '107', who = 'Isma', s = 30 }
  store.pawbby_samples[#store.pawbby_samples + 1] = { t = T0 - k * 8 * 3600 + 600, w = 4200, src = '107', who = 'Charlie', s = 20 }
end
store.pawbby_daily = {}
for k = 10, 1, -1 do
  store.pawbby_daily[#store.pawbby_daily + 1] = { d = 'd' .. k, Isma = { v = 3, w = 5300 }, Charlie = { v = 3, w = 4200 } }
end
store.pawbby_day = os.date('%Y-%m-%d', T0)
store.pawbby_samples_v2 = true   -- as on the LM: the 2026-09 one-off reset is done
run({ { { ['112'] = 2342, ['116'] = 'work_idle' } } })
check(objects['32/5/4'] == 5300 and objects['32/6/4'] == 4200, 'per-cat last weight seeded from samples')
check(objects['32/5/5'] == 5300 and objects['32/5/6'] == 0 and objects['32/5/8'] == 3, 'per-cat 7d weight, change, visits/day')
check(logged('no-visit alert after 18 h (Isma)'), 'gap limit logged at start')
-- a counted Isma visit followed by a clean: one record with the clean attached
visit(5310)
local cyc = { { { ['116'] = 'work_aclean' } } }
for i = 1, 23 do cyc[#cyc + 1] = idle end
cyc[#cyc + 1] = { { ['116'] = 'work_idle' } }
run(cyc)
local vl = store.pawbby_visitlog
check(vl and #vl == 1, 'one visit record')
local r = vl[1]
check(r.cat == 'Isma' and r.w == 5310 and r.s == 11 and r.t0 and r.t1 and r.t1 > r.t0, 'record holds cat, weight, seconds, times')
check(r.dep == 0 and r.peak == 5310, 'deposit and peak recorded')
check(r.clean == 120, 'the following clean is attached (got ' .. tostring(r.clean) .. ')')
check(objects['32/5/3'] == 11 and objects['32/5/2'] == 2 and objects['32/5/7'] == 1, 'Isma: seconds, minutes since (2 min of clean), visits today')
-- a peek with weight but no DP 107: uncounted record with an estimated cat
run({ { { ['116'] = 'cat_near' } }, { { ['112'] = 2342 + 4210 } }, { { ['112'] = 2342 } },
      { { ['116'] = 'cat_near_leave' } }, idle, idle, idle, idle })
check(#store.pawbby_visitlog == 2 and store.pawbby_visitlog[2].cat == nil and store.pawbby_visitlog[2].est == 'Charlie',
  'uncounted visit recorded, cat estimated from the peak')
check(store.pawbby_cats.Charlie.seen and store.pawbby_cats.Charlie.seen > store.pawbby_cats.Charlie.last,
  'an uncounted visit by Charlie counts as a sign of life')
-- test alert: app objects only
objects['32/3/34'] = true
local na = #alerts
run({ idle })
check(objects['32/3/32'] == 1 and objects['32/3/33'] == 1 and objects['32/3/31']:find('Test alert', 1, true), 'test alert on the app objects')
check(#alerts == na and objects['32/3/34'] == false, 'test alert: no LM alert, button cleared')
-- 20 h without Isma: watch alert, once
for i = 1, 20 * 12 do clock = clock + 300; chunk() end
check(logged('[Watch] (general) Isma has not used the litter box'), 'no-visit alert for Isma')
check(logged('[Watch] (general) Charlie has not used the litter box') and objects['32/3/33'] == 2, 'and for Charlie, timed from her uncounted visit')
check(objects['32/5/10'] == 1 and objects['32/5/9'] == 'No visit 20 h', 'Isma health shows the gap')
check(objects['32/5/11'] == 18 and objects['32/6/11'] == 18, 'alert limit per cat published')
local gaps = 0
for _, l in ipairs(logs) do if l:find('ALERT', 1, true) and l:find('Isma has not used', 1, true) then gaps = gaps + 1 end end
check(gaps <= 2, 'the gap alert repeats at most every 6 h (got ' .. gaps .. ')')
-- box stuck with the lid open for 11 minutes
run({ { { ['116'] = 'lid_open' } } })
for i = 1, 11 * 12 do clock = clock + 5; chunk() end
check(logged('has been in state lid_open'), 'stuck alert')
dump('phase 3')

-------------------------------------------------- 13. box offline -------
world()
dev.connected = function() return false end
dev.connect = function() return nil, 'connect: Network unreachable' end
dev.close = function() end
for i = 1, 20 * 12 do run({ idle }) end
check(logged('has been offline for'), 'offline alert after 15 min')
dev.connected = function() return true end

------------------------------- 14. alerts through the shared library ----
local sent = {}
package.preload['user.alerts'] = function()
  -- _G: this file has a local named alerts (the LM alert() capture)
  _G.alerts = { send = function(feed, level, source, text, detail)
    sent[#sent + 1] = { feed = feed, level = level, source = source, text = text, detail = detail }
    return true
  end }
  return _G.alerts
end
package.loaded['user.alerts'] = nil
world()
run({ { { ['112'] = 2342, ['116'] = 'work_idle', ['114'] = 'motor_ok' } } })
objects['32/3/34'] = true
run({ idle })
run({ { { ['114'] = 'motor_stall' } } })
local function find(feed, txt)
  for _, a in ipairs(sent) do if a.feed == feed and a.text:find(txt, 1, true) then return a end end
end
local t = find('system', 'Test alert')
check(t and t.level == 1 and t.source == 'Litter box', 'test alert goes to the system feed (admin phone only)')
local m = find('system', 'motor problem (motor_stall)')
check(m and m.level == 2 and m.detail:find('DP 114 = motor_stall', 1, true), 'motor fault to system with detail')
check(objects['32/3/32'] == nil or objects['32/3/32'] == 0, 'old litter-box feed not written when the library is there')
-- cat alerts go to general
store.pawbby_samples = {}
for _, w in ipairs({ 5300, 5280, 5320 }) do store.pawbby_samples[#store.pawbby_samples + 1] = { t = T0, w = w, src = '107', who = 'Isma' } end
for _, w in ipairs({ 4100, 4120, 4090 }) do store.pawbby_samples[#store.pawbby_samples + 1] = { t = T0, w = w, src = '107', who = 'Charlie' } end
for i = 1, 4 do visit(5300 + i * 3) end
local f = find('general', 'times in the last 2 hours')
check(f and f.level == 3 and f.source == 'Cats', 'frequent visits go to the general feed as urgent')
package.preload['user.alerts'] = nil
package.loaded['user.alerts'] = nil
_G.alerts = nil

print('ALL CHECKS PASSED')
