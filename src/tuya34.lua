--[[
  tuya34 -- Tuya local protocol v3.4 client for LogicMachine (LM5, LuaJIT 2.0)
  Install as user library named "tuya34", use with: require('user.tuya34')

  Dependencies: ffi (LuaJIT), libcrypto (OpenSSL 3.x), luasocket, encdec, json
  Crypto: AES-128-ECB via EVP, PKCS#7 padding done in Lua, HMAC-SHA256 via encdec
--]]

local ffi = require('ffi')
local socket = require('socket')
require('encdec')

local M = {}

------------------------------------------------------------------ crypto ----

-- pcall guard: resident scripts keep the Lua state between cycles,
-- a second cdef of the same symbols would raise "attempt to redefine"
pcall(ffi.cdef, [[
typedef struct evp_cipher_ctx_st EVP_CIPHER_CTX;
typedef struct evp_cipher_st EVP_CIPHER;
EVP_CIPHER_CTX *EVP_CIPHER_CTX_new(void);
void EVP_CIPHER_CTX_free(EVP_CIPHER_CTX *ctx);
const EVP_CIPHER *EVP_aes_128_ecb(void);
int EVP_CIPHER_CTX_set_padding(EVP_CIPHER_CTX *x, int padding);
int EVP_EncryptInit_ex(EVP_CIPHER_CTX *ctx, const EVP_CIPHER *type,
  void *impl, const unsigned char *key, const unsigned char *iv);
int EVP_EncryptUpdate(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl,
  const unsigned char *in, int inl);
int EVP_DecryptInit_ex(EVP_CIPHER_CTX *ctx, const EVP_CIPHER *type,
  void *impl, const unsigned char *key, const unsigned char *iv);
int EVP_DecryptUpdate(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl,
  const unsigned char *in, int inl);
]])

local C = ffi.load('crypto')

