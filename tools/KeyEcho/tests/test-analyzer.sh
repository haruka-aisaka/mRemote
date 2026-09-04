#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
analyzer="$test_dir/../analyze-keyecho.sh"
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/mremote-keyecho-test.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT

expect_rejected() {
  local input_path=$1
  if "$analyzer" "$input_path" 1 >/dev/null 2>&1; then
    echo "expected KeyEcho sample to be rejected: $input_path" >&2
    exit 1
  fi
}

"$analyzer" "$test_dir/sample-pass.jsonl" 1 >/dev/null
expect_rejected "$test_dir/sample-fail.jsonl"

jq -c 'select(.type == "metadata" or .scan_code == "0x7B")' \
  "$test_dir/sample-pass.jsonl" > "$test_tmp/eisu-only.jsonl"
"$analyzer" "$test_tmp/eisu-only.jsonl" 1 eisu >/dev/null
if "$analyzer" "$test_tmp/eisu-only.jsonl" 1 both >/dev/null 2>&1; then
  echo "expected an EISU-only run to fail both-target analysis" >&2
  exit 1
fi
if "$analyzer" "$test_dir/sample-pass.jsonl" 1 eisu >/dev/null 2>&1; then
  echo "expected an EISU run containing KANA events to be rejected" >&2
  exit 1
fi

jq -c 'if .type == "metadata" then del(.keyecho_version) else . end' \
  "$test_dir/sample-pass.jsonl" > "$test_tmp/missing-metadata-field.jsonl"
expect_rejected "$test_tmp/missing-metadata-field.jsonl"

jq -c 'if .type == "event" and .sequence == 2 then .sequence = 1 else . end' \
  "$test_dir/sample-pass.jsonl" > "$test_tmp/duplicate-sequence.jsonl"
expect_rejected "$test_tmp/duplicate-sequence.jsonl"

jq -c 'if .type == "event" and .sequence >= 2 then .sequence += 1 else . end' \
  "$test_dir/sample-pass.jsonl" > "$test_tmp/sequence-gap.jsonl"
expect_rejected "$test_tmp/sequence-gap.jsonl"

jq -c 'if .type == "event" and .sequence == 2 then .monotonic_ns = 0 else . end' \
  "$test_dir/sample-pass.jsonl" > "$test_tmp/reversed-time.jsonl"
expect_rejected "$test_tmp/reversed-time.jsonl"

jq -c 'if .type == "event" and .sequence == 1 then del(.injected) else . end' \
  "$test_dir/sample-pass.jsonl" > "$test_tmp/incomplete-event.jsonl"
expect_rejected "$test_tmp/incomplete-event.jsonl"

jq -c '.' "$test_dir/sample-pass.jsonl" > "$test_tmp/unexpected-event.jsonl"
jq -c '
  select(.type == "event" and .sequence == 4)
  | .sequence = 5
  | .monotonic_ns = 5
  | .scan_code = "0x20"
  | .vk_code = "0x20"
' "$test_dir/sample-pass.jsonl" >> "$test_tmp/unexpected-event.jsonl"
expect_rejected "$test_tmp/unexpected-event.jsonl"

jq -c '.' "$test_dir/sample-pass.jsonl" > "$test_tmp/repeated-metadata.jsonl"
jq -c 'select(.type == "metadata")' "$test_dir/sample-pass.jsonl" \
  >> "$test_tmp/repeated-metadata.jsonl"
expect_rejected "$test_tmp/repeated-metadata.jsonl"

if "$analyzer" "$test_dir/sample-pass.jsonl" 1000001 >/dev/null 2>&1; then
  echo "expected excessive cycle count to be rejected" >&2
  exit 1
fi
if "$analyzer" "$test_dir/sample-pass.jsonl" 1 unknown >/dev/null 2>&1; then
  echo "expected unknown target mode to be rejected" >&2
  exit 1
fi

echo "KeyEcho analyzer tests passed"
