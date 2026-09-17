# Tuya local protocol v3.4, as used by this box

Summary of what `src/tuya34.lua` implements and was confirmed against the
PAWBBY. Gotchas and failed attempts are in `FINDINGS.md`; datapoints in
`DATAPOINTS.md`.

## Transport

TCP port 6668. The box accepts **one** connection at a time; the vendor app
must be closed. Idle connections are dropped after roughly 30 s, so the
script sends a heartbeat every 10 s.

## Frame

    00 00 55 AA | seq u32 | cmd u32 | len u32 | payload | HMAC-SHA256 (32) | 00 00 AA 55

- all integers big-endian
- `len` = payload length + 36 (HMAC + suffix)
- the HMAC covers everything from the prefix up to the end of the payload
- frames **from** the device carry a 4-byte return code before the payload;
  the parser detects it by block alignment (payload length not a multiple of
  16, but length − 4 is)

## Commands

| Cmd | Name | Use here |
|-----|------|----------|
| 0x03 | SESS_START | handshake step 1 |
| 0x04 | SESS_RESP | handshake step 2 (device) |
| 0x05 | SESS_FINISH | handshake step 3 |
| 0x07 | CONTROL | not used by this box |
| 0x08 | STATUS | unsolicited broadcast from the device |
| 0x09 | HEARTBEAT | keepalive, payload `{}` |
| 0x0a | DP_QUERY | **status query that works on this firmware** |
| 0x0d | CONTROL_NEW | writes |
| 0x10 | DP_QUERY_NEW | ignored by this firmware |

## Session key negotiation

All three handshake frames use the device's local key for both AES and HMAC.

    -> 0x03  AES(local_key, local_nonce)                        16 random bytes
    <- 0x04  AES(local_key, remote_nonce .. HMAC(local_key, local_nonce))
    -> 0x05  AES(local_key, HMAC(local_key, remote_nonce))

    session_key = AES-ECB(local_key, local_nonce XOR remote_nonce), no padding

The device's HMAC proof is checked; a mismatch almost always means a wrong
local key. After the handshake the session key is used for AES and HMAC.

## Crypto

AES-128-ECB. Payloads are PKCS#7-padded in Lua, and the cipher runs with
padding disabled. On the LM this goes through libcrypto via LuaJIT FFI,
because there is no `aes` module. `encdec.hmacsha256` returns hex, so it is
converted to raw bytes before use.

## Payloads

Query (0x0a):

    {"gwId": id, "devId": id, "uid": id, "t": "<unix time as string>"}

Write (0x0d), prefixed with the 15-byte version header `"3.4"` + 12 zero bytes:

    {"protocol": 5, "t": <unix time>, "data": {"dps": {"106": "AQEAAQA="}}}

No `cid`. Device messages carry the same header before the JSON; the parser
skips to the first `{`. Replies are either `{"dps": {...}}` or
`{"protocol": n, "t": ..., "data": {"dps": {...}}}`.
