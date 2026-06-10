# Container MITM for *arbitrary* origins — an exploration

> **STATUS: Exploration / forward-looking proposal — NOT built.**
> Nothing in this document is implemented. The shipped, tested container-MITM mechanism is
> [§05 — Trust & MITM](05-trust-and-mitm.md); this doc only sketches how that mechanism *could* be
> generalised, and weighs the trade-offs. Read every "would / could / one option" below as
> conditional, not as current behaviour.

## Why the allowlist is the ceiling

Today the lab can MITM a container's HTTPS only for a **curated list of FQDNs** — the model stores
plus `mitmExtraHosts` ([§05.2](05-trust-and-mitm.md)). That ceiling is not incidental; it is baked
into the two mechanisms §05 uses, and **both** are keyed on a hostname you must know in advance:

- **Redirection is DNS-based.** Each MITM'd host gets a `/etc/hosts` line — `127.0.0.1 <fqdn>` on
  the client ([`mitm.nix`](../nix/modules/mitm.nix)) and `<client-ip> <fqdn>` inside each container
  ([`ca-injector.nix`](../nix/modules/ca-injector.nix)). No line, no interception.
- **Certs are pre-minted per FQDN.** `cache-gen-secrets` writes one leaf per cert group to
  `secrets/<client>/mitm/<group>.{crt,key}` ([`secrets-gen.nix`](../nix/secrets-gen.nix)), and the
  client `:443` server blocks pick one by SNI ([`nginx-client.nix`](../nix/modules/nginx-client.nix)).
  No leaf, no valid forged cert.

So intercepting an origin you *cannot enumerate up front* — the realistic case for arbitrary
container workloads (a RunPod image may `pip install`, `git clone`, or fetch weights from dozens of
hosts) — requires making **both** halves hostname-agnostic. That is the thesis of this doc, and the
lens for every section below.

## The three pieces that would have to change

| Concern | §05 today (hostname-keyed) | Arbitrary-origin replacement |
|---|---|---|
| **Redirection** | `/etc/hosts` line per FQDN, host + container | **nftables DNAT** at the docker bridge, by port |
| **Cert minting** | pre-minted per-FQDN leaves, SNI-selected | **on-the-fly leaves** minted per SNI under the same MITM CA |
| **CA delivery** | runc shim bind-mounts CA bundle + env vars | a container **filesystem layer** *or* keep the shim |

The CA *trust anchor* does not change — it is still the **per-client MITM CA** from
[§05.1](05-trust-and-mitm.md). Only the delivery, the redirection, and the leaf-minting become
general. Those three are all about *interception*; arbitrary origins surface a fourth, orthogonal
concern the curated design never had to face — **authorization**, the moment those origins include
private registries — covered in *Serving private origins* below.

## Redirection: nftables DNAT at the docker bridge

The lab has no DNS server, which is exactly why §05 falls back to `/etc/hosts`. To catch destinations
hostname-agnostically you stop caring about names and intercept at the packet layer instead.
Container egress inside the client leaves on docker's default bridge (`docker0` — no custom `bip` is
set, [`docker-client.nix`](../nix/modules/docker-client.nix)), so a DNAT rule anchored to that
interface can redirect container traffic into the proxy.

The cardinal rule: **do not intercept everything.** A container will legitimately dial origins we do
*not* cache — a payment API, an S3 PUT, an arbitrary HTTPS REST call — and those must pass through
untouched. Breaking unrelated egress violates the "containers run unmodified" requirement just as
badly as breaking a pull. So interception is **opt-in by origin**, enforced as a **two-stage filter**:

1. **An IP-range set (coarse) at the bridge** — only traffic to a *maintained* set of origin/CDN
   ranges is DNAT'd to the proxy; everything else routes straight out, never touched.
2. **An SNI allowlist (fine) at the proxy** — once a redirected flow arrives, `ssl_preread` the
   ClientHello and MITM **only** if the SNI is an origin we actually cache; otherwise
   `stream`-passthrough it to the real upstream (see *Cert minting* below).

