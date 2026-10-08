#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK_FILE="$REPO_ROOT/config/dependencies/freerdp.lock"

# shellcheck disable=SC1090
source "$LOCK_FILE"

BUILD_ROOT="$REPO_ROOT/.build/freerdp"
OUTPUT_PATH="$REPO_ROOT/artifacts/$XCFRAMEWORK_NAME"
SOURCE_OVERRIDE=""
OPENSSL_ARCHIVE_OVERRIDE=""
OFFLINE=0
DRY_RUN=0
JOBS="$(sysctl -n hw.logicalcpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')"
OPENSSL_BUILD_PROFILE_VERSION=3
FREERDP_BUILD_PROFILE_VERSION=2
RUNTIME_PREFIX=/usr/local
RUNTIME_OPENSSLDIR=/etc/ssl

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[freerdp-build] %s\n' "$*"
}

usage() {
  sed -n 's/^#> //p' "$0"
}

#> Usage: scripts/build-freerdp-xcframework.sh [options]
#>
#> Build the locked FreeRDP/WinPR and OpenSSL sources into a static XCFramework.
#>
#> Options:
#>   --dry-run                 Validate the lock and print the build plan only.
#>   --offline                 Forbid downloads; require populated source/cache paths.
#>   --source-dir PATH         Use an existing clean FreeRDP git checkout.
#>   --openssl-archive PATH    Use an existing pinned OpenSSL release archive.
#>   --build-root PATH         Put intermediate files under PATH.
#>   --output PATH             XCFramework output path (must not already exist).
#>   --jobs N                  Parallel build jobs.
#>   -h, --help                Show this help.

