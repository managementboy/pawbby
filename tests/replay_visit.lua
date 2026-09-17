--[[ Offline replay of pawbby_resident.lua against mocked LM globals and a fake
     device. Frames are fed per 5 s script cycle. Run: tests/run.sh ]]
local SRC = ...
local T0 = 1789630000   -- 2026-09-17, morning
local clock, logs, objects, store, alerts, queries, inbox, writes

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
grp = {
  find = function(ga) return objects[ga] ~= nil and { value = objects[ga] } or nil end,
  getvalue = function(ga) return objects[ga] end,
  write = function(ga, v) objects[ga] = v end,
  update = function(ga, v) objects[ga] = v end,
  create = function(o) if objects[o.address] == nil then objects[o.address] = false end end,
}
storage = { get = function(k) return store[k], 'x' end,  -- 2nd value like LM
            set = function(k, v) store[k] = v end }
encdec = { base64dec = b64dec }
package.preload['user.tuya34'] = function() return { new = function() return dev end } end
package.preload['socket'] = function() return { gettime = function() return clock end } end
package.preload['encdec'] = function() return encdec end

local chunk = assert(loadstring(SRC, '=pawbby_resident'))

local function world()
  pawbby = nil
  clock, logs, objects, store, alerts, queries, inbox, writes = T0, {}, {}, {}, {}, 0, {}, {}
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
check(#alerts == 0, 'DP 102 must not alert')
check(objects['32/3/15'] == '', 'stale 102 fault cleared and not re-set')
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

print('ALL CHECKS PASSED')