```
# illustrative only — not in the repo
table inet container-mitm {
  set cdn_origins { type ipv4_addr; flags interval; auto-merge; }   # fed by the updater daemon
  chain prerouting {
    type nat hook prerouting priority dstnat;
    iifname "docker0" ip daddr @cdn_origins tcp dport { 80, 443 } dnat ip to 10.44.44.10:443
    # ...and the ip6 equivalent (cdn_origins6) for the v6 bridge
  }
}
```

Four things make this more subtle than one rule:

- **It must coexist with what's already there.** The only nftables today is the *masquerade* in
  [`network-setup.nix`](../nix/network-setup.nix) (`table inet cache-nat`, postrouting). DNAT runs
  in `prerouting`/`dstnat` and would fire first, but docker installs its own chains
  (`DOCKER-USER`, the `docker-proxy`), so a real implementation has to place the rule where it sees
  container traffic *before* docker's SNAT and the lab's masquerade rewrite it.
- **Scope by a maintained IP-range set, not by port.** The tempting shortcut is to DNAT *all*
  container `:443` and let the SNI stage sort it out. Don't: that drags every unrelated TLS flow
  through the proxy and makes a proxy outage a total-egress outage. Gate the rule on a named nft
  **interval set** of the origin/CDN ranges we cache (`@cdn_origins` above), kept fresh by an
  external updater (see below). Note the **coarse/fine split is not optional**: CDN ranges are
  *shared* — CloudFront fronts thousands of tenants — so the IP set alone over-captures, and the
  SNI stage is what actually protects the other tenant's API. By-port-everything remains *possible*
  (it is what makes truly *arbitrary*, un-enumerable interception work) but is the maximally broad,
  generally undesirable fallback, not the default.
- **Recovering the original destination.** Once traffic is DNAT'd, the proxy has lost the original
  dst IP. With TLS that usually does not matter — we route on the **SNI**, not the address — so the
  proxy can connect upstream by the SNI name. `SO_ORIGINAL_DST`/TPROXY is the fallback for clients
  that send no SNI (rare, and largely un-MITM-able anyway).
- **Recovering from an empty/stale set fails safe.** A range not yet in the set escapes to WAN — a
  cache *miss*, not a breakage; a de-listed range still hits the proxy but the SNI stage passes it
  through. So set staleness degrades hit-rate, never correctness.

The payoff over `/etc/hosts`: a container that ignores `/etc/hosts` — a static Go/musl binary doing
its own resolution, a hardcoded IP, a private DNS-over-HTTPS resolver — sails past §05's redirection
but cannot escape a bridge-level DNAT.

### The IP-range updater is its own design problem — *follow-up required*

The `@cdn_origins` set has to be populated from somewhere, and the obvious source is the published
range feeds the big origins maintain: AWS `ip-ranges.json` (service-tagged — `CLOUDFRONT`,
`CLOUDFRONT_ORIGIN_FACING`, `S3`; notably Hugging Face weight downloads have historically ridden
S3/CloudFront, so this feed covers much of the model-weight case), GitHub `api.github.com/meta`,
Cloudflare `cloudflare.com/ips-v4`, Fastly, GCP `cloud.json`. A daemon (or timer) pulls these,
filters to the services we cache, and atomically rewrites the nft set
(`nft flush/add element …` — the set churns while the ruleset stays static).

This is deceptively dangerous and **needs a detailed design of its own — not covered here.** A few
load-bearing requirements to capture now, because this class of script has a long history of going
badly wrong:

- **Cap the rate of change.** A single refresh must not be able to add/remove more than a sane
  bound; a feed that suddenly publishes "all of AWS" must be rejected, not applied — otherwise the
  proxy becomes a fleet-wide egress black hole.
- **Persist range history on disk.** Keep prior snapshots locally so that if a source is
  unreachable or returns garbage, the daemon **falls back to the last-known-good set** rather than
  flushing to empty (empty = silent cache bypass; a bad parse must never widen or zero the set).
- **Validate before apply, apply atomically, roll back trivially.** Schema-check every feed,
  size-cap the result, swap the set in one transaction, and keep the previous set ready to restore.
- **Treat the feed as a privileged, untrusted input.** It steers what traffic the proxy can
  decrypt, so a compromised or malformed feed is a security event, not just an availability one.

The full failure-mode analysis (refresh cadence, partial-feed handling, v4/v6 parity, observability,
alerting on churn) is a follow-up design, deliberately out of scope for this document.

