#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
records_dir=$(cd "$test_dir/.." && pwd)
validator="$records_dir/validate-input-baseline.sh"
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/mremote-baseline-test.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 69
fi

jq empty \
  "$records_dir/input-baseline.schema.json" \
  "$records_dir/input-baseline.template.json" \
  "$records_dir/development-host.json"

jq '
  walk(
    if type == "string" and startswith("__REQUIRED") then "redacted"
    else . end
  )
  | .captured_at = "2026-09-04T13:00:00+09:00"
' "$records_dir/input-baseline.template.json" > "$test_tmp/valid.json"

"$validator" "$test_tmp/valid.json" >/dev/null

expect_invalid() {
  local name=$1
  local filter=$2
  local output="$test_tmp/$name.json"
  jq "$filter" "$test_tmp/valid.json" > "$output"
  if "$validator" "$output" >/dev/null 2>&1; then
    echo "expected invalid baseline to be rejected: $name" >&2
    exit 1
  fi
}

if "$validator" "$records_dir/input-baseline.template.json" >/dev/null 2>&1; then
  echo "uncompleted template must be rejected" >&2
  exit 1
fi

expect_invalid missing-pointer-manufacturer 'del(.pointer.manufacturer)'
expect_invalid missing-windows-version 'del(.windows_target.version)'
expect_invalid nested-extra-field '.device.unexpected = "not allowed"'
expect_invalid root-extra-field '.unexpected = true'
expect_invalid incomplete-modifier-remapping 'del(.ipados_settings.modifier_remapping.globe)'
expect_invalid extra-source-policy '.harness.keyboard_source_policy["0x92"] = "uikit"'
expect_invalid invalid-timestamp '.captured_at = "2026-09-04 13:00"'
expect_invalid whitespace-record-id '.record_id = "   "'
expect_invalid malformed-mapping '.expected_mappings[0].set1_scan_code = "0x7b"'

echo "input baseline validator tests passed"
