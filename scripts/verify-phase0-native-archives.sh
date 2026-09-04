#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK_FILE="$REPO_ROOT/config/dependencies/freerdp.lock"

# shellcheck disable=SC1090
source "$LOCK_FILE"

RELEASE_ARCHIVE="${1:-}"
SYMBOL_AUDIT_ARCHIVE="${2:-}"
APP_NAME="Phase0HarnessNative.app"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    "Usage: $0 RELEASE.xcarchive SYMBOL_AUDIT.xcarchive" \
    "Verify the unsigned Phase 0 distribution-shaped and symbol-audit archives."
}

[[ -n "$RELEASE_ARCHIVE" && -n "$SYMBOL_AUDIT_ARCHIVE" ]] || {
  usage >&2
  exit 2
}
[[ -n "${IOS_DEPLOYMENT_TARGET:-}" ]] || die "IOS_DEPLOYMENT_TARGET missing from lock"

for command_name in file otool plutil rg xcrun; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

archive_executable() {
  local archive="$1"
  local app="$archive/Products/Applications/$APP_NAME"
  local executable_name
  [[ -d "$app" ]] || die "application missing from archive: $app"
  [[ -f "$app/Info.plist" ]] || die "Info.plist missing from archive: $app"
  executable_name="$(plutil -extract CFBundleExecutable raw -o - "$app/Info.plist")"
  [[ -n "$executable_name" && -f "$app/$executable_name" ]] ||
    die "application executable missing from archive: $archive"
  printf '%s\n' "$app/$executable_name"
}

