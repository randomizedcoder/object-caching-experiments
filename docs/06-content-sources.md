# 06 — Content sources

Three classes of artifact are cached, each keyed to match how its origin addresses content. All
sources are defined in [`nix/constants/`](../nix/constants/) so adding one is a data change.

## 6.1 OCI registries

Five Tier-1 registries, from [`nix/constants/network.nix`](../nix/constants/network.nix):

| `ns=` | Upstream | Zot oracle |
|-------|----------|-----------|
| docker.io | https://registry-1.docker.io | :5050 |
| gcr.io | https://gcr.io | :5051 |
| ghcr.io | https://ghcr.io | :5052 |
| quay.io | https://quay.io | :5053 |
| registry.k8s.io | https://registry.k8s.io | :5054 |

Keying (both tiers): **blobs** on the `sha256:` digest alone (immutable, dedup across repos),
**manifests** on `ns:uri` (mutable by-tag, short TTL). The `ns=` param is how containerd signals
the original registry through a mirror; the cache maps it to the real upstream host (note
docker.io is *not* identity). CDN 30x responses are followed by the cache and stored under the
digest key. Full flow in [03](03-client.md) (client) and [04](04-cache-vms.md) (shared).

## 6.2 apt mirrors

Three Ubuntu mirrors, from [`nix/constants/app.nix`](../nix/constants/app.nix):
`archive.ubuntu.com`, `security.ubuntu.com`, `ports.ubuntu.com`. Cached over plain HTTP — `.deb`s
and indices are GPG-signed, so there is nothing to gain from intercepting TLS. Indices get a short
5m TTL, `.deb`s (content-addressed by version) get 30d. Keyed on `host + request_uri`.

## 6.3 Model stores

Four LLM model stores, each on a dedicated cache-VM vhost
([`nix/constants/app.nix`](../nix/constants/app.nix)). Two `kind`s:

| Store | `kind` | Vhost | FQDNs intercepted |
|-------|--------|-------|-------------------|
| Hugging Face | http | :8100 | huggingface.co, cdn-lfs.huggingface.co, cdn-lfs-us-1.huggingface.co |
| ModelScope | http | :8101 | modelscope.cn, www.modelscope.cn, modelscope.oss-cn-beijing.aliyuncs.com |
| PyTorch Hub | http | :8102 | download.pytorch.org, github.com, objects.githubusercontent.com |
| Ollama | oci | :8103 | registry.ollama.ai |

- **`kind = http`** — the cache proxies to the origin named in `X-Orig-Host`, then follows the
  metadata 30x to the content CDN (HF LFS, Aliyun OSS) **itself** via `@follow_lfs`, caching the
  content-addressed payload under the original path with signed query args dropped — so the same
  file collapses to one entry no matter how many signed URLs are handed out. Relative redirects
  (e.g. HF canonicalising a model id) are re-resolved against the original origin; absolute CDN
  redirects pass through. TTL 60d.
- **`kind = oci`** — Ollama speaks the OCI distribution protocol, so it reuses the same
  digest-keyed blob / short-TTL manifest split as the registries.

Every model FQDN is reached through the MITM `:443` path: `/etc/hosts` pins it to the client, the
client terminates TLS with a forged leaf, and the cache VM does the origin/CDN work. See
[05](05-trust-and-mitm.md).

## 6.4 The "extra" vhost

Arbitrary MITM'd HTTPS third-party repos (`mitmExtraHosts`, currently `download.docker.com`) share
a single generic vhost on `:8104` (`cache_extra` zone). It uses the same origin-agnostic
`X-Orig-Host` template as the `http` model stores, so adding a host is a one-line constant change —
no new vhost.
