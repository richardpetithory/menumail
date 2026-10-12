#!/bin/zsh
# Builds MenuMail and wraps the binary in build.noindex/MenuMail.app (".noindex" keeps this
# working copy out of Spotlight; `make run` installs it to /Applications).
#
# Local builds sign with "MenuMail Local Signing" (see create-signing-cert.sh) when available,
# so Keychain access grants survive rebuilds, and fall back to ad-hoc signing otherwise.
#
# Overrides (used by release.sh):
#   MENUMAIL_ARCHS          e.g. "arm64 x86_64" for a universal binary (default: host arch)
#   MENUMAIL_APP_DIR        output directory for MenuMail.app (default: build.noindex)
#   MENUMAIL_SIGN_IDENTITY  signing identity; also enables the hardened runtime and a secure
#                         timestamp, which notarization requires
set -euo pipefail
cd "${0:A:h}/.."

CONFIG="${1:-release}"
BUILD_FLAGS=(-c "$CONFIG")
for arch in ${=MENUMAIL_ARCHS:-}; do BUILD_FLAGS+=(--arch "$arch"); done
swift build "${BUILD_FLAGS[@]}"
BIN="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)/menumail"

APP="${MENUMAIL_APP_DIR:-build.noindex}/MenuMail.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/menumail"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The built-in OAuth client, so users can just sign in (see Config/oauth-client.env.example).
# The file is gitignored to keep the client out of the public repo.
CLIENT_CONFIG=Config/oauth-client.env
if [[ -f "$CLIENT_CONFIG" ]]; then
    MENUMAIL_CLIENT_ID="" MENUMAIL_CLIENT_SECRET=""
    source "$CLIENT_CONFIG"
    if [[ -z "$MENUMAIL_CLIENT_ID" || -z "$MENUMAIL_CLIENT_SECRET" ]]; then
        echo "error: $CLIENT_CONFIG must set MENUMAIL_CLIENT_ID and MENUMAIL_CLIENT_SECRET" >&2
        exit 1
    fi
    /usr/libexec/PlistBuddy -c "Add :MenuMailOAuthClientID string $MENUMAIL_CLIENT_ID" \
        -c "Add :MenuMailOAuthClientSecret string $MENUMAIL_CLIENT_SECRET" "$APP/Contents/Info.plist"
else
    echo "note: no $CLIENT_CONFIG, so users will have to set up their own OAuth client" >&2
fi

# App icon, drawn by the app itself (MenuMailIcon) so it matches the menu bar icon.
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$BIN" --render-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "${ICONSET:h}"

LOCAL_IDENTITY="MenuMail Local Signing"
if [[ -n "${MENUMAIL_SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$MENUMAIL_SIGN_IDENTITY" "$APP"
elif security find-certificate -c "$LOCAL_IDENTITY" >/dev/null 2>&1; then
    codesign --force --sign "$LOCAL_IDENTITY" "$APP"
else
    echo "warning: \"$LOCAL_IDENTITY\" not found; signing ad-hoc (run scripts/create-signing-cert.sh)" >&2
    codesign --force --sign - "$APP"
fi
echo "Built $APP"
