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

--[[ Returns cmd, payload (still encrypted), bytes_consumed -- or nil if the
     buffer does not yet hold a complete frame. Device frames carry a 4 byte
     return code between length and payload; detected via block alignment. ]]
local function unframe(buf)
  local s = buf:find(PREFIX, 1, true)
  if not s then return nil end
  if #buf < s + 15 then return nil end
  local cmd = ru32(buf, s + 8)
  local len = ru32(buf, s + 12)
  local total = 16 + len
  if #buf < s + total - 1 then return nil end
  local plen = len - 36
  local payload = buf:sub(s + 16, s + 15 + plen)
  if plen % 16 ~= 0 and (plen - 4) % 16 == 0 then
    payload = payload:sub(5)          -- strip return code
  end
  return cmd, payload, s + total - 1
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

-- blocking read of exactly one frame, honouring the socket timeout
function Device:_recv()
  while true do
    local cmd, payload, consumed = unframe(self.buf)
    if cmd then
      self.buf = self.buf:sub(consumed + 1)
      return cmd, payload
    end
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
  local ok, err = sock:connect(self.ip, self.port)
  if not ok then return nil, 'connect: ' .. tostring(err) end
  sock:setoption('tcp-nodelay', true)
  self.sock = sock
  self.seq = 1
  self.buf = ''

  local lnonce = randbytes(16)
  self:_send(M.CMD.SESS_START, aes(self.key, pad(lnonce), true), self.key)

  local cmd, payload = self:_recv()
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
  return true
end

function Device:close()
  if self.sock then pcall(function() self.sock:close() end) end
  self.sock, self.skey, self.buf = nil, nil, ''
end

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
  self.sock:settimeout(timeout or 0.2)
  local cmd, payload = self:_recv()
  if not cmd then return nil, payload end

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
  local s = plain:find('{')
  if not s then return nil, 'nojson', cmd, plain end
  local okj, obj = pcall(json.decode, plain:sub(s))
  if not okj or type(obj) ~= 'table' then return nil, 'badjson', cmd, plain end

  -- v3.4 wraps payloads as { protocol = n, t = ..., data = { dps = {...} } }
  local dps = obj.dps or (obj.data and obj.data.dps)
  if dps then return dps, cmd end
  return nil, 'nodps', cmd
end

return M
