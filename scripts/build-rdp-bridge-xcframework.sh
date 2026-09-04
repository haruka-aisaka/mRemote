#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK_FILE="$REPO_ROOT/config/dependencies/freerdp.lock"

# shellcheck disable=SC1090
source "$LOCK_FILE"

FREERDP_XCFRAMEWORK="$REPO_ROOT/artifacts/$XCFRAMEWORK_NAME"
BRIDGE_XCFRAMEWORK_NAME="mRemoteRDPBridge.xcframework"
BUILD_ROOT="$REPO_ROOT/.build/rdp-bridge"
OUTPUT_PATH="$REPO_ROOT/artifacts/$BRIDGE_XCFRAMEWORK_NAME"
DRY_RUN=0

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[rdp-bridge-build] %s\n' "$*"
}

usage() {
  sed -n 's/^#> //p' "$0"
}

#> Usage: scripts/build-rdp-bridge-xcframework.sh [options]
#>
#> Build the FreeRDP-backed C ABI as a two-slice static XCFramework. FreeRDP
#> remains a separate XCFramework and must be linked by the final app.
#>
#> Options:
#>   --freerdp-xcframework PATH  Use this generated FreeRDP XCFramework.
#>   --build-root PATH           Put intermediate objects under PATH.
#>   --output PATH               Write the bridge XCFramework to PATH.
#>   --dry-run                   Validate arguments and print the build plan.
#>   -h, --help                  Show this help.

