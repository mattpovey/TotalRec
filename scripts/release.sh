#!/bin/zsh

set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly REPO_ROOT="${SCRIPT_DIR:h}"
readonly PROJECT_PATH="${REPO_ROOT}/TotalRec.xcodeproj"
readonly SCHEME="TotalRec"
readonly APP_NAME="TotalRec"

TEAM_ID="${DEVELOPMENT_TEAM:-HL3W54MB57}"
NOTARY_PROFILE="${NOTARY_PROFILE:-TotalRec-notary}"
OUTPUT_ROOT="${OUTPUT_DIR:-${REPO_ROOT}/dist}"
CLEAN_OUTPUT=0
PREFLIGHT_ONLY=0

usage() {
    cat <<'USAGE'
Build, sign, notarize, and verify a distributable TotalRec disk image.

Usage:
  scripts/release.sh [options]

Options:
  --team-id ID             Apple Developer team ID (default: HL3W54MB57)
  --notary-profile NAME    notarytool Keychain profile (default: TotalRec-notary)
  --output-dir PATH        Artifact directory (default: ./dist)
  --clean                  Replace this version's existing artifact directory
  --preflight              Check local tools and the Developer ID certificate only
  -h, --help               Show this help

Environment equivalents:
  DEVELOPMENT_TEAM, NOTARY_PROFILE, OUTPUT_DIR

The script deliberately has no unsigned or skip-notarization shipping mode.
USAGE
}