## Cert minting: on-the-fly leaves

Pre-minted leaves cannot answer an SNI you have never seen, so an arbitrary-origin design needs to
**mint a leaf on demand**, signed by the same per-client MITM CA the container already trusts. Two
routes:

- **Mint inside nginx (recommended).** OpenResty is already the `:443` terminator, so an
  `ssl_certificate_by_lua` handler could read the SNI, generate-or-cache a leaf for that name under
  the MITM CA, and hand it to the handshake. This keeps one component on the data path and reuses
  the existing trust anchor.
- **A dedicated transparent MITM proxy** (mitmproxy-style) sitting in front of the cache, doing the
  same generate-per-SNI dance.

**On engine choice / performance.** mitmproxy is excellent for *prototyping* the SNI dance, but it
is **Python** — the per-connection overhead and the GIL make it the wrong **data-path** engine for
multi-GiB image/model traffic at fleet scale. OpenResty is the right call, and the reason is *where
the work lands*: TLS termination, `proxy_pass`, and `proxy_cache` are nginx C core + OpenSSL, with
Lua running only at the **SNI callback** (microseconds per *connection*, nothing per *byte*). The
one genuinely expensive step — minting+signing a leaf — is **language-agnostic** (mitmproxy pays it
too) and is fixed the same way everywhere: mint once per hostname and **cache the leaf**. Flows you
*don't* MITM cost **zero crypto** — `ssl_preread` + `stream`-passthrough runs at near line-rate. And
because the cache is *already* OpenResty, doing the MITM there avoids bolting a second, slower
process onto the data path.

Because interception is already scoped to origins we cache (the two-stage filter above), the proxy
is not in the path of *all* `:443` — but the SNI passthrough is still mandatory as the second filter
stage and as the escape hatch for flows that arrive but must not (or cannot) be broken: `ssl_preread`
the ClientHello and **stream-passthrough** anything whose SNI we don't cache, or that would fail (see
pinning below), and MITM the rest. One hard limit to state plainly: **Encrypted Client Hello (ECH)**
hides the SNI, so SNI-based routing — and therefore selective MITM — simply cannot see those
connections.

### Designing the Lua SNI minter — lessons from mitmproxy

mitmproxy's `CertStore` (`mitmproxy/certs.py`) and its handshake glue
(`mitmproxy/addons/tlsconfig.py`, `get_cert`) are a battle-tested reference for the generate-per-SNI
dance. Read for *design*, not for code to port — it is single-process Python; OpenResty is
multi-worker and on the data path, which changes several decisions. The transferable lessons:

**Performance — minting is one *signature*, not a keygen.** mitmproxy never generates a keypair per
host: every leaf reuses a single long-lived private key (it actually reuses the CA's own keypair —
`dummy_cert` sets the leaf public key to the CA's and signs with the CA key), so the per-SNI cost is
exactly one certificate build + one `sign()`. The Lua minter must do the same: load **one** leaf
private key at `init_by_lua` and reuse it for every host; per-SNI work is then a template + a single
signature. And because this signature is on the **handshake** path, prefer an **ECDSA P-256** MITM CA
+ leaf key over RSA-2048 — EC signing is dramatically cheaper per handshake (mitmproxy defaults to
RSA because it is a debugging tool where throughput is not the point; our fleet path is the opposite).

**Caching — bounded, name-keyed, two-tier.** mitmproxy keeps an in-memory dict keyed by name with a
hard cap (`STORE_CAP = 100`, FIFO eviction) and **collapses wildcards** on lookup (`asterisk_forms`:
a single `*.huggingface.co` leaf serves every subdomain, so a flood of distinct subdomains still
mints once). In OpenResty this becomes two tiers: a per-worker `lua-resty-lrucache` holding the
*parsed* `cdata` cert/key (what `ngx.ssl.set_cert`/`set_priv_key` consume, so no re-parse per
handshake), backed by a shared `lua_shared_dict` of the PEM/DER bytes so only **one worker** mints a
given host and the rest read it back. Size the shared dict as the cap; it LRU-evicts under an SNI
flood. Optionally wildcard-collapse the cache key as mitmproxy does, to shrink both mint count and
memory.

**Concurrency — guard the cold-host stampede.** Single-process mitmproxy never races; nginx has N
workers that can all take a cold SNI at once. Wrap the mint in a `lua-resty-lock` keyed by host so a
burst of first-contact handshakes signs once, not N times. `ssl_certificate_by_lua` permits yielding,
so the lock's non-blocking `ngx.sleep` is fine; the signature itself is a short blocking FFI call
(fast for EC).

**Correctness — the footguns that make strict clients reject the leaf.** These are exactly the
clients we serve (Go SDKs, `requests`, package managers), so getting them wrong is fatal, not
cosmetic. From `certs.py`:
- **AKI must equal the issuer CA's SubjectKeyIdentifier, byte-for-byte** — copy the CA's stored SKI
  into the leaf's `AuthorityKeyIdentifier`; do **not** recompute it from the public key (that yields
  a SHA-1 digest and mismatches modern truncated-SHA-256 SKIs). Strict chain builders
  (`X509_V_FLAG_X509_STRICT`, Go `crypto/x509`, Python `ssl`) reject the mismatch with "authority and
  subject key identifier mismatch" (`certs.py` documents this at length around `dummy_cert`).
