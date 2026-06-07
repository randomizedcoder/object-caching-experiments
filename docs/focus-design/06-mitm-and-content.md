[← Contents](README.md)

**HTTPS interception, model stores, Ubuntu clients, apt.** Part of the [focused design](README.md).

---

## 14. HTTPS interception (internal CA / MITM)

The container and apt paths above are plain HTTP on the lab subnet. The **model stores and HTTPS third-party repos are HTTPS**, and we want to cache their (often multi-GB) payloads — so we deliberately break E2E TLS on this trusted subnet, where **we own every host and every CA**. This is the focused-design re-scope-in of `design.md` §12–13.

### 14.1 Why MITM is required here

Unlike `docker pull`, the model-store clients do **not** speak the containerd `hosts.toml` protocol and offer no usable mirror knob:

| client            | how it fetches                                   | why hosts.toml / proxy alone won't cache it          |
|-------------------|--------------------------------------------------|------------------------------------------------------|
| `huggingface-cli` / `hf_hub_download` | HTTPS to `huggingface.co`, LFS 302→`cdn-lfs*.huggingface.co` | no mirror setting that rewrites the LFS CDN host     |
| `ollama pull`     | HTTPS OCI-style to `registry.ollama.ai`          | not containerd; ignores `certs.d/hosts.toml`         |
| `modelscope` SDK  | HTTPS to `modelscope.cn` + OSS file CDN          | no mirror knob                                       |
| `torch.hub` / pip | HTTPS to `download.pytorch.org` + GitHub assets  | no mirror knob                                       |

To read the request URL (so we can consistent-hash and cache by path/digest) we must terminate TLS ourselves. The only way to do that without errors is to **own a CA the client trusts** and present a cert for the requested FQDN.

### 14.2 The internal CA and per-FQDN certs

