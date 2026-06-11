-- ─── nix/modules/mitm-minter.lua ───────────────────────────────────────
-- On-the-fly per-SNI leaf minter for the client nginx :443 frontend
-- (focus-design §14.6). Replaces the pre-minted per-FQDN leaves: in the
-- ssl_certificate_by_lua phase we read the SNI, mint+sign a leaf for that
-- name under this client's MITM CA, and install it for the handshake.
--
-- Design (lessons distilled from mitmproxy's CertStore, see §14.6):
--   * ONE reused EC leaf key, loaded once at init — per-SNI cost is a single
--     ECDSA signature, never a keygen.
--   * Two-tier cache: a per-worker lua-resty-lrucache holding the PARSED
--     cdata cert (what ngx.ssl.set_cert consumes, so zero re-parse per
--     handshake), backed by a shared_dict of the leaf PEM so only ONE worker
--     mints a given host and the rest read it back.
--   * A per-host lua-resty-lock collapses the cold-SNI stampede across the N
--     workers so a burst of first-contact handshakes signs once, not N times.
--   * Correctness footguns that make strict clients (Go crypto/x509, python
--     ssl, package managers) reject a forged leaf:
--       - AKI copied BYTE-FOR-BYTE from the CA's stored SKI (we pass the
--         issuer cert to OpenSSL's `authorityKeyIdentifier=keyid`, which
--         copies the issuer SKI rather than recomputing it).
--       - name in the SAN only, subject empty, SAN marked critical.
--       - NO subjectKeyIdentifier on the leaf (a shared SKI breaks SChannel).
--       - EKU serverAuth, a random serial, a back-dated notBefore.
--
-- Fail-safe: any error leaves the static placeholder cert in place and lets
-- the handshake proceed/fail on its own — the minter never throws out of the
-- cert phase and never takes a worker down.

local ssl       = require "ngx.ssl"
local x509      = require "resty.openssl.x509"
local pkey      = require "resty.openssl.pkey"
local name_lib  = require "resty.openssl.x509.name"
local altname   = require "resty.openssl.x509.altname"
local extension = require "resty.openssl.x509.extension"
local digest    = require "resty.openssl.digest"
local bn        = require "resty.openssl.bn"
local rand      = require "resty.openssl.rand"
local lrucache  = require "resty.lrucache"
local resty_lock = require "resty.lock"

local _M = {}

-- init-time state (loaded once in the master, inherited by workers on fork).
local cfg            -- the opts table from init()
local ca_cert        -- resty.openssl.x509 of the MITM CA (issuer ctx for AKI)
local ca_pkey        -- resty.openssl.pkey of the CA private key (signs leaves)
local ca_pem         -- CA cert PEM (appended to the chain we serve)
local ca_subject     -- resty.openssl.x509.name of the CA subject (leaf issuer)
local leaf_pkey      -- resty.openssl.pkey, the single reused leaf key
local leaf_key_cdata -- ngx.ssl parsed private key (constant across hosts)
local sha256         -- resty.openssl.digest instance reused for signing
local lru            -- per-worker cache of parsed cert cdata

local function read_file(path)
  local f, err = io.open(path, "r")
  if not f then return nil, "open " .. path .. ": " .. (err or "?") end
  local data = f:read("*a")
  f:close()
  return data
end

