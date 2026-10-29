#!/bin/bash
# release.sh — build, test, screenshot, sign, notarize and publish an Apple app.
#
# One script for every v57 app. A project describes itself in a `release.env` at its
# root (see release.env.example); Dev's Release tool edits the same file and runs this
# script, so a release from the app and one from a terminal are the same release.
#
#   Tools/release/release.sh [--project DIR] [--version X.Y.Z] [--dry-run] STEP...
#
# Steps, in the order `all` runs them:
#   check        tools, signing identity, notary profile, gh login, clean tree
#   build        xcodebuild build
#   test         xcodebuild test (skipped when TEST_SCHEME is empty)
#   screenshots  the scenes in .dev/screenshots.json (dev-screenshots; pictures in its output folder),
#                else UI test SCREENSHOT_TEST per locale, attachments exported as PNGs
#   archive      xcodebuild archive with the release version and build number
#   direct       Developer ID export, notarize + staple, <App>.zip and <App>.dmg (macOS);
#                with DIRECT_ARCHS="universal arm64" also <App>-AppleSilicon.zip/.dmg
#   github       GitHub Release v<version> with the direct-download files
#   appstore     App Store Connect upload of the archive
#   all          every step the config enables
#
# Output for a reader and for Dev alike: plain lines, plus marker lines
#   ::step NAME   ::done NAME   ::skip NAME REASON   ::fail NAME REASON   ::artifact PATH
# Artifacts land in build/release/<version>/ inside the project.

set -euo pipefail

STEPS_ALL="check build test screenshots archive direct github appstore"
# The Dev repo this script sits in (Tools/release/ or Dev/Release/), for dev-screenshots; in Dev.app it's no repo.
SCRIPT_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_DIR="$PWD"
VERSION=""
DRY_RUN=0
STEPS=""

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT_DIR="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    all) STEPS="$STEPS_ALL"; shift ;;
    check|build|test|screenshots|archive|direct|github|appstore) STEPS="$STEPS $1"; shift ;;
    *) echo "unknown argument: $1" >&2; usage 2 ;;
  esac
done
[ -n "$STEPS" ] || usage 2

cd "$PROJECT_DIR"
PROJECT_DIR="$PWD"
[ -f release.env ] || { echo "::fail config no release.env in $PROJECT_DIR (copy Tools/release/release.env.example)"; exit 1; }

# Defaults, then the project's own values.
APP_NAME=""; SCHEME=""; PROJECT=""; WORKSPACE=""; PLATFORM="macos"; TEAM_ID=""
CONFIGURATION="Release"; TEST_SCHEME=""; TEST_DESTINATION=""; SCREENSHOT_TEST=""
SCREENSHOT_LOCALES="en"; SCREENSHOT_DESTINATION=""; DIRECT_DOWNLOAD="zip dmg"; DIRECT_ARCHS="universal"
NOTARY_PROFILE=""; GITHUB_REPO=""; GITHUB_DRAFT="yes"; APP_STORE="no"
ASC_KEY_ID=""; ASC_ISSUER_ID=""; ASC_KEY_PATH=""
# shellcheck disable=SC1091
. ./release.env
[ -n "$SCHEME" ] || { echo "::fail config SCHEME is not set in release.env"; exit 1; }
APP_NAME="${APP_NAME:-$SCHEME}"
DIRECT_DOWNLOAD="${DIRECT_DOWNLOAD//,/ }"
DIRECT_ARCHS="${DIRECT_ARCHS//,/ }"
SCREENSHOT_LOCALES="${SCREENSHOT_LOCALES//,/ }"

if [ -n "$WORKSPACE" ]; then CONTAINER=(-workspace "$WORKSPACE")
elif [ -n "$PROJECT" ]; then CONTAINER=(-project "$PROJECT")
else CONTAINER=(); fi

case "$PLATFORM" in
  macos) DESTINATION="generic/platform=macOS"; TEST_DESTINATION="${TEST_DESTINATION:-platform=macOS}" ;;
  ios) DESTINATION="generic/platform=iOS" ;;
  *) echo "::fail config PLATFORM must be macos or ios"; exit 1 ;;
esac

if [ -z "$VERSION" ]; then
  VERSION=$(xcodebuild ${CONTAINER[@]+"${CONTAINER[@]}"} -scheme "$SCHEME" -configuration "$CONFIGURATION" \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ MARKETING_VERSION = / {print $2; exit}')
fi
VERSION="${VERSION:-1.0}"
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M)
OUT="$PROJECT_DIR/build/release/$VERSION"
ARCHIVE="$OUT/$APP_NAME.xcarchive"
mkdir -p "$OUT"
echo "$APP_NAME $VERSION ($BUILD_NUMBER), $PLATFORM, scheme $SCHEME -> ${OUT#"$PROJECT_DIR"/}"

