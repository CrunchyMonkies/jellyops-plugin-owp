# jellyops-plugin-owp

[OpenWatchParty](https://github.com/mhbxyz/OpenWatchParty) — synchronized watch parties for
Jellyfin — ported to **Jellyfin v12 (.NET 10)** and packaged as a JellyOps `JellyfinPlugin`
image-volume with a companion WebSocket session server.

Upstream targets net9 / Jellyfin 10.11. This repo is the v12 port for the CrunchyMonkies
JellyOps cluster, built against the Jellyfin fork at tag **`v12.0.0-rc2-jc-0.2.0`** (ABI
`12.0.0.0`). Upstream is MIT; this port keeps that license (`LICENSE`).

## How it works

1. **Plugin** (`src/Plugin`, C#) exposes `/OpenWatchParty/{ClientScript,Info,Token}`:
   - `ClientScript` serves the concatenated web client bundle (`Web/plugin.js`).
   - `Token` mints a short-lived HMAC-SHA256 **JWT** (IdentityModel 8.x) the session server validates.
2. On startup a scheduled task (`FileTransformationIntegration`) reflection-registers an
   `index.html` transform with the **File Transformation** plugin
   ([jellyops-plugin-file-transformation](../jellyops-plugin-file-transformation)), which injects
   `<script src="/OpenWatchParty/ClientScript" defer>` into the served web client.
   > This requires a **non-split (web-serving) Jellyfin instance** — FT patches the server's own
   > web pipeline. Both plugins bind the host's `Newtonsoft.Json` (neither ships its own) so the
   > `JObject` passed across the reflection boundary has matching assembly identity.
3. The client dials the **session server** (upstream Rust `owp-session-server`, run as a companion
   workload) over `wss://…/owp/ws` to sync play/pause/seek across viewers.

## Client bundle

Upstream ships 26 IIFE modules loaded one-by-one by a dev loader. Because each module is a
self-contained `(() => { … window.OpenWatchParty … })()` with no ES imports, we concatenate them
(in the upstream `client_js_files` order) into a single `src/Plugin/Web/plugin.js` served by the
controller. Regenerate after editing any module under `src/Plugin/Web/client/`:

```sh
scripts/bundle-client.sh   # -> src/Plugin/Web/plugin.js (committed, embedded)
```

CI fails if the committed bundle is stale.

## Build & package

```sh
# Requires a sibling jellyfin-src checkout at tag v12.0.0-rc2-jc-0.2.0.
docker/build-push.sh [TAG]          # bundle -> publish -> strip -> FROM-scratch image -> GHCR
PUSH=false docker/build-push.sh     # build locally only
```

CI (`.github/workflows/plugin-image.yml`) does the same on `v*` tags; it needs the repo secret
**`JELLYFIN_SRC_TOKEN`** (PAT with `contents:read` on the private `CrunchyMonkies/jellyfin`).

## Deploy

Apply in order (FT must be present first):

```sh
kubectl -n jellyfin create secret generic owp-creds \
  --from-literal=jwt-secret="$(openssl rand -base64 48)"   # shared plugin/session-server key
# pin spec.pluginImage.reference to the digest build-push.sh printed
kubectl apply -f k8s/30-jellyfinplugin.yaml    # plugin + companion session server + Service
kubectl apply -f k8s/40-httproute-ws.yaml      # /owp -> owp-session-server:3000 (WebSocket)
```

| File | Purpose |
|------|---------|
| `k8s/30-jellyfinplugin.yaml` | `JellyfinPlugin` CR: plugin image-volume + `owp-session-server` workload/Service + firstrun config seed |
| `k8s/35-owp-credentials.yaml` | Template for the shared `owp-creds` JWT Secret (do not commit a real value) |
| `k8s/40-httproute-ws.yaml` | Gateway API `HTTPRoute` carve-out routing `/owp/*` to the session server |

## Verify

- Both `owp` and `file-transformation` plugins `Loaded`; `GET /OpenWatchParty/Info` → 200.
- Served `index.html` contains `<script src="/OpenWatchParty/ClientScript" defer>`.
- The OWP UI appears in `/web`; two clients sync play/pause/seek over `wss://…/owp/ws`.
- `GET https://jellyfin.bne1.ouchi.com.au/owp/health` → `ok`.