while (($#)); do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --offline)
      OFFLINE=1
      shift
      ;;
    --source-dir)
      (($# >= 2)) || die "--source-dir requires a path"
      SOURCE_OVERRIDE="$2"
      shift 2
      ;;
    --openssl-archive)
      (($# >= 2)) || die "--openssl-archive requires a path"
      OPENSSL_ARCHIVE_OVERRIDE="$2"
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
    --jobs)
      (($# >= 2)) || die "--jobs requires a number"
      JOBS="$2"
      shift 2
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

required_lock_fields=(
  LOCK_FORMAT_VERSION FREERDP_VERSION FREERDP_TAG FREERDP_GIT_URL FREERDP_COMMIT
  FREERDP_COMMIT_TIMESTAMP FREERDP_LICENSE_SHA256 OPENSSL_VERSION OPENSSL_TAG
  OPENSSL_ARCHIVE_URL OPENSSL_ARCHIVE_SHA256 OPENSSL_LICENSE_SHA256
  TPCIRCULARBUFFER_C_SHA256 TPCIRCULARBUFFER_H_SHA256
  SOLAR_MD4_C_SHA256 SOLAR_MD4_H_SHA256 SOLAR_MD5_C_SHA256 SOLAR_MD5_H_SHA256
  WINPR_HASHTABLE_C_SHA256 WINPR_WINDOWS_ZONES_C_SHA256
  IOS_DEPLOYMENT_TARGET XCFRAMEWORK_NAME SBOM_CREATED
)
for field in "${required_lock_fields[@]}"; do
  [[ -n "${!field:-}" ]] || die "missing lock field: $field"
done

[[ "$LOCK_FORMAT_VERSION" == "1" ]] || die "unsupported lock format: $LOCK_FORMAT_VERSION"
[[ "$FREERDP_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "invalid FreeRDP commit in lock"
[[ "$FREERDP_LICENSE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "invalid FreeRDP license hash"
[[ "$OPENSSL_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "invalid OpenSSL archive hash"
[[ "$OPENSSL_LICENSE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "invalid OpenSSL license hash"
bundled_hash_fields=(
  TPCIRCULARBUFFER_C_SHA256 TPCIRCULARBUFFER_H_SHA256
  SOLAR_MD4_C_SHA256 SOLAR_MD4_H_SHA256 SOLAR_MD5_C_SHA256 SOLAR_MD5_H_SHA256
  WINPR_HASHTABLE_C_SHA256 WINPR_WINDOWS_ZONES_C_SHA256
)
for field in "${bundled_hash_fields[@]}"; do
  [[ "${!field}" =~ ^[0-9a-f]{64}$ ]] || die "invalid bundled source hash: $field"
done
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"

FREERDP_SOURCE_DIR="${SOURCE_OVERRIDE:-$BUILD_ROOT/src/FreeRDP}"
OPENSSL_ARCHIVE="${OPENSSL_ARCHIVE_OVERRIDE:-$BUILD_ROOT/downloads/openssl-$OPENSSL_VERSION.tar.gz}"
OPENSSL_SOURCE_DIR="$BUILD_ROOT/src/openssl-$OPENSSL_VERSION"
OPENSSL_SOURCE_MANIFEST="$BUILD_ROOT/src/openssl-$OPENSSL_VERSION.files.sha256"

print_plan() {
  printf '%s\n' \
    "lock=$LOCK_FILE" \
    "FreeRDP=$FREERDP_VERSION" \
    "FreeRDP commit=$FREERDP_COMMIT" \
    "OpenSSL=$OPENSSL_VERSION" \
    "OpenSSL archive sha256=$OPENSSL_ARCHIVE_SHA256" \
    "deployment target=iOS $IOS_DEPLOYMENT_TARGET" \
    "runtime prefix=$RUNTIME_PREFIX" \
    "OpenSSL runtime config=$RUNTIME_OPENSSLDIR" \
    "slice=device:arm64 (PLATFORM=OS64)" \
    "slice=simulator:arm64 (PLATFORM=SIMULATORARM64)" \
    "slice=maccatalyst:arm64 (PLATFORM=MAC_CATALYST_ARM64)" \
    "static channels=cliprdr,rdpsnd,rdpdr,drdynvc,disp,rdpgfx,rdpei,drive,audin,rail" \
    "audio subsystems=upstream ios + fake (adapter must select sys:ios; iOS path is PCM-only)" \
    "disabled codecs=FFmpeg,OpenH264,Opus,JPEG,WebP" \
    "source=$FREERDP_SOURCE_DIR" \
    "openssl archive=$OPENSSL_ARCHIVE" \
    "build root=$BUILD_ROOT" \
    "output=$OUTPUT_PATH"
}

if ((DRY_RUN)); then
  print_plan
  exit 0
fi

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

for command_name in git cmake curl grep perl make shasum tar xcodebuild xcode-select xcrun; do
  require_command "$command_name"
done
[[ -x /usr/bin/libtool ]] || die "Apple /usr/bin/libtool is required"
[[ -x /usr/bin/ranlib ]] || die "Apple /usr/bin/ranlib is required"
[[ -x /usr/libexec/PlistBuddy ]] || die "Apple PlistBuddy is required"

mkdir -p "$BUILD_ROOT/src" "$BUILD_ROOT/downloads" "$BUILD_ROOT/slices" "$(dirname "$OUTPUT_PATH")"

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

verify_locked_source_file() {
  local source_dir="$1"
  local relative_path="$2"
  local expected_hash="$3"
  local path="$source_dir/$relative_path"
  [[ -f "$path" ]] || die "locked bundled source is missing: $relative_path"
  local actual_hash
  actual_hash="$(sha256_file "$path")"
  [[ "$actual_hash" == "$expected_hash" ]] ||
    die "locked bundled source hash mismatch: $relative_path ($actual_hash)"
}

verify_freerdp_source() {
  local source_dir="$1"
  [[ -d "$source_dir/.git" ]] || die "FreeRDP source is not a git checkout: $source_dir"
  local actual_commit actual_timestamp
  actual_commit="$(git -C "$source_dir" rev-parse HEAD)"
  [[ "$actual_commit" == "$FREERDP_COMMIT" ]] ||
    die "FreeRDP commit mismatch: expected $FREERDP_COMMIT, got $actual_commit"
  actual_timestamp="$(git -C "$source_dir" show -s --format=%ct HEAD)"
  [[ "$actual_timestamp" == "$FREERDP_COMMIT_TIMESTAMP" ]] ||
    die "FreeRDP commit timestamp mismatch: expected $FREERDP_COMMIT_TIMESTAMP, got $actual_timestamp"
  [[ -z "$(git -C "$source_dir" status --porcelain --untracked-files=all)" ]] ||
    die "FreeRDP checkout is not clean (tracked or untracked changes): $source_dir"
  [[ -f "$source_dir/LICENSE" ]] || die "FreeRDP LICENSE is missing"
  local license_hash
  license_hash="$(sha256_file "$source_dir/LICENSE")"
  [[ "$license_hash" == "$FREERDP_LICENSE_SHA256" ]] ||
    die "FreeRDP LICENSE hash mismatch: $license_hash"

  verify_locked_source_file "$source_dir" \
    channels/rdpsnd/client/ios/TPCircularBuffer.c "$TPCIRCULARBUFFER_C_SHA256"
  verify_locked_source_file "$source_dir" \
    channels/rdpsnd/client/ios/TPCircularBuffer.h "$TPCIRCULARBUFFER_H_SHA256"
  verify_locked_source_file "$source_dir" winpr/libwinpr/crypto/md4.c "$SOLAR_MD4_C_SHA256"
  verify_locked_source_file "$source_dir" winpr/libwinpr/crypto/md4.h "$SOLAR_MD4_H_SHA256"
  verify_locked_source_file "$source_dir" winpr/libwinpr/crypto/md5.c "$SOLAR_MD5_C_SHA256"
  verify_locked_source_file "$source_dir" winpr/libwinpr/crypto/md5.h "$SOLAR_MD5_H_SHA256"
  verify_locked_source_file "$source_dir" \
    winpr/libwinpr/utils/collections/HashTable.c "$WINPR_HASHTABLE_C_SHA256"
  verify_locked_source_file "$source_dir" \
    winpr/libwinpr/timezone/WindowsZones.c "$WINPR_WINDOWS_ZONES_C_SHA256"
}

prepare_freerdp_source() {
  if [[ -n "$SOURCE_OVERRIDE" ]]; then
    verify_freerdp_source "$FREERDP_SOURCE_DIR"
    return
  fi

  if [[ -d "$FREERDP_SOURCE_DIR/.git" ]]; then
    verify_freerdp_source "$FREERDP_SOURCE_DIR"
    return
  fi
  [[ ! -e "$FREERDP_SOURCE_DIR" ]] || die "source path exists but is not a git checkout: $FREERDP_SOURCE_DIR"
  ((OFFLINE == 0)) || die "offline mode: FreeRDP source is not cached"

  log "fetching exact FreeRDP commit $FREERDP_COMMIT"
  mkdir -p "$FREERDP_SOURCE_DIR"
  git -C "$FREERDP_SOURCE_DIR" init --quiet
  git -C "$FREERDP_SOURCE_DIR" remote add origin "$FREERDP_GIT_URL"
  git -C "$FREERDP_SOURCE_DIR" fetch --quiet --depth 1 origin "$FREERDP_COMMIT"
  git -C "$FREERDP_SOURCE_DIR" -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD
  verify_freerdp_source "$FREERDP_SOURCE_DIR"
}

verify_openssl_archive() {
  local archive="$1"
  [[ -f "$archive" ]] || die "OpenSSL archive does not exist: $archive"
  local actual_hash
  actual_hash="$(sha256_file "$archive")"
  [[ "$actual_hash" == "$OPENSSL_ARCHIVE_SHA256" ]] ||
    die "OpenSSL archive hash mismatch: expected $OPENSSL_ARCHIVE_SHA256, got $actual_hash"
}

prepare_openssl_archive() {
  if [[ -f "$OPENSSL_ARCHIVE" ]]; then
    verify_openssl_archive "$OPENSSL_ARCHIVE"
    return
  fi
  ((OFFLINE == 0)) || die "offline mode: OpenSSL archive is not cached"
  [[ -z "$OPENSSL_ARCHIVE_OVERRIDE" ]] || die "OpenSSL archive override does not exist: $OPENSSL_ARCHIVE"

  log "downloading OpenSSL $OPENSSL_VERSION"
  local partial="$OPENSSL_ARCHIVE.partial.$$"
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --output "$partial" "$OPENSSL_ARCHIVE_URL"
  verify_openssl_archive "$partial"
  mv "$partial" "$OPENSSL_ARCHIVE"
}

validate_openssl_source_layout() {
  local source_dir="$1"
  local entry

  while IFS= read -r -d '' entry; do
    [[ "$entry" != *$'\n'* ]] || die "OpenSSL source contains a newline in a path: $entry"
  done < <(find "$source_dir" -print0)

  if [[ -n "$(find "$source_dir" -type l -print -quit)" ]]; then
    die "OpenSSL source contains a symbolic link; the file-manifest policy requires regular files only"
  fi
  if [[ -n "$(find "$source_dir" ! -type d ! -type f -print -quit)" ]]; then
    die "OpenSSL source contains a non-regular filesystem entry"
  fi
}

write_openssl_source_manifest() {
  local source_dir="$1"
  local manifest="$2"
  local temporary_manifest
  local files=()
  local file
  temporary_manifest="$(mktemp "$BUILD_ROOT/src/openssl-source-manifest.XXXXXX")"

  (
    trap 'rm -f "$temporary_manifest"' EXIT
    cd "$source_dir"
    while IFS= read -r file; do
      files+=("$file")
    done < <(find . -type f -print | LC_ALL=C sort)
    ((${#files[@]} > 0)) || die "OpenSSL source manifest would be empty"
    shasum -a 256 "${files[@]}" > "$temporary_manifest"
    mv "$temporary_manifest" "$manifest"
    trap - EXIT
  )
}

verify_openssl_source_manifest() {
  local source_dir="$1"
  local manifest="$2"
  [[ -f "$manifest" ]] ||
    die "OpenSSL source manifest is missing; remove the cached source and extract it again: $manifest"

  validate_openssl_source_layout "$source_dir"

  local expected_count actual_count
  expected_count="$(awk 'END { print NR + 0 }' "$manifest")"
  actual_count="$(find "$source_dir" -type f -print | wc -l | tr -d '[:space:]')"
  [[ "$actual_count" == "$expected_count" ]] ||
    die "OpenSSL source file count mismatch: expected $expected_count, got $actual_count"

  (
    cd "$source_dir"
    shasum -a 256 -c "$manifest" >/dev/null
  ) || die "OpenSSL source manifest verification failed"
}

prepare_openssl_source() {
  if [[ ! -d "$OPENSSL_SOURCE_DIR" ]]; then
    local extract_root
    extract_root="$(mktemp -d "$BUILD_ROOT/src/openssl-extract.XXXXXX")"
    tar -xzf "$OPENSSL_ARCHIVE" -C "$extract_root"
    [[ -d "$extract_root/openssl-$OPENSSL_VERSION" ]] || die "unexpected OpenSSL archive layout"
    mv "$extract_root/openssl-$OPENSSL_VERSION" "$OPENSSL_SOURCE_DIR"
    rmdir "$extract_root"
    validate_openssl_source_layout "$OPENSSL_SOURCE_DIR"
    write_openssl_source_manifest "$OPENSSL_SOURCE_DIR" "$OPENSSL_SOURCE_MANIFEST"
  fi
  verify_openssl_source_manifest "$OPENSSL_SOURCE_DIR" "$OPENSSL_SOURCE_MANIFEST"
  [[ -f "$OPENSSL_SOURCE_DIR/LICENSE.txt" ]] || die "OpenSSL LICENSE.txt is missing"
  local license_hash
  license_hash="$(sha256_file "$OPENSSL_SOURCE_DIR/LICENSE.txt")"
  [[ "$license_hash" == "$OPENSSL_LICENSE_SHA256" ]] ||
    die "OpenSSL LICENSE hash mismatch: expected $OPENSSL_LICENSE_SHA256, got $license_hash"
}

prepare_freerdp_source
# CMake preserves the spelling of its -S argument in CMAKE_HOME_DIRECTORY.
# Resolve aliases such as macOS' /tmp -> /private/tmp once the checkout exists
# so cache validation and -ffile-prefix-map use the same absolute path.
FREERDP_SOURCE_DIR="$(cd "$FREERDP_SOURCE_DIR" && pwd -P)"
prepare_openssl_archive
prepare_openssl_source

export SOURCE_DATE_EPOCH="$FREERDP_COMMIT_TIMESTAMP"
export ZERO_AR_DATE=1

build_openssl_slice() {
  local slice="$1"
  local sdk="$2"
  local apple_platform="$3"
  local slice_root="$BUILD_ROOT/slices/$slice"
  local stage_root="$slice_root/openssl-stage"
  local prefix="$stage_root$RUNTIME_PREFIX"
  local build_dir="$BUILD_ROOT/slices/$slice/openssl-build"
  local input_stamp="$slice_root/openssl-inputs.stamp"
  local config_args=(iphoneos-cross no-shared no-tests no-apps no-docs no-module)
  local cc_extra

  local developer_dir sdk_version cross_top cross_sdk cc
  if [[ "$sdk" == "iphonesimulator" ]]; then
    config_args+=(no-asm)
    cc_extra="-target arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator -mios-simulator-version-min=${IOS_DEPLOYMENT_TARGET}"
  elif [[ "$sdk" == "macosx" ]]; then
    # Mac Catalyst: the macOS SDK compiled for the iOS ABI (macabi). OpenSSL's
    # darwin64 target supplies the arm64 assembly; the triple picks the ABI.
    config_args=(darwin64-arm64-cc "${config_args[@]:1}")
    cc_extra="-target arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-macabi -isysroot $(xcrun --sdk macosx --show-sdk-path)"
  else
    cc_extra="-miphoneos-version-min=${IOS_DEPLOYMENT_TARGET}"
  fi

  local xcode_version clang_version source_path source_manifest_hash input_payload expected_fingerprint
  developer_dir="$(xcode-select -print-path)"
  sdk_version="$(xcrun --sdk "$sdk" --show-sdk-version)"
  cross_top="$developer_dir/Platforms/$apple_platform.platform/Developer"
  cross_sdk="${apple_platform}${sdk_version}.sdk"
  cc="$developer_dir/usr/bin/gcc -arch arm64 $cc_extra"
  xcode_version="$(xcodebuild -version 2>/dev/null | tr '\n' '/')"
  clang_version="$(xcrun --sdk "$sdk" clang --version | sed -n '1p')"
  source_path="$(cd "$OPENSSL_SOURCE_DIR" && pwd -P)"
  source_manifest_hash="$(sha256_file "$OPENSSL_SOURCE_MANIFEST")"
  input_payload="$(printf '%s\n' \
    "profile=$OPENSSL_BUILD_PROFILE_VERSION" \
    "lock_format=$LOCK_FORMAT_VERSION" \
    "openssl_version=$OPENSSL_VERSION" \
    "openssl_tag=$OPENSSL_TAG" \
    "archive_sha256=$OPENSSL_ARCHIVE_SHA256" \
    "license_sha256=$OPENSSL_LICENSE_SHA256" \
    "source_dir=$OPENSSL_SOURCE_DIR" \
    "source_path=$source_path" \
    "source_manifest_sha256=$source_manifest_hash" \
    "source_date_epoch=$SOURCE_DATE_EPOCH" \
    "deployment_target=$IOS_DEPLOYMENT_TARGET" \
    "slice=$slice" \
    "sdk=$sdk" \
    "sdk_version=$sdk_version" \
    "apple_platform=$apple_platform" \
    "build_dir=$build_dir" \
    "stage_root=$stage_root" \
    "runtime_prefix=$RUNTIME_PREFIX" \
    "runtime_openssldir=$RUNTIME_OPENSSLDIR" \
    "xcode=$xcode_version" \
    "clang=$clang_version" \
    "cc=$cc" \
    "configure=${config_args[*]} --prefix=$RUNTIME_PREFIX --openssldir=$RUNTIME_OPENSSLDIR --libdir=lib")"
  expected_fingerprint="$(printf '%s\n' "$input_payload" | shasum -a 256 | awk '{print $1}')"

  local actual_fingerprint=""
  if [[ -f "$input_stamp" ]]; then
    actual_fingerprint="$(sed -n 's/^fingerprint=//p' "$input_stamp")"
  fi
  if [[ "$actual_fingerprint" == "$expected_fingerprint" && \
        -f "$prefix/lib/libssl.a" && -f "$prefix/lib/libcrypto.a" && \
        "$(xcrun lipo -archs "$prefix/lib/libssl.a")" == "arm64" && \
        "$(xcrun lipo -archs "$prefix/lib/libcrypto.a")" == "arm64" ]]; then
    log "reusing fingerprinted OpenSSL slice $slice"
    return
  fi

  [[ "$build_dir" == "$slice_root/openssl-build" ]] || die "unsafe OpenSSL build path"
  [[ "$stage_root" == "$slice_root/openssl-stage" ]] || die "unsafe OpenSSL stage path"
  rm -rf "$build_dir" "$stage_root"
  rm -f "$input_stamp"
  mkdir -p "$build_dir" "$stage_root"
  log "building OpenSSL slice $slice (input fingerprint $expected_fingerprint)"
  (
    cd "$build_dir"
    env CROSS_TOP="$cross_top" CROSS_SDK="$cross_sdk" CC="$cc" \
      perl "$OPENSSL_SOURCE_DIR/Configure" "${config_args[@]}" \
      "--prefix=$RUNTIME_PREFIX" "--openssldir=$RUNTIME_OPENSSLDIR" --libdir=lib
    env CROSS_TOP="$cross_top" CROSS_SDK="$cross_sdk" CC="$cc" make -j "$JOBS" build_sw
    env CROSS_TOP="$cross_top" CROSS_SDK="$cross_sdk" CC="$cc" \
      make DESTDIR="$stage_root" install_sw
  )
  [[ -f "$prefix/lib/libssl.a" && -f "$prefix/lib/libcrypto.a" ]] ||
    die "OpenSSL slice build did not install both static libraries: $slice"
  {
    printf '%s\n' "$input_payload"
    printf 'fingerprint=%s\n' "$expected_fingerprint"
  } > "$input_stamp.tmp.$$"
  mv "$input_stamp.tmp.$$" "$input_stamp"
}

disabled_channels=(
  AINPUT ECHO ENCOMSP GEOMETRY GFXREDIR LOCATION PARALLEL PRINTER
  RDP2TCP RDPEAR RDPECAM RDPEMSC RDPEWA REMDESK SERIAL
  SMARTCARD SSHAGENT TELEMETRY TSMF URBDRC VIDEO
)
required_channels=(CLIPRDR RDPSND RDPDR DRDYNVC DISP RDPGFX RDPEI DRIVE AUDIN RAIL)

cache_value() {
  local cache="$1"
  local key="$2"
  sed -n "s/^${key}:[^=]*=//p" "$cache" | tail -n 1
}

sanitize_generated_buildflags() {
  local build_dir="$1"
  local source_path="$2"
  local headers=(
    "$build_dir/include/freerdp/buildflags.h"
    "$build_dir/winpr/include/winpr/buildflags.h"
  )
  local header

  for header in "${headers[@]}"; do
    [[ -f "$header" ]] || die "generated build flags header is missing: $header"
  done

  env MREMOTE_FREERDP_BUILD_DIR="$build_dir" MREMOTE_FREERDP_SOURCE_DIR="$source_path" \
    perl -pi -e \
      's/\Q$ENV{MREMOTE_FREERDP_BUILD_DIR}\E/\/usr\/src\/FreeRDP-build/g; s/\Q$ENV{MREMOTE_FREERDP_SOURCE_DIR}\E/\/usr\/src\/FreeRDP/g' \
      "${headers[@]}"

  for header in "${headers[@]}"; do
    if LC_ALL=C grep -F "$build_dir" "$header" >/dev/null ||
       LC_ALL=C grep -F "$source_path" "$header" >/dev/null; then
      die "host path remains in generated build flags header: $header"
    fi
  done
}

assert_cache_value() {
  local cache="$1"
  local key="$2"
  local expected="$3"
  local actual
  actual="$(cache_value "$cache" "$key")"
  [[ "$actual" == "$expected" ]] ||
    die "$key must be $expected for a release slice (got ${actual:-missing})"
}

build_freerdp_slice() {
  local slice="$1"
  local platform="$2"
  local sdk="$3"
  local slice_root="$BUILD_ROOT/slices/$slice"
  local openssl_prefix="$slice_root/openssl-stage$RUNTIME_PREFIX"
  local openssl_input_stamp="$slice_root/openssl-inputs.stamp"
  local build_dir="$slice_root/freerdp-build"
  local install_root="$slice_root/freerdp-stage"
  local install_dir="$install_root$RUNTIME_PREFIX"
  local input_stamp="$slice_root/freerdp-inputs.stamp"
  local cache="$build_dir/CMakeCache.txt"

  verify_freerdp_source "$FREERDP_SOURCE_DIR"
  local source_path
  source_path="$(cd "$FREERDP_SOURCE_DIR" && pwd -P)"
  # WITH_GFX_H264: advertise AVC420 although FreeRDP has no decoder of its own
  # here; the bridge decodes AVC420 with VideoToolbox (bridge/src/h264_decoder.c).
  local c_flags="-O2 -DNDEBUG -DWITH_GFX_H264 -ffile-prefix-map=$source_path=/usr/src/FreeRDP -ffile-prefix-map=$build_dir=/usr/src/FreeRDP-build"

  local cmake_args=(
    -S "$FREERDP_SOURCE_DIR"
    -B "$build_dir"
    -G "Unix Makefiles"
    "-DCMAKE_TOOLCHAIN_FILE=$FREERDP_SOURCE_DIR/cmake/ios.toolchain.cmake"
    "-DPLATFORM=$platform"
    "-DDEPLOYMENT_TARGET=$IOS_DEPLOYMENT_TARGET"
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_DEPLOYMENT_TARGET"
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF
    -DENABLE_BITCODE=OFF
    -DCMAKE_DISABLE_FIND_PACKAGE_Opus=ON
    -DCMAKE_DISABLE_FIND_PACKAGE_uriparser=ON
    -DCMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON
    -DCMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY=ON
    "-DCMAKE_C_FLAGS_RELEASE=$c_flags"
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    "-DCMAKE_INSTALL_PREFIX=$RUNTIME_PREFIX"
    -DCMAKE_INSTALL_LIBDIR=lib
    "-DCMAKE_PREFIX_PATH=$openssl_prefix"
    "-DCMAKE_FIND_ROOT_PATH=$openssl_prefix"
    "-DOPENSSL_ROOT_DIR=$openssl_prefix"
    "-DOPENSSL_INCLUDE_DIR=$openssl_prefix/include"
    "-DOPENSSL_SSL_LIBRARY=$openssl_prefix/lib/libssl.a"
    "-DOPENSSL_CRYPTO_LIBRARY=$openssl_prefix/lib/libcrypto.a"
    -DOPENSSL_USE_STATIC_LIBS=ON
    -DBUILD_SHARED_LIBS=OFF
    -DBUILD_TESTING=OFF
    -DBUILD_TESTING_INTERNAL=OFF
    -DBUILD_BENCHMARK=OFF
    -DWITH_CLANG_FORMAT=OFF
    -DWITH_CCACHE=OFF
    -DWITH_MANPAGES=OFF
    -DWITH_SAMPLE=OFF
    -DWITH_SERVER=OFF
    -DWITH_SERVER_CHANNELS=OFF
    -DWITH_CLIENT_COMMON=ON
    -DWITH_CLIENT=OFF
    -DWITH_CLIENT_SDL=OFF
    -DWITH_CLIENT_INTERFACE=OFF
    -DWITH_CHANNELS=ON
    -DWITH_CLIENT_CHANNELS=ON
    -DWITH_THIRD_PARTY=OFF
    -DWITH_OPENSSL=ON
    -DWITH_INTERNAL_MD4=ON
    -DWITH_INTERNAL_MD5=ON
    -DWITH_INTERNAL_RC4=ON
    -DWITH_JSON_DISABLED=ON
    -DWITH_CJSON_REQUIRED=OFF
    -DWITH_AAD=OFF
    -DWITH_KRB5=OFF
    -DWITH_SMARTCARD_EMULATE=OFF
    -DWITH_PCSC=OFF
    -DWITH_URIPARSER=OFF
    -DWITH_FFMPEG=OFF
    -DWITH_DSP_FFMPEG=OFF
    -DWITH_VIDEO_FFMPEG=OFF
    -DWITH_VIDEOTOOLBOX=OFF
    -DWITH_OPENH264=OFF
    -DWITH_OPUS=OFF
    -DWITH_JPEG=OFF
    -DWINPR_UTILS_IMAGE_PNG=OFF
    -DWINPR_UTILS_IMAGE_WEBP=OFF
    -DWINPR_UTILS_IMAGE_JPEG=OFF
    -DWITH_SWSCALE=OFF
    -DWITH_CAIRO=OFF
    -DWITH_OPENCL=OFF
    -DWITH_X11=OFF
    -DWITH_WAYLAND=OFF
    -DWITH_FUSE=OFF
    -DWITH_MACAUDIO=OFF
    -DWITH_IOSAUDIO=ON
    -DWITH_ABSOLUTE_PLUGIN_LOAD_PATHS=OFF
    -DWITH_DEBUG_ALL=OFF
    # pipe2() is declared by the 27.0 SDKs but only exists from iOS/macOS 27.
    # The probe sees the declaration, WinPR then weak-links it, and every
    # event creation calls through a null pointer below the deployment target.
    -DWINPR_HAVE_PIPE2=OFF
  )
  if [[ "$platform" == MAC_CATALYST* ]]; then
    # libSystem exports pthread_setschedprio, so the link probe finds it, but
    # the macOS headers do not declare it. iOS takes the fallback path anyway.
    cmake_args+=(-DPTHREAD_SETSCHEDPRIO=OFF)
  fi
  local channel
  for channel in "${disabled_channels[@]}"; do
    cmake_args+=("-DCHANNEL_${channel}=OFF" "-DCHANNEL_${channel}_CLIENT=OFF" "-DCHANNEL_${channel}_SERVER=OFF")
  done
  for channel in "${required_channels[@]}"; do
    cmake_args+=("-DCHANNEL_${channel}=ON" "-DCHANNEL_${channel}_CLIENT=ON" "-DCHANNEL_${channel}_SERVER=OFF")
  done

  [[ -f "$openssl_input_stamp" ]] ||
    die "OpenSSL input stamp is missing for FreeRDP slice $slice: $openssl_input_stamp"

  local source_commit sdk_version sdk_path xcode_version cmake_version
  local openssl_input_hash cmake_args_payload input_payload expected_fingerprint
  source_commit="$(git -C "$FREERDP_SOURCE_DIR" rev-parse HEAD)"
  sdk_version="$(xcrun --sdk "$sdk" --show-sdk-version)"
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  xcode_version="$(xcodebuild -version 2>/dev/null | tr '\n' '/')"
  cmake_version="$(cmake --version | sed -n '1p')"
  openssl_input_hash="$(sha256_file "$openssl_input_stamp")"
  cmake_args_payload="$(printf 'cmake_arg=%q\n' "${cmake_args[@]}")"
  input_payload="$(printf '%s\n' \
    "profile=$FREERDP_BUILD_PROFILE_VERSION" \
    "lock_format=$LOCK_FORMAT_VERSION" \
    "freerdp_version=$FREERDP_VERSION" \
    "freerdp_tag=$FREERDP_TAG" \
    "freerdp_commit=$source_commit" \
    "freerdp_source=$source_path" \
    "source_date_epoch=$SOURCE_DATE_EPOCH" \
    "slice=$slice" \
    "platform=$platform" \
    "sdk=$sdk" \
    "sdk_version=$sdk_version" \
    "sdk_path=$sdk_path" \
    "xcode=$xcode_version" \
    "cmake=$cmake_version" \
    "install_root=$install_root" \
    "openssl_inputs_sha256=$openssl_input_hash" \
    "$cmake_args_payload")"
  expected_fingerprint="$(printf '%s\n' "$input_payload" | shasum -a 256 | awk '{print $1}')"

  local actual_fingerprint=""
  local cached_home=""
  if [[ -f "$input_stamp" ]]; then
    actual_fingerprint="$(sed -n 's/^fingerprint=//p' "$input_stamp")"
  fi
  if [[ -f "$cache" ]]; then
    cached_home="$(cache_value "$cache" CMAKE_HOME_DIRECTORY)"
  fi

  if [[ "$actual_fingerprint" == "$expected_fingerprint" && \
        "$cached_home" == "$source_path" && -f "$build_dir/Makefile" ]]; then
    log "reusing fingerprinted FreeRDP configuration for slice $slice"
  else
    [[ "$build_dir" == "$slice_root/freerdp-build" ]] || die "unsafe FreeRDP build path"
    rm -rf "$build_dir"
    rm -f "$input_stamp"
    mkdir -p "$build_dir"
    log "configuring FreeRDP slice $slice (input fingerprint $expected_fingerprint)"
    cmake "${cmake_args[@]}"
    [[ "$(cache_value "$cache" CMAKE_HOME_DIRECTORY)" == "$source_path" ]] ||
      die "CMake source directory mismatch after configuring FreeRDP slice $slice"
    {
      printf '%s\n' "$input_payload"
      printf 'fingerprint=%s\n' "$expected_fingerprint"
    } > "$input_stamp.tmp.$$"
    mv "$input_stamp.tmp.$$" "$input_stamp"
  fi

  sanitize_generated_buildflags "$build_dir" "$source_path"
  cmake --build "$build_dir" --parallel "$JOBS"
  [[ "$install_root" == "$slice_root/freerdp-stage" ]] || die "unsafe FreeRDP stage path"
  rm -rf "$install_root"
  env DESTDIR="$install_root" cmake --install "$build_dir"

  assert_cache_value "$cache" BUILD_SHARED_LIBS OFF
  assert_cache_value "$cache" CMAKE_INTERPROCEDURAL_OPTIMIZATION OFF
  assert_cache_value "$cache" ENABLE_BITCODE OFF
  assert_cache_value "$cache" ENABLE_BITCODE_INT OFF
  assert_cache_value "$cache" WITH_SERVER OFF
  assert_cache_value "$cache" WITH_SERVER_CHANNELS OFF
  assert_cache_value "$cache" WITH_CLIENT OFF
  assert_cache_value "$cache" WITH_CLIENT_COMMON ON
  assert_cache_value "$cache" WITH_CLIENT_CHANNELS ON
  assert_cache_value "$cache" WITH_FFMPEG OFF
  assert_cache_value "$cache" WITH_OPENH264 OFF
  assert_cache_value "$cache" WITH_IOSAUDIO ON
  assert_cache_value "$cache" OPENSSL_SSL_LIBRARY "$openssl_prefix/lib/libssl.a"
  assert_cache_value "$cache" OPENSSL_CRYPTO_LIBRARY "$openssl_prefix/lib/libcrypto.a"
  for channel in "${required_channels[@]}"; do
    assert_cache_value "$cache" "CHANNEL_${channel}" ON
    assert_cache_value "$cache" "CHANNEL_${channel}_CLIENT" ON
    assert_cache_value "$cache" "CHANNEL_${channel}_SERVER" OFF
  done
  for channel in "${disabled_channels[@]}"; do
    assert_cache_value "$cache" "CHANNEL_${channel}" OFF
  done

  if find "$install_dir" -type f \( -name '*.dylib' -o -name '*.so' -o -name '*.bundle' \) -print | grep -q .; then
    die "dynamic library or plugin found in static install: $install_dir"
  fi
}

package_slice() {
  local slice="$1"
  local sdk="$2"
  local slice_root="$BUILD_ROOT/slices/$slice"
  local install_dir="$slice_root/freerdp-stage$RUNTIME_PREFIX"
  local openssl_prefix="$slice_root/openssl-stage$RUNTIME_PREFIX"
  local package_dir="$slice_root/package"
  local headers_dir="$package_dir/Headers"
  local output_library="$package_dir/libmremote-freerdp.a"
  local archives=()
  local archive

  [[ -f "$install_dir/lib/libfreerdp3.a" ]] || die "libfreerdp3.a was not installed for $slice"
  [[ -f "$install_dir/lib/libfreerdp-client3.a" ]] || die "libfreerdp-client3.a was not installed for $slice"
  [[ -f "$install_dir/lib/libwinpr3.a" ]] || die "libwinpr3.a was not installed for $slice"

  [[ "$package_dir" == "$slice_root/package" ]] || die "unsafe package path"
  rm -rf "$package_dir"
  mkdir -p "$headers_dir"
  cp -R "$install_dir/include/freerdp3/." "$headers_dir/"
  cp -R "$install_dir/include/winpr3/." "$headers_dir/"
  cp -R "$openssl_prefix/include/openssl" "$headers_dir/"

  local target
  if [[ "$sdk" == "iphonesimulator" ]]; then
    target="arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator"
  elif [[ "$sdk" == "macosx" ]]; then
    target="arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-macabi"
  else
    target="arm64-apple-ios${IOS_DEPLOYMENT_TARGET}"
  fi
  printf '%s\n' \
    '#include <freerdp/freerdp.h>' \
    '#include <winpr/wtypes.h>' \
    '#include <openssl/ssl.h>' |
    xcrun --sdk "$sdk" clang -target "$target" -fsyntax-only -x c -I "$headers_dir" -

  while IFS= read -r archive; do
    archives+=("$archive")
  done < <(find "$install_dir" -type f -name '*.a' -print | LC_ALL=C sort)
  archives+=("$openssl_prefix/lib/libssl.a" "$openssl_prefix/lib/libcrypto.a")

  ((${#archives[@]} >= 5)) || die "unexpectedly small static archive set for $slice"
  log "merging ${#archives[@]} static archives for $slice"
  /usr/bin/libtool -static -o "$output_library" "${archives[@]}"
  /usr/bin/ranlib "$output_library"

  local architectures
  architectures="$(xcrun lipo -archs "$output_library")"
  [[ "$architectures" == "arm64" ]] || die "unexpected architecture for $slice: $architectures"
}

build_openssl_slice device iphoneos iPhoneOS
build_freerdp_slice device OS64 iphoneos
package_slice device iphoneos

build_openssl_slice simulator iphonesimulator iPhoneSimulator
build_freerdp_slice simulator SIMULATORARM64 iphonesimulator
package_slice simulator iphonesimulator

build_openssl_slice maccatalyst macosx MacOSX
build_freerdp_slice maccatalyst MAC_CATALYST_ARM64 macosx
package_slice maccatalyst macosx

verify_freerdp_source "$FREERDP_SOURCE_DIR"

normalize_xcframework_plist() {
  local plist="$1/Info.plist"
  local wanted=(ios-arm64 ios-arm64-simulator ios-arm64-maccatalyst)
  local count index identifier position

  # xcodebuild emits the slices in no fixed order, which would make otherwise
  # identical output differ. Move each wanted slice to the end in turn.
  count="$(plutil -extract AvailableLibraries raw -o - "$plist")"
  [[ "$count" == "${#wanted[@]}" ]] || die "unexpected XCFramework slice count: $count"
  for identifier in "${wanted[@]}"; do
    position=""
    for ((index = 0; index < count; index++)); do
      if [[ "$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$index:LibraryIdentifier" "$plist")" == "$identifier" ]]; then
        position="$index"
      fi
    done
    [[ -n "$position" ]] || die "XCFramework slice is missing: $identifier"
    /usr/libexec/PlistBuddy -c "Copy :AvailableLibraries:$position :MRemoteMovedLibrary" "$plist"
    /usr/libexec/PlistBuddy -c "Delete :AvailableLibraries:$position" "$plist"
    /usr/libexec/PlistBuddy -c "Copy :MRemoteMovedLibrary :AvailableLibraries:$((count - 1))" "$plist"
    /usr/libexec/PlistBuddy -c 'Delete :MRemoteMovedLibrary' "$plist"
  done
}

assert_no_input_paths() {
  local artifact="$1"
  local source_path build_root_path forbidden match
  source_path="$(cd "$FREERDP_SOURCE_DIR" && pwd -P)"
  build_root_path="$(cd "$BUILD_ROOT" && pwd -P)"

  # Check both the caller's spelling and the physical path. On macOS /tmp is
  # an alias for /private/tmp, and build tools can preserve either spelling.
  for forbidden in "$FREERDP_SOURCE_DIR" "$source_path" "$BUILD_ROOT" "$build_root_path"; do
    match="$(LC_ALL=C grep -R -a -F -l -- "$forbidden" "$artifact" 2>/dev/null | head -n 1 || true)"
    [[ -z "$match" ]] || die "build input path remains in artifact: $forbidden ($match)"
  done
}

[[ ! -e "$OUTPUT_PATH" ]] || die "output already exists; choose a fresh --output path: $OUTPUT_PATH"
log "creating $XCFRAMEWORK_NAME"
xcodebuild -create-xcframework \
  -library "$BUILD_ROOT/slices/device/package/libmremote-freerdp.a" \
  -headers "$BUILD_ROOT/slices/device/package/Headers" \
  -library "$BUILD_ROOT/slices/simulator/package/libmremote-freerdp.a" \
  -headers "$BUILD_ROOT/slices/simulator/package/Headers" \
  -library "$BUILD_ROOT/slices/maccatalyst/package/libmremote-freerdp.a" \
  -headers "$BUILD_ROOT/slices/maccatalyst/package/Headers" \
  -output "$OUTPUT_PATH"

normalize_xcframework_plist "$OUTPUT_PATH"
assert_no_input_paths "$OUTPUT_PATH"
"$SCRIPT_DIR/verify-freerdp-xcframework.sh" "$OUTPUT_PATH"
"$SCRIPT_DIR/generate-dependency-metadata.sh" \
  --output "$(dirname "$OUTPUT_PATH")/FreeRDP.spdx.json"

checksum_file="$(dirname "$OUTPUT_PATH")/$(basename "$OUTPUT_PATH").sha256"
(
  cd "$(dirname "$OUTPUT_PATH")"
  find "$(basename "$OUTPUT_PATH")" -type f -print | LC_ALL=C sort | while IFS= read -r file; do
    shasum -a 256 "$file"
  done
) > "$checksum_file"

log "build complete: $OUTPUT_PATH"
log "checksums: $checksum_file"
