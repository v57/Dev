#!/bin/bash
# release.sh — build, test, archive, package, sign, notarize and publish an app for every platform it ships on.
#
# One script for every v57 app. A project describes itself in a `release.env` at its
# root (see release.env.example); Dev's Release tool and Workflows edit the same file and run
# this script, so a release from the app and one from a terminal are the same release.
#
#   Tools/release/release.sh [--project DIR] [--platform P] [--host USER@HOST] [--output DIR]
#                            [--version X.Y.Z] [--build N] [--commit REV] [--no-zip] [--dry-run] STEP...
#
# --build and --commit pin the build number (else the commit count) and the commit the manifest names (else HEAD),
# so every step of one run agrees when the branch moves on while it runs.
#
# Platforms (--platform, else PLATFORM in release.env): macos and ios build on this Mac; windows and linux build
# on another machine over SSH (--host, else WINDOWS_HOST / LINUX_HOST: Dev passes its UTM VMs), which gets the
# project and every package it builds from on this Mac (V57_LOCAL=1), and the packages come back here; android
# cross-compiles on this Mac (not set up yet).
#
# Steps, in the order `all` runs them (a step that doesn't apply to the platform is skipped):
#   check        tools, signing identity, notary profile, gh login, the build host
#   build        a build (xcodebuild; swift build on Windows and Linux)
#   test         xcodebuild test (skipped when TEST_SCHEME is empty)
#   screenshots  the scenes in .dev/screenshots.json (dev-screenshots; pictures in its output folder),
#                else UI test SCREENSHOT_TEST per locale, attachments exported as PNGs
#   archive      the release build with the version and build number, packaged:
#                macOS <App>.xcarchive + Developer ID signed <App>.zip/.dmg (not notarized), iOS <App>.xcarchive,
#                Windows <App>-Windows-<arch>.zip, Linux <App>-Linux-<arch>.tar.gz, Android <App>-Android.apk
#   direct       macOS: notarize + staple, <App>.zip and <App>.dmg again; with DIRECT_ARCHS="universal arm64"
#                also <App>-AppleSilicon.zip/.dmg
#   bundle       one <App>-<version>-<build>.zip with every platform's packages and archives in the output
#                folder, and manifest.json (app, version, build, commit, files with sizes and SHA-256); with
#                --no-zip the folder <App>-<version>-<build>/ instead (files linked, archives cloned)
#   github       GitHub Release v<version> with every platform's download files
#   appstore     App Store Connect upload of the archive (macOS, iOS)
#   googleplay   Google Play upload (Android; not built yet)
#   msstore      Microsoft Store submission (Windows; not built yet)
#   all          every step the config enables
#
# Output for a reader and for Dev alike: plain lines, plus marker lines
#   ::step NAME   ::done NAME   ::skip NAME REASON   ::fail NAME REASON
#   ::artifact KIND PLATFORM PATH   (KIND: archive, package, bundle, manifest, tests, screenshots)
#   ::progress DONE TOTAL WHAT      (bundle: each file it adds, then the zip)
# Files land in <output>/<platform>/ (default output: build/release/<version>/ inside the project); each platform
# folder lists its artifacts in artifacts.tsv, which bundle and github read.

set -euo pipefail

STEPS_ALL="check build test screenshots archive direct bundle github appstore googleplay msstore"
# The Dev repo this script sits in (Tools/release/ or App/Resources/), for dev-screenshots; in Dev.app it's no repo.
SCRIPT_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_DIR="$PWD"
VERSION=""
DRY_RUN=0
STEPS=""
ARG_PLATFORM=""
ARG_HOST=""
ARG_OUTPUT=""
ARG_BUILD=""
ARG_COMMIT=""
NO_ZIP=0

usage() { sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT_DIR="$2"; shift 2 ;;
    --platform) ARG_PLATFORM="$2"; shift 2 ;;
    --host) ARG_HOST="$2"; shift 2 ;;
    --output) ARG_OUTPUT="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --build) ARG_BUILD="$2"; shift 2 ;;
    --commit) ARG_COMMIT="$2"; shift 2 ;;
    --no-zip) NO_ZIP=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    all) STEPS="$STEPS_ALL"; shift ;;
    check|build|test|screenshots|archive|direct|bundle|github|appstore|googleplay|msstore) STEPS="$STEPS $1"; shift ;;
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
DIRECT_SETTINGS=""; NOTARY_PROFILE=""; GITHUB_REPO=""; GITHUB_DRAFT="yes"; APP_STORE="no"
ASC_KEY_ID=""; ASC_ISSUER_ID=""; ASC_KEY_PATH=""
PACKAGE_PATH=""; WINDOWS_PRODUCT=""; WINDOWS_HOST=""; LINUX_PRODUCT=""; LINUX_HOST=""; LINUX_STATIC="yes"
LINUX_JOBS=4; SWIFTUI_PATH=""
ANDROID_PRODUCT=""; ANDROID_KEYSTORE=""; ANDROID_KEY_ALIAS=""; ANDROID_KEYCHAIN_ITEM=""
GOOGLE_PLAY="no"; GOOGLE_PLAY_TRACK="internal"; GOOGLE_PLAY_KEY_PATH=""
MS_STORE="no"; MS_STORE_APP_ID=""
# shellcheck disable=SC1091
. ./release.env
[ -n "$SCHEME" ] || { echo "::fail config SCHEME is not set in release.env"; exit 1; }
APP_NAME="${APP_NAME:-$SCHEME}"
PLATFORM="${ARG_PLATFORM:-${PLATFORM:-macos}}"
DIRECT_DOWNLOAD="${DIRECT_DOWNLOAD//,/ }"
DIRECT_ARCHS="${DIRECT_ARCHS//,/ }"
SCREENSHOT_LOCALES="${SCREENSHOT_LOCALES//,/ }"

