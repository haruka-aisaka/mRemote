#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK_FILE="$REPO_ROOT/config/dependencies/freerdp.lock"

# shellcheck disable=SC1090
source "$LOCK_FILE"

BRIDGE_XCFRAMEWORK="${1:-$REPO_ROOT/artifacts/mRemoteRDPBridge.xcframework}"
FREERDP_XCFRAMEWORK="${2:-$REPO_ROOT/artifacts/$XCFRAMEWORK_NAME}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

for path in "$BRIDGE_XCFRAMEWORK" "$FREERDP_XCFRAMEWORK"; do
  [[ -d "$path" ]] || die "XCFramework not found: $path"
  [[ -f "$path/Info.plist" ]] || die "Info.plist not found: $path"
done
for command_name in file plutil xcrun; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

library_count="$(plutil -extract AvailableLibraries raw -o - "$BRIDGE_XCFRAMEWORK/Info.plist")"
[[ "$library_count" == "2" ]] || die "expected exactly 2 bridge slices, got $library_count"

required_bridge_symbols=(
  mr_rdp_config_init
  mr_rdp_callbacks_init
  mr_rdp_key_event_init
  mr_rdp_pointer_event_init
  mr_rdp_clipboard_probe_init
  mr_rdp_display_resize_request_init
  mr_rdp_session_create
  mr_rdp_session_run
  mr_rdp_session_request_stop
  mr_rdp_session_respond_certificate
  mr_rdp_session_cancel_challenge
  mr_rdp_session_send_key
  mr_rdp_session_send_pointer
  mr_rdp_session_start_clipboard_probe
  mr_rdp_session_request_display_resize
  mr_rdp_session_destroy
  mr_rdp_status_name
  mr_rdpsnd_format_init
  mr_rdpsnd_config_init
  mr_rdpsnd_callbacks_init
  mr_rdpsnd_format_supported
  mr_rdpsnd_device_create
  mr_rdpsnd_device_open
  mr_rdpsnd_device_set_format
  mr_rdpsnd_device_set_focused
  mr_rdpsnd_device_play
  mr_rdpsnd_device_close
  mr_rdpsnd_device_free
)

required_linked_addins=(
  cliprdr_VirtualChannelEntryEx
  rdpsnd_VirtualChannelEntryEx
  rdpsnd_DVCPluginEntry
  rdpdr_VirtualChannelEntryEx
  drdynvc_VirtualChannelEntryEx
  disp_DVCPluginEntry
  rdpgfx_DVCPluginEntry
  rdpei_DVCPluginEntry
  drive_DeviceServiceEntry
  audin_DVCPluginEntry
  rail_VirtualChannelEntryEx
  ios_freerdp_rdpsnd_client_subsystem_entry
)

device_count=0
simulator_count=0