-- Called from init_by_lua_block. opts carries the on-box paths + tunables
-- (see constants.mitmMinter). Returns true, or nil+err (the caller logs;
-- a failed init means the static placeholder cert is all that's served).
function _M.init(opts)
  local ca_key_pem, leaf_key_pem, err
  ca_pem, err = read_file(opts.ca_cert)
  if not ca_pem then return nil, err end
  ca_key_pem, err = read_file(opts.ca_key)
  if not ca_key_pem then return nil, err end
  leaf_key_pem, err = read_file(opts.leaf_key)
  if not leaf_key_pem then return nil, err end

  ca_cert, err = x509.new(ca_pem)
  if not ca_cert then return nil, "parse CA cert: " .. tostring(err) end
  ca_pkey, err = pkey.new(ca_key_pem)
  if not ca_pkey then return nil, "parse CA key: " .. tostring(err) end
  ca_subject, err = ca_cert:get_subject_name()
  if not ca_subject then return nil, "CA subject: " .. tostring(err) end

  leaf_pkey, err = pkey.new(leaf_key_pem)
  if not leaf_pkey then return nil, "parse leaf key: " .. tostring(err) end
  leaf_key_cdata, err = ssl.parse_pem_priv_key(leaf_key_pem)
  if not leaf_key_cdata then return nil, "ssl parse leaf key: " .. tostring(err) end

  sha256, err = digest.new("sha256")
  if not sha256 then return nil, "digest sha256: " .. tostring(err) end

  lru, err = lrucache.new(opts.lru_size or 512)
  if not lru then return nil, "lrucache: " .. tostring(err) end

  -- Set last: handle() gates on cfg, so a partial init never serves.
  cfg = opts
  return true
end

local function is_ipv4(host)
  return host:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
end

local function is_ip(host)
  return is_ipv4(host) or host:find(":", 1, true) ~= nil
end

-- Single-level wildcard collapse: cdn-lfs.huggingface.co → *.huggingface.co
-- (a one-label wildcard matches exactly that sub-domain depth). Apex names
-- (one dot) and IP literals are returned unchanged. Returns the SAN/cache-key
-- string actually used.
local function san_key(host)
  if not cfg.wildcard_collapse or is_ip(host) then return host end
  local _, dots = host:gsub("%.", "")
  if dots < 2 then return host end   -- apex like huggingface.co
  local parent = host:match("^[^.]+%.(.+)$")
  if not parent then return host end
  return "*." .. parent
end

local function stat_incr(field)
  local d = ngx.shared[cfg.stats_dict]
  if d then d:incr(field, 1, 0) end
end

-- Build + sign a leaf whose only identity is `san` (a DNS name, possibly a
-- wildcard, or an IP literal). Returns the leaf PEM, or nil+err.
local function mint(san)
  local leaf, err = x509.new()
  if not leaf then return nil, "x509.new: " .. tostring(err) end

  leaf:set_version(2)                       -- X.509 v3
  leaf:set_pubkey(leaf_pkey)                -- the shared reused leaf key
  leaf:set_subject_name(name_lib.new())     -- empty subject → SAN is the identity
  leaf:set_issuer_name(ca_subject)

  -- random serial (16 bytes, top bit cleared → unambiguously positive, ≤20 octets)
  local sbytes = rand.bytes(16)
  if sbytes then
    sbytes = string.char(string.byte(sbytes, 1) % 128) .. sbytes:sub(2)
    local serial = bn.from_binary(sbytes)
    if serial then leaf:set_serial_number(serial) end
  end

  local now = ngx.time()
  leaf:set_not_before(now - (cfg.backdate_seconds or 0))
  leaf:set_not_after(now + (cfg.leaf_ttl_seconds or 604800))

  -- SAN (critical, since the subject is empty)
  local sans = altname.new()
  local ok
  ok, err = sans:add(is_ip(san) and "IP" or "DNS", san)
  if not ok then return nil, "altname add: " .. tostring(err) end
  ok, err = leaf:set_subject_alt_name(sans)
  if not ok then return nil, "set SAN: " .. tostring(err) end
  leaf:set_subject_alt_name_critical(true)

  leaf:set_basic_constraints({ CA = false })
  leaf:set_basic_constraints_critical(true)

  -- EC leaves want digitalSignature (no keyEncipherment — that's an RSA use).
  local ku = extension.new("keyUsage", "critical,digitalSignature")
  if ku then leaf:add_extension(ku) end
  local eku = extension.new("extendedKeyUsage", "serverAuth")
  if eku then leaf:add_extension(eku) end

  -- AKI = the CA's SubjectKeyIdentifier, copied verbatim. Passing the issuer
  -- cert makes OpenSSL's `keyid` form read the CA's stored SKI instead of
  -- recomputing one (the byte-for-byte match strict chain builders require).
  local aki = extension.new("authorityKeyIdentifier", "keyid", { issuer = ca_cert })
  if aki then leaf:add_extension(aki) end

  ok, err = leaf:sign(ca_pkey, sha256)
  if not ok then return nil, "sign: " .. tostring(err) end

  return leaf:to_PEM()
end

-- Install a parsed (cert_cdata) into the live handshake.
local function apply(cert_cdata)
  local ok, err = ssl.clear_certs()
  if not ok then return nil, "clear_certs: " .. tostring(err) end
  ok, err = ssl.set_cert(cert_cdata)
  if not ok then return nil, "set_cert: " .. tostring(err) end
  ok, err = ssl.set_priv_key(leaf_key_cdata)
  if not ok then return nil, "set_priv_key: " .. tostring(err) end
  return true
end

-- Parse leaf PEM (+ the CA, so clients get the full chain) into the cdata
-- ngx.ssl consumes, and memoise it per worker.
local function parse_and_cache(key, leaf_pem)
  local chain = leaf_pem .. ca_pem
  local cert_cdata, err = ssl.parse_pem_cert(chain)
  if not cert_cdata then return nil, "parse_pem_cert: " .. tostring(err) end
  lru:set(key, cert_cdata)
  return cert_cdata
end

-- ssl_certificate_by_lua entrypoint. Never raises: on any failure it logs and
-- returns, leaving the static placeholder cert in place (fail-safe).
function _M.handle()
  if not cfg then return end   -- init failed; placeholder cert serves

  local host, err = ssl.server_name()
  if not host then
    -- No SNI → nothing to forge. Leave the placeholder; the handshake fails
    -- on name mismatch. (This is also the seam the future ssl_preread
    -- stream-passthrough escape hatch attaches to, §14.6.)
    return
  end
  host = host:lower()
  local key = san_key(host)

  -- tier 1: per-worker parsed cdata
  local cert_cdata = lru:get(key)
  if cert_cdata then
    apply(cert_cdata)
    return
  end

  -- tier 2: shared PEM cache
  local certs = ngx.shared[cfg.cert_dict]
  local leaf_pem = certs and certs:get(key)
  if leaf_pem then
    cert_cdata, err = parse_and_cache(key, leaf_pem)
    if cert_cdata then apply(cert_cdata) else
      ngx.log(ngx.ERR, "mitm-minter: ", err, " (host ", host, ")")
    end
    return
  end

  -- cold host: serialise the mint across workers with a per-host lock.
  local lock, lerr = resty_lock:new(cfg.lock_dict)
  if not lock then
    ngx.log(ngx.ERR, "mitm-minter: lock new: ", lerr)
    return
  end
  local elapsed = lock:lock(key)
  if not elapsed then
    -- couldn't acquire (timeout): fall through and mint unlocked rather than
    -- fail the handshake — worst case is a duplicate signature.
    ngx.log(ngx.WARN, "mitm-minter: lock timeout for ", key)
  end

  -- re-check the shared cache: another worker may have minted while we waited.
  leaf_pem = certs and certs:get(key)
  if not leaf_pem then
    leaf_pem, err = mint(key)
    if leaf_pem then
      stat_incr("mint")
      ngx.log(ngx.INFO, "mitm-minter: minted leaf for ", key,
              host ~= key and (" (sni " .. host .. ")") or "")
      if certs then
        local ok, serr, forcible = certs:set(key, leaf_pem)
        if not ok then ngx.log(ngx.WARN, "mitm-minter: cert dict set: ", serr) end
        if forcible then stat_incr("evict") end
      end
    else
      stat_incr("error")
      ngx.log(ngx.ERR, "mitm-minter: mint failed for ", key, ": ", err)
    end
  end

  if leaf_pem then
    cert_cdata, err = parse_and_cache(key, leaf_pem)
  end
  if elapsed then lock:unlock() end

  if cert_cdata then
    apply(cert_cdata)
  elseif err then
    ngx.log(ngx.ERR, "mitm-minter: ", err, " (host ", host, ")")
  end
end

return _M