local function aes(key, data, encrypt)
  local ctx = C.EVP_CIPHER_CTX_new()
  if encrypt then
    C.EVP_EncryptInit_ex(ctx, C.EVP_aes_128_ecb(), nil, key, nil)
  else
    C.EVP_DecryptInit_ex(ctx, C.EVP_aes_128_ecb(), nil, key, nil)
  end
  C.EVP_CIPHER_CTX_set_padding(ctx, 0)
  local out = ffi.new('unsigned char[?]', #data + 16)
  local outl = ffi.new('int[1]')
  if encrypt then
    C.EVP_EncryptUpdate(ctx, out, outl, data, #data)
  else
    C.EVP_DecryptUpdate(ctx, out, outl, data, #data)
  end
  C.EVP_CIPHER_CTX_free(ctx)
  local res = ffi.string(out, outl[0])
  return res
end

local function pad(s)
  local n = 16 - (#s % 16)
  return s .. string.rep(string.char(n), n)
end

local function unpad(s)
  if #s == 0 then return s end
  local n = string.byte(s, #s)
  if n > 0 and n <= 16 and n <= #s then return s:sub(1, #s - n) end
  return s
end

-- encdec.hmacsha256(data, key) returns 64 lowercase hex chars -> convert to raw
local function hmac(key, data)
  local hex = encdec.hmacsha256(data, key)
  return (hex:gsub('%x%x', function(b) return string.char(tonumber(b, 16)) end))
end

local function randbytes(n)
  local f = io.open('/dev/urandom', 'rb')
  if f then
    local b = f:read(n)
    f:close()
    if b and #b == n then return b end
  end
  local t = {}
  for i = 1, n do t[i] = string.char(math.random(0, 255)) end
  return table.concat(t)
end

local function sxor(a, b)
  local t = {}
  for i = 1, #a do
    t[i] = string.char(bit.bxor(string.byte(a, i), string.byte(b, i)))
  end
  return table.concat(t)
end

------------------------------------------------------------------ framing ---

local PREFIX = '\000\000\085\170'   -- 0x000055AA
local SUFFIX = '\000\000\170\085'   -- 0x0000AA55

M.CMD = {
  SESS_START  = 0x03,
  SESS_RESP   = 0x04,
  SESS_FINISH = 0x05,
  CONTROL     = 0x07,
  STATUS      = 0x08,   -- unsolicited broadcast from device
  HEARTBEAT   = 0x09,
  DP_QUERY    = 0x0a,
  CONTROL_NEW = 0x0d,   -- used for writes on v3.4
  DP_QUERY_NEW = 0x10,  -- used for reads on v3.4
}

local function u32(n)
  return string.char(
    bit.band(bit.rshift(n, 24), 255), bit.band(bit.rshift(n, 16), 255),
    bit.band(bit.rshift(n, 8), 255), bit.band(n, 255))
end

local function ru32(s, i)
  local a, b, c, d = string.byte(s, i, i + 3)
  return a * 16777216 + b * 65536 + c * 256 + d
end

-- v3.4: length field covers payload + 32 byte HMAC + 4 byte suffix
local function frame(seq, cmd, payload, key)
  local body = PREFIX .. u32(seq) .. u32(cmd) .. u32(#payload + 36) .. payload
  return body .. hmac(key, body) .. SUFFIX
end

--[[ Bounds for incoming frames (code review 2026-11-18, T3-PAWBBY #a5).
     A status frame of this box is a few hundred bytes; anything above
     MAX_LEN is not a frame of ours but a corrupt length field. ]]
local MIN_LEN = 36            -- HMAC + suffix, empty payload
local MAX_LEN = 16384

--[[ Returns cmd, payload (still encrypted), bytes_consumed, mac_ok -- or nil
     (plus the number of leading bytes that can be dropped) if the buffer
     does not yet hold a complete frame. Device frames carry a 4 byte return
     code between length and payload; detected via block alignment.
     hkey: key for the frame's HMAC (local key in the handshake, session key
     afterwards); mac_ok is false when the HMAC or the suffix does not match
     (code review 2026-11-18, T3-PAWBBY #a4). The HMAC covers the 16 byte
     header and the whole payload including the return code. ]]
local function unframe(buf, hkey)
  local from = 1
  while true do
    local s = buf:find(PREFIX, from, true)
    if not s then
      -- no prefix: everything but the last 3 bytes (a prefix may straddle
      -- two reads) is junk (code review 2026-11-18, T3-PAWBBY #a5)
      return nil, math.max(0, #buf - 3)
    end
    if #buf < s + 15 then return nil, s - 1 end
    local cmd = ru32(buf, s + 8)
    local len = ru32(buf, s + 12)
    if len < MIN_LEN or len > MAX_LEN then
      -- corrupt length: this prefix is not a frame start, look for the next
      -- (code review 2026-11-18, T3-PAWBBY #a5)
      from = s + 1
    else
      local total = 16 + len
      if #buf < s + total - 1 then return nil, s - 1 end
      local plen = len - 36
      local raw = buf:sub(s + 16, s + 15 + plen)
      local mac = buf:sub(s + 16 + plen, s + 47 + plen)
      local suf = buf:sub(s + 48 + plen, s + 51 + plen)
      if suf ~= SUFFIX then
        -- no suffix where the length says: not a frame start either (a prefix inside a payload); look for the next
        -- one, never hand the bytes on (diff review 2026-11-18, T3-PAWBBY)
        from = s + 1
      else
      local macok = hkey == nil or mac == hmac(hkey, buf:sub(s, s + 15 + plen))
      local payload = raw
      if plen % 16 ~= 0 and (plen - 4) % 16 == 0 then
        payload = payload:sub(5)          -- strip return code
      end
      return cmd, payload, s + total - 1, macok
      end
    end
  end
end

------------------------------------------------------------------- device ---

local Device = {}
Device.__index = Device

-- cfg: { ip = '192.168.x.x', id = '...', key = '...', port = 6668, debug = false }
function M.new(cfg)
  return setmetatable({
    ip = cfg.ip,
    id = cfg.id,
    key = cfg.key,
    port = cfg.port or 6668,
    debug = cfg.debug and true or false,
    seq = 1,
    buf = '',
    sock = nil,
    skey = nil,
  }, Device)
end

function Device:_send(cmd, payload, key)
  local pkt = frame(self.seq, cmd, payload, key)
  self.seq = self.seq + 1
  return self.sock:send(pkt)
end

-- blocking read of exactly one frame, honouring the socket timeout.
-- hkey: HMAC key of the expected frame (see unframe).
function Device:_recv(hkey)
  --[[ A peer that streams bytes without ever completing a frame would keep
       this loop reading forever (each receive returns at once); give up after
       the timeout the caller set (code review 2026-11-18, T3-PAWBBY #a5). ]]
  local stop = socket.gettime() + (self.tmo or 5)
  while true do
    local cmd, payload, consumed, macok = unframe(self.buf, hkey)
    if cmd then
      self.buf = self.buf:sub(consumed + 1)
      if macok then
        self.lastrx = socket.gettime()
        return cmd, payload
      end
      -- forged or corrupt frame (code review 2026-11-18, T3-PAWBBY #a4). The HMAC scheme is not yet confirmed
      -- against the real box, so until M.ENFORCE_MAC is switched on the frame is still accepted and only logged
      -- (once per minute): a wrong scheme must not take the litter box offline. Switch it on once the LM log has
      -- shown no "bad HMAC" line for a few days of normal traffic.
      if not M.ENFORCE_MAC then
        local now = socket.gettime()
        if now - (self.lastbadlog or 0) > 60 then
          self.lastbadlog = now
          log('tuya rx cmd=' .. tostring(cmd) .. ': bad HMAC/suffix (log only, ENFORCE_MAC off)')
        end
        self.lastrx = now
        return cmd, payload
      end
      if self.debug then log('tuya rx cmd=' .. tostring(cmd) .. ' dropped: bad HMAC/suffix') end
      return nil, 'badmac', cmd
    end
    if payload and payload > 0 then self.buf = self.buf:sub(payload + 1) end   -- junk
    if socket.gettime() >= stop then return nil, 'timeout' end
    local chunk, err, partial = self.sock:receive(1024)
    chunk = chunk or partial
    if chunk and #chunk > 0 then
      self.buf = self.buf .. chunk
    elseif err == 'closed' then
      return nil, 'closed'
    else
      return nil, err or 'timeout'
    end
  end
end

--[[ Three way session key negotiation:
       -> 0x03  ENC(local_nonce)                      key = local_key
       <- 0x04  ENC(remote_nonce .. HMAC(local_nonce)) key = local_key
       -> 0x05  ENC(HMAC(remote_nonce))               key = local_key
     session_key = AES_ECB(local_key, local_nonce XOR remote_nonce), no padding
     Everything afterwards uses session_key for both AES and HMAC.           ]]
function Device:connect(timeout)
  self:close()
  local sock = socket.tcp()
  sock:settimeout(timeout or 5)
  self.tmo = timeout or 5
  local ok, err = sock:connect(self.ip, self.port)
  if not ok then return nil, 'connect: ' .. tostring(err) end
  sock:setoption('tcp-nodelay', true)
  self.sock = sock
  self.seq = 1
  self.buf = ''

  local lnonce = randbytes(16)
  self:_send(M.CMD.SESS_START, aes(self.key, pad(lnonce), true), self.key)

  local cmd, payload = self:_recv(self.key)
  if cmd ~= M.CMD.SESS_RESP then
    self:close()
    return nil, 'handshake: unexpected cmd ' .. tostring(cmd) .. ' ' .. tostring(payload)
  end

  local plain = unpad(aes(self.key, payload, false))
  local rnonce = plain:sub(1, 16)
  local proof = plain:sub(17, 48)
  if proof ~= hmac(self.key, lnonce) then
    self:close()
    return nil, 'handshake: HMAC mismatch (wrong local key?)'
  end

  self:_send(M.CMD.SESS_FINISH,
    aes(self.key, pad(hmac(self.key, rnonce)), true), self.key)

  -- exactly one block, encrypted without padding
  self.skey = aes(self.key, sxor(lnonce, rnonce), true)
  self.lastrx = socket.gettime()
  return true
end

function Device:close()
  if self.sock then pcall(function() self.sock:close() end) end
  self.sock, self.skey, self.buf = nil, nil, ''
end

-- seconds without a valid frame before poll() drops the session (#a5)
M.STALE_S = 60
M.ENFORCE_MAC = false   -- drop frames with a bad HMAC/suffix; off = log only (see tuya:_recv, T3-PAWBBY #a4)

function Device:connected()
  return self.sock ~= nil and self.skey ~= nil
end

--[[ The device prefixes its own broadcasts with a 15 byte protocol header:
     the literal "3.4" followed by 12 zero bytes, then the JSON. Writes need
     the same header or the box answers "data format error". ]]
local VERSION_HEADER = '3.4' .. string.rep('\000', 12)

function Device:_sendjson(cmd, obj, header)
  local body = json.encode(obj)
  if header then body = VERSION_HEADER .. body end
  if self.debug then
    log('tuya tx cmd=' .. string.format('0x%02x', cmd)
        .. (header and ' [hdr] ' or ' ') .. json.encode(obj))
  end
  return self:_send(cmd, aes(self.skey, pad(body), true), self.skey)
end

--[[ Status query. CONFIRMED for this device: variant 1, classic DP_QUERY
     (0x0a) with the gwId/devId envelope. Variant 2 (DP_QUERY_NEW 0x10) is
     kept for other firmware but this box ignores it. ]]
function Device:query(variant)
  if variant == 2 then
    return self:_sendjson(M.CMD.DP_QUERY_NEW, {
      protocol = 5, t = os.time(), data = {},
    })
  end
  return self:_sendjson(M.CMD.DP_QUERY, {
    gwId = self.id, devId = self.id, uid = self.id, t = tostring(os.time()),
  })
end

function Device:heartbeat()
  return self:_send(M.CMD.HEARTBEAT, aes(self.skey, pad('{}'), true), self.skey)
end

--[[ dps: { ['106'] = 'AQEAAQA=' }
     v3.4 write. No cid: that field belongs to gateway sub-devices and makes
     this box answer "data format error". Variants, in case the box refuses:
       1 - CONTROL_NEW (0x0d), { protocol, t, data = { dps } }
       2 - CONTROL_NEW (0x0d), { dps, t }
       3 - CONTROL (0x07),     { devId, uid, t, dps }                      ]]
function Device:set(dps, variant)
  if variant == 2 then
    -- header + bare dps envelope
    return self:_sendjson(M.CMD.CONTROL_NEW, { dps = dps, t = os.time() }, true)
  elseif variant == 3 then
    -- header + classic CONTROL (0x07) envelope
    return self:_sendjson(M.CMD.CONTROL, {
      devId = self.id, uid = self.id, t = tostring(os.time()), dps = dps,
    }, true)
  end
  -- default: header + v3.4 protocol wrapper on CONTROL_NEW (0x0d)
  return self:_sendjson(M.CMD.CONTROL_NEW, {
    protocol = 5,
    t = os.time(),
    data = { dps = dps },
  }, true)
end

--[[ Poll for one message. Set the socket timeout short (0.2 s) when calling
     from a resident script so the cycle does not block. Returns:
       dps_table, cmd   on a status/query/broadcast frame carrying data
       nil, 'timeout'   nothing pending
       nil, 'closed'    connection dropped, caller should reconnect
       nil, 'nojson'|'badjson', cmd, plaintext   undecodable frame      ]]
function Device:poll(timeout)
  if not self:connected() then return nil, 'closed' end
  --[[ The box answers the heartbeat every 10 s. No valid frame for
       STALE_S means the link is dead or only carries garbage, which never
       ends in 'closed' by itself: close it so the caller reconnects and the
       offline alert can run (code review 2026-11-18, T3-PAWBBY #a5). ]]
  if socket.gettime() - (self.lastrx or 0) > M.STALE_S then
    log('tuya: no valid frame for ' .. M.STALE_S .. ' s, closing the session')
    self:close()
    return nil, 'closed'
  end
  self.tmo = timeout or 0.2
  self.sock:settimeout(self.tmo)
  local cmd, payload, bcmd = self:_recv(self.skey)
  if not cmd then return nil, payload, bcmd end

  if self.debug then
    log('tuya rx cmd=' .. string.format('0x%02x', cmd)
        .. ' enc_len=' .. tostring(payload and #payload or 0))
  end

  if not payload or #payload == 0 then return nil, 'empty', cmd end

  local ok, plain = pcall(function() return unpad(aes(self.skey, payload, false)) end)
  if not ok or not plain then return nil, 'decrypt', cmd end

  if self.debug then
    log('tuya rx plain: ' .. plain:sub(1, 400))
  end

  -- the plaintext is returned on failure: without debug on, it is the only
  -- trace of a frame this parser does not understand
  --[[ Skip the 15 byte "3.4" header by length, not by searching for '{':
       its 12 "zero" bytes are not always zero (seen 2026-11-10/11:
       "3.4" .. 00 00 00 00 00 00 78 7b 00 00 00 01), and a 0x7b byte in
       there is a '{', which made the JSON start in the wrong place
       ("badjson (cmd 8)") and dropped those DP 111/113 updates. ]]
  if plain:sub(1, 3) == '3.4' and #plain > 15 then plain = plain:sub(16) end
  local s = plain:find('{')
  if not s then return nil, 'nojson', cmd, plain end
  local okj, obj = pcall(json.decode, plain:sub(s))
  if not okj or type(obj) ~= 'table' then return nil, 'badjson', cmd, plain end

  -- v3.4 wraps payloads as { protocol = n, t = ..., data = { dps = {...} } }
  -- type checks: a number in "data" or a non-table "dps" must not raise
  -- (code review 2026-11-18, T3-PAWBBY #a9)
  local dps = obj.dps
  if dps == nil and type(obj.data) == 'table' then dps = obj.data.dps end
  if type(dps) == 'table' then return dps, cmd end
  return nil, 'nodps', cmd
end

-- internals for the offline tests (tests/tuya34_frames.lua) only
M._test = { frame = frame, unframe = unframe, aes = aes, pad = pad, hmac = hmac }

return M
