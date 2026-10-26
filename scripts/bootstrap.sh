#!/bin/sh
#
# OpenWatchParty BOOTSTRAP hook — runs on EVERY pod startup, after the operator has staged
# this image into /config/plugins/OpenWatchParty_<version>/ and before Jellyfin starts.
# Baked into the plugin image root and auto-run by the JellyOps operator for imageVolumeCopy
# plugins.
#
# Responsibility: remove SUPERSEDED OpenWatchParty plugin dirs left on the /config PVC.
#
# Why: the operator never prunes old plugin dirs, and Jellyfin keeps the HIGHEST version of a
# plugin and deletes the rest. Our old source port shipped as 1.0.x.0, whereas the upstream
# release now packaged here is 0.8.0.0. A leftover OpenWatchParty_1.0.1.0 dir would therefore
# win, and Jellyfin would delete the dir we just staged. The CR is authoritative, so any other
# dir whose meta.json carries our GUID is removed.
#
# Fail-open under the jellyops hook runner (failurePolicy: Ignore).
set -eu

GUID="0f2fd0fd-09ff-4f49-9f1c-4a8f421a4b7d"
CONFIG_DIR="${CONFIG_DIR:-/config}"
PLUGINS_DIR="${CONFIG_DIR}/plugins"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { echo "[owp-bootstrap] $*"; }

for dir in "$PLUGINS_DIR"/*/; do
  dir="${dir%/}"
  [ -d "$dir" ] || continue
  [ "$dir" = "$SELF_DIR" ] && continue
  [ -f "$dir/meta.json" ] || continue
  if grep -qi "\"guid\"[[:space:]]*:[[:space:]]*\"$GUID\"" "$dir/meta.json"; then
    log "Removing superseded OpenWatchParty plugin dir $dir"
    rm -rf "$dir"
  fi
done
