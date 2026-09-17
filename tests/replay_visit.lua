--[[ Offline replay of pawbby_resident.lua against mocked LM globals and a fake
     device. Frames are fed per 5 s script cycle. Run: tests/run.sh ]]
local SRC = ...
local T0 = 1789630000
local clock = T0
local logs, objects, store, alerts, queries = {}, {}, {}, {}, 0

os.time = function() return clock end
function log(s) logs[#logs + 1] = string.format('%5d %s', clock - T0, s) end
function alert(s) alerts[#alerts + 1] = s end
grp = {
  find = function(ga) return objects[ga] and { value = objects[ga] } end,
  getvalue = function(ga) return objects[ga] end,
  write = function(ga, v) objects[ga] = v end,
  update = function(ga, v) objects[ga] = v end,
  create = function(o) objects[o.address] = objects[o.address] or false end,
}
storage = { get = function(k) return store[k], 'x' end,  -- 2nd value like LM
            set = function(k, v) store[k] = v end }
encdec = { base64dec = function(s)
  local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  s = s:gsub('[^' .. b .. '=]', '')
  return (s:gsub('.', function(x)
    if x == '=' then return '' end
    local r, f = '', (b:find(x) - 1)
    for i = 6, 1, -1 do r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and '1' or '0') end
    return r
  end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
    if #x ~= 8 then return '' end
    local c = 0
    for i = 1, 8 do c = c + (x:sub(i, i) == '1' and 2 ^ (8 - i) or 0) end
    return string.char(c)
  end))
end }

local inbox = {}   -- frames delivered on the next poll
local dev = {
  connected = function() return true end,
  heartbeat = function() end,
  query = function() queries = queries + 1 end,
  set = function() error('replay must never write to the device') end,
  poll = function()
    local f = table.remove(inbox, 1)
    if f then return f end
    return nil, 'timeout'
  end,
}
package.preload['user.tuya34'] = function() return { new = function() return dev end } end
package.preload['socket'] = function() return { gettime = function() return clock end } end
local encdec_mod = encdec
package.preload['encdec'] = function() encdec = encdec_mod; return encdec end

objects['32/3/15'] = '102:AQAACwAAAA'   -- the stale fault seen on the LM
objects['32/3/9'] = 2371.84             -- litter refill left in Cat Weight
local chunk = assert(loadstring(SRC, '=pawbby_resident'))

-- one entry per 5 s cycle: list of dps tables arriving in that cycle
local function run(cycles)
  for _, frames in ipairs(cycles) do
    for _, d in ipairs(frames) do inbox[#inbox + 1] = d end
    chunk()
    clock = clock + 5
  end
end

local idle = {}
run({
  { { ['112'] = 2342, ['116'] = 'work_idle' } },
  { { ['116'] = 'cat_near' } },                         -- 09:26:56
  idle,
  { { ['116'] = 'cat_enter' } },                        -- 09:27:12
  { { ['116'] = 'cat_near_leave' } },                   -- 09:27:17 split
  { { ['116'] = 'cat_near' }, { ['112'] = 6590 } },     -- 09:27:22 re-entry, weight up
  { { ['112'] = 6600 } },
  { { ['116'] = 'cat_leave' } },                        -- 09:27:37
  { { ['107'] = 'AQAABRCYAAsA' } },                     -- 09:27:38
  { { ['112'] = 2350 } },
  { { ['116'] = 'cat_near_leave' } },                   -- 09:27:48
  idle, idle, idle, idle,
  { { ['116'] = 'work_aclean' } },
  { { ['116'] = 'work_idle' }, { ['102'] = 'AQAACwAAAAAAAAAAAAAA' } },
  idle,
  -- second visit, byte-identical 107 payload, more than 60 s later
  { { ['116'] = 'cat_enter' } }, { { ['112'] = 5100 } },
  { { ['107'] = 'AQAABRCYAAsA' } },
  { { ['116'] = 'cat_near_leave' } }, idle, idle, idle, idle,
  -- a lid-open visit must be discarded
  { { ['116'] = 'cat_near' } }, { { ['116'] = 'lid_open' } }, { { ['112'] = 9000 } },
  idle, idle, idle, idle,
})

for _, l in ipairs(logs) do print(l) end
print('alerts', #alerts, 'queries', queries)
local samples = store.pawbby_samples or {}
print('samples', #samples)
for _, s in ipairs(samples) do print('  w=' .. s.w, 'p107=' .. tostring(s.p107)) end
print('visits', objects['32/3/7'], 'catkg', objects['32/3/9'], 'fault', string.format('%q', tostring(objects['32/3/15'])))

local function check(c, m) if not c then error('FAIL: ' .. m, 0) end end
check(table.concat(logs, ' | '):find('cleared leftover cat weight 2371.84', 1, true), 'leftover cat weight cleared')
check(#alerts == 0, 'DP 102 must not alert')
check(objects['32/3/15'] == '', 'stale 102 fault cleared and not re-set')
check(#samples == 2, 'two cat samples (lid visit discarded)')
check(samples[1].w == 4258 and samples[1].p107 == 'AQAABRCYAAsA', 'split visit merged, 107 attached')
check(samples[2].w == 2750, 'second visit measured')
check(objects['32/3/7'] == 2, 'identical 107 payload counted twice')
print('ALL CHECKS PASSED')