run() {
  echo "\$ $*"
  [ "$DRY_RUN" = 1 ] || "$@"
}

# xcodebuild is loud; keep errors, warnings and the result lines.
# XCB_TOOL: another xcodebuild (the archive's xcodebuild-release).
xcb() {
  local tool="${XCB_TOOL:-xcodebuild}"
  echo "\$ $(basename "$tool") $*"
  [ "$DRY_RUN" = 1 ] && return 0
  local log="$OUT/xcodebuild-$CURRENT.log"
  if "$tool" "$@" >"$log" 2>&1; then
    grep -E "warning:|\*\* .* SUCCEEDED \*\*|Test Suite .* (passed|failed)|Executed [0-9]+ test" "$log" | sort -u | tail -40 || true
  else
    grep -E "error:|\*\* .* FAILED \*\*|failed \(" "$log" | sort -u | head -40 || true
    echo "full log: $log"
    return 1
  fi
}

CURRENT=""
step() { CURRENT="$1"; echo; echo "::step $1"; }
done_step() { echo "::done $CURRENT"; }
skip() { echo "::skip $CURRENT $1"; }
fail() { echo "::fail $CURRENT $1"; exit 1; }
artifact() { echo "::artifact $1"; }

# ── steps ────────────────────────────────────────────────────────────────

do_check() {
  step check
  command -v xcodebuild >/dev/null || fail "xcodebuild not found"
  xcodebuild -version | sed -n 1p
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    echo "note: the working tree has uncommitted changes; the release builds them"
  fi
  if wants direct; then
    security find-identity -v -p codesigning | grep "Developer ID Application:.*($TEAM_ID)" >/dev/null \
      || fail "no Developer ID Application certificate for team $TEAM_ID in the keychain"
    echo "Developer ID Application certificate for $TEAM_ID: found"
    [ -n "$NOTARY_PROFILE" ] || fail "NOTARY_PROFILE is empty (xcrun notarytool store-credentials <name>)"
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
      || fail "notary profile '$NOTARY_PROFILE' does not work (xcrun notarytool store-credentials $NOTARY_PROFILE)"
    echo "notary profile $NOTARY_PROFILE: works"
  fi
  if wants github; then
    command -v gh >/dev/null || fail "gh (GitHub CLI) not found"
    gh auth status >/dev/null 2>&1 || fail "gh is not logged in (gh auth login)"
    [ -n "$GITHUB_REPO" ] || fail "GITHUB_REPO is empty"
    echo "GitHub: $GITHUB_REPO"
  fi
  done_step
}

do_build() {
  step build
  xcb ${CONTAINER[@]+"${CONTAINER[@]}"} -scheme "$SCHEME" -configuration "$CONFIGURATION" -destination "$DESTINATION" build \
    || fail "the build failed"
  done_step
}

do_test() {
  step test
  [ -n "$TEST_SCHEME" ] || { skip "TEST_SCHEME is empty"; return; }
  [ -n "$TEST_DESTINATION" ] || { skip "TEST_DESTINATION is empty"; return; }
  run rm -rf "$OUT/tests.xcresult"
  xcb ${CONTAINER[@]+"${CONTAINER[@]}"} -scheme "$TEST_SCHEME" -destination "$TEST_DESTINATION" \
    -resultBundlePath "$OUT/tests.xcresult" test || fail "tests failed"
  artifact "$OUT/tests.xcresult"
  done_step
}

# dev-screenshots: $DEV_SCREENSHOTS, Dev's own binary (Dev sets DEV_APP_EXECUTABLE), one on the PATH, this repo's
# package, or the installed Dev.
screenshot_tool() {
  if [ -n "${DEV_SCREENSHOTS:-}" ]; then SHOT_TOOL=("$DEV_SCREENSHOTS")
  elif [ -n "${DEV_APP_EXECUTABLE:-}" ]; then SHOT_TOOL=("$DEV_APP_EXECUTABLE" --screenshots)
  elif command -v dev-screenshots >/dev/null; then SHOT_TOOL=(dev-screenshots)
  elif [ -f "$SCRIPT_REPO/Package.swift" ] && grep -q dev-screenshots "$SCRIPT_REPO/Package.swift"; then
    SHOT_TOOL=(swift run -c release --package-path "$SCRIPT_REPO" dev-screenshots)
  elif [ -x /Applications/Dev.app/Contents/MacOS/Dev ]; then SHOT_TOOL=(/Applications/Dev.app/Contents/MacOS/Dev --screenshots)
  else fail "dev-screenshots not found (set DEV_SCREENSHOTS, or install Dev)"; fi
}