- **Put the name in the SAN, not the CN.** Per RFC 2818 modern clients validate the
  SubjectAlternativeName and ignore the Common Name; the SNI goes in the SAN (`DNSName`, or
  `IPAddress` for an IP literal), marked critical if the subject is empty.
- **Do not give the leaf the CA's SKI** (mitmproxy omits the leaf SKI entirely — a shared SKI breaks
  Windows SChannel).
- **EKU `serverAuth`, a random serial, and a back-dated `notBefore`** (mitmproxy back-dates ~2 days
  via `CERT_VALIDITY_OFFSET` to tolerate client clock skew). Leaf TTL can be short since we re-mint
  freely.

**Handshake wiring.** In `ssl_certificate_by_lua`: read the SNI with `ngx.ssl.server_name()`; **no
SNI → do not mint**, fall to `stream`-passthrough (you have no identity to forge, and it is the
already-required escape hatch). With an SNI, look it up in the two-tier cache or mint, then
`ngx.ssl.clear_certs()` + `set_cert` + `set_priv_key`. Unlike mitmproxy we can mint **purely from the
SNI** and skip its optional "upstream-cert sniffing" (`tlsconfig.py` copying the real origin's
CN/SAN/org): because we are the CA the client trusts, the leaf only has to match what the client
*asked for* (the SNI), not what the origin actually presents — simpler, and it avoids a blocking
upstream TLS handshake inside the cert callback.

## CA injection: filesystem layer vs the runc shim

Whichever redirection you pick, the container still has to **trust** the forged cert, so the MITM CA
must be inside it. §05 does this with the runc shim ([§05.4](05-trust-and-mitm.md)): bind-mounts
over the distro CA paths **plus** env vars (`SSL_CERT_FILE`, `CURL_CA_BUNDLE`, …). The user's idea is
to instead **inject a filesystem layer** that carries the `.crt`.

| | **Filesystem layer** (proposed) | **runc bind-mount + env** (today, [§05.4](05-trust-and-mitm.md)) |
|---|---|---|
| Looks native to the image | yes — appears as image content | no — appears only at runtime |
| Survives `docker save` / export | yes | no |
| Custom runtime needed | no | yes (`runc-with-ca`) |
| Can set env vars (`SSL_CERT_FILE` …) | **no** — a layer carries files, not process env | yes |
| Reaches apps with embedded/own bundles | only if it overwrites the exact path they read | env vars catch many of these |
| Cost model | re-inject **per image** (mutates content) | one shim, applies to every container |

The honest read: a layer is a **viable delivery vector** but **weaker on its own**, because it
loses the env-var lever that today's design leans on for tools that don't read the system store.
Nothing stops combining them (layer for the file paths, plus env injection), but then you have not
actually removed the runtime hook. Note too that a layer **mutates image content** — relevant both
to the cache's byte-identical guarantees and to the constraint below.

### How the runc shim actually works — and why it isn't per-layer

A common first guess is that runc fires *per image layer*, so the shim could detect "the Ubuntu
layer" or "the Fedora layer" and inject only the matching CA path. That is not how it works, and the
distinction matters for anyone weighing selectivity:

