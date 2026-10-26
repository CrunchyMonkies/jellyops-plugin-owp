# jellyops-plugin-owp

[OpenWatchParty](https://github.com/mhbxyz/OpenWatchParty) — synchronized watch parties for
Jellyfin — packaged as a JellyOps `JellyfinPlugin` image-volume with a companion WebSocket
session server.

This repo used to carry a source port of OpenWatchParty to Jellyfin v12. Upstream now ships
Jellyfin v12 builds itself (net10.0, `Jellyfin.Controller` 12.0.0, targetAbi `12.0.0.0`), so this
repo **repackages the unmodified upstream release** instead:

| Component | Source | Pin |
|-----------|--------|-----|
| Plugin payload | `mhbxyz/OpenWatchParty` release `v0.8.0`, asset `OpenWatchParty-v0.8.0.zip` | sha256 `f86145bf…0cdd` (`docker/build-push.sh`, workflow) |
| Session server | `ghcr.io/mhbxyz/owp-session-server:0.8.0` | `@sha256:e0634bf2…9f68` (`k8s/30-jellyfinplugin.yaml`) |

Plugin and session server share WebSocket protocol **v1**. Upstream claims Jellyfin 12.0/12.1;
the deployed server is **v12.3** (`ghcr.io/crunchymonkies/jellyfin:v12.3-jc-0.2.4`). It loads
because targetAbi 12.0.0.0 <= 12.3. The Jellyfin APIs the plugin references (BasePlugin,
IHasWebPages, IScheduledTask, IPluginServiceRegistrator, NetworkConfiguration, …) did not change
between v12.0 and v12.3. Upstream is MIT (`LICENSE`).

## How it works

1. **Plugin** (`OpenWatchPartyPlugin.dll`) exposes `/OpenWatchParty/{ClientScript,Client/*,Info,Token}`
   and injects the client loader into the server's own `index.html` response. The injection is
   native middleware, so the File Transformation plugin is **not** required. This needs a
   **non-split (web-serving) Jellyfin instance**.
2. `Token` mints a short-lived HMAC-SHA256 JWT that the session server validates. Both sides
   share the `owp-creds` secret, which must be **Base64 of >= 32 random bytes**.
3. The client dials the **session server** over `wss://…/owp/ws`. Invite links go over
   `https://…/owp/invite`.

## Hooks (baked into the image root, auto-run by the operator)

- `scripts/firstrun.sh` (once per instance) seeds `/config/plugins/configurations/OpenWatchPartyPlugin.xml`
  from the CR env/Secret: JWT secret, `wss://` URL, audience/issuer, TTLs.
- `scripts/bootstrap.sh` (every start) deletes other `OpenWatchParty_*` dirs carrying our GUID.
  Jellyfin keeps the highest plugin version, so the old `OpenWatchParty_1.0.1.0` source-port
  build would otherwise outrank the upstream `0.8.0.0`.

## Build & package

```sh
PUSH=false BUILDER=podman docker/build-push.sh   # download+verify zip -> FROM-scratch image, local only
docker/build-push.sh [TAG]                       # ... and push to GHCR
```

CI (`.github/workflows/plugin-image.yml`) does the same on `v*` tags or `workflow_dispatch`. It
only needs `GITHUB_TOKEN`. To move to a new upstream release, bump `OWP_TAG` + `OWP_SHA256` (script
and workflow), the Dockerfile labels, `meta.version`, and the session-server digest together.

## Deploy

```sh
kubectl -n jellyfin create secret generic owp-creds \
  --from-literal=jwt-secret="$(openssl rand -base64 48)"   # shared plugin/session-server key
# pin spec.pluginImage.reference to the digest CI / build-push.sh printed
kubectl apply -f k8s/30-jellyfinplugin.yaml    # plugin + companion session server + Service
kubectl apply -f k8s/40-httproute-ws.yaml      # /owp -> owp-session-server:3000 (ws + invite)
```

| File | Purpose |
|------|---------|
| `k8s/30-jellyfinplugin.yaml` | `JellyfinPlugin` CR: plugin image-volume + `owp-session-server` workload/Service + hook env |
| `k8s/35-owp-credentials.yaml` | Template for the shared `owp-creds` JWT Secret (do not commit a real value) |
| `k8s/40-httproute-ws.yaml` | Gateway API `HTTPRoute` carve-out routing `/owp/*` to the session server |

## Verify

- Plugin `OpenWatchParty` 0.8.0.0 is `Active`, and `GET /OpenWatchParty/Info` returns 200.
- Served `index.html` contains the OpenWatchParty client loader, and the OWP UI appears in `/web`.
- Two clients sync play/pause/seek over `wss://…/owp/ws`, and invite links work.
- `GET https://jellyfin.bne1.ouchi.com.au/owp/health` returns `ok`.