do_screenshots() {
  step screenshots
  if [ -f .dev/screenshots.json ]; then
    screenshot_tool
    run "${SHOT_TOOL[@]}" capture --project "$PROJECT_DIR" || fail "some scenes were not captured"
    local output
    output=$(sed -n 's/.*"output" *: *"\([^"]*\)".*/\1/p' .dev/screenshots.json | head -1)
    artifact "$PROJECT_DIR/${output:-.build/screenshots}"
    done_step
    return
  fi
  [ -n "$SCREENSHOT_TEST" ] || { skip "no .dev/screenshots.json and SCREENSHOT_TEST is empty"; return; }
  local destination="${SCREENSHOT_DESTINATION:-$TEST_DESTINATION}"
  local scheme="${TEST_SCHEME:-$SCHEME}"
  for locale in $SCREENSHOT_LOCALES; do
    local result="$OUT/screenshots-$locale.xcresult"
    local folder="$OUT/screenshots/$locale"
    run rm -rf "$result" "$folder"
    mkdir -p "$folder"
    xcb ${CONTAINER[@]+"${CONTAINER[@]}"} -scheme "$scheme" -destination "$destination" \
      -only-testing "$SCREENSHOT_TEST" -testLanguage "${locale%%-*}" -testRegion "${locale##*-}" \
      -resultBundlePath "$result" test || fail "screenshot tests failed for $locale"
    run xcrun xcresulttool export attachments --path "$result" --output-path "$folder"
    artifact "$folder"
  done
  done_step
}

do_archive() {
  step archive
  run rm -rf "$ARCHIVE"
  # macOS: archived through xcodebuild-release, the release link every v57 app ships with (LTO, ld-archive-prelink,
  # actool-icon-slim: unused package code goes, apps 35-50% smaller, the icon's fallbacks as HEVC). Its one copy is
  # Code's CodeActions/Release: Dev's Release tool passes the copy inside the app as RELEASE_TOOLS, and from a
  # terminal it's the Code checkout beside this Dev repo.
  local tool=xcodebuild
  if [ "$PLATFORM" = macos ]; then
    tool="${RELEASE_TOOLS:-$SCRIPT_REPO/../Code/Sources/CodeActions/Release}/xcodebuild-release"
    [ -x "$tool" ] || fail "xcodebuild-release not found at $tool (set RELEASE_TOOLS to Code's Sources/CodeActions/Release)"
  fi
  XCB_TOOL="$tool" xcb ${CONTAINER[@]+"${CONTAINER[@]}"} -scheme "$SCHEME" -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" -archivePath "$ARCHIVE" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    archive || fail "the archive failed"
  artifact "$ARCHIVE"
  done_step
}

notarize() {
  run xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m \
    || fail "notarization of $(basename "$1") failed (xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE)"
}

# Signs, notarizes and staples a .app in place.
notarize_app() {
  local app="$1" upload="$OUT/notarize-$(basename "$1" .app).zip"
  run codesign --verify --deep --strict "$app"
  run ditto -c -k --keepParent "$app" "$upload"
  notarize "$upload"
  run xcrun stapler staple "$app"
  run rm -f "$upload"
}

# <name>.zip and <name>.dmg from a notarized app; the dmg is signed, notarized and stapled too.
package() {
  local app="$1" name="$2"
  case " $DIRECT_DOWNLOAD " in *" zip "*)
    run rm -f "$OUT/$name.zip"
    run ditto -c -k --keepParent "$app" "$OUT/$name.zip"
    artifact "$OUT/$name.zip" ;;
  esac
  case " $DIRECT_DOWNLOAD " in *" dmg "*)
    local stage="$OUT/dmg-$name"
    run rm -rf "$stage" "$OUT/$name.dmg"
    run mkdir -p "$stage"
    run cp -R "$app" "$stage/"
    run ln -s /Applications "$stage/Applications"
    run hdiutil create -volname "$APP_NAME" -srcfolder "$stage" -ov -format ULFO "$OUT/$name.dmg"
    run rm -rf "$stage"
    run codesign --sign "$IDENTITY" --timestamp "$OUT/$name.dmg"
    notarize "$OUT/$name.dmg"
    run xcrun stapler staple "$OUT/$name.dmg"
    artifact "$OUT/$name.dmg" ;;
  esac
}