- **Layers are assembled before runc ever runs.** The **snapshotter** pulls, unpacks, and stacks the
  layers at *image-unpack* time; by container start they are already merged into one `rootfs`.
- **runc is called once per container**, on the OCI *bundle* (`config.json` + the merged `rootfs`) —
  not per layer. runc has no concept of "the Ubuntu layer"; layering lives entirely below it. There
  is nothing layer-shaped to branch on at create time.

The shim ([`ca-injector-wrapper.nix`](../nix/ca-injector-wrapper.nix)) is registered as docker's
`default-runtime = "runc-with-ca"` ([`ca-injector.nix`](../nix/modules/ca-injector.nix)). On the
`create` subcommand it `jq`-patches the bundle's `config.json` — appending read-only bind mounts and
env vars — then `exec`'s the real runc. It is **strictly fail-open**: any error leaves `config.json`
untouched and still launches the container, so it can never abort an unmodified user workload.

**On the "unclean" multi-distro mounts.** It looks like the shim injects Red Hat cert paths into an
Ubuntu image, but every entry mounts the *same one source file*
(`/etc/cache-mitm-ca-bundle.crt`, content = system public CAs ++ MITM CA) at several distro paths.
The bundle is distro-agnostic; the Fedora-flavoured path on an Ubuntu box is just an extra mountpoint
onto identical content, holding a file nothing there reads. runc creates any missing mountpoint, so
over-mounting a path the image lacks is harmless. Mounting *all* paths is a deliberate
distro-agnosticism trade — it avoids needing to detect the distro at all.

### If you wanted to be selective

Selectivity is possible but the clean inspection point depends on the snapshotter — and this lab runs
`features.containerd-snapshotter = true` ([`docker-client.nix`](../nix/modules/docker-client.nix)):

| Inspection point | Can read distro (`/etc/os-release`)? | Fail-open? |
|---|---|---|
| runc `create` shim (today) | **No** under containerd-snapshotter — merged rootfs isn't a plain dir at create time (same reason §05.4 uses mounts, not a file-touching hook) | yes |
| OCI `createContainer` hook | yes — runs in the container namespace after rootfs mount | **no** — a hook error aborts the container |
| **Image-unpack time** | yes — full unpacked filesystem + image config/labels visible | n/a (per image, not per container) |

So the cleanest way to mount only the native path is to **decide the distro at image-unpack time**
(per image, filesystem fully visible) and have the create-shim apply the already-chosen path —
*not* to detect it inside the create-time shim, where the snapshotter hides the rootfs. Under the
old `overlay2` graphdriver the rootfs *is* pre-mounted at create time and the shim could read
os-release directly; opting into the containerd snapshotter closes that door.

### The shim need not be bash

A "runtime" in `daemon.json` is just **any executable that speaks the runc CLI**
(`create`/`start`/`kill`/`delete`/`state`, `--bundle`, …) and `exec`'s the real runc. Bash was
chosen because today's job is tiny — one `jq` transform + `exec` — and ~30 auditable lines make the
fail-open property trivial to verify. A **Go or Rust** shim is the natural upgrade *if* selective
injection is wanted: it can unmarshal `config.json` into the real `opencontainers/runtime-spec`
structs instead of string-munging, get structured "inspect, decide, but never abort on error"
control flow, and branch on a distro decision cleanly (real-world references: **youki** in Rust,
**crun** in C, thin Go shims over `runtime-spec`). The limitation removed by Go/Rust is *bash*, not
the *snapshotter* — even a Rust shim cannot reliably read the merged rootfs at create time while
`containerd-snapshotter` is on.

## Serving private origins: delegated auth

Everything above is about *interception* — getting the bytes off the wire. The moment "arbitrary
origins" includes a **private** registry it surfaces a separate axis the curated allowlist never
touched: **authorization**. The model stores §05 MITMs are anonymous public reads; but the
usage data shows containers pulling from `registry.runpod.net`, which answers an anonymous
manifest request with `401`. A cache that has terminated the client's TLS now holds a decrypted,
*unauthenticated* request for content it may already have on disk. It must not simply serve those
bytes — that would turn the cache into an authorization bypass, handing any tenant another tenant's
private images.

