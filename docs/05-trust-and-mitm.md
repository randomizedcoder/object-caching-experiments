# 05 — Trust & MITM

The hard requirement (R1) is that an external user's Dockerfile and `docker pull`/`curl` work
**unmodified** — no `-k`, no baked-in CA, no edits. For plain-HTTP apt and the `?ns=`-routed OCI
path that is easy. But model stores (Hugging Face, etc.) are HTTPS-only, and to cache an HTTPS
response the cache must terminate the TLS. That means intercepting HTTPS with certificates the
client already trusts — i.e. a MITM, run deliberately on a trusted lab subnet.

This part describes the **two distinct CAs** the lab uses (they are easy to conflate, and must
not be), the per-FQDN leaf certs, host redirection, and the runc shim that injects trust into
*containers* so their pulls work unmodified too.

## 5.1 Two CAs, two jobs

| | **Cache CA** | **Per-client MITM CA** |
|---|---|---|
| Purpose | Authenticate the **client → cache** TLS hop | Forge origin certs so the client can **terminate** model-store HTTPS |
| Signs | one shared cache-server cert (SAN `caches.cache.lab` + both cache IPs) | per-FQDN leaf certs for every MITM'd host |
| Trusted by | every client (`proxy_ssl_verify on` against `/etc/nginx/cache-ca.crt`) | the client's own nginx + anything it injects trust into |
| Scope | one CA for the whole lab | **one CA per client** — never shared |
| Distribution | public cert SSH-copied to every client; private key + server key never leave the cache VMs | minted locally per client; private key never leaves that client |

The cache CA only proves "you are really talking to our cache layer." It **never forges origins**.
The MITM CA only forges origins for interception; it is per-client so no client can impersonate
another. Keep them separate. Both are defined in
[`nix/constants/security.nix`](../nix/constants/security.nix).

## 5.2 What gets intercepted, and the cert groups

Everything MITM'd is the model-store FQDNs plus a short list of HTTPS third-party repos
(`mitmExtraHosts`, currently `download.docker.com`). The leaf certs are organised into **cert
groups** (`mitmCertGroups`): each model store groups all its FQDNs under one cert (one SNI
`server{}` listing them together); each extra host is its own one-FQDN cert. The group list is
derived from `modelStores` + `mitmExtraHosts`, so adding a store or host automatically mints the
right leaves. `cache-gen-secrets` writes them to `secrets/<client>/mitm/<name>.{crt,key}`.

## 5.3 Redirection and termination on the client

There is no DNS server in the lab, so every MITM'd FQDN is pinned to the client via `/etc/hosts`
([`mitm.nix`](../nix/modules/mitm.nix), `networking.extraHosts` → `127.0.0.1 <fqdn>`). A `curl`
on the host therefore resolves `huggingface.co` to loopback and lands on the client nginx `:443`
frontend. That frontend has one `server{}` per cert group: SNI selects the per-FQDN leaf, nginx
terminates the TLS, and forwards the decrypted request to the cache layer with the original origin
in `X-Orig-Host` (and the consistent-hash key set for peer selection). The cache→origin hop then
uses the normal **public** CA.

## 5.4 Making *container* pulls work unmodified — the runc CA-injector

`/etc/hosts` poisoning on the host does not reach inside a container, and a container's trust store
won't contain the MITM CA — so a `FROM huggingface.co/...` or an in-build
`curl https://huggingface.co/...` would fail cert validation. The fix is a custom OCI runtime shim
([`ca-injector.nix`](../nix/modules/ca-injector.nix)): dockerd's `default-runtime` is set to
`runc-with-ca`, whose wrapper, on the `create` call, `jq`-injects read-only bind mounts into the
bundle's `config.json` and then exec's the real `runc`. Into every container it slips:

1. **CA trust**, delivered two ways at once because images keep their trust store in different
   places: the **primary** mechanism is environment variables every common TLS library honours
   (`SSL_CERT_FILE` / `CURL_CA_BUNDLE` / `REQUESTS_CA_BUNDLE` / `GIT_SSL_CAINFO` /
   `NODE_EXTRA_CA_CERTS`) all pointed at one fixed in-container path; plus belt-and-suspenders
   bind mounts over the well-known distro CA paths for tools that ignore the env vars. The bundle
   is the system public CAs **plus** this client's MITM CA, so it can fully replace the default
   store without losing normal public-CA trust.
2. **Host redirection** — an `/etc/hosts` that pins each MITM'd FQDN to the **client's LAN IP**
   (not `127.0.0.1`, which inside a container is the container's own loopback), so the container
   reaches the client nginx `:443` over the bridge.

Two design choices make this safe:

- **Bind mounts, not a create-time hook.** With the containerd-snapshotter image store the
  container rootfs isn't visible at create-hook time, so a hook physically cannot touch the
  container's files. `config.json` `.mounts` are honoured regardless of snapshotter, and runc
  creates the mountpoint if absent (over-mounting a path the image lacks is harmless).
- **Fail-open.** The wrapper only edits `config.json` best-effort and falls back to the untouched
  file; it never runs a hook that could exit non-zero and abort the user's container.

The same shim is shared with the Ubuntu clients — it references only fixed `/etc` paths, so it is
node-agnostic.