for index in 0 1; do
  identifier="$(plutil -extract "AvailableLibraries.$index.LibraryIdentifier" raw -o - \
    "$BRIDGE_XCFRAMEWORK/Info.plist")"
  library_path="$(plutil -extract "AvailableLibraries.$index.LibraryPath" raw -o - \
    "$BRIDGE_XCFRAMEWORK/Info.plist")"
  headers_path="$(plutil -extract "AvailableLibraries.$index.HeadersPath" raw -o - \
    "$BRIDGE_XCFRAMEWORK/Info.plist")"
  platform="$(plutil -extract "AvailableLibraries.$index.SupportedPlatform" raw -o - \
    "$BRIDGE_XCFRAMEWORK/Info.plist")"
  architecture="$(plutil -extract \
    "AvailableLibraries.$index.SupportedArchitectures.0" raw -o - \
    "$BRIDGE_XCFRAMEWORK/Info.plist")"
  variant="$(plutil -extract "AvailableLibraries.$index.SupportedPlatformVariant" raw -o - \
    "$BRIDGE_XCFRAMEWORK/Info.plist" 2>/dev/null || true)"
  archive="$BRIDGE_XCFRAMEWORK/$identifier/$library_path"
  headers="$BRIDGE_XCFRAMEWORK/$identifier/$headers_path"
  freerdp_archive="$FREERDP_XCFRAMEWORK/$identifier/libmremote-freerdp.a"
  freerdp_headers="$FREERDP_XCFRAMEWORK/$identifier/Headers"

  [[ "$platform" == "ios" ]] || die "bridge slice $identifier is not iOS"
  [[ "$architecture" == "arm64" ]] || die "bridge slice $identifier is not arm64"
  [[ -f "$archive" ]] || die "bridge archive missing: $archive"
  [[ -f "$headers/mremote/rdp_bridge.h" ]] || die "bridge header missing in $identifier"
  [[ -f "$headers/mremote/rdpsnd.h" ]] || die "rdpsnd header missing in $identifier"
  [[ -f "$freerdp_archive" ]] || die "matching FreeRDP archive missing for $identifier"
  [[ -f "$freerdp_headers/freerdp/freerdp.h" ]] ||
    die "matching FreeRDP headers missing for $identifier"
  [[ "$(xcrun lipo -archs "$archive")" == "arm64" ]] ||
    die "bridge archive is not arm64: $archive"
  file "$archive" | grep -q 'current ar archive' || die "bridge slice is not static: $archive"

  if [[ "$variant" == "simulator" ]]; then
    ((simulator_count += 1))
    sdk="iphonesimulator"
    target="arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator"
  elif [[ -z "$variant" ]]; then
    ((device_count += 1))
    sdk="iphoneos"
    target="arm64-apple-ios${IOS_DEPLOYMENT_TARGET}"
  else
    die "unsupported platform variant in $identifier: $variant"
  fi

  printf '%s\n' \
    '#include <mremote/rdp_bridge.h>' \
    '#include <mremote/rdpsnd.h>' |
    xcrun --sdk "$sdk" clang -target "$target" -fsyntax-only -x c -I "$headers" -

  symbols="$(xcrun nm -g "$archive")"
  for symbol in "${required_bridge_symbols[@]}"; do
    grep -Eq "[[:space:]]_${symbol}$" <<<"$symbols" ||
      die "required bridge symbol missing: $symbol ($identifier)"
  done
  grep -Eq '(^|[[:space:]])_freerdp_connect$' <<<"$(xcrun nm -u "$archive")" ||
    die "bridge slice does not reference the FreeRDP backend: $identifier"

  link_output="$(mktemp "/tmp/mremote-rdp-bridge-link-${sdk}.XXXXXX")"
  trap 'rm -f "$link_output"' EXIT
  printf '%s\n' \
    '#include <mremote/rdp_bridge.h>' \
    'int main(void) {' \
    '  mr_rdp_config config;' \
    '  mr_rdp_config_init(&config);' \
    '  return (int)mr_rdp_session_create(&config, 0, 0, 0);' \
    '}' |
    xcrun --sdk "$sdk" clang -target "$target" \
      -Wno-deprecated-declarations \
      -I "$headers" -I "$freerdp_headers" \
      -x c - -x none "$archive" "$freerdp_archive" \
      -framework Foundation -framework AudioToolbox -framework AVFoundation \
      -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
      -o "$link_output"

  linked_symbols="$(xcrun nm "$link_output")"
  for symbol in "${required_linked_addins[@]}"; do
    grep -Eq "[[:space:]]_${symbol}$" <<<"$linked_symbols" ||
      die "static add-in was not retained by the real bridge link: $symbol ($identifier)"
  done
  rm -f "$link_output"
  trap - EXIT
done

[[ "$device_count" == "1" ]] || die "expected one bridge device slice"
[[ "$simulator_count" == "1" ]] || die "expected one bridge simulator slice"

if find "$BRIDGE_XCFRAMEWORK" -type f \
  \( -name '*.dylib' -o -name '*.so' -o -name '*.bundle' \) -print | grep -q .; then
  die "dynamic library/plugin found in bridge XCFramework"
fi

printf 'verified: %s\n' "$BRIDGE_XCFRAMEWORK"
printf 'slices: ios-arm64, ios-arm64-simulator\n'
printf 'backend: pinned FreeRDP adapter (separate FreeRDP XCFramework)\n'
printf 'link smoke: bridge + FreeRDP + retained static channel table/add-ins\n'