if [ -n "$WORKSPACE" ]; then CONTAINER=(-workspace "$WORKSPACE")
elif [ -n "$PROJECT" ]; then CONTAINER=(-project "$PROJECT")
else CONTAINER=(); fi
# DERIVED_DATA (environment): where xcodebuild builds, else Xcode's default.
DERIVED=()
[ -n "${DERIVED_DATA:-}" ] && DERIVED=(-derivedDataPath "$DERIVED_DATA")

APPLE=0
case "$PLATFORM" in
  macos) APPLE=1; DESTINATION="generic/platform=macOS"; TEST_DESTINATION="${TEST_DESTINATION:-platform=macOS}" ;;
  ios) APPLE=1; DESTINATION="generic/platform=iOS" ;;
  windows|linux|android) DESTINATION="" ;;
  *) echo "::fail config PLATFORM must be macos, ios, windows, linux or android"; exit 1 ;;
esac

if [ -z "$VERSION" ] && [ ${#CONTAINER[@]} -gt 0 ]; then
  VERSION=$(xcodebuild "${CONTAINER[@]}" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ MARKETING_VERSION = / {print $2; exit}')
fi
VERSION="${VERSION:-1.0}"
BUILD_NUMBER="${ARG_BUILD:-$(git rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M)}"
BASE="${ARG_OUTPUT:-$PROJECT_DIR/build/release/$VERSION}"
mkdir -p "$BASE"
BASE="$(cd "$BASE" && pwd)"
OUT="$BASE/$PLATFORM"
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

# artifact KIND PATH: a file this run made, for Dev and for the bundle and github steps (OUT/artifacts.tsv, one
# "KIND<tab>PATH" line per file; a file made again keeps one line).
artifact() {
  echo "::artifact $1 $PLATFORM $2"
  local list="$OUT/artifacts.tsv"
  touch "$list"
  { grep -v -F "	$2" "$list" || true; printf '%s\t%s\n' "$1" "$2"; } >"$list.new"
  mv "$list.new" "$list"
}

# Every "PLATFORM<tab>KIND<tab>PATH" of every platform in the output folder, kinds filtered by $1 (a regex).
artifacts_of() {
  local list
  for list in "$BASE"/*/artifacts.tsv; do
    [ -f "$list" ] || continue
    awk -F'\t' -v kinds="^($1)\$" -v platform="$(basename "$(dirname "$list")")" \
      '$1 ~ kinds { print platform "\t" $0 }' "$list"
  done
}

apple_only() { [ "$APPLE" = 1 ] || { skip "$1"; return 1; }; }

# ── other machines (Windows and Linux) ───────────────────────────────────

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new)

# The machine that builds this platform: --host, else WINDOWS_HOST / LINUX_HOST.
build_host() {
  HOST="$ARG_HOST"
  if [ -z "$HOST" ]; then
    case "$PLATFORM" in windows) HOST="$WINDOWS_HOST" ;; linux) HOST="$LINUX_HOST" ;; esac
  fi
  [ -n "$HOST" ] || fail "no machine to build $PLATFORM on (--host user@address, or $(echo "$PLATFORM" | tr a-z A-Z)_HOST in release.env)"
}

# The package the other platforms build: PACKAGE_PATH, else the project's App/ package (a v57 app's), else the root.
swift_package() {
  local path="$PACKAGE_PATH"
  if [ -z "$path" ]; then
    if [ -f "$PROJECT_DIR/App/Package.swift" ]; then path=App; else path=.; fi
  fi
  PACKAGE_DIR="$(cd "$PROJECT_DIR/$path" && pwd)"
  [ -f "$PACKAGE_DIR/Package.swift" ] || fail "no Package.swift in $path (PACKAGE_PATH)"
}

# The paths a manifest names packages by: `.package(path: "…")`, and `v57("Name")` with its helper's own prefix
# (`.package(path: "../\(name)")`: "../" or "../../").
manifest_paths() {
  grep -oE '\.package\(path: *"[^"\\]+"' "$1" | sed -E 's/.*"([^"]+)"/\1/' || true
  local prefix
  prefix=$(grep -oE '\.package\(path: *"(\.\./)+\\\(name\)"' "$1" | head -1 | sed -E 's/.*"((\.\.\/)+).*/\1/' || true)
  [ -n "$prefix" ] || return 0
  grep -oE 'v57\("[A-Za-z0-9_-]+"\)' "$1" | sed -E 's/v57\("([^"]+)"\)/\1/' | sort -u | sed "s|^|$prefix|" || true
}

# LOCAL_FOLDERS: the folders the package builds from on this Mac with V57_LOCAL=1: the project, and every package
# its manifests name by path, transitively (`.package(path: "…")`, and `v57("Name")`, the v57 manifests' helper
# for a sibling checkout). A package that is a repository's App/ folder brings its repository.
local_folders() {
  LOCAL_FOLDERS=("$PROJECT_DIR")
  local queue=("$PACKAGE_DIR") seen=" $PACKAGE_DIR " dir manifest prefix path folder
  while [ ${#queue[@]} -gt 0 ]; do
    dir="${queue[0]}"; queue=("${queue[@]:1}")
    manifest="$dir/Package.swift"
    [ -f "$manifest" ] || continue
    local found=()
    while IFS= read -r path; do found+=("$path"); done < <(manifest_paths "$manifest")
    for path in ${found[@]+"${found[@]}"}; do
      [ -d "$dir/$path" ] || continue
      path="$(cd "$dir/$path" && pwd)"
      case "$seen" in *" $path "*) continue ;; esac
      seen="$seen$path "
      queue+=("$path")
      folder="$path"
      [ "$(basename "$path")" = App ] && [ -f "$(dirname "$path")/Package.swift" ] && folder="$(dirname "$path")"
      case " ${LOCAL_FOLDERS[*]} " in *" $folder "*) ;; *) LOCAL_FOLDERS+=("$folder") ;; esac
    done
  done
  # Their common parent: the remote tree mirrors the folders below it, so relative paths resolve there too.
  SOURCE_ROOT="${LOCAL_FOLDERS[0]}"
  for folder in "${LOCAL_FOLDERS[@]}"; do
    until [ "$SOURCE_ROOT" = / ] || case "$folder/" in "$SOURCE_ROOT"/*) true ;; *) false ;; esac; do
      SOURCE_ROOT="$(dirname "$SOURCE_ROOT")"
    done
  done
  SWIFTUI_DIR=""
  for folder in "${LOCAL_FOLDERS[@]}"; do [ "$(basename "$folder")" = SwiftUI ] && SWIFTUI_DIR="$folder"; done
  if [ -n "$SWIFTUI_PATH" ]; then SWIFTUI_DIR="$(cd "$PROJECT_DIR/$SWIFTUI_PATH" && pwd)"; fi
  [ -n "$SWIFTUI_DIR" ] || fail "the package doesn't build from a SwiftUI checkout (v57/SwiftUI's build scripts; SWIFTUI_PATH)"
}

rel() { echo "${1#"$SOURCE_ROOT"/}"; }

# Left behind: version control, build output (rebuilt there, so an incremental build keeps it), editor state.
SYNC_EXCLUDES=(.git .build '.build-*' .claude DerivedData xcuserdata .swiftpm node_modules .gradle graphify-out .DS_Store
  Ports '*.xcworkspace')

# Copies LOCAL_FOLDERS into REMOTE_TREE on HOST: rsync to Linux (a mirror), a tar file to Windows (the folders are
# replaced, their .build folders and their App\.build folders kept).
sync_sources() {
  local count=${#LOCAL_FOLDERS[@]} folder
  echo "copying $count folders to $HOST:$REMOTE_TREE"
  for folder in "${LOCAL_FOLDERS[@]}"; do echo "  $(rel "$folder")"; done
  [ "$DRY_RUN" = 1 ] && return 0
  if [ "$PLATFORM" = linux ]; then
    local excludes=() pattern
    for pattern in "${SYNC_EXCLUDES[@]}"; do excludes+=(--exclude "$pattern"); done
    local dirs=""
    for folder in "${LOCAL_FOLDERS[@]}"; do dirs="$dirs '$REMOTE_TREE/$(rel "$folder")'"; done
    ssh "${SSH_OPTS[@]}" "$HOST" "mkdir -p $dirs" || fail "can't reach $HOST"
    for folder in "${LOCAL_FOLDERS[@]}"; do
      rsync -az --delete "${excludes[@]}" --exclude /build -e "ssh ${SSH_OPTS[*]}" \
        "$folder/" "$HOST:$REMOTE_TREE/$(rel "$folder")/" || fail "copying $(rel "$folder") failed"
    done
  else
    local tarball="$OUT/sources.tar" excludes=() pattern names=() list=""
    for pattern in "${SYNC_EXCLUDES[@]}"; do excludes+=(--exclude "$pattern"); done
    for folder in "${LOCAL_FOLDERS[@]}"; do
      names+=("$(rel "$folder")")
      excludes+=(--exclude "$(rel "$folder")/build")
      list="$list'$(rel "$folder")',"
    done
    COPYFILE_DISABLE=1 tar -C "$SOURCE_ROOT" -cf "$tarball" "${excludes[@]}" "${names[@]}" || fail "packing the sources failed"
    windows_ps "New-Item -ItemType Directory -Force '$REMOTE_TREE' | Out-Null" || fail "can't reach $HOST"
    scp -q "${SSH_OPTS[@]}" "$tarball" "$HOST:${REMOTE_TREE//\\//}/sources.tar" || fail "copying the sources failed"
    rm -f "$tarball"
    windows_ps "\$tree = '$REMOTE_TREE'
foreach (\$name in @(${list%,})) {
  \$dir = Join-Path \$tree \$name
  if (Test-Path \$dir) {
    Get-ChildItem -Force \$dir -Exclude .build,App | Remove-Item -Recurse -Force
    if (Test-Path \"\$dir\\App\") { Get-ChildItem -Force \"\$dir\\App\" -Exclude .build | Remove-Item -Recurse -Force }
  }
}
tar -xf \"\$tree\\sources.tar\" -C \$tree
if (\$LASTEXITCODE -ne 0) { exit 1 }
Remove-Item \"\$tree\\sources.tar\"" || fail "unpacking the sources on $HOST failed"
  fi
}

# Runs a PowerShell script on the Windows host (encoded, so no quoting reaches its shell).
windows_ps() {
  local encoded
  encoded=$(printf '%s' "\$ProgressPreference = 'SilentlyContinue'
$1" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')
  ssh "${SSH_OPTS[@]}" "$HOST" "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
}

# Runs a bash script on the Linux host in a login shell (its PATH has the Swift toolchain), sent base64.
linux_sh() {
  local encoded
  encoded=$(printf '%s' "$1" | base64 | tr -d '\n')
  ssh "${SSH_OPTS[@]}" "$HOST" "echo $encoded | base64 -d | bash -l"
}

# What a remote build shows of its output (all of it is in the log): errors, what it fetches, links and stages.
REMOTE_SHOWN='error:|[Bb]uild complete|^Building |^Staged|^Fetching|^Cloning|^Computing|^Creating working copy|Linking |dev-release-file|^Swift version|^[0-9]+\.[0-9]+\.[0-9]+$'

# remote_run SCRIPT: the platform's script on HOST, its output in OUT/remote-<step>.log, shown as REMOTE_SHOWN keeps
# it (the end of the log when it fails); the files it names on "dev-release-file: PATH" lines come back into OUT.
remote_run() {
  local log="$OUT/remote-$CURRENT.log" status=0
  echo "\$ ($PLATFORM on $HOST)"
  [ "$DRY_RUN" = 1 ] && return 0
  set +e
  # sed -l: line by line, so the log and the shown lines keep up with the build.
  if [ "$PLATFORM" = windows ]; then windows_ps "$1"; else linux_sh "$1"; fi 2>&1 \
    | sed -l -E $'s/\r$//; s/\x1b\\[[0-9;]*m//g' | tee "$log" | grep --line-buffered -E "$REMOTE_SHOWN"
  status=${PIPESTATUS[0]}
  set -e
  if [ "$status" != 0 ]; then
    echo "… the end of the log:"
    tail -40 "$log"
    return "$status"
  fi
  local file name
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    file="${file//\\//}"
    name=$(basename "$file")
    echo "copying $name from $HOST"
    scp -q "${SSH_OPTS[@]}" "$HOST:$file" "$OUT/" || { echo "copying $file failed"; return 1; }
    # Windows' ACLs arrive as odd modes (rw----r-x).
    chmod 644 "$OUT/$name"
    REMOTE_FILES+=("$OUT/$name")
  done < <(sed -n 's/^dev-release-file: //p' "$log")
}

# The VM build of this platform: swift build (build), or the release build packaged (archive).
remote_build() {
  local kind="$1"
  build_host
  swift_package
  local_folders
  local product name="${APP_NAME// /}"
  if [ "$PLATFORM" = windows ]; then
    product="${WINDOWS_PRODUCT:-${name}WinUI}"
    REMOTE_TREE="${WINDOWS_RELEASE_ROOT:-C:\\rel}\\$name"
  else
    product="${LINUX_PRODUCT:-$name}"
    REMOTE_TREE="dev-release/$name"
  fi
  sync_sources
  REMOTE_FILES=()
  local package swiftui
  if [ "$PLATFORM" = windows ]; then
    package="$REMOTE_TREE\\$(rel "$PACKAGE_DIR" | tr / '\\')"
    swiftui="$REMOTE_TREE\\$(rel "$SWIFTUI_DIR" | tr / '\\')"
    if [ "$kind" = build ]; then
      remote_run "\$ErrorActionPreference = 'Stop'
\$env:V57_LOCAL = '1'
swift build --package-path '$package' --product '$product'
exit \$LASTEXITCODE" || fail "the Windows build failed (log: $OUT/remote-$CURRENT.log)"
    else
      # build-app.ps1 stages the app DLL, its DLLs, the Swift runtime and the WinUI host in .build\winui\<product>;
      # the zip holds that folder as <App>\, without the PDBs, and the host takes the app's name as SwiftUI's
      # install-apps.ps1 does: WinUI reads <exe name>.pri, and SwiftUIHost.exe opens no window.
      remote_run "\$ErrorActionPreference = 'Stop'
\$env:V57_LOCAL = '1'
& '$swiftui\\Windows\\scripts\\build-app.ps1' -PackagePath '$package' -Product '$product' -Configuration release
\$arch = if (\$env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
\$out = '$REMOTE_TREE\\out'
if (Test-Path \$out) { Remove-Item -Recurse -Force \$out }
New-Item -ItemType Directory \$out | Out-Null
Copy-Item '$package\\.build\\winui\\$product' \"\$out\\$name\" -Recurse
Get-ChildItem \"\$out\\$name\" -Recurse -Filter *.pdb | Remove-Item -Force
Rename-Item \"\$out\\$name\\SwiftUIHost.exe\" '$name.exe'
Rename-Item \"\$out\\$name\\SwiftUIHost.pri\" '$name.pri'
\$zip = \"\$out\\$name-Windows-\$arch.zip\"
tar.exe -a -c -f \$zip -C \$out '$name'
if (\$LASTEXITCODE -ne 0) { exit 1 }
'dev-release-file: ' + \$zip" || fail "the Windows release build failed (log: $OUT/remote-$CURRENT.log)"
    fi
  else
    package="\$HOME/$REMOTE_TREE/$(rel "$PACKAGE_DIR")"
    swiftui="\$HOME/$REMOTE_TREE/$(rel "$SWIFTUI_DIR")"
    if [ "$kind" = build ]; then
      remote_run "set -e
export V57_LOCAL=1
swift build --package-path \"$package\" --product '$product' -j $LINUX_JOBS" \
        || fail "the Linux build failed (log: $OUT/remote-$CURRENT.log)"
    else
      local static=""
      [ "$LINUX_STATIC" = yes ] && static="--static"
      # build-app stages the executable, its resource bundles, the symbol font, Info.plist and a .desktop file in
      # .build/linux/<product>; the tarball holds that folder as <App>/ (the .desktop file names <App> and points
      # at /opt/<App>).
      remote_run "set -eo pipefail
export V57_LOCAL=1
cd \"$swiftui\"
Linux/scripts/build-app --package \"$package\" -c release $static --jobs $LINUX_JOBS '$product'
case \$(uname -m) in aarch64|arm64) arch=arm64 ;; *) arch=x64 ;; esac
out=\"\$HOME/$REMOTE_TREE/out\"
rm -rf \"\$out\" && mkdir -p \"\$out\"
cp -a \"$package/.build/linux/$product\" \"\$out/$name\"
sed -i -e \"s|$package/.build/linux/$product|/opt/$name|g\" -e \"s|^Name=.*|Name=$name|\" \"\$out/$name\"/*.desktop
tar -czf \"\$out/$name-Linux-\$arch.tar.gz\" -C \"\$out\" '$name'
echo \"dev-release-file: \$out/$name-Linux-\$arch.tar.gz\"" || fail "the Linux release build failed (log: $OUT/remote-$CURRENT.log)"
    fi
  fi
}

# ── steps ────────────────────────────────────────────────────────────────

do_check() {
  step check
  case "$PLATFORM" in
    windows|linux)
      build_host
      swift_package
      local_folders
      echo "builds on $HOST from ${#LOCAL_FOLDERS[@]} folders below $SOURCE_ROOT"
      if [ "$DRY_RUN" = 0 ]; then
        if [ "$PLATFORM" = windows ]; then
          windows_ps 'swift --version | Select-Object -First 1; dotnet --version' || fail "$HOST has no Swift or .NET (or doesn't answer)"
        else
          linux_sh 'swift --version 2>&1 | head -1' || fail "$HOST has no Swift (or doesn't answer)"
        fi
      fi
      done_step
      return ;;
    android)
      swift_package
      [ -n "$ANDROID_KEYSTORE" ] || fail "ANDROID_KEYSTORE is empty: a release-signed APK needs the release key (keytool -genkeypair)"
      [ -f "$ANDROID_KEYSTORE" ] || fail "no keystore at $ANDROID_KEYSTORE"
      done_step
      return ;;
  esac
  command -v xcodebuild >/dev/null || fail "xcodebuild not found"
  xcodebuild -version | sed -n 1p
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    echo "note: the working tree has uncommitted changes; the release builds them"
  fi
  if wants direct && [ "$PLATFORM" = macos ]; then
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
  case "$PLATFORM" in
    windows|linux) remote_build build; done_step; return ;;
    android) skip "the archive step builds Android"; return ;;
  esac
  xcb ${CONTAINER[@]+"${CONTAINER[@]}"} -scheme "$SCHEME" -configuration "$CONFIGURATION" -destination "$DESTINATION" \
    ${DERIVED[@]+"${DERIVED[@]}"} build || fail "the build failed"
  done_step
}

do_test() {
  step test
  apple_only "tests on $PLATFORM run as command steps" || return 0
  [ -n "$TEST_SCHEME" ] || { skip "TEST_SCHEME is empty"; return; }
  [ -n "$TEST_DESTINATION" ] || { skip "TEST_DESTINATION is empty"; return; }
  run rm -rf "$OUT/tests.xcresult"
  xcb ${CONTAINER[@]+"${CONTAINER[@]}"} -scheme "$TEST_SCHEME" -destination "$TEST_DESTINATION" ${DERIVED[@]+"${DERIVED[@]}"} \
    -resultBundlePath "$OUT/tests.xcresult" test || fail "tests failed"
  artifact tests "$OUT/tests.xcresult"
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
  apple_only "screenshots are taken on this Mac (macos or ios)" || return 0
  if [ -f .dev/screenshots.json ]; then
    screenshot_tool
    run "${SHOT_TOOL[@]}" capture --project "$PROJECT_DIR" || fail "some scenes were not captured"
    local output
    output=$(sed -n 's/.*"output" *: *"\([^"]*\)".*/\1/p' .dev/screenshots.json | head -1)
    artifact screenshots "$PROJECT_DIR/${output:-.build/screenshots}"
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
    xcb ${CONTAINER[@]+"${CONTAINER[@]}"} -scheme "$scheme" -destination "$destination" ${DERIVED[@]+"${DERIVED[@]}"} \
      -only-testing "$SCREENSHOT_TEST" -testLanguage "${locale%%-*}" -testRegion "${locale##*-}" \
      -resultBundlePath "$result" test || fail "screenshot tests failed for $locale"
    run xcrun xcresulttool export attachments --path "$result" --output-path "$folder"
    artifact screenshots "$folder"
  done
  done_step
}

# The Developer ID Application identity of TEAM_ID (its hash), else the name codesign looks up.
developer_id() {
  IDENTITY=$(security find-identity -v -p codesigning | awk -v team="($TEAM_ID)" \
    'index($0, "Developer ID Application:") && index($0, team) {print $2; exit}')
  HAS_DEVELOPER_ID=0
  [ -n "$IDENTITY" ] && HAS_DEVELOPER_ID=1
  IDENTITY="${IDENTITY:-Developer ID Application}"
}

# The archive's app exported with Developer ID into OUT/developer-id (EXPORTED_APP). Automatic signing: Xcode makes
# the Developer ID profile an app with iCloud or push needs.
export_developer_id() {
  local export="$OUT/developer-id"
  local options="$OUT/ExportOptions-developer-id.plist"
  cat >"$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
  run rm -rf "$export"
  xcb -exportArchive -archivePath "$ARCHIVE" -exportPath "$export" -exportOptionsPlist "$options" \
    -allowProvisioningUpdates || fail "the Developer ID export failed"
  EXPORTED_APP="$export/$APP_NAME.app"
  [ -d "$EXPORTED_APP" ] || [ "$DRY_RUN" = 1 ] || fail "the export has no $APP_NAME.app"
}

do_archive() {
  step archive
  case "$PLATFORM" in
    windows|linux)
      remote_build archive
      local file
      for file in ${REMOTE_FILES[@]+"${REMOTE_FILES[@]}"}; do artifact package "$file"; done
      done_step
      return ;;
    android) android_archive; done_step; return ;;
  esac
  run rm -rf "$ARCHIVE"
  # macOS: archived through xcodebuild-release, the release link every v57 app ships with (LTO, ld-archive-prelink,
  # actool-icon-slim: unused package code goes, apps 35-50% smaller, the icon's fallbacks as HEVC). Its one copy is
  # Code's CodeActions/Release: Dev passes the copy inside the app as RELEASE_TOOLS, and from a terminal it's the
  # Code checkout beside this Dev repo.
  # Automatic signing makes or renews the team's profiles on the way (iCloud and other capabilities need them).
  local tool=xcodebuild settings=()
  if [ "$PLATFORM" = macos ]; then
    # From a worktree of this repo, the Code checkout beside its main checkout.
    local main
    main="$(dirname "$(git -C "$SCRIPT_REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "$SCRIPT_REPO/.git")")"
    tool="${RELEASE_TOOLS:-$main/../Code/Sources/CodeActions/Release}/xcodebuild-release"
    [ -x "$tool" ] || fail "xcodebuild-release not found at $tool (set RELEASE_TOOLS to Code's Sources/CodeActions/Release)"
    # The build the direct downloads come from (an update check only they have, say).
    if [ -n "$DIRECT_DOWNLOAD" ] && [ -n "$DIRECT_SETTINGS" ]; then settings=("$DIRECT_SETTINGS"); fi
  fi
  XCB_TOOL="$tool" xcb ${CONTAINER[@]+"${CONTAINER[@]}"} -scheme "$SCHEME" -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" ${DERIVED[@]+"${DERIVED[@]}"} -archivePath "$ARCHIVE" -allowProvisioningUpdates \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" ${settings[@]+"${settings[@]}"} archive \
    || fail "the archive failed"
  artifact archive "$ARCHIVE"
  # macOS downloads before notarization: the Developer ID export as <App>.zip and a signed <App>.dmg (direct
  # notarizes and staples them).
  if [ "$PLATFORM" = macos ] && [ -n "$DIRECT_DOWNLOAD" ]; then
    developer_id
    if [ "$HAS_DEVELOPER_ID" = 1 ]; then
      export_developer_id
      package "$EXPORTED_APP" "$APP_NAME" sign
    else
      echo "no Developer ID Application certificate for $TEAM_ID: packaging the archive's app as it is signed"
      package "$ARCHIVE/Products/Applications/$APP_NAME.app" "$APP_NAME"
    fi
  fi
  done_step
}

