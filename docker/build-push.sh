#!/usr/bin/env bash
#
# Build and push the OpenWatchParty plugin image-volume payload for JellyOps.
#
# Regenerates the client bundle (scripts/bundle-client.sh -> src/Plugin/Web/plugin.js),
# compiles src/Plugin against a sibling jellyfin-src checkout pinned to the Jellyfin
# v12 rc2 tag the deployed server runs (v12.0.0-rc2-jc-0.2.0), strips host assemblies
# (the .csproj StripHostAssemblies* targets), bakes firstrun.sh, and packages a
# FROM-scratch image. Newtonsoft.Json is intentionally NOT shipped (host-bound).
#
# Usage: docker/build-push.sh [TAG]
# Env:  REGISTRY (default ghcr.io/crunchymonkies/jellyops-plugin-owp)
#       IMAGE    (default <REGISTRY>/plugin)
#       JELLYFIN_SRC (default <repo>/../jellyfin-src)
#       PUSH     (default true)
set -euo pipefail

REGISTRY="${REGISTRY:-ghcr.io/crunchymonkies/jellyops-plugin-owp}"
IMAGE="${IMAGE:-${REGISTRY}/plugin}"
PUSH="${PUSH:-true}"
TAG="${1:-$(date +%Y%m).$(date +%d).1}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JELLYFIN_SRC="${JELLYFIN_SRC:-$(cd "$ROOT/.." && pwd)/jellyfin-src}"
PROJECT="$ROOT/src/Plugin/OpenWatchParty.Plugin.csproj"

[ -d "$JELLYFIN_SRC" ] || { echo "!! jellyfin-src not found at $JELLYFIN_SRC" >&2; exit 1; }
# Pin: build only against the rc2 tag the deployed server runs.
want="v12.0.0-rc2-jc-0.2.0"
got="$(git -C "$JELLYFIN_SRC" describe --tags --exact-match 2>/dev/null || echo none)"
[ "$got" = "$want" ] || { echo "!! jellyfin-src is at '$got', expected '$want' (rc2)" >&2; exit 1; }

echo ">> Regenerating client bundle"
"$ROOT/scripts/bundle-client.sh"

CTX="$(mktemp -d)"; trap 'rm -rf "$CTX"' EXIT
mkdir -p "$CTX/plugin"

echo ">> Publishing plugin (Release, net10.0) against $JELLYFIN_SRC"
dotnet publish "$PROJECT" -c Release -o "$CTX/publish" -v minimal
cp "$CTX/publish/"*.dll "$CTX/plugin/"
cp "$CTX/publish/meta.json" "$CTX/plugin/meta.json"
cp "$ROOT/scripts/firstrun.sh" "$CTX/plugin/firstrun.sh"
chmod +x "$CTX/plugin/firstrun.sh"

# Sanity: our DLL + meta + hook must be present.
test -f "$CTX/plugin/OpenWatchParty.Plugin.dll" || { echo "!! plugin DLL missing" >&2; exit 1; }
test -f "$CTX/plugin/meta.json"                 || { echo "!! meta.json missing"  >&2; exit 1; }
test -f "$CTX/plugin/firstrun.sh"               || { echo "!! firstrun.sh missing" >&2; exit 1; }

# Host assemblies must NOT ship (type-identity conflicts in the plugin ALC). Newtonsoft
# must NOT ship either — the plugin binds the host copy for cross-plugin JObject identity.
LEAKED="$(find "$CTX/plugin" -maxdepth 1 -type f \( -name 'Emby.*' -o -name 'MediaBrowser.*' \
  -o -name 'Newtonsoft.*' -o \( -name 'Jellyfin.*' -a ! -name 'OpenWatchParty*' \) \))"
[ -z "$LEAKED" ] || { echo "!! forbidden assemblies leaked:" >&2; echo "$LEAKED" >&2; exit 1; }
echo ">> Payload:"; ( cd "$CTX/plugin" && ls -1 )

cp "$ROOT/docker/Dockerfile.plugin" "$CTX/Dockerfile.plugin"
echo ">> Building ${IMAGE} (tags: ${TAG}, latest)"
docker build --provenance=false -f "$CTX/Dockerfile.plugin" -t "${IMAGE}:${TAG}" -t "${IMAGE}:latest" "$CTX"

if [ "$PUSH" = "true" ]; then
  docker push "${IMAGE}:${TAG}"; docker push "${IMAGE}:latest"
  DIGEST="$(docker inspect --format='{{range .RepoDigests}}{{println .}}{{end}}' "${IMAGE}:${TAG}" | grep "^${IMAGE}@" | head -1)"
  echo ">> Pushed. Pin in k8s (spec.pluginImage.reference): ${DIGEST}"
else
  echo ">> PUSH=false — built only."
fi