do_direct() {
  step direct
  [ "$PLATFORM" = macos ] || { skip "direct downloads are for macOS apps"; return; }
  [ -d "$ARCHIVE" ] || [ "$DRY_RUN" = 1 ] || fail "no archive at $ARCHIVE (run the archive step)"
  IDENTITY=$(security find-identity -v -p codesigning | awk -v team="($TEAM_ID)" \
    'index($0, "Developer ID Application:") && index($0, team) {print $2; exit}')
  IDENTITY="${IDENTITY:-Developer ID Application}"
  local export="$OUT/developer-id"
  local options="$OUT/ExportOptions-developer-id.plist"
  cat >"$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST
  run rm -rf "$export"
  xcb -exportArchive -archivePath "$ARCHIVE" -exportPath "$export" -exportOptionsPlist "$options" \
    || fail "the Developer ID export failed"
  local app="$export/$APP_NAME.app"
  [ -d "$app" ] || [ "$DRY_RUN" = 1 ] || fail "the export has no $APP_NAME.app"

  # Versionless names keep https://github.com/<repo>/releases/latest/download/<file> stable.
  # With both variants the universal app is <App>, the Apple silicon one <App>-AppleSilicon.
  local thin_name="$APP_NAME"
  case " $DIRECT_ARCHS " in *" universal "*)
    notarize_app "$app"
    package "$app" "$APP_NAME"
    thin_name="$APP_NAME-AppleSilicon" ;;
  esac
  case " $DIRECT_ARCHS " in *" arm64 "*)
    # A thinned copy is a new binary: it is signed again with the same entitlements
    # and the hardened runtime, then notarized on its own.
    local thin="$OUT/arm64/$APP_NAME.app" entitlements="$OUT/entitlements.plist"
    run rm -rf "$OUT/arm64"
    run mkdir -p "$OUT/arm64"
    run ditto "$app" "$thin"
    # lipo, not `ditto --arch`: ditto copies a signed universal binary whole.
    if [ "$DRY_RUN" = 1 ]; then echo "\$ lipo -thin arm64 (every universal Mach-O in $thin)"
    else
      while IFS= read -r -d '' file; do
        if lipo -archs "$file" 2>/dev/null | grep -q " "; then
          lipo "$file" -thin arm64 -output "$file.thin" && mv "$file.thin" "$file"
        fi
      done < <(find "$thin" -type f -perm -u+x -print0)
    fi
    if [ "$DRY_RUN" = 1 ]; then echo "\$ codesign -d --entitlements :- $app > $entitlements"
    else codesign -d --entitlements :- "$app" >"$entitlements" 2>/dev/null || true; fi
    if [ -s "$entitlements" ] || [ "$DRY_RUN" = 1 ]; then
      run codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$IDENTITY" "$thin"
    else
      run codesign --force --options runtime --timestamp --sign "$IDENTITY" "$thin"
    fi
    notarize_app "$thin"
    package "$thin" "$thin_name" ;;
  esac
  [ "$DRY_RUN" = 1 ] || spctl --assess --type execute --verbose "$app" 2>&1 | sed -n 1,2p
  done_step
}

do_github() {
  step github
  [ -n "$GITHUB_REPO" ] || { skip "GITHUB_REPO is empty"; return; }
  local files=()
  for kind in $DIRECT_DOWNLOAD; do
    for name in "$APP_NAME" "$APP_NAME-AppleSilicon"; do
      [ -f "$OUT/$name.$kind" ] && files+=("$OUT/$name.$kind")
    done
  done
  [ ${#files[@]} -gt 0 ] || [ "$DRY_RUN" = 1 ] || fail "no direct-download files in $OUT (run the direct step)"
  local tag="v$VERSION" draft=()
  [ "$GITHUB_DRAFT" = yes ] && draft=(--draft)
  if gh release view "$tag" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
    run gh release upload "$tag" ${files[@]+"${files[@]}"} --repo "$GITHUB_REPO" --clobber
  else
    run gh release create "$tag" ${files[@]+"${files[@]}"} --repo "$GITHUB_REPO" --title "$APP_NAME $VERSION" \
      --generate-notes ${draft[@]+"${draft[@]}"}
  fi
  echo "stable link: https://github.com/$GITHUB_REPO/releases/latest/download/$APP_NAME.zip"
  [ "$GITHUB_DRAFT" = yes ] && echo "the release is a DRAFT: publish it on GitHub when it looks right"
  done_step
}

do_appstore() {
  step appstore
  [ "$APP_STORE" = yes ] || { skip "APP_STORE is not yes"; return; }
  [ -d "$ARCHIVE" ] || [ "$DRY_RUN" = 1 ] || fail "no archive at $ARCHIVE (run the archive step)"
  local options="$OUT/ExportOptions-app-store.plist"
  cat >"$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
  local auth=()
  if [ -n "$ASC_KEY_ID" ] && [ -n "$ASC_ISSUER_ID" ] && [ -n "$ASC_KEY_PATH" ]; then
    auth=(-authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"
          -authenticationKeyPath "$ASC_KEY_PATH")
  fi
  xcb -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/app-store" -exportOptionsPlist "$options" \
    -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} || fail "the App Store Connect upload failed"
  echo "uploaded $VERSION ($BUILD_NUMBER) to App Store Connect"
  done_step
}

wants() { case " $STEPS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

for name in $STEPS_ALL; do
  if wants "$name"; then "do_$name"; fi
done
echo
echo "::finished $VERSION"
