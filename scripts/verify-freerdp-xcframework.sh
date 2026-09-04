#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK_FILE="$REPO_ROOT/config/dependencies/freerdp.lock"
# shellcheck disable=SC1090
source "$LOCK_FILE"

XCFRAMEWORK_PATH="${1:-$REPO_ROOT/artifacts/$XCFRAMEWORK_NAME}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ -d "$XCFRAMEWORK_PATH" ]] || die "XCFramework not found: $XCFRAMEWORK_PATH"
[[ -f "$XCFRAMEWORK_PATH/Info.plist" ]] || die "Info.plist not found"
command -v plutil >/dev/null 2>&1 || die "plutil is required"
command -v xcrun >/dev/null 2>&1 || die "xcrun is required"
command -v grep >/dev/null 2>&1 || die "grep is required"

library_count="$(plutil -extract AvailableLibraries raw -o - "$XCFRAMEWORK_PATH/Info.plist")"
[[ "$library_count" == "2" ]] || die "expected exactly 2 slices, got $library_count"

# The build normalizes this order because xcodebuild may emit the same two
# slices in either order, which would make otherwise identical output differ.
first_identifier="$(plutil -extract AvailableLibraries.0.LibraryIdentifier raw -o - "$XCFRAMEWORK_PATH/Info.plist")"
second_identifier="$(plutil -extract AvailableLibraries.1.LibraryIdentifier raw -o - "$XCFRAMEWORK_PATH/Info.plist")"
[[ "$first_identifier" == "ios-arm64" ]] ||
  die "device slice must be first in Info.plist (got $first_identifier)"
[[ "$second_identifier" == "ios-arm64-simulator" ]] ||
  die "simulator slice must be second in Info.plist (got $second_identifier)"

device_count=0
simulator_count=0

required_symbols=(
  cliprdr_VirtualChannelEntryEx
  rdpsnd_VirtualChannelEntryEx
  rdpsnd_DVCPluginEntry
  rdpdr_VirtualChannelEntryEx
  drdynvc_VirtualChannelEntryEx
  disp_DVCPluginEntry
  rdpgfx_DVCPluginEntry
  ios_freerdp_rdpsnd_client_subsystem_entry
  fake_freerdp_rdpsnd_client_subsystem_entry
)

forbidden_audio_symbols=(
  alsa_freerdp_rdpsnd_client_subsystem_entry
  mac_freerdp_rdpsnd_client_subsystem_entry
  opensles_freerdp_rdpsnd_client_subsystem_entry
  oss_freerdp_rdpsnd_client_subsystem_entry
  pulse_freerdp_rdpsnd_client_subsystem_entry
  sndio_freerdp_rdpsnd_client_subsystem_entry
  winmm_freerdp_rdpsnd_client_subsystem_entry
)