while (($#)); do
  case "$1" in
    --freerdp-xcframework)
      (($# >= 2)) || die "--freerdp-xcframework requires a path"
      FREERDP_XCFRAMEWORK="$2"
      shift 2
      ;;
    --build-root)
      (($# >= 2)) || die "--build-root requires a path"
      BUILD_ROOT="$2"
      shift 2
      ;;
    --output)
      (($# >= 2)) || die "--output requires a path"
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ -n "${IOS_DEPLOYMENT_TARGET:-}" ]] || die "IOS_DEPLOYMENT_TARGET is missing from lock"
[[ "$IOS_DEPLOYMENT_TARGET" =~ ^[0-9]+([.][0-9]+)*$ ]] ||
  die "invalid IOS_DEPLOYMENT_TARGET: $IOS_DEPLOYMENT_TARGET"
[[ -d "$FREERDP_XCFRAMEWORK" ]] ||
  die "FreeRDP XCFramework not found: $FREERDP_XCFRAMEWORK"
[[ -f "$FREERDP_XCFRAMEWORK/Info.plist" ]] || die "FreeRDP Info.plist not found"

for command_name in file plutil shasum xcodebuild xcrun; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done
[[ -x /usr/bin/libtool ]] || die "Apple /usr/bin/libtool is required"
[[ -x /usr/libexec/PlistBuddy ]] || die "PlistBuddy is required"

printf '%s\n' \
  "deployment target=iOS $IOS_DEPLOYMENT_TARGET" \
  "slice=device:arm64" \
  "slice=simulator:arm64" \
  "backend=FreeRDP $FREERDP_VERSION" \
  "FreeRDP XCFramework=$FREERDP_XCFRAMEWORK" \
  "build root=$BUILD_ROOT" \
  "output=$OUTPUT_PATH"

if ((DRY_RUN)); then
  exit 0
fi

[[ ! -e "$OUTPUT_PATH" ]] || die "output already exists; choose a fresh --output path: $OUTPUT_PATH"
mkdir -p "$BUILD_ROOT/device" "$BUILD_ROOT/simulator" "$(dirname "$OUTPUT_PATH")"

build_slice() {
  local slice="$1"
  local identifier="$2"
  local sdk="$3"
  local target="$4"
  local slice_root="$BUILD_ROOT/$slice"
  local freerdp_slice="$FREERDP_XCFRAMEWORK/$identifier"
  local headers="$freerdp_slice/Headers"
  local archive="$freerdp_slice/libmremote-freerdp.a"
  local sdk_path
  local source
  local object
  local objects=()

  [[ -f "$archive" ]] || die "FreeRDP archive missing for $slice: $archive"
  [[ -f "$headers/freerdp/freerdp.h" ]] || die "FreeRDP headers missing for $slice"
  [[ -f "$headers/winpr/wtypes.h" ]] || die "WinPR headers missing for $slice"
  [[ -f "$headers/openssl/x509.h" ]] || die "OpenSSL headers missing for $slice"
  [[ "$(xcrun lipo -archs "$archive")" == "arm64" ]] ||
    die "FreeRDP archive is not arm64 for $slice"

  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  for source in \
    rdp_bridge.c \
    rdpsnd.c \
    certificate_chain.c \
    control_deadline.c \
    input_command_queue.c \
    freerdp_backend.c; do
    object="$slice_root/${source%.c}.o"
    xcrun --sdk "$sdk" clang \
      -target "$target" \
      -isysroot "$sdk_path" \
      -std=c11 -O2 -DNDEBUG -fno-common \
      -ffile-prefix-map="$REPO_ROOT=/usr/src/mRemote" \
      -Wall -Wextra -Wpedantic -Werror \
      -I "$REPO_ROOT/bridge/include" \
      -I "$REPO_ROOT/bridge/src" \
      -isystem "$headers" \
      -c "$REPO_ROOT/bridge/src/$source" \
      -o "$object"
    objects+=("$object")
  done

  /usr/bin/libtool -static -D \
    -o "$slice_root/libmRemoteRDPBridge.a" \
    "${objects[@]}"
  [[ "$(xcrun lipo -archs "$slice_root/libmRemoteRDPBridge.a")" == "arm64" ]] ||
    die "bridge archive is not arm64 for $slice"
}

build_slice \
  device ios-arm64 iphoneos \
  "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}"
build_slice \
  simulator ios-arm64-simulator iphonesimulator \
  "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator"

log "creating $BRIDGE_XCFRAMEWORK_NAME"
xcodebuild -create-xcframework \
  -library "$BUILD_ROOT/device/libmRemoteRDPBridge.a" \
  -headers "$REPO_ROOT/bridge/include" \
  -library "$BUILD_ROOT/simulator/libmRemoteRDPBridge.a" \
  -headers "$REPO_ROOT/bridge/include" \
  -output "$OUTPUT_PATH"

# Keep deterministic device-then-simulator metadata ordering across Xcode
# versions, matching the pinned FreeRDP artifact.
first_identifier="$(/usr/libexec/PlistBuddy \
  -c 'Print :AvailableLibraries:0:LibraryIdentifier' "$OUTPUT_PATH/Info.plist")"
case "$first_identifier" in
  ios-arm64)
    ;;
  ios-arm64-simulator)
    /usr/libexec/PlistBuddy \
      -c 'Copy :AvailableLibraries:0 :MRemoteSimulatorLibrary' "$OUTPUT_PATH/Info.plist"
    /usr/libexec/PlistBuddy \
      -c 'Delete :AvailableLibraries:0' "$OUTPUT_PATH/Info.plist"
    /usr/libexec/PlistBuddy \
      -c 'Copy :MRemoteSimulatorLibrary :AvailableLibraries:1' "$OUTPUT_PATH/Info.plist"
    /usr/libexec/PlistBuddy \
      -c 'Delete :MRemoteSimulatorLibrary' "$OUTPUT_PATH/Info.plist"
    ;;
  *)
    die "unexpected first XCFramework slice: $first_identifier"
    ;;
esac

assert_no_host_paths() {
  local artifact="$1"
  local build_root_path
  local forbidden
  local match

  build_root_path="$(cd "$BUILD_ROOT" && pwd -P)"
  for forbidden in \
    "$REPO_ROOT" \
    "$build_root_path" \
    '/Users/' \
    '/private/tmp/' \
    '/private/var/folders/'; do
    match="$(LC_ALL=C grep -R -a -F -l -- "$forbidden" "$artifact" 2>/dev/null |
      head -n 1 || true)"
    [[ -z "$match" ]] ||
      die "host/build path remains in bridge artifact: $forbidden ($match)"
  done
}

assert_no_host_paths "$OUTPUT_PATH"

"$SCRIPT_DIR/verify-rdp-bridge-xcframework.sh" \
  "$OUTPUT_PATH" "$FREERDP_XCFRAMEWORK"

checksum_file="$(dirname "$OUTPUT_PATH")/$(basename "$OUTPUT_PATH").sha256"
(
  cd "$(dirname "$OUTPUT_PATH")"
  find "$(basename "$OUTPUT_PATH")" -type f -print | LC_ALL=C sort |
    while IFS= read -r file_path; do
      shasum -a 256 "$file_path"
    done
) > "$checksum_file"

log "build complete: $OUTPUT_PATH"
log "checksums: $checksum_file"