The principle: **the cache makes no authorization decision of its own.** It re-uses the origin's
verdict. The client's own credential rides in the decrypted request; the cache's only job is to
confirm the origin *would have* honoured that credential for this repo, and serve from cache only on
a pass. To do that you have to know how registry auth is carried.

- **Basic.** A per-request `Authorization: Basic base64(user:pass)` header — quite literally "just a
  header," re-presented on every call. There is no exchange; the registry validates it inline.
- **Bearer / token.** A `401` carries `WWW-Authenticate: Bearer realm=…,service=…,scope=…`; the
  client GETs that realm/token endpoint, gets back an RS256-signed JWT scoped to one repo + action
  with a short (~5-min) expiry, and retries with `Authorization: Bearer <jwt>`. The credential the
  cache sees is the JWT, not the password.

Two ways to turn that into a gate, and the **general** one wins by default:

- **`access_by_lua` origin-probe (general, recommended).** Before serving, the cache replays the
  client's *exact* credential against the origin's cheapest authoritative endpoint — a `HEAD` on the
  manifest, or the token-endpoint handshake. Origin says `200`/grants the scope → serve cache;
  `401`/`403` → relay the denial untouched. This is **auth-scheme-agnostic**: it works for Basic,
  Bearer, mTLS-fronted, or any future scheme, because the origin — not the cache — interprets the
  credential. It costs one small round-trip per authorization, not per byte.
- **`lua-resty-jwt` local verification (optimization, Bearer only).** For token registries you can
  skip the round-trip: fetch the registry's JWKS once, then verify the Bearer JWT's signature,
  `exp`, `aud`/`service`, and `scope` locally in `access_by_lua`. Faster and origin-independent, but
  it only understands signed-JWT schemes and it trusts the token until expiry (no instant
  revocation). Treat it as a cache layer *over* the probe, not a replacement.

Reconcile the two with a **short-TTL authz cache** keyed by `(client-identity, repo)` — a passing
probe (or a still-valid verified JWT) authorizes subsequent pulls of that repo for, say, a minute,
so a multi-layer image pull does not probe per blob. The TTL is the revocation-latency knob.

Three caveats to state plainly:

- **Rate-limit irony.** A naive per-request origin-probe spends exactly the Docker Hub *manifest*
  rate-limit budget the cache exists to conserve. The authz cache is what keeps the probe count near
  one-per-(client,repo), not one-per-pull — without it the gate defeats the cache's own purpose.
- **Availability coupling.** Origin-probing reintroduces a hard dependency on origin reachability for
  *cached* content; if the registry is down, even a hot blob can't be authorized. Local JWT
  verification breaks that coupling for token registries — another reason to layer it on.
- **Digest-dedup vs per-repo authz.** Blobs are deduplicated by `sha256` across repos
  ([§06.1](06-content-sources.md)) but authorization is **per-repo**. The gate must bind to the
  authorized *manifest's* repo, never to a bare blob digest — otherwise a tenant authorized for repo
  A could pull a private blob that only physically exists because repo B (another tenant) cached it.

## Worked example: accelerator fetch surfaces

Interception only earns its keep on origins a container *actually* hits. A concrete, high-value set
is the GPU accelerators with compiled kernels — `triton-lang/triton`, `dao-ailab/flash-attention`,
`thu-ml/sageattention`, `huggingface/accelerate` — which are heavy, repeatedly fetched across the
fleet, and arrive over **three different surfaces**, each wanting a different mechanism:

