#!/bin/sh
#
# OpenWatchParty FIRST-RUN hook — runs ONCE per Jellyfin instance, the first time the
# plugin starts (tracked by the operator under /config/.jellyops/firstrun/). Baked into
# the plugin image root (plugin/firstrun.sh) and auto-detected by the JellyOps operator
# for imageVolumeCopy plugins; the CR only supplies env.
#
# Responsibility: seed the declarative plugin configuration XML the plugin deserializes on
# load, so the JWT secret / session-server URL come from the JellyfinPlugin CR (env +
# Secret) rather than being typed into the dashboard.
#
# The config filename is derived from the plugin assembly name. Upstream OpenWatchParty
# ships OpenWatchPartyPlugin.dll (our old source port shipped OpenWatchParty.Plugin.dll), so:
#   /config/plugins/configurations/OpenWatchPartyPlugin.xml
# The root element MUST be <PluginConfiguration> (the config class name) so the host
# XmlSerializer binds it. Element names match PluginConfiguration.cs properties.
#
# CRITICAL: OWP_JWT_SECRET must be the SAME secret handed to the companion session server
# (env JWT_SECRET), and audience/issuer must match (JWT_AUDIENCE / JWT_ISSUER) — the plugin
# mints tokens the Rust server validates.
#
# Env (from spec.install.env / Secret):
#   OWP_JWT_SECRET          [required]  Base64/Base64URL of >= 32 random bytes, no whitespace
#                                       (e.g. `openssl rand -base64 48`); shared with the session
#                                       server. Upstream >= 0.6 REJECTS anything else on both sides.
#   OWP_SESSION_SERVER_URL  [required]  e.g. wss://jellyfin.bne1.ouchi.com.au/owp/ws
#   OWP_JWT_AUDIENCE        [OpenWatchParty]
#   OWP_JWT_ISSUER          [Jellyfin]
#   OWP_TOKEN_TTL_SECONDS   [3600]      clamped 60..86400 by the plugin
#   OWP_INVITE_TTL_SECONDS  [3600]      clamped 60..86400 by the plugin
set -eu

CONFIG_DIR="${CONFIG_DIR:-/config}"
CFG_DIR="${CONFIG_DIR}/plugins/configurations"
CFG="${CFG_DIR}/OpenWatchPartyPlugin.xml"

: "${OWP_JWT_SECRET:?OWP_JWT_SECRET is required (shared with the session server)}"
: "${OWP_SESSION_SERVER_URL:?OWP_SESSION_SERVER_URL is required}"

OWP_JWT_AUDIENCE="${OWP_JWT_AUDIENCE:-OpenWatchParty}"
OWP_JWT_ISSUER="${OWP_JWT_ISSUER:-Jellyfin}"
OWP_TOKEN_TTL_SECONDS="${OWP_TOKEN_TTL_SECONDS:-3600}"
OWP_INVITE_TTL_SECONDS="${OWP_INVITE_TTL_SECONDS:-3600}"

mkdir -p "$CFG_DIR"

# Minimal XML escaper for element text (& < > " ').
xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

# Upstream validates the secret (plugin JwtSecretValidator + session server): Base64/Base64URL,
# >= 32 decoded bytes, no whitespace, enough diversity. Warn early on the cheap checks; a bad
# secret makes /OpenWatchParty/Token return 503 and the session server refuse to start.
case "$OWP_JWT_SECRET" in
  *[!A-Za-z0-9+/=_-]*) echo ">> WARNING: OWP_JWT_SECRET is not Base64/Base64URL; upstream will reject it." >&2 ;;
esac
if [ "$(printf '%s' "$OWP_JWT_SECRET" | wc -c)" -lt 43 ]; then
  echo ">> WARNING: OWP_JWT_SECRET encodes < 32 bytes; upstream will reject it (use openssl rand -base64 48)." >&2
fi

echo ">> Seeding OpenWatchParty config -> $CFG"
cat > "$CFG" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<PluginConfiguration xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <JwtSecret>$(xml_escape "$OWP_JWT_SECRET")</JwtSecret>
  <JwtAudience>$(xml_escape "$OWP_JWT_AUDIENCE")</JwtAudience>
  <JwtIssuer>$(xml_escape "$OWP_JWT_ISSUER")</JwtIssuer>
  <TokenTtlSeconds>$(xml_escape "$OWP_TOKEN_TTL_SECONDS")</TokenTtlSeconds>
  <InviteTtlSeconds>$(xml_escape "$OWP_INVITE_TTL_SECONDS")</InviteTtlSeconds>
  <SessionServerUrl>$(xml_escape "$OWP_SESSION_SERVER_URL")</SessionServerUrl>
</PluginConfiguration>
EOF

echo ">> OpenWatchParty config seeded."
