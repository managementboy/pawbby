--[[ Offline checks of the tuya34 frame reader (code review 2026-11-18,
     T3-PAWBBY #a4 #a5 #a9): HMAC and suffix checks, junk and corrupt length
     fields, a garbage stream that never completes a frame, the stale-session
     close and the type checks on the decoded JSON. Real AES/HMAC through
     libcrypto; socket, encdec and json are mocked. Run: tests/run.sh ]]
local SRC = ...
local ffi = require('ffi')
pcall(ffi.cdef, [[
const void *EVP_sha256(void);
unsigned char *HMAC(const void *md, const void *key, int key_len,
  const unsigned char *d, size_t n, unsigned char *out, unsigned int *out_len);
]])
local C = ffi.load('crypto')

encdec = { hmacsha256 = function(data, key)
  local out, n = ffi.new('unsigned char[32]'), ffi.new('unsigned int[1]')
  C.HMAC(C.EVP_sha256(), key, #key, data, #data, out, n)
  return (ffi.string(out, n[0]):gsub('.', function(c) return string.format('%02x', c:byte()) end))
end }

local clock, chunks, logs = 1000, {}, {}
local nextjson
json = { decode = function() return nextjson end, encode = function() return '{}' end }
function log(s) logs[#logs + 1] = s end
local sock = {
  settimeout = function() end,
  close = function() end,
  receive = function()
    clock = clock + 0.01
    local c = table.remove(chunks, 1)
    if c == 'FOREVER' then table.insert(chunks, 1, c); return 'xxxxxxxxxxxxxxxx' end
    if c then return c end
    return nil, 'timeout'
  end,
}
package.preload['socket'] = function() return { gettime = function() return clock end } end
package.preload['encdec'] = function() return encdec end
local M = assert(loadstring(SRC, '=tuya34'))()
local T = M._test

local function check(c, m) if not c then error('FAIL: ' .. m, 0) end end

local skey = '0123456789abcdef'
local dev = M.new({ ip = '127.0.0.1', id = 'x', key = 'fedcba9876543210' })
dev.sock, dev.skey, dev.lastrx = sock, skey, clock

-- a device frame: 4 byte return code, then the encrypted payload
local function devframe(key)
  local enc = T.aes(skey, T.pad('{"dps":{"1":true}}'), true)
  return T.frame(7, M.CMD.STATUS, '\0\0\0\0' .. enc, key or skey)
end

nextjson = { dps = { ['1'] = true } }
chunks = { devframe() }
local dps = dev:poll(0.2)
check(type(dps) == 'table' and dps['1'] == true, 'valid frame decoded')

-- #a4 log-only mode (the default until the scheme is confirmed on the real box): a bad HMAC is accepted
M.ENFORCE_MAC = false
nextjson = { dps = { ['1'] = true } }
chunks = { devframe('wrongwrongwrong!') }
local lo = dev:poll(0.2)
check(type(lo) == 'table' and lo['1'] == true, '#a4 log-only: bad HMAC still accepted')

-- #a4 enforcing: wrong HMAC key and a broken suffix are dropped
M.ENFORCE_MAC = true
chunks = { devframe('wrongwrongwrong!') }
local d, info = dev:poll(0.2)
check(d == nil and info == 'badmac', '#a4 frame with a wrong HMAC dropped (got ' .. tostring(info) .. ')')
local f = devframe()
chunks = { f:sub(1, -2) .. 'X' }
d, info = dev:poll(0.2)
check(d == nil and info ~= 'badmac', '#a4 broken suffix = no frame (skipped as junk, not decoded) (got ' .. tostring(info) .. ')')
check(#dev.buf <= 3, '#a4 the bytes without a suffix are dropped (' .. #dev.buf .. ' left)')
M.ENFORCE_MAC = false
-- the same in log-only mode: a frame without its suffix is never handed on (diff review)
dev.buf = ''
chunks = { f:sub(1, -2) .. 'X' }
d, info = dev:poll(0.2)
check(d == nil, 'log-only: broken suffix still not decoded')
-- and a good frame after such junk is found
dev.buf = ''
nextjson = { dps = { ['1'] = true } }
chunks = { f:sub(1, -2) .. 'X' .. devframe() }
d = dev:poll(0.2)
check(type(d) == 'table' and d['1'] == true, 'good frame after a frame with a broken suffix is decoded')

-- #a5: junk before the prefix, a corrupt length, then a good frame
local bad = '\0\0\85\170' .. '\0\0\0\1' .. '\0\0\0\8' .. '\0\0\0\5'   -- len 5 < 36
chunks = { 'garbage' .. bad .. devframe() }
dps = dev:poll(0.2)
check(type(dps) == 'table', '#a5 good frame found after junk and a corrupt length')
check(dev.buf == '', '#a5 junk dropped from the buffer')
local huge = '\0\0\85\170' .. '\0\0\0\1' .. '\0\0\0\8' .. '\127\0\0\0'
chunks = { huge .. devframe() }
dps = dev:poll(0.2)
check(type(dps) == 'table', '#a5 huge length skipped')

-- #a5: a stream that never completes a frame returns on time, buffer bounded
chunks = { 'FOREVER' }
local t0 = clock
d, info = dev:poll(0.2)
check(d == nil and info == 'timeout' and clock - t0 < 1, '#a5 garbage stream returns timeout')
check(#dev.buf <= 3 + 16, '#a5 buffer stays small (got ' .. #dev.buf .. ')')
chunks, dev.buf = {}, ''

-- #a5: no valid frame for STALE_S closes the session
dev.lastrx = clock - M.STALE_S - 1
d, info = dev:poll(0.2)
check(d == nil and info == 'closed' and not dev:connected(), '#a5 stale session closed')
check(logs[#logs]:find('no valid frame', 1, true) ~= nil, '#a5 stale close logged')
dev.sock, dev.skey, dev.lastrx = sock, skey, clock

-- #a9: "data" a number, "dps" not a table: no error
nextjson = { data = 5 }
chunks = { devframe() }
d, info = dev:poll(0.2)
check(d == nil and info == 'nodps', '#a9 numeric data')
nextjson = { dps = 7 }
chunks = { devframe() }
d, info = dev:poll(0.2)
check(d == nil and info == 'nodps', '#a9 non-table dps')

print('tuya34: ALL FRAME CHECKS PASSED')
