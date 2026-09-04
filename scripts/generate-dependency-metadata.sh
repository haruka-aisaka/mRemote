#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK_FILE="$REPO_ROOT/config/dependencies/freerdp.lock"
TEMPLATE="$REPO_ROOT/ThirdParty/SBOM.spdx.json.in"
OUTPUT="$REPO_ROOT/ThirdParty/SBOM.spdx.json"

# shellcheck disable=SC1090
source "$LOCK_FILE"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --output)
      (($# >= 2)) || die "--output requires a path"
      OUTPUT="$2"
      shift 2
      ;;
    -h|--help)
      printf 'Usage: scripts/generate-dependency-metadata.sh [--output PATH]\n'
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ -f "$TEMPLATE" ]] || die "SBOM template missing: $TEMPLATE"
mkdir -p "$(dirname "$OUTPUT")"
temporary="$OUTPUT.tmp.$$"
trap 'rm -f "$temporary"' EXIT

sed \
  -e "s|@FREERDP_VERSION@|$FREERDP_VERSION|g" \
  -e "s|@FREERDP_COMMIT@|$FREERDP_COMMIT|g" \
  -e "s|@FREERDP_GIT_URL@|$FREERDP_GIT_URL|g" \
  -e "s|@OPENSSL_VERSION@|$OPENSSL_VERSION|g" \
  -e "s|@OPENSSL_TAG@|$OPENSSL_TAG|g" \
  -e "s|@OPENSSL_ARCHIVE_URL@|$OPENSSL_ARCHIVE_URL|g" \
  -e "s|@OPENSSL_ARCHIVE_SHA256@|$OPENSSL_ARCHIVE_SHA256|g" \
  -e "s|@TPCIRCULARBUFFER_C_SHA256@|$TPCIRCULARBUFFER_C_SHA256|g" \
  -e "s|@TPCIRCULARBUFFER_H_SHA256@|$TPCIRCULARBUFFER_H_SHA256|g" \
  -e "s|@SOLAR_MD4_C_SHA256@|$SOLAR_MD4_C_SHA256|g" \
  -e "s|@SOLAR_MD4_H_SHA256@|$SOLAR_MD4_H_SHA256|g" \
  -e "s|@SOLAR_MD5_C_SHA256@|$SOLAR_MD5_C_SHA256|g" \
  -e "s|@SOLAR_MD5_H_SHA256@|$SOLAR_MD5_H_SHA256|g" \
  -e "s|@WINPR_HASHTABLE_C_SHA256@|$WINPR_HASHTABLE_C_SHA256|g" \
  -e "s|@WINPR_WINDOWS_ZONES_C_SHA256@|$WINPR_WINDOWS_ZONES_C_SHA256|g" \
  -e "s|@SBOM_CREATED@|$SBOM_CREATED|g" \
  "$TEMPLATE" > "$temporary"

if command -v jq >/dev/null 2>&1; then
  jq --exit-status . "$temporary" >/dev/null
elif command -v ruby >/dev/null 2>&1; then
  ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0)))' "$temporary"
else
  printf 'warning: jq/ruby unavailable; generated JSON was not syntax-checked\n' >&2
fi
mv "$temporary" "$OUTPUT"
trap - EXIT
printf 'generated: %s\n' "$OUTPUT"