| Surface | Examples | Mechanism | MITM needed? |
|---|---|---|---|
| **PyPI wheel** | triton, accelerate (flash-attn/sageattention where a matching wheel exists) | point pip at a PyPI mirror via injected `PIP_INDEX_URL` / `pip.conf` | **No** — config-redirect to a protocol-native mirror |
| **GitHub release asset** | flash-attention prebuilt `.whl` (cu/torch/cpXX-matrixed, ~100–300 MB) at `github.com/.../releases/download/…` → `*.githubusercontent.com` CDN | intercept and cache as an immutable, stable-URL blob | **Yes**, but easy — large immutable objects, long TTL |
| **git clone / source build** | sageattention, any source build, off `github.com` smart-HTTP | a git-aware caching proxy (dynamic pack negotiation doesn't byte-cache) | partial — protocol-specific, the hardest of the three |

Two principles fall out, and they sharpen the rest of this document:

- **Prefer config-redirect over MITM wherever a native mirror + a config knob exists.** pip
  (`PIP_INDEX_URL`), apt (`Acquire::*::Proxy`), and dnf (`proxy=` / repo `baseurl`) can all be
  pointed at a protocol-native cache with **no TLS interception at all** — and the runc shim already
  injects env vars ([§05.4](05-trust-and-mitm.md)), so `PIP_INDEX_URL` is nearly free. This is the
  same philosophy §05 already uses for OCI (the `hosts.toml` registry mirror) and plain-HTTP apt;
  MITM is the **exception** for origins with no mirror/knob, not the rule. (Config-redirect is still
  *injection* — the shim bind-mounts the config or sets the env — and, like the CA env-vars, it is
  best-effort: a Dockerfile that explicitly pins its own index/sources overrides it, which R1 says it
  generally should.)
- **MITM is really only forced for the GitHub release-asset wheels (and, awkwardly, git clones).**
  Those `*.githubusercontent.com` hosts are exactly the CDN-fronted origins the `@cdn_origins` IP set
  + SNI allowlist above is for, and GitHub's published ranges (`api.github.com/meta`) feed the
  updater daemon directly. The release-asset case is the *happy* path: immutable blobs at stable URLs
  cache trivially once intercepted. The git-clone case is the genuinely hard one and would want a
  git-aware proxy rather than a byte cache.

## Honest limits

- **Cert/SPKI pinning.** Any client that pins a certificate or public key (many Go SDKs, mobile-ish
  clients, some package managers) rejects a forged leaf no matter how the CA is delivered. These
  must be detected and passed through, never MITM'd.
- **HSTS-preload / ECH.** Preload lists and ECH reduce what is interceptable; ECH in particular
  blinds the SNI router.
- **IPv6 parity.** The bridge is dual-stack (`fd44:44:44::/64`); DNAT, minting, and passthrough all
  need a v6 path or v6 egress silently escapes.
- **Double-NAT / conntrack.** A new `dstnat` rule shares conntrack with the existing `cache-nat`
  masquerade in [`network-setup.nix`](../nix/network-setup.nix); ordering and hairpin cases need
  care so a redirected flow isn't re-masqueraded into a black hole.
- **Per-SNI minting cost.** Generating+signing a leaf on first contact adds handshake latency and a
  signing load; leaves must be cached.
- **The R1 "unmodified Dockerfile" constraint** ([memory / §05 intro](05-trust-and-mitm.md)).
  Bridge DNAT is fully transparent — the user's Dockerfile and `docker run` are untouched, so it is
  **R1-safe**. An injected layer is more delicate: the *Dockerfile* is still unmodified, but the
  *image the container runs* is not byte-for-byte what was pulled — defensible as "transparent," but
  worth being explicit about.

## What this would touch if it were ever built

Pointers only — **none of this exists**:

- a `dstnat` block in [`network-setup.nix`](../nix/network-setup.nix) (today: masquerade only),
  gated on a named `@cdn_origins` interval set;
- a standalone **IP-range updater daemon** feeding that set from published range feeds — itself a
  separate, failure-mode-heavy design (rate-cap, on-disk last-known-good fallback, validate/apply
  atomically), flagged above as a required follow-up;
- per-SNI dynamic-cert logic in [`nginx-client.nix`](../nix/modules/nginx-client.nix) (or a new
  module), plus an `ssl_preread` passthrough path;
- a layer-injection alternative to [`ca-injector.nix`](../nix/modules/ca-injector.nix);
- an `access_by_lua` delegated-auth gate on the serving path in
  [`nginx-cache.nix`](../nix/modules/nginx-cache.nix) (today: no authorization on cache reads),
  with a `(client-identity, repo)` authz cache and an optional `lua-resty-jwt` fast path for token
  registries.

## Relationship to §05

This is a **generalisation** of [§05](05-trust-and-mitm.md), not a correction of it: it trades the
curated-FQDN allowlist for hostname-agnostic interception at the cost of dynamic certs, packet-layer
redirection, and a longer list of things that can break (pinning, ECH, double-NAT). §05 remains the
**shipped, tested** design; this document is a sketch to be evaluated, not a commitment.
