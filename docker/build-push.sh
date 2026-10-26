#!/usr/bin/env bash
#
# Build and push the OpenWatchParty plugin image-volume payload for JellyOps.
#
# The payload is NOT compiled here. It is the upstream mhbxyz/OpenWatchParty release artifact
# (OpenWatchParty-v<version>.zip: net10.0, Jellyfin.Controller 12.0.0, targetAbi 12.0.0.0),
# verified against a pinned SHA-256, unzipped into the build context's `plugin/` dir, and
# packaged into a FROM-scratch image whose root IS the Jellyfin plugin directory. The jellyops
# standard hooks (firstrun.sh, bootstrap.sh) are baked in alongside it.
#
# The image is built with --provenance=false so it is a single plain manifest the kubelet
# mounts cleanly as an image volume.
#
# Usage: docker/build-push.sh [TAG]
# Env:  REGISTRY    (default ghcr.io/crunchymonkies/jellyops-plugin-owp)
#       IMAGE       (default <REGISTRY>/plugin)
#       OWP_REPO    (default mhbxyz/OpenWatchParty)
#       OWP_TAG     (default v0.8.0)
#       OWP_SHA256  (default: the pinned v0.8.0 zip digest; must be changed with OWP_TAG)
#       BUILDER     (default docker; podman works, e.g. BUILDER=podman)
#       PUSH        (default true)
set -euo pipefail

REGISTRY="${REGISTRY:-ghcr.io/crunchymonkies/jellyops-plugin-owp}"
IMAGE="${IMAGE:-${REGISTRY}/plugin}"
OWP_REPO="${OWP_REPO:-mhbxyz/OpenWatchParty}"
OWP_TAG="${OWP_TAG:-v0.8.0}"
OWP_SHA256="${OWP_SHA256:-f86145bf14f7414bda2ab2925565d00198a46d7bf346ccd0186136002dd70cdd}"
OWP_ASSET="OpenWatchParty-${OWP_TAG}.zip"
BUILDER="${BUILDER:-docker}"
PUSH="${PUSH:-true}"
TAG="${1:-$(date +%Y%m).$(date +%d).1}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTX="$(mktemp -d)"; trap 'rm -rf "$CTX"' EXIT
mkdir -p "$CTX/plugin"

echo ">> Downloading ${OWP_REPO} ${OWP_TAG} (${OWP_ASSET})"
gh release download "${OWP_TAG}" --repo "${OWP_REPO}" --pattern "${OWP_ASSET}" --dir "$CTX" --clobber
echo "${OWP_SHA256}  $CTX/${OWP_ASSET}" | sha256sum -c - >/dev/null \
  || { echo "!! ${OWP_ASSET} does not match OWP_SHA256=${OWP_SHA256}" >&2; exit 1; }
unzip -o -q "$CTX/${OWP_ASSET}" -d "$CTX/plugin"

cp "$ROOT/scripts/firstrun.sh"  "$CTX/plugin/firstrun.sh"
cp "$ROOT/scripts/bootstrap.sh" "$CTX/plugin/bootstrap.sh"
chmod +x "$CTX/plugin/firstrun.sh" "$CTX/plugin/bootstrap.sh"

for f in OpenWatchPartyPlugin.dll meta.json firstrun.sh bootstrap.sh; do
  test -f "$CTX/plugin/$f" || { echo "!! $f missing from payload" >&2; exit 1; }
done

# Host assemblies must NOT ship (type-identity conflicts in the plugin ALC); upstream already
# excludes them (ExcludeAssets=runtime) — fail loudly if a future release regresses.
LEAKED="$(find "$CTX/plugin" -maxdepth 1 -type f \( -name 'Emby.*' -o -name 'MediaBrowser.*' \
  -o -name 'Newtonsoft.*' -o \( -name 'Jellyfin.*' -a ! -name 'OpenWatchParty*' \) \))"
[ -z "$LEAKED" ] || { echo "!! forbidden assemblies leaked:" >&2; echo "$LEAKED" >&2; exit 1; }

PLUGIN_VERSION="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$CTX/plugin/meta.json" | head -1 | grep -oE '[0-9.]+')"
TARGET_ABI="$(grep -oE '"targetAbi"[[:space:]]*:[[:space:]]*"[^"]+"' "$CTX/plugin/meta.json" | head -1 | grep -oE '[0-9.]+')"
echo ">> Payload (meta.json version ${PLUGIN_VERSION}, targetAbi ${TARGET_ABI}):"; ( cd "$CTX/plugin" && ls -1 )

cp "$ROOT/docker/Dockerfile.plugin" "$CTX/Dockerfile.plugin"
echo ">> Building ${IMAGE} (tags: ${PLUGIN_VERSION}, ${TAG}, latest)"
PROV=()
[ "$BUILDER" = "docker" ] && PROV=(--provenance=false)
"$BUILDER" build "${PROV[@]}" -f "$CTX/Dockerfile.plugin" \
  -t "${IMAGE}:${PLUGIN_VERSION}" -t "${IMAGE}:${TAG}" -t "${IMAGE}:latest" "$CTX"

if [ "$PUSH" = "true" ]; then
  for t in "${PLUGIN_VERSION}" "${TAG}" latest; do "$BUILDER" push "${IMAGE}:${t}"; done
  DIGEST="$("$BUILDER" inspect --format='{{range .RepoDigests}}{{println .}}{{end}}' "${IMAGE}:${PLUGIN_VERSION}" | grep "^${IMAGE}@" | head -1)"
  echo ">> Pushed. Pin in k8s (spec.pluginImage.reference): ${DIGEST}"
else
  echo ">> PUSH=false — built only."
fi