# Android: the app library cross-compiled and staged into an APK by v57/SwiftUI's Android scripts (never installed:
# --no-install), then signed with the release key. Not verified yet: no app builds for Android, and the release key
# doesn't exist (ANDROID_KEYSTORE, its password in the keychain item ANDROID_KEYCHAIN_ITEM).
android_archive() {
  swift_package
  [ -n "$ANDROID_KEYSTORE" ] || fail "ANDROID_KEYSTORE is empty: a release-signed APK needs the release key"
  local swiftui="${SWIFTUI_PATH:+$PROJECT_DIR/$SWIFTUI_PATH}"
  swiftui="${swiftui:-$PROJECT_DIR/../SwiftUI}"
  [ -x "$swiftui/Android/scripts/build-app" ] || fail "no v57/SwiftUI checkout at $swiftui (SWIFTUI_PATH)"
  local product="${ANDROID_PRODUCT:-${APP_NAME// /}Android}" identifier
  identifier=$(xcodebuild ${CONTAINER[@]+"${CONTAINER[@]}"} -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ PRODUCT_BUNDLE_IDENTIFIER = / {print $2; exit}')
  V57_LOCAL=1 run "$swiftui/Android/scripts/build-app" --package-path "$PACKAGE_DIR" --product "$product" -c release \
    --no-install --app-id "${identifier:-dev.v57.$(echo "$APP_NAME" | tr A-Z a-z)}" --label "$APP_NAME" || fail "the Android build failed"
  local apk
  apk=$(find "$swiftui/Android/demo/build/outputs/apk/release" -name '*.apk' 2>/dev/null | head -1)
  [ -n "$apk" ] || [ "$DRY_RUN" = 1 ] || fail "the Android build made no APK"
  local password
  password=$(security find-generic-password -s "${ANDROID_KEYCHAIN_ITEM:-android-release-key}" -w 2>/dev/null) \
    || fail "no keychain item ${ANDROID_KEYCHAIN_ITEM:-android-release-key} with the keystore's password"
  local apksigner
  apksigner=$(find "${ANDROID_HOME:-$HOME/Library/Android/sdk}/build-tools" -name apksigner | sort | tail -1)
  [ -n "$apksigner" ] || fail "apksigner not found (Android SDK build-tools)"
  run "$apksigner" sign --ks "$ANDROID_KEYSTORE" ${ANDROID_KEY_ALIAS:+--ks-key-alias "$ANDROID_KEY_ALIAS"} \
    --ks-pass "pass:$password" --out "$OUT/$APP_NAME-Android.apk" "$apk" || fail "signing the APK failed"
  artifact package "$OUT/$APP_NAME-Android.apk"
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

# package APP NAME [sign|notarize]: <name>.zip and <name>.dmg of an app; the dmg is signed with Developer ID
# (sign), and also notarized and stapled (notarize).
package() {
  local app="$1" name="$2" seal="${3:-}"
  case " $DIRECT_DOWNLOAD " in *" zip "*)
    run rm -f "$OUT/$name.zip"
    run ditto -c -k --keepParent "$app" "$OUT/$name.zip"
    artifact package "$OUT/$name.zip" ;;
  esac
  case " $DIRECT_DOWNLOAD " in *" dmg "*)
    local stage="$OUT/dmg-$name"
    run rm -rf "$stage" "$OUT/$name.dmg"
    run mkdir -p "$stage"
    run cp -R "$app" "$stage/"
    run ln -s /Applications "$stage/Applications"
    run hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$stage" -ov -format ULFO "$OUT/$name.dmg"
    run rm -rf "$stage"
    if [ -n "$seal" ]; then run codesign --sign "$IDENTITY" --timestamp "$OUT/$name.dmg"; fi
    if [ "$seal" = notarize ]; then
      notarize "$OUT/$name.dmg"
      run xcrun stapler staple "$OUT/$name.dmg"
    fi
    artifact package "$OUT/$name.dmg" ;;
  esac
}