verify_archive_shape() {
  local archive="$1"
  local executable="$2"
  local scan_release_paths="$3"
  local app="${executable%/*}"
  local build_info
  local dependency
  local forbidden
  local minimum_os
  local packaged_file
  local packaged_type

  [[ "$(xcrun lipo -archs "$executable")" == "arm64" ]] ||
    die "archive executable is not arm64-only: $executable"
  file "$executable" | rg -q 'Mach-O 64-bit executable arm64' ||
    die "archive product is not an arm64 Mach-O executable: $executable"
  build_info="$(xcrun vtool -show-build "$executable")"
  rg -q '^[[:space:]]*platform[[:space:]]+IOS[[:space:]]*$' <<<"$build_info" ||
    die "archive executable is not built for iOS: $executable"
  rg -q "^[[:space:]]*minos[[:space:]]+$IOS_DEPLOYMENT_TARGET[[:space:]]*$" \
    <<<"$build_info" ||
    die "archive minimum OS does not match $IOS_DEPLOYMENT_TARGET: $executable"
  minimum_os="$(plutil -extract MinimumOSVersion raw -o - "$app/Info.plist")"
  [[ "$minimum_os" == "$IOS_DEPLOYMENT_TARGET" ]] ||
    die "Info.plist MinimumOSVersion is $minimum_os, expected $IOS_DEPLOYMENT_TARGET"
  [[ -n "$(plutil -extract NSLocalNetworkUsageDescription raw -o - "$app/Info.plist")" ]] ||
    die "Local Network usage description is missing"

  while IFS= read -r dependency; do
    case "$dependency" in
      /System/Library/PrivateFrameworks/*)
        die "private framework dependency: $dependency ($executable)"
        ;;
      /System/Library/Frameworks/*|/usr/lib/libobjc.A.dylib|\
      /usr/lib/libSystem.B.dylib|/usr/lib/swift/*.dylib) ;;
      *) die "non-system dynamic dependency: $dependency ($executable)" ;;
    esac
  done < <(otool -L "$executable" | tail -n +2 | awk '{print $1}')

  while IFS= read -r -d '' packaged_file; do
    [[ "$packaged_file" == "$executable" ]] && continue
    packaged_type="$(file -b "$packaged_file")"
    [[ "$packaged_type" != *Mach-O* ]] ||
      die "additional Mach-O packaged in application: $packaged_file"
  done < <(find "$app" -type f -print0)
  while IFS= read -r -d '' packaged_file; do
    die "dynamic code container packaged in application: $packaged_file"
  done < <(find "$app" -type d \
    \( -name Frameworks -o -name PlugIns -o -name '*.framework' \
       -o -name '*.appex' -o -name '*.xpc' -o -name '*.bundle' \) -print0)

  if [[ "$scan_release_paths" == "1" ]]; then
    for forbidden in "$REPO_ROOT" '/Users/' '/private/tmp/' '/private/var/folders/'; do
      if LC_ALL=C rg -aFq -- "$forbidden" "$executable"; then
        die "host/build path remains in distribution executable: $forbidden"
      fi
    done
  fi
}

RELEASE_EXECUTABLE="$(archive_executable "$RELEASE_ARCHIVE")"
SYMBOL_AUDIT_EXECUTABLE="$(archive_executable "$SYMBOL_AUDIT_ARCHIVE")"
RELEASE_DSYM="$RELEASE_ARCHIVE/dSYMs/Phase0HarnessNative.app.dSYM/Contents/Resources/DWARF/Phase0HarnessNative"

[[ -f "$RELEASE_DSYM" ]] || die "Release dSYM executable missing: $RELEASE_DSYM"
verify_archive_shape "$RELEASE_ARCHIVE" "$RELEASE_EXECUTABLE" 1
# SymbolAudit intentionally retains local paths to make static symbols auditable.
verify_archive_shape "$SYMBOL_AUDIT_ARCHIVE" "$SYMBOL_AUDIT_EXECUTABLE" 0

mach_uuid() {
  xcrun dwarfdump --uuid "$1" | awk '$1 == "UUID:" { print $2 " " $3 }'
}

RELEASE_UUID="$(mach_uuid "$RELEASE_EXECUTABLE")"
RELEASE_DSYM_UUID="$(mach_uuid "$RELEASE_DSYM")"
SYMBOL_AUDIT_UUID="$(mach_uuid "$SYMBOL_AUDIT_EXECUTABLE")"
[[ -n "$RELEASE_UUID" && "$RELEASE_UUID" == "$RELEASE_DSYM_UUID" ]] ||
  die "Release executable and dSYM UUIDs do not match"
[[ -n "$SYMBOL_AUDIT_UUID" && "$RELEASE_UUID" != "$SYMBOL_AUDIT_UUID" ]] ||
  die "Release and SymbolAudit executables are not distinct builds"

release_exported_names="$(xcrun nm -gU "$RELEASE_EXECUTABLE" | awk 'NF >= 3 { print $NF }')"
[[ "$release_exported_names" == '__mh_execute_header' ]] ||
  die "Release executable is not distribution-stripped"

required_release_symbols=(
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
  mr_rdp_session_send_key
  mr_rdp_session_send_pointer
  mr_rdp_session_start_clipboard_probe
  mr_rdp_session_request_display_resize
  mr_rdp_session_destroy
  cliprdr_VirtualChannelEntryEx
  rdpsnd_VirtualChannelEntryEx
  rdpsnd_DVCPluginEntry
  rdpdr_VirtualChannelEntryEx
  drdynvc_VirtualChannelEntryEx
  disp_DVCPluginEntry
  rdpgfx_DVCPluginEntry
  ios_freerdp_rdpsnd_client_subsystem_entry
)

required_symbol_audit_symbols=(
  "${required_release_symbols[@]}"
  mr_rdp_session_cancel_challenge
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

release_symbols="$(xcrun nm -U "$RELEASE_DSYM")"
symbol_audit_symbols="$(xcrun nm -U "$SYMBOL_AUDIT_EXECUTABLE")"
for symbol in "${required_release_symbols[@]}"; do
  rg -q "[[:space:]]_$symbol$" <<<"$release_symbols" ||
    die "required symbol missing from Release dSYM: $symbol"
done
for symbol in "${required_symbol_audit_symbols[@]}"; do
  rg -q "[[:space:]]_$symbol$" <<<"$symbol_audit_symbols" ||
    die "required symbol missing from SymbolAudit executable: $symbol"
done

printf 'verified Release archive: %s\n' "$RELEASE_ARCHIVE"
printf 'verified SymbolAudit archive: %s\n' "$SYMBOL_AUDIT_ARCHIVE"
printf 'shape: arm64, iOS minimum %s, system-only dynamic dependencies, no plugin bundle\n' \
  "$IOS_DEPLOYMENT_TARGET"
printf 'symbols: stripped Release+dSYM used surface/add-ins; SymbolAudit full public bridge surface\n'
printf 'scope: unsigned static/archive inspection only; private-API/App Store and physical-device evidence are not covered\n'