for index in 0 1; do
  identifier="$(plutil -extract "AvailableLibraries.$index.LibraryIdentifier" raw -o - "$XCFRAMEWORK_PATH/Info.plist")"
  library_path="$(plutil -extract "AvailableLibraries.$index.LibraryPath" raw -o - "$XCFRAMEWORK_PATH/Info.plist")"
  platform="$(plutil -extract "AvailableLibraries.$index.SupportedPlatform" raw -o - "$XCFRAMEWORK_PATH/Info.plist")"
  architecture="$(plutil -extract "AvailableLibraries.$index.SupportedArchitectures.0" raw -o - "$XCFRAMEWORK_PATH/Info.plist")"
  headers_path="$(plutil -extract "AvailableLibraries.$index.HeadersPath" raw -o - "$XCFRAMEWORK_PATH/Info.plist")"
  variant="$(plutil -extract "AvailableLibraries.$index.SupportedPlatformVariant" raw -o - "$XCFRAMEWORK_PATH/Info.plist" 2>/dev/null || true)"
  archive="$XCFRAMEWORK_PATH/$identifier/$library_path"
  headers_dir="$XCFRAMEWORK_PATH/$identifier/$headers_path"

  [[ "$platform" == "ios" ]] || die "slice $identifier is not an iOS slice"
  [[ "$architecture" == "arm64" ]] || die "slice $identifier is not arm64"
  [[ -f "$archive" ]] || die "slice archive missing: $archive"
  [[ -f "$headers_dir/freerdp/freerdp.h" ]] || die "FreeRDP public header missing in $identifier"
  [[ -f "$headers_dir/winpr/wtypes.h" ]] || die "WinPR public header missing in $identifier"
  [[ -f "$headers_dir/openssl/ssl.h" ]] || die "OpenSSL public header missing in $identifier"
  grep -Fq '#define WINPR_INSTALL_PREFIX "/usr/local"' "$headers_dir/winpr/build-config.h" ||
    die "WinPR install prefix is not reproducible in $identifier"
  grep -Fq '#define WINPR_INSTALL_SYSCONFDIR "/usr/local/etc"' "$headers_dir/winpr/build-config.h" ||
    die "WinPR sysconf prefix is not reproducible in $identifier"
  [[ "$(xcrun lipo -archs "$archive")" == "arm64" ]] || die "archive is not arm64: $archive"
  file "$archive" | grep -q 'current ar archive' || die "slice is not a static archive: $archive"

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
    '#include <freerdp/freerdp.h>' \
    '#include <winpr/wtypes.h>' \
    '#include <openssl/ssl.h>' |
    xcrun --sdk "$sdk" clang -target "$target" -fsyntax-only -x c -I "$headers_dir" -

  symbols="$(xcrun nm -gU "$archive")"
  for symbol in "${required_symbols[@]}"; do
    grep -Eq "[[:space:]]_${symbol}$" <<<"$symbols" || die "required static symbol missing: $symbol ($identifier)"
  done
  for symbol in "${forbidden_audio_symbols[@]}"; do
    if grep -Eq "[[:space:]]_${symbol}$" <<<"$symbols"; then
      die "unexpected rdpsnd audio subsystem present: $symbol ($identifier)"
    fi
  done

  printf '%s\n' \
    '#include <freerdp/freerdp.h>' \
    '#include <openssl/ssl.h>' \
    'extern void cliprdr_VirtualChannelEntryEx(void);' \
    'extern void rdpsnd_VirtualChannelEntryEx(void);' \
    'extern void rdpsnd_DVCPluginEntry(void);' \
    'extern void rdpdr_VirtualChannelEntryEx(void);' \
    'extern void drdynvc_VirtualChannelEntryEx(void);' \
    'extern void disp_DVCPluginEntry(void);' \
    'extern void rdpgfx_DVCPluginEntry(void);' \
    'extern void ios_freerdp_rdpsnd_client_subsystem_entry(void);' \
    'extern void fake_freerdp_rdpsnd_client_subsystem_entry(void);' \
    'typedef void (*entry_point)(void);' \
    'static entry_point volatile entry_points[] = {' \
    '  cliprdr_VirtualChannelEntryEx, rdpsnd_VirtualChannelEntryEx,' \
    '  rdpsnd_DVCPluginEntry, rdpdr_VirtualChannelEntryEx,' \
    '  drdynvc_VirtualChannelEntryEx,' \
    '  disp_DVCPluginEntry, rdpgfx_DVCPluginEntry,' \
    '  ios_freerdp_rdpsnd_client_subsystem_entry,' \
    '  fake_freerdp_rdpsnd_client_subsystem_entry' \
    '};' \
    'int main(void) {' \
    '  freerdp *instance = freerdp_new();' \
    '  freerdp_free(instance);' \
    '  SSL_CTX *ssl_context = SSL_CTX_new(TLS_method());' \
    '  SSL_CTX_free(ssl_context);' \
    '  return entry_points[0] == 0;' \
    '}' |
    xcrun --sdk "$sdk" clang -target "$target" -Wno-deprecated-declarations \
      -I "$headers_dir" -x c - -x none "$archive" \
      -framework Foundation -framework AudioToolbox -o /dev/null
done

[[ "$device_count" == "1" ]] || die "expected one device slice"
[[ "$simulator_count" == "1" ]] || die "expected one simulator slice"

if find "$XCFRAMEWORK_PATH" -type f \( -name '*.dylib' -o -name '*.so' -o -name '*.bundle' \) -print | grep -q .; then
  die "dynamic library/plugin found in XCFramework"
fi
if find "$XCFRAMEWORK_PATH" -type d -name '*.framework' -print | grep -q .; then
  die "nested dynamic framework found in XCFramework"
fi

host_path_match="$(LC_ALL=C grep -R -a -E -l \
  '/Users/|/home/runner/|/private/tmp/|/private/var/folders/|/var/folders/' \
  "$XCFRAMEWORK_PATH" 2>/dev/null | head -n 1 || true)"
[[ -z "$host_path_match" ]] || die "host build path found in XCFramework: $host_path_match"

printf 'verified: %s\n' "$XCFRAMEWORK_PATH"
printf 'slices: ios-arm64, ios-arm64-simulator\n'
printf 'static add-ins: cliprdr, rdpsnd, rdpdr, drdynvc, disp, rdpgfx\n'
printf 'link smoke: FreeRDP/OpenSSL/static add-ins + Foundation/AudioToolbox\n'
printf 'audio subsystems: ios (PCM-only) + upstream fake; integration must select sys:ios\n'