**Each client gets its own CA.** Rather than one lab-wide root, every client mints and trusts its *own* internal CA — full per-client isolation. `nix run .#cache-gen-ca` (offline, output to `secrets/`) iterates over the client registry (`client0` + `ubuntuClients`, [§10](03-architecture.md#10-constants-module-nixconstantsnix)) and for **each client**:

1. Generate a long-lived per-client root CA (`secrets/<client>/ca/<client>-CA.crt` + key).
2. Mint one leaf cert per FQDN in `union(modelStores.*.fqdns, mitmExtraHosts)` ([§10](03-architecture.md#10-constants-module-nixconstantsnix)), each signed by **that client's** CA, SAN = the FQDN.
3. Write each leaf cert+key where that client's nginx loads it for SNI-based selection (`ssl_certificate` per `server_name`, generated into `secrets/<client>/mitm/`).

So the layout is `secrets/<client>/{ca,mitm}/` per box, and a given client trusts **only its own root** ([§14.4](#144-trust-insertion-on-hosts-and-inside-containers)). This is deliberately narrower than a shared CA: compromising one client's CA cannot forge a certificate that any *other* client trusts, and each client is independently provisionable. Certs live only in `secrets/` and only cover the lab FQDNs — a narrow blast radius, as preferred for trusted-network MITM.

> **Not to be confused with the cache CA.** This per-client MITM CA exists so the client nginx can *impersonate HTTPS origins* on its `:443` listeners. The **cache CA** ([§11.5](04-client.md#115-encrypted-client-to-cache-hop-tls)) is a separate, lab-wide trust system that only *authenticates the cache layer* on the client→cache hop. They sign different things, live in different `secrets/` subtrees (`secrets/<client>/` vs `secrets/cache/`), and are trusted by different parties.

### 14.3 DNS redirection + TLS termination at the client nginx

We use the simple `/etc/hosts` poisoning route (no DNS server in v1):

```
# /etc/hosts on every client (and injected into containers, §14.4)
127.0.0.1  huggingface.co cdn-lfs.huggingface.co cdn-lfs-us-1.huggingface.co
127.0.0.1  registry.ollama.ai
127.0.0.1  modelscope.cn www.modelscope.cn modelscope.oss-cn-beijing.aliyuncs.com
127.0.0.1  download.pytorch.org github.com objects.githubusercontent.com
127.0.0.1  download.docker.com
```

The **client nginx** binds `:443`, terminates TLS (SNI-selected per-FQDN cert), checks its local hot tier, and on a miss forwards the decrypted request to the right cache-VM nginx vhost with the **same consistent-hash** used everywhere else. One daemon does it all — no `crt-list`, no `hitch` sidecar:

```nginx
# client nginx :443 — one server{} per model-store FQDN group, generated
# from constants.modelStores. HTTP/3 + HTTP/2 here (a listener we own).
server {
    listen 443 quic reuseport;             # HTTP/3
    listen 443 ssl;                         # HTTP/2 fallback
    http2 on;
    server_name huggingface.co cdn-lfs.huggingface.co cdn-lfs-us-1.huggingface.co;
    ssl_certificate     /etc/nginx/mitm/huggingface.crt;   # this client's own leaf,
    ssl_certificate_key /etc/nginx/mitm/huggingface.key;   # signed by this client's CA (§14.2)
    add_header Alt-Svc 'h3=":443"; ma=86400';

    proxy_cache oci_hot;                    # same small local hot tier
    location / {
        set $cache_key "hf:$uri";
        proxy_set_header Host $host;
        proxy_pass https://shared_caches_hf;  # → cache VM :8100, hash on path; TLS (§11.5)
    }
}
# … ollama (:8103), modelscope (:8101), pytorch (:8102), download.docker.com (:8104)
```

The client→cache hop is TLS under the **cache CA** ([§11.5](04-client.md#115-encrypted-client-to-cache-hop-tls)) — a different trust anchor from the per-client MITM CA that just terminated the client's `:443`. The cache key is the original host + path (signed CDN query args excluded, [§13.2](05-cache-vms.md#132-nginx-wildcard-oci-catch-all) rules), so the same model file collapses to one cache entry. Because this `:443` listener is **ours on both ends of the TLS**, it offers **HTTP/3 + HTTP/2** to the model CLIs (QUIC tuning in [§18.3](07-tuning-observability.md#183-quic--http3-tuning)); the nginx→cache-VM hop remains HTTP/1.1 ([§11.4](04-client.md#114-transport--http-versions)).

### 14.4 Trust insertion on hosts and inside containers

Each client trusts **only its own** per-client CA ([§14.2](#142-the-internal-ca-and-per-fqdn-certs)):

- **NixOS `client0`**: `security.pki.certificateFiles = [ caCrt ]` where `caCrt` is *this host's* CA (`secrets/client0/ca/client0-CA.crt`), plus the `/etc/hosts` block via `networking.extraHosts`.
- **Ubuntu clients**: Ansible `mitm-trust` role drops **that host's** CA (`secrets/<client>/ca/<client>-CA.crt`) into `/usr/local/share/ca-certificates/` + `update-ca-certificates`, and appends the `/etc/hosts` block.
- **Inside containers** (a `docker run python … huggingface-cli download` must also trust us): the `ca-injector.nix` **runc prestart hook** bind-mounts **the local host's** CA into each container's trust path and adds the `/etc/hosts` entries — so a container validates the same host it runs on. No Dockerfile change, preserving the unmodified-Dockerfile constraint. (Full design: `design.md` §13.5.)

> **Trust-boundary scope.** This is safe *only* because the lab is a private bridge we fully control. The CA must never leave `secrets/` and this design must never be lifted onto a multi-tenant or untrusted network.

---

## 15. LLM model store caching

We cache four popular model sources so the lab can prove out "second download of the same weights never leaves the subnet" for the LLM workflow, not just containers.

### 15.1 The four sources and their shapes

| store         | protocol             | interception | cache-VM vhost | notes                                            |
|---------------|----------------------|--------------|----------------|--------------------------------------------------|
| Hugging Face  | HTTPS + LFS 302→CDN  | MITM ([§14](#14-https-interception-internal-ca--mitm))   | nginx `:8100`  | biggest; LFS blobs are content-addressed (sha256)|
| Ollama        | HTTPS OCI-style      | MITM ([§14](#14-https-interception-internal-ca--mitm))   | nginx `:8103`  | manifests + digest-keyed blob layers             |
| ModelScope    | HTTPS + OSS file CDN | MITM ([§14](#14-https-interception-internal-ca--mitm))   | nginx `:8101`  | HF-like; mirrors many HF models for APAC         |
| PyTorch Hub   | HTTPS + GitHub assets| MITM ([§14](#14-https-interception-internal-ca--mitm))   | nginx `:8102`  | `download.pytorch.org` + release tarballs        |

All four reach the cache VMs as plain HTTP (decrypted at the client nginx), are consistent-hashed by the client nginx, and are cached by nginx with a host+path key that strips signed CDN query args. The client-facing `:443` listeners offer HTTP/3+H2 ([§14.3](#143-dns-redirection--tls-termination-at-the-client-nginx)) since both ends of that TLS are ours.

### 15.2 Hugging Face

`huggingface.co` serves metadata/manifests directly and redirects actual weight files (LFS) with a `302` to `cdn-lfs*.huggingface.co`. nginx vhost on `:8100` follows the redirect itself and keys the blob by its content-addressed LFS path (mirrors the Option-1 `@follow_cdn` pattern from [§13.2](05-cache-vms.md#132-nginx-wildcard-oci-catch-all)):

```nginx
proxy_cache_path /var/lib/cache/nginx/hf levels=1:2 keys_zone=cache_hf:50m
                 max_size=200g inactive=60d use_temp_path=off;
server {
    listen 8100 ssl;                                       # TLS to clients (§11.5; shared cache cert)
    ssl_certificate     /etc/nginx/cache/cache-server.crt;
    ssl_certificate_key /etc/nginx/cache/cache-server.key;
    resolver 1.1.1.1 ipv6=off valid=300s;
    location = /health { return 200 "ok\n"; }
    location / {
        set $orig $http_x_orig_host;             # set by the client nginx (SNI)
        proxy_pass https://$orig;                # cache→origin hop: PUBLIC CA (unchanged)
        proxy_ssl_server_name on;
        proxy_cache cache_hf;
        proxy_cache_key "$orig:$uri";            # $args excluded
        proxy_cache_valid 200 206 60d;
        proxy_intercept_errors on; recursive_error_pages on;
        error_page 301 302 307 308 = @follow_lfs;
        add_header X-Cache-Status $upstream_cache_status;
        add_header X-Cache-Upstream-Time $upstream_response_time;   # origin fetch on a MISS
    }
    location @follow_lfs {
        set $cdn $upstream_http_location;
        proxy_pass $cdn;
        proxy_cache cache_hf;
        proxy_cache_key "hf-lfs:$uri";           # original LFS path, signed args dropped
        proxy_cache_valid 200 206 60d;
        proxy_cache_lock on;
    }
}
```

`proxy_cache_valid 206` matters: model downloaders use HTTP range requests for resumable multi-GB pulls.

### 15.3 Ollama

`ollama pull llama3` fetches an OCI-style manifest then digest-addressed blob layers from `registry.ollama.ai`. After MITM termination at the client nginx, the cache-VM nginx vhost on `:8103` treats it like the OCI wildcard ([§13.2](05-cache-vms.md#132-nginx-wildcard-oci-catch-all)) — key blobs on the `sha256:<digest>` in the path, long TTL:

```nginx
location ~ "/v2/.+/blobs/sha256:" {
    proxy_pass https://registry.ollama.ai;
    proxy_ssl_server_name on;
    proxy_cache cache_ollama;
    proxy_cache_key "ollama:blob:$uri";          # digest in $uri → immutable
    proxy_cache_valid 200 206 60d;
}
location / {                                      # manifests/tags — short TTL
    proxy_pass https://registry.ollama.ai;
    proxy_ssl_server_name on;
    proxy_cache cache_ollama;
    proxy_cache_key "ollama:$uri";
    proxy_cache_valid 200 5m;
}
```

> Ollama could *alternatively* be served by a Zot instance (it speaks a close-enough OCI dialect). We keep it on nginx in v1 to avoid betting on Zot's compatibility with Ollama's non-standard registry; promoting it to Zot is a [§23](08-operations.md#23-future-work) follow-up if the nginx path proves the demand.

### 15.4 ModelScope and PyTorch Hub

Both are HF-shaped HTTPS file downloads with their own object CDNs (`modelscope` → Aliyun OSS; `pytorch` → `download.pytorch.org` + GitHub release assets). Each gets a nginx vhost (`:8101`, `:8102`) using the **same** redirect-following + `host:path` key + `206`-cacheable template as [§15.2](#152-hugging-face). The only per-store differences (FQDNs, cache dir, zone) come from `constants.modelStores`, so the three HTTP model vhosts are generated by one `lib.mapAttrs` in `nix/modules/nginx-cache.nix`.

---

## 16. Ubuntu clients

Three real-world rigs to prove the design holds on stock distros, lifted from the `runpod/ansible-host` Vagrant+libvirt pattern:

| client       | Docker install path                    | role                                            |
|--------------|----------------------------------------|-------------------------------------------------|
| `ubuntu2204` | `docker.io` (Ubuntu repo)              | "casual user" path; older Docker                |
| `ubuntu2404` | `docker-ce` (download.docker.com)      | current recommended path                        |
| `ubuntu2604` | `docker-ce`                            | next-LTS coverage                               |

Each Ubuntu VM bridges onto `cachebr0` via libvirt `:public_network, :dev => "cachebr0"` with a static IP/MAC from `constants.nix`, and is configured by Ansible to run the **same** logical stack as `client0`: containerd `hosts.toml`, the client **OpenResty** nginx (local hot tier + hash router + :443 MITM + in-process Lua health-checks, [§11.3](04-client.md#113-health-checking-passive-and-in-process-active)), MITM CA trust + `/etc/hosts` ([§14](#14-https-interception-internal-ca--mitm)), the **cache CA** at `/etc/nginx/cache-ca.crt` for the encrypted client→cache hop ([§11.5](04-client.md#115-encrypted-client-to-cache-hop-tls)), kernel sysctls ([§18.1](07-tuning-observability.md#181-kernel--network-sysctls-all-machines)), node_exporter. OpenResty installs from its own apt repo rather than the distro nginx. Box pins (reused from runpod):

```
2204: bento,       202502.21.0, sha256 1db70l5bcrnrs9sxq2rlldq7kb4lhcxw1qscg6lmlxz6fyv57dl2
2404: bento,       202508.03.0, sha256 1pazin59p565bvx85r4parfwfrgn0iggdfrzfqw98clp6a8ij1nh
2604: cloud-image, 20260421.0.0, sha256 0jzcg72ii492si4rr88ayrjkm0xkvpf9c47anbwfj3qfr0m88fab
```

Ansible roles (under `ansible/roles/`): `docker/install`, `containerd/hosts-toml`, `nginx-client` (OpenResty + Lua healthcheck), `mitm-trust` (per-client MITM CA into the system store **and** the cache CA into `/etc/nginx/cache-ca.crt`, [§11.5](04-client.md#115-encrypted-client-to-cache-hop-tls)), `sysctls`, `node_exporter`. Each role's templates are fed the same `constants.nix` data via a `nix eval --json` export, so there is one source of truth across NixOS and Ubuntu. Both client types must produce semantically equivalent end state — verified by running the same `docker pull` + `apt install` + `huggingface-cli download` workload from each and comparing cache metrics.

---

## 17. apt caching

Ubuntu's default apt repos (`archive.ubuntu.com`, `security.ubuntu.com`, `ports.ubuntu.com`) are **HTTP** — packages are GPG-signed, so HTTP is safe to cache. Each Ubuntu client gets an apt proxy drop-in pointing at its local nginx apt frontend:

```
# /etc/apt/apt.conf.d/01proxy  → client nginx apt frontend :8090
Acquire::http::Proxy "http://127.0.0.1:8090";
```

Flow: `apt update && apt install curl` → local nginx (hot tier) → consistent hash → nginx apt cache on `cache0`/`cache1` → upstream. The apt frontend is just another `server {}` on the same client nginx, so apt and container traffic share the same cache fabric and health-checking.

**HTTPS third-party repos.** Installing `docker-ce` on `ubuntu2404`/`ubuntu2604` pulls from `https://download.docker.com`. That host is in `constants.mitmExtraHosts`, so it is `/etc/hosts`-redirected to the client nginx, TLS-terminated with our minted cert ([§14](#14-https-interception-internal-ca--mitm)), and served by a dedicated nginx vhost on the cache VMs — i.e. it caches just like the model stores. Add an apt-side `Acquire::https::Proxy` only if a repo insists on CONNECT-style proxying; with `/etc/hosts` MITM the default HTTPS fetch already lands on us.

---