fail() {
    print -u2 -- "error: $*"
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

while (( $# > 0 )); do
    case "$1" in
        --team-id)
            (( $# >= 2 )) || fail "--team-id requires a value"
            TEAM_ID="$2"
            shift 2
            ;;
        --notary-profile)
            (( $# >= 2 )) || fail "--notary-profile requires a value"
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --output-dir)
            (( $# >= 2 )) || fail "--output-dir requires a value"
            OUTPUT_ROOT="$2"
            shift 2
            ;;
        --clean)
            CLEAN_OUTPUT=1
            shift
            ;;
        --preflight)
            PREFLIGHT_ONLY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1 (run with --help for usage)"
            ;;
    esac
done

[[ -d "$PROJECT_PATH" ]] || fail "Xcode project not found at $PROJECT_PATH"
[[ -n "$TEAM_ID" ]] || fail "the Developer team ID cannot be empty"
[[ -n "$NOTARY_PROFILE" ]] || fail "the notarytool Keychain profile cannot be empty"

for tool in awk cat codesign ditto grep hdiutil lipo ln mkdir mktemp plutil rm \
    security shasum spctl xcodebuild xcrun; do
    require_command "$tool"
done

IDENTITIES="$(security find-identity -v -p codesigning 2>&1 || true)"
SIGNING_HASH="$({ print -r -- "$IDENTITIES" } | awk -v team="$TEAM_ID" '
    index($0, "Developer ID Application:") && index($0, "(" team ")") {
        print $2
        exit
    }
')"

if [[ -z "$SIGNING_HASH" ]]; then
    print -u2 -- "No valid Developer ID Application certificate was found for team ${TEAM_ID}."
    print -u2 -- "In Xcode, open Settings > Accounts, select the team, choose Manage Certificates,"
    print -u2 -- "and create or import a Developer ID Application certificate."
    exit 2
fi

print -- "Developer ID certificate: ${SIGNING_HASH} (team ${TEAM_ID})"
print -- "Notary Keychain profile: ${NOTARY_PROFILE}"

if (( PREFLIGHT_ONLY )); then
    print -- "Preflight passed. The notary profile will be validated by Apple during submission."
    exit 0
fi

readonly SETTINGS_DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/TotalRec-release-settings.XXXXXX")"
cleanup_settings_derived_data() {
    rm -rf -- "$SETTINGS_DERIVED_DATA"
}
trap cleanup_settings_derived_data EXIT

BUILD_SETTINGS="$(
    cd "$REPO_ROOT"
    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration Release \
        -derivedDataPath "$SETTINGS_DERIVED_DATA" \
        -showBuildSettings \
        -json \
        CODE_SIGNING_ALLOWED=NO
)"

VERSION="$(print -r -- "$BUILD_SETTINGS" | plutil -extract '0.buildSettings.MARKETING_VERSION' raw -o - -)"
BUILD_NUMBER="$(print -r -- "$BUILD_SETTINGS" | plutil -extract '0.buildSettings.CURRENT_PROJECT_VERSION' raw -o - -)"
[[ -n "$VERSION" && "$VERSION" != *[^A-Za-z0-9._-]* ]] || fail "unsafe marketing version: $VERSION"
[[ -n "$BUILD_NUMBER" && "$BUILD_NUMBER" != *[^A-Za-z0-9._-]* ]] || fail "unsafe build number: $BUILD_NUMBER"
cleanup_settings_derived_data
trap - EXIT

mkdir -p "$OUTPUT_ROOT"
OUTPUT_ROOT="${OUTPUT_ROOT:A}"
RELEASE_DIR="${OUTPUT_ROOT}/${APP_NAME}-${VERSION}-${BUILD_NUMBER}"

if [[ -e "$RELEASE_DIR" ]]; then
    if (( ! CLEAN_OUTPUT )); then
        fail "$RELEASE_DIR already exists; pass --clean to replace this version's artifacts"
    fi
    [[ "$RELEASE_DIR" == "${OUTPUT_ROOT}/${APP_NAME}-"* ]] || fail "refusing to clean unexpected path: $RELEASE_DIR"
    rm -rf -- "$RELEASE_DIR"
fi

mkdir -p "$RELEASE_DIR"
readonly ARCHIVE_PATH="${RELEASE_DIR}/${APP_NAME}.xcarchive"
readonly DERIVED_DATA_PATH="${RELEASE_DIR}/DerivedData"
readonly EXPORT_PATH="${RELEASE_DIR}/export"
readonly EXPORT_OPTIONS="${RELEASE_DIR}/ExportOptions.plist"
readonly STAGING_PATH="${RELEASE_DIR}/dmg-root"
readonly DMG_PATH="${RELEASE_DIR}/${APP_NAME}-${VERSION}.dmg"

plutil -create xml1 "$EXPORT_OPTIONS"
plutil -insert method -string developer-id "$EXPORT_OPTIONS"
plutil -insert destination -string export "$EXPORT_OPTIONS"
plutil -insert signingStyle -string automatic "$EXPORT_OPTIONS"
plutil -insert teamID -string "$TEAM_ID" "$EXPORT_OPTIONS"

print -- "Archiving universal Release build..."
(
    cd "$REPO_ROOT"
    xcodebuild archive \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -archivePath "$ARCHIVE_PATH" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY='Developer ID Application' \
        ONLY_ACTIVE_ARCH=NO \
        ARCHS='arm64 x86_64'
)

print -- "Exporting Developer ID application..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates

readonly APP_PATH="${EXPORT_PATH}/${APP_NAME}.app"
[[ -d "$APP_PATH" ]] || fail "export did not produce $APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
SIGNATURE_DETAILS="$(codesign -d --verbose=4 "$APP_PATH" 2>&1)"
print -r -- "$SIGNATURE_DETAILS" | grep -F 'Authority=Developer ID Application:' >/dev/null \
    || fail "exported app is not signed with Developer ID Application"
print -r -- "$SIGNATURE_DETAILS" | grep -F 'flags=0x10000(runtime)' >/dev/null \
    || fail "exported app does not have Hardened Runtime enabled"

readonly EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/${APP_NAME}"
ARCHITECTURES="$(lipo -archs "$EXECUTABLE_PATH")"
[[ " $ARCHITECTURES " == *' arm64 '* ]] || fail "exported app is missing arm64 support: $ARCHITECTURES"
[[ " $ARCHITECTURES " == *' x86_64 '* ]] || fail "exported app is missing x86_64 support: $ARCHITECTURES"
print -- "Architectures: $ARCHITECTURES"

mkdir -p "$STAGING_PATH"
ditto "$APP_PATH" "${STAGING_PATH}/${APP_NAME}.app"
ln -s /Applications "${STAGING_PATH}/Applications"

print -- "Creating and signing disk image..."
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_PATH" \
    -format UDZO \
    -ov \
    "$DMG_PATH"
codesign --force --timestamp --sign "$SIGNING_HASH" "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

print -- "Submitting disk image to Apple's notary service..."
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

print -- "Stapling and validating the notarization ticket..."
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"

readonly CHECKSUM_PATH="${DMG_PATH}.sha256"
(
    cd "$RELEASE_DIR"
    shasum -a 256 "${DMG_PATH:t}" > "${CHECKSUM_PATH:t}"
)

rm -rf -- "$STAGING_PATH" "$DERIVED_DATA_PATH"
print -- "Release ready: $DMG_PATH"
print -- "Checksum:      $CHECKSUM_PATH"