do_direct() {
  step direct
  [ "$PLATFORM" = macos ] || { skip "notarized direct downloads are for macOS apps"; return; }
  [ -d "$ARCHIVE" ] || [ "$DRY_RUN" = 1 ] || fail "no archive at $ARCHIVE (run the archive step)"
  [ -n "$NOTARY_PROFILE" ] || fail "NOTARY_PROFILE is empty (xcrun notarytool store-credentials <name>)"
  developer_id
  export_developer_id
  local app="$EXPORTED_APP"

  # Versionless names keep https://github.com/<repo>/releases/latest/download/<file> stable.
  # With both variants the universal app is <App>, the Apple silicon one <App>-AppleSilicon.
  local thin_name="$APP_NAME"
  case " $DIRECT_ARCHS " in *" universal "*)
    notarize_app "$app"
    package "$app" "$APP_NAME" notarize
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
    package "$thin" "$thin_name" notarize ;;
  esac
  [ "$DRY_RUN" = 1 ] || spctl --assess --type execute --verbose "$app" 2>&1 | sed -n 1,2p
  done_step
}

# A JSON string.
json() {
  local text="${1//\\/\\\\}"
  text="${text//\"/\\\"}"
  printf '"%s"' "${text//	/\\t}"
}

do_bundle() {
  step bundle
  local entries
  entries=$(artifacts_of 'archive|package')
  [ -n "$entries" ] || [ "$DRY_RUN" = 1 ] || fail "no archives or packages in $BASE (run the archive step first)"
  # The result is the folder <name>/ (--no-zip: Dev's Export, which only copies it on this Mac), else <name>.zip.
  local name="$APP_NAME-$VERSION-$BUILD_NUMBER" stage result
  if [ "$NO_ZIP" = 1 ]; then stage="$BASE/$name" result="$BASE/$name"; else stage="$BASE/.bundle" result="$BASE/$name.zip"; fi
  local commit branch dirty=false
  commit=$(git rev-parse "${ARG_COMMIT:-HEAD}" 2>/dev/null || echo "$ARG_COMMIT")
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  [ -n "$(git status --porcelain 2>/dev/null)" ] && dirty=true
  run rm -rf "$stage" "$result"
  [ "$DRY_RUN" = 1 ] && { echo "\$ manifest.json + $(basename "$result")"; done_step; return; }
  mkdir -p "$stage"
  local files="" kind path platform file size sum first=1 done=0 total
  total=$(printf '%s\n' "$entries" | grep -c .)
  [ "$NO_ZIP" = 1 ] || total=$((total + 1))
  while IFS=$'\t' read -r platform kind path; do
    echo "::progress $done $total $platform/$(basename "$path")"
    done=$((done + 1))
    [ -e "$path" ] || { echo "missing, left out: $path"; continue; }
    mkdir -p "$stage/$platform"
    file="$platform/$(basename "$path")"
    sum=null
    if [ -d "$path" ] && [ "$NO_ZIP" = 1 ]; then
      # A folder (an .xcarchive) is cloned (APFS: no space, no time); it has a size but no checksum.
      cp -cR "$path" "$stage/$file" 2>/dev/null || cp -R "$path" "$stage/$file"
      size=$(find "$stage/$file" -type f -exec stat -f %z {} + | awk '{s += $1} END {print s + 0}')
    else
      if [ -d "$path" ]; then
        # In the zip a folder travels zipped, so it has one checksum.
        file="$file.zip"
        ditto -c -k --norsrc --noextattr --noqtn --keepParent "$path" "$stage/$file"
      else
        # Files are linked in, not copied.
        ln "$path" "$stage/$file" 2>/dev/null || cp "$path" "$stage/$file"
      fi
      size=$(stat -f %z "$stage/$file")
      sum="\"$(shasum -a 256 "$stage/$file" | awk '{print $1}')\""
    fi
    echo "  $file  $size bytes  sha256 ${sum//\"/}"
    [ $first = 1 ] || files="$files,"
    first=0
    files="$files
    {\"platform\": $(json "$platform"), \"kind\": $(json "$kind"), \"path\": $(json "$file"), \"size\": $size, \"sha256\": $sum}"
  done <<<"$entries"
  cat >"$stage/manifest.json" <<JSON
{
  "format": 1,
  "app": $(json "$APP_NAME"),
  "version": $(json "$VERSION"),
  "build": $BUILD_NUMBER,
  "commit": $(json "$commit"),
  "branch": $(json "$branch"),
  "dirty": $dirty,
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "bundle": $(json "$(basename "$result")"),
  "artifacts": [$files
  ]
}
JSON
  cp "$stage/manifest.json" "$BASE/manifest.json"
  if [ "$NO_ZIP" != 1 ]; then
    echo "::progress $done $total $name.zip"
    # Its parts are compressed already: stored, not compressed again. No `._` files for extended attributes, which
    # Windows and Linux would unpack as clutter.
    ditto -c -k --norsrc --noextattr --noqtn --zlibCompressionLevel 0 "$stage" "$result" || fail "zipping the bundle failed"
    rm -rf "$stage"
  fi
  PLATFORM=all
  echo "::artifact manifest all $BASE/manifest.json"
  echo "::artifact bundle all $result"
  echo "$(basename "$result"): $(du -sh "$result" | awk '{print $1}')"
  done_step
}

do_github() {
  step github
  [ -n "$GITHUB_REPO" ] || { skip "GITHUB_REPO is empty"; return; }
  # Every platform's download files in the output folder.
  local files=() platform kind path
  while IFS=$'\t' read -r platform kind path; do
    [ -f "$path" ] && files+=("$path")
  done < <(artifacts_of package)
  [ ${#files[@]} -gt 0 ] || [ "$DRY_RUN" = 1 ] || fail "no download files in $BASE (run the archive and direct steps)"
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
  apple_only "App Store Connect takes macOS and iOS archives" || return 0
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

# Google Play: the Play Developer API's edits (upload an .aab to GOOGLE_PLAY_TRACK, commit) with a service account
# key. A slot for now: Android ships as APKs on GitHub first.
do_googleplay() {
  step googleplay
  [ "$GOOGLE_PLAY" = yes ] || { skip "GOOGLE_PLAY is not yes"; return; }
  [ "$PLATFORM" = android ] || { skip "Google Play takes Android builds"; return; }
  [ -n "$GOOGLE_PLAY_KEY_PATH" ] || fail "GOOGLE_PLAY_KEY_PATH is empty (a Play Console service account key)"
  fail "the Google Play upload isn't built yet (needs an .aab and the Play Developer API, track $GOOGLE_PLAY_TRACK)"
}

# Microsoft Store: a Partner Center submission (MSIX package) for MS_STORE_APP_ID. A slot for now: Windows ships
# as a zip on GitHub first.
do_msstore() {
  step msstore
  [ "$MS_STORE" = yes ] || { skip "MS_STORE is not yes"; return; }
  [ "$PLATFORM" = windows ] || { skip "the Microsoft Store takes Windows builds"; return; }
  [ -n "$MS_STORE_APP_ID" ] || fail "MS_STORE_APP_ID is empty (the app's Store ID in Partner Center)"
  fail "the Microsoft Store submission isn't built yet (needs an MSIX package and the Partner Center API)"
}

wants() { case " $STEPS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

for name in $STEPS_ALL; do
  if wants "$name"; then "do_$name"; fi
done
echo
echo "::finished $VERSION"
