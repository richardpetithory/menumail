#!/bin/zsh
# Builds a signed, notarized MenuMail release:
#
#   make release                   bump version, build a universal app signed with your
#                                  Developer ID, notarize + staple it, zip it to dist/
#   make release ARGS=--publish    also commit the bump, tag it, push, and create a GitHub
#                                  release with the zip (needs a GitHub remote and gh)
#   make release-check             show the next version and check prerequisites only
#
# Like mopeds' ios-build, the version bump in Resources/Info.plist is rolled back if the run
# is canceled or fails before the notarized build exists. Without --publish the bump is left
# uncommitted.
#
# One-time setup:
#   1. Developer ID certificate: Xcode > Settings > Accounts > (your team) > Manage
#      Certificates > + > "Developer ID Application". Only the account holder can create it.
#   2. Notarization credentials, saved to the keychain. MenuMail shares MaKeep's profile (same
#      Apple ID and team); to create it:
#        xcrun notarytool store-credentials makeep-notary --apple-id <apple id> --team-id 47K8399UUS
#      When asked for a password, use an app-specific password from account.apple.com.
#      MENUMAIL_NOTARY_PROFILE overrides the profile name.
#   3. Config/oauth-client.env with the built-in OAuth client (see the README).
set -euo pipefail
cd "${0:A:h}/.."

PLIST=Resources/Info.plist
PROFILE="${MENUMAIL_NOTARY_PROFILE:-makeep-notary}"
DRY_RUN=false
PUBLISH=false
for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        --publish) PUBLISH=true ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }
plist_set() { /usr/libexec/PlistBuddy -c "Set :$1 $2" "$PLIST"; }

CURRENT_VERSION=$(plist_get CFBundleShortVersionString)
CURRENT_BUILD=$(plist_get CFBundleVersion)
NEXT_VERSION="${CURRENT_VERSION%.*}.$(( ${CURRENT_VERSION##*.} + 1 ))"
NEXT_BUILD=$(( CURRENT_BUILD + 1 ))
echo "Version: $CURRENT_VERSION ($CURRENT_BUILD) -> $NEXT_VERSION ($NEXT_BUILD)"

# --- Preflight: fail before touching the version -----------------------------------------
problems=()
IDENTITY="${MENUMAIL_DEVELOPER_ID:-$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
if [[ -z "$IDENTITY" ]]; then
    problems+=("No \"Developer ID Application\" certificate in the keychain (setup step 1 in scripts/release.sh).")
fi
if [[ ! -f Config/oauth-client.env ]]; then
    problems+=("No Config/oauth-client.env, so users would have to set up their own OAuth client (see Config/oauth-client.env.example).")
fi
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    problems+=("No working notarization credentials named \"$PROFILE\" (setup step 2 in scripts/release.sh).")
fi
if $PUBLISH; then
    command -v gh >/dev/null || problems+=("--publish needs the GitHub CLI (gh).")
    git remote get-url origin >/dev/null 2>&1 || problems+=("--publish needs a GitHub remote named origin.")
    if [[ -n "$(git status --porcelain | grep -v " $PLIST\$" || true)" ]]; then
        problems+=("--publish tags the current commit; commit or stash other changes first.")
    fi
fi

if (( ${#problems} )); then
    echo "\nNot ready to release:" >&2
    printf '  - %s\n' "${problems[@]}" >&2
    $DRY_RUN || exit 1
fi
if $DRY_RUN; then
    (( ${#problems} )) || echo "Ready to release, signing as: $IDENTITY"
    echo "Dry run: nothing changed."
    exit 0
fi

# --- Bump, with rollback until the notarized build exists ---------------------------------
ORIGINAL_PLIST="$(mktemp)"
cp "$PLIST" "$ORIGINAL_PLIST"
ROLLBACK_ARMED=true
on_exit() {
    local code=$?
    if $ROLLBACK_ARMED; then
        cp "$ORIGINAL_PLIST" "$PLIST"
        echo "Restored version $CURRENT_VERSION ($CURRENT_BUILD)." >&2
    fi
    rm -f "$ORIGINAL_PLIST"
    exit $code
}
trap on_exit EXIT
trap 'echo "\nRelease canceled." >&2; exit 130' INT TERM

plist_set CFBundleShortVersionString "$NEXT_VERSION"
plist_set CFBundleVersion "$NEXT_BUILD"

STAGING=build.noindex/release
APP="$STAGING/MenuMail.app"
rm -rf "$STAGING"

echo "\n==> Building universal app, signed as: $IDENTITY"
MENUMAIL_ARCHS="arm64 x86_64" MENUMAIL_APP_DIR="$STAGING" MENUMAIL_SIGN_IDENTITY="$IDENTITY" \
    ./scripts/bundle.sh release
codesign --verify --strict --deep "$APP"

echo "\n==> Notarizing (usually takes a few minutes)"
ditto -c -k --keepParent "$APP" "$STAGING/notarize.zip"
xcrun notarytool submit "$STAGING/notarize.zip" --keychain-profile "$PROFILE" --wait \
    --output-format json > "$STAGING/notarization.json"
STATUS=$(plutil -extract status raw -o - "$STAGING/notarization.json")
if [[ "$STATUS" != Accepted ]]; then
    echo "Notarization finished with status: $STATUS" >&2
    SUBMISSION_ID=$(plutil -extract id raw -o - "$STAGING/notarization.json" 2>/dev/null || true)
    [[ -n "$SUBMISSION_ID" ]] && xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" >&2
    exit 1
fi
xcrun stapler staple "$APP"
spctl --assess --type execute -vv "$APP"

mkdir -p dist
ARTIFACT="dist/MenuMail-$NEXT_VERSION.zip"
rm -f "$ARTIFACT"
ditto -c -k --keepParent "$APP" "$ARTIFACT"
ROLLBACK_ARMED=false  # The version is baked into a notarized build now; keep the bump.
echo "\nNotarized release: $ARTIFACT"

if $PUBLISH; then
    echo "\n==> Publishing v$NEXT_VERSION to GitHub"
    git commit -m "Release MenuMail $NEXT_VERSION" -- "$PLIST"
    git tag "v$NEXT_VERSION"
    git push origin HEAD "v$NEXT_VERSION"
    gh release create "v$NEXT_VERSION" "$ARTIFACT" --verify-tag \
        --title "MenuMail $NEXT_VERSION" --generate-notes
else
    echo "Remember to commit $PLIST (version $NEXT_VERSION, build $NEXT_BUILD)."
fi
