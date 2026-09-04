#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
records_dir=$(cd "$test_dir/.." && pwd)
validator="$records_dir/validate-phase0-markdown.sh"
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/mremote-phase0-markdown-test.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT

draft_test_record="$test_tmp/draft-test-record.md"
sed \
  -e 's/__REQUIRED_OR_REDACTED__/redacted/g' \
  -e 's/__REQUIRED__\.json/input-baseline-redacted.json/g' \
  -e 's/__REQUIRED__/redacted/g' \
  -e 's/__PENDING__/pending/g' \
  "$records_dir/phase0-test-record.template.md" > "$draft_test_record"

make_all_pass_test_record() {
  local source=$1
  local output=$2
  local decision=$3
  awk -F '|' -v OFS='|' -v gate_decision="$decision" '
    /^\|[[:space:]]*`/ && $3 ~ /`(PASS|FAIL|BLOCKED|NOT RUN)`/ {
      $3 = " `PASS` "
      $4 = " evidence-" NR "-sha256 "
    }
    /^- Decision:/ {
      $0 = "- Decision: `" gate_decision "` (`GO`, `NO-GO`, or `UNDECIDED`)"
    }
    /^- Accepted FreeRDP version\/commit:/ {
      $0 = "- Accepted FreeRDP version/commit: `3.31.1 / redacted-commit`"
    }
    /^- Deferred validation:/ {
      $0 = "- Deferred validation: `pointer, channels, audio, 4K, and multi-session`"
    }
    /^- Rationale and unresolved risks:/ {
      $0 = "- Rationale and unresolved risks: reviewed; no unresolved Gate risks"
    }
    { print }
  ' "$source" > "$output"
}

make_matrix() {
  local output=$1
  local test_record_name=$2
  sed \
    -e 's/__REQUIRED_OR_REDACTED__/redacted/g' \
    -e 's/__REQUIRED__\.json/input-baseline-redacted.json/g' \
    -e "s/__REQUIRED__\.md/$test_record_name/g" \
    -e 's/__REQUIRED__/1/g' \
    -e '/^| `1` |/s/| `NOT RUN` |/| `PASS` |/' \
    -e 's/- `FAIL`: `1`/- `FAIL`: `0`/' \
    -e 's/- `BLOCKED`: `1`/- `BLOCKED`: `0`/' \
    -e 's/- `NOT RUN`: `1`/- `NOT RUN`: `0`/' \
    -e 's/- Missing agreed combinations: `1`/- Missing agreed combinations: `0`/' \
    -e 's/- Status: `INCOMPLETE`/- Status: `COMPLETE`/' \
    "$records_dir/phase0-matrix.template.md" > "$output"
}

all_pass_test_record="$test_tmp/all-pass-undecided.md"
make_all_pass_test_record "$draft_test_record" "$all_pass_test_record" UNDECIDED

go_test_record="$test_tmp/phase0-test-complete.md"
make_all_pass_test_record "$draft_test_record" "$go_test_record" GO

complete_matrix="$test_tmp/phase0-matrix-complete.md"
make_matrix "$complete_matrix" "$(basename "$go_test_record")"

incomplete_matrix="$test_tmp/phase0-matrix-incomplete.md"
sed \
  -e '/^| `1` |/s/| `PASS` |/| `NOT RUN` |/' \
  -e 's/- `PASS`: `1`/- `PASS`: `0`/' \
  -e 's/- `NOT RUN`: `0`/- `NOT RUN`: `1`/' \
  -e 's/- Status: `COMPLETE`/- Status: `INCOMPLETE`/' \
  "$complete_matrix" > "$incomplete_matrix"

incomplete_missing_matrix="$test_tmp/phase0-matrix-incomplete-missing.md"
sed \
  -e 's/- Agreed combination count: `1`/- Agreed combination count: `2`/' \
  -e 's/- Missing agreed combinations: `0`/- Missing agreed combinations: `1`/' \
  "$incomplete_matrix" > "$incomplete_missing_matrix"

"$validator" "$draft_test_record" >/dev/null
"$validator" "$all_pass_test_record" >/dev/null
"$validator" "$incomplete_matrix" >/dev/null
"$validator" "$incomplete_missing_matrix" >/dev/null
"$validator" "$go_test_record" "$complete_matrix" >/dev/null

crlf_test_record="$test_tmp/draft-test-record-crlf.md"
awk '{ printf "%s\r\n", $0 }' "$draft_test_record" > "$crlf_test_record"
"$validator" "$crlf_test_record" >/dev/null

expect_invalid_copy() {
  local name=$1
  local source=$2
  local sed_expression=$3
  local output="$test_tmp/$name.md"
  sed "$sed_expression" "$source" > "$output"
  if "$validator" "$output" >/dev/null 2>&1; then
    echo "expected invalid Phase 0 Markdown record to be rejected: $name" >&2
    exit 1
  fi
}

expect_invalid_files() {
  local name=$1
  shift
  if "$validator" "$@" >/dev/null 2>&1; then
    echo "expected invalid Phase 0 Gate set to be rejected: $name" >&2
    exit 1
  fi
}

expect_invalid_files test-template "$records_dir/phase0-test-record.template.md"
expect_invalid_files matrix-template "$records_dir/phase0-matrix.template.md"

expect_invalid_copy test-placeholder "$draft_test_record" \
  's/| Run ID | `redacted` |/| Run ID | `__REQUIRED__` |/'
expect_invalid_copy test-invalid-result "$draft_test_record" \
  '/`P0-BUILD-01`/s/`NOT RUN`/`SKIPPED`/'
expect_invalid_copy test-contradictory-result "$draft_test_record" \
  '/`P0-BUILD-01`/s/`NOT RUN`/`NOT RUN` actually PASS/'
expect_invalid_copy test-invalid-decision "$draft_test_record" \
  's/- Decision: `UNDECIDED`/- Decision: `MAYBE`/'
expect_invalid_copy test-duplicate-decision "$draft_test_record" \
  '/^- Decision:/p'
expect_invalid_copy test-contradictory-decision "$draft_test_record" \
  's/- Decision: `UNDECIDED`/- Decision: `UNDECIDED` actually GO/'
expect_invalid_copy test-missing-id "$draft_test_record" \
  '/`P0-TEARDOWN-01`/d'
expect_invalid_copy test-duplicate-id "$draft_test_record" \
  's/`P0-TEARDOWN-01`/`P0-BUILD-01`/'
expect_invalid_copy test-missing-metadata "$draft_test_record" \
  '/| Git commit |/d'
expect_invalid_copy test-blank-metadata "$draft_test_record" \
  's/| Git commit | `redacted` |/| Git commit | |/'
expect_invalid_copy test-blank-gate-field "$draft_test_record" \
  's/- Deferred validation: `pending`/- Deferred validation:/'
expect_invalid_copy test-extra-result-column "$draft_test_record" \
  '/`P0-BUILD-01`/s/|$/| extra |/'

fenced_test_record="$test_tmp/fenced-test-record.md"
awk 'NR == 1 { print "```text" } { print }' \
  "$draft_test_record" > "$fenced_test_record"
expect_invalid_files test-fenced-content "$fenced_test_record"

guidance_only_pass="$test_tmp/guidance-only-pass.md"
sed '/^|[[:space:]]*`/s/| `NOT RUN` |/| `PASS` |/' \
  "$draft_test_record" > "$guidance_only_pass"
expect_invalid_files test-guidance-as-evidence "$guidance_only_pass"
expect_invalid_copy test-blank-pass-evidence "$all_pass_test_record" \
  '/`P0-BUILD-01`/s/| evidence-[^|]* |/| |/'

"$validator" "$go_test_record" >/dev/null
expect_invalid_files complete-matrix-without-linked-record "$complete_matrix"

no_go_test_record="$test_tmp/all-pass-no-go.md"
make_all_pass_test_record "$draft_test_record" "$no_go_test_record" NO-GO
mixed_decision_matrix="$test_tmp/phase0-matrix-mixed-decisions.md"
sed 's/`phase0-test-complete.md`/`phase0-test-complete.md`, `all-pass-no-go.md`/' \
  "$complete_matrix" > "$mixed_decision_matrix"
"$validator" "$go_test_record" "$no_go_test_record" "$mixed_decision_matrix" >/dev/null

nonpass_matrix="$test_tmp/phase0-matrix-nonpass-link.md"
make_matrix "$nonpass_matrix" "$(basename "$draft_test_record")"
expect_invalid_files complete-matrix-linked-to-nonpass \
  "$draft_test_record" "$nonpass_matrix"
expect_invalid_files complete-matrix-missing-named-link \
  "$all_pass_test_record" "$complete_matrix"

expect_invalid_copy matrix-placeholder "$incomplete_matrix" \
  's/| Matrix ID | `1` |/| Matrix ID | `__REQUIRED__` |/'
expect_invalid_copy matrix-invalid-result "$incomplete_matrix" \
  '/^| `1` |/s/| `NOT RUN` |/| `SKIPPED` |/'
expect_invalid_copy matrix-contradictory-result "$incomplete_matrix" \
  '/^| `1` |/s/| `NOT RUN` |/| `NOT RUN` actually PASS |/'
expect_invalid_copy matrix-invalid-status "$incomplete_matrix" \
  's/- Status: `INCOMPLETE`/- Status: `UNKNOWN`/'
expect_invalid_copy matrix-duplicate-status "$incomplete_matrix" \
  '/^- Status:/p'
expect_invalid_copy matrix-contradictory-status "$incomplete_matrix" \
  's/- Status: `INCOMPLETE`/- Status: `INCOMPLETE` actually COMPLETE/'
expect_invalid_copy matrix-row-count "$incomplete_matrix" \
  's/- Rows present: `1`/- Rows present: `2`/'
expect_invalid_copy matrix-pass-count "$incomplete_matrix" \
  's/- `PASS`: `0`/- `PASS`: `1`/'
expect_invalid_copy matrix-missing-count "$incomplete_matrix" \
  's/- Missing agreed combinations: `0`/- Missing agreed combinations: `1`/'
expect_invalid_copy matrix-count-trailing-text "$incomplete_matrix" \
  's/- Rows present: `1`/- Rows present: `1` approximately/'
expect_invalid_copy matrix-missing-metadata "$incomplete_matrix" \
  '/| FreeRDP commit |/d'
expect_invalid_copy matrix-blank-combination-cell "$incomplete_matrix" \
  '/^| `1` |/s/| `1` | `input-baseline/| | `input-baseline/'
expect_invalid_copy matrix-blank-baseline-link "$incomplete_matrix" \
  '/^| `1` |/s/| `input-baseline-redacted.json` |/| |/'
expect_invalid_copy matrix-blank-test-link "$incomplete_matrix" \
  '/^| `1` |/s/| `phase0-test-complete.md` |/| |/'
expect_invalid_copy matrix-extra-column "$incomplete_matrix" \
  '/^| `1` |/s/|$/| extra |/'
expect_invalid_copy matrix-duplicate-combination "$incomplete_matrix" \
  '/^| `1` |/p'
expect_invalid_copy matrix-blank-review-notes "$incomplete_matrix" \
  's/- Review notes: `1`/- Review notes:/'

false_complete_matrix="$test_tmp/false-complete-matrix.md"
sed 's/- Status: `INCOMPLETE`/- Status: `COMPLETE`/' \
  "$incomplete_matrix" > "$false_complete_matrix"
expect_invalid_files matrix-false-complete "$false_complete_matrix"

echo "Phase 0 Markdown validator tests passed"
