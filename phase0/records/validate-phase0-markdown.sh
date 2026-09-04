#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "usage: $0 PHASE0_TEST_RECORD_OR_MATRIX.md [...]" >&2
  exit 64
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
test_record_template="$script_dir/phase0-test-record.template.md"

fail() {
  echo "invalid or incomplete Phase 0 Markdown record: $1${2:+: $2}" >&2
  return 65
}

reject_unsupported_content() {
  local record_path=$1
  if LC_ALL=C grep -Eq '__[A-Z][A-Z0-9_]*__' -- "$record_path"; then
    fail "$record_path" "uncompleted placeholder"
  fi
  if LC_ALL=C grep -Eq '^[[:space:]]*(```|~~~)' -- "$record_path"; then
    fail "$record_path" "fenced blocks are not allowed in a Gate record"
  fi
}

validate_test_record() {
  local record_path=$1

  LC_ALL=C awk \
    -v record_path="$record_path" \
    -v template_path="$test_record_template" '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }

    function present(value, unwrapped) {
      value = trim(value)
      if (value == "") {
        return 0
      }
      if (substr(value, 1, 1) == "`" && substr(value, length(value), 1) == "`") {
        unwrapped = substr(value, 2, length(value) - 2)
        return trim(unwrapped) != ""
      }
      return 1
    }

    function exact_code_value(value, inner) {
      value = trim(value)
      if (length(value) < 3 || substr(value, 1, 1) != "`" ||
          substr(value, length(value), 1) != "`") {
        return "__MALFORMED_CODE_VALUE__"
      }
      inner = substr(value, 2, length(value) - 2)
      if (index(inner, "`") != 0) {
        return "__MALFORMED_CODE_VALUE__"
      }
      return inner
    }

    function prefixed_id(value, remainder, closing) {
      value = trim(value)
      if (substr(value, 1, 1) != "`") {
        return "__MALFORMED_ID__"
      }
      value = substr(value, 2)
      closing = index(value, "`")
      if (closing == 0) {
        return "__MALFORMED_ID__"
      }
      remainder = trim(substr(value, closing + 1))
      if (remainder == "") {
        return "__MALFORMED_ID__"
      }
      return substr(value, 1, closing - 1)
    }

    function decision_value(value, suffix) {
      value = trim(value)
      suffix = " (`GO`, `NO-GO`, or `UNDECIDED`)"
      if (length(value) >= length(suffix) &&
          substr(value, length(value) - length(suffix) + 1) == suffix) {
        value = substr(value, 1, length(value) - length(suffix))
      }
      return exact_code_value(value)
    }

    function pending_value(value, normalized) {
      value = trim(value)
      if (substr(value, 1, 1) == "`" && substr(value, length(value), 1) == "`") {
        value = substr(value, 2, length(value) - 2)
      }
      normalized = tolower(trim(value))
      return normalized == "pending" || normalized == "tbd" || normalized == "unknown"
    }

    function report(message) {
      print "invalid or incomplete Phase 0 test record: " record_path ": " message > "/dev/stderr"
      invalid = 1
    }

    function set_gate_field(name, value) {
      gate_seen[name]++
      gate_value[name] = trim(value)
    }

    BEGIN {
      required_text = "P0-BUILD-01 P0-TLS-01 P0-DSP-01 KEY-EISU-01 KEY-KANA-01 KEY-IME-02 P0-TEARDOWN-01"
      required_count = split(required_text, required, " ")
      for (i = 1; i <= required_count; i++) {
        expected[required[i]] = 1
      }

      metadata_names[1] = "Run ID"
      metadata_names[2] = "Date/time and timezone"
      metadata_names[3] = "Git commit"
      metadata_names[4] = "FreeRDP commit"
      metadata_names[5] = "Harness build/configuration"
      metadata_names[6] = "Windows target (redacted name)"
      metadata_names[7] = "Operator"
      for (i = 1; i <= 7; i++) {
        expected_metadata[metadata_names[i]] = 1
      }

      gate_names[1] = "Accepted FreeRDP version/commit"
      gate_names[2] = "Minimum OS"
      gate_names[3] = "Deferred validation"
      gate_names[4] = "Rationale and unresolved risks"

      template_in_results = 0
      while ((getline template_line < template_path) > 0) {
        sub(/\r$/, "", template_line)
        if (template_line == "## Results") {
          template_in_results = 1
          continue
        }
        if (template_in_results && template_line ~ /^## /) {
          template_in_results = 0
        }
        if (template_in_results && template_line ~ /^\|[[:space:]]*`/) {
          split(template_line, template_columns, "|")
          template_id = prefixed_id(template_columns[2])
          if (template_id != "__MALFORMED_ID__") {
            canonical_evidence[template_id] = trim(template_columns[4])
          }
        }
      }
      close(template_path)
    }

    {
      sub(/\r$/, "")
    }

    $0 == "# Phase 0 Core Adoption test record" {
      title_count++
    }

    $0 == "## Run metadata" {
      metadata_heading_count++
      in_metadata = 1
      next
    }

    in_metadata && /^## / {
      in_metadata = 0
    }

    in_metadata && /^\|[[:space:]]*Field[[:space:]]*\|[[:space:]]*Value[[:space:]]*\|$/ {
      metadata_header_count++
      metadata_rows_started = 1
      next
    }

    in_metadata && metadata_rows_started && /^\|[[:space:]]*:?-+/ {
      next
    }

    in_metadata && metadata_rows_started && /^\|/ {
      column_count = split($0, columns, "|")
      if (column_count != 4) {
        report("Run metadata rows must contain exactly two cells")
        next
      }
      field = trim(columns[2])
      value = trim(columns[3])
      metadata_seen[field]++
      if (!(field in expected_metadata)) {
        report("unexpected Run metadata field " field)
      }
      if (!present(value)) {
        report("blank Run metadata value for " field)
      }
    }

    $0 == "## Results" {
      in_results = 1
      results_heading_count++
      next
    }

    in_results && /^## / {
      in_results = 0
    }

    in_results && $0 == "| ID | Result | Evidence / measured value | Notes |" {
      results_header_count++
      results_rows_started = 1
      next
    }

    in_results && results_rows_started && /^\|[[:space:]]*:?-+/ {
      next
    }

    in_results && results_rows_started && /^\|/ {
      column_count = split($0, columns, "|")
      if (column_count != 6) {
        report("Results rows must contain exactly four cells and no pipe characters")
        next
      }

      id = prefixed_id(columns[2])
      if (id == "__MALFORMED_ID__") {
        report("malformed Results row ID/description")
        next
      }
      result = exact_code_value(columns[3])
      evidence = trim(columns[4])

      row_count++
      seen[id]++
      if (!(id in expected)) {
        report("unexpected test ID " id)
      }
      if (result != "PASS" && result != "FAIL" && result != "BLOCKED" && result != "NOT RUN") {
        report("invalid result for " id ": " result)
      } else {
        if (result != "PASS") {
          non_pass_count++
        } else if (!present(evidence)) {
          report("PASS requires non-empty evidence for " id)
        } else if (evidence == canonical_evidence[id]) {
          report("PASS evidence still contains template guidance for " id)
        }
      }
    }

    $0 == "## Gate decision" {
      gate_heading_count++
    }

    /^- Decision:[[:space:]]*/ {
      decision_count++
      decision = $0
      sub(/^- Decision:[[:space:]]*/, "", decision)
      decision = decision_value(decision)
    }

    /^- Accepted FreeRDP version\/commit:[[:space:]]*/ {
      value = $0
      sub(/^- Accepted FreeRDP version\/commit:[[:space:]]*/, "", value)
      set_gate_field("Accepted FreeRDP version/commit", value)
    }
    /^- Deferred validation:[[:space:]]*/ {
      value = $0
      sub(/^- Deferred validation:[[:space:]]*/, "", value)
      set_gate_field("Deferred validation", value)
    }
    /^- Minimum OS:[[:space:]]*/ {
      value = $0
      sub(/^- Minimum OS:[[:space:]]*/, "", value)
      set_gate_field("Minimum OS", value)
    }
    /^- Rationale and unresolved risks:[[:space:]]*/ {
      value = $0
      sub(/^- Rationale and unresolved risks:[[:space:]]*/, "", value)
      set_gate_field("Rationale and unresolved risks", value)
    }

    END {
      if (title_count != 1) {
        report("expected exactly one test-record title")
      }
      if (metadata_heading_count != 1 || metadata_header_count != 1) {
        report("missing or duplicate Run metadata table")
      }
      for (i = 1; i <= 7; i++) {
        field = metadata_names[i]
        if (metadata_seen[field] != 1) {
          report("missing or duplicate Run metadata field " field)
        }
      }
      if (results_heading_count != 1 || results_header_count != 1) {
        report("missing or duplicate Results table")
      }
      for (i = 1; i <= required_count; i++) {
        id = required[i]
        if (!(id in seen)) {
          report("missing required test ID " id)
        } else if (seen[id] != 1) {
          report("duplicate required test ID " id)
        }
      }
      if (row_count != required_count) {
        report("Results row count does not match the required test set")
      }
      if (gate_heading_count != 1) {
        report("missing or duplicate Gate decision section")
      }
      if (decision_count != 1) {
        report("missing or duplicate Gate decision")
      } else if (decision != "GO" && decision != "NO-GO" && decision != "UNDECIDED") {
        report("invalid Gate decision: " decision)
      } else if (decision == "GO" && non_pass_count != 0) {
        report("GO requires every Results row to be PASS")
      }
      for (i = 1; i <= 4; i++) {
        field = gate_names[i]
        if (gate_seen[field] != 1) {
          report("missing or duplicate Gate field " field)
        } else if (!present(gate_value[field])) {
          report("blank Gate field " field)
        } else if (decision == "GO" && pending_value(gate_value[field])) {
          report("GO cannot retain pending Gate field " field)
        }
      }
      if (!invalid) {
        print decision "\t" (non_pass_count == 0 ? "PASS" : "NONPASS")
      }
      exit invalid ? 65 : 0
    }
  ' "$record_path"
}

validate_matrix() {
  local record_path=$1

  LC_ALL=C awk -v record_path="$record_path" '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }

    function present(value, unwrapped) {
      value = trim(value)
      if (value == "") {
        return 0
      }
      if (substr(value, 1, 1) == "`" && substr(value, length(value), 1) == "`") {
        unwrapped = substr(value, 2, length(value) - 2)
        return trim(unwrapped) != ""
      }
      return 1
    }

    function exact_code_value(value, inner) {
      value = trim(value)
      if (length(value) < 3 || substr(value, 1, 1) != "`" ||
          substr(value, length(value), 1) != "`") {
        return "__MALFORMED_CODE_VALUE__"
      }
      inner = substr(value, 2, length(value) - 2)
      if (index(inner, "`") != 0) {
        return "__MALFORMED_CODE_VALUE__"
      }
      return inner
    }

    function plain_or_code_value(value, unwrapped) {
      value = trim(value)
      if (substr(value, 1, 1) == "`") {
        return exact_code_value(value)
      }
      if (index(value, "`") != 0) {
        return "__MALFORMED_CODE_VALUE__"
      }
      return value
    }

    function status_value(value, suffix) {
      value = trim(value)
      suffix = " (`COMPLETE` or `INCOMPLETE`)"
      if (length(value) >= length(suffix) &&
          substr(value, length(value) - length(suffix) + 1) == suffix) {
        value = substr(value, 1, length(value) - length(suffix))
      }
      return exact_code_value(value)
    }

    function report(message) {
      print "invalid or incomplete Phase 0 matrix: " record_path ": " message > "/dev/stderr"
      invalid = 1
    }

    function set_count(name, value) {
      count_seen[name]++
      declared[name] = exact_code_value(trim(value))
    }

    function parse_references(value, parts, part_count, part, reference, base, i) {
      value = trim(value)
      part_count = split(value, parts, ",")
      if (part_count == 0) {
        report("Phase 0 test record(s) must name at least one Markdown file")
        return
      }
      for (i = 1; i <= part_count; i++) {
        part = trim(parts[i])
        reference = plain_or_code_value(part)
        if (reference == "__MALFORMED_CODE_VALUE__" ||
            reference !~ /^[A-Za-z0-9._\/-]+\.md$/ ||
            reference ~ /(^|\/)\.\.?($|\/)/) {
          report("invalid Phase 0 test-record reference " part)
          continue
        }
        base = reference
        sub(/^.*\//, "", base)
        if ((base in reference_path_by_base) && reference_path_by_base[base] != reference) {
          report("ambiguous test-record basename " base)
          continue
        }
        reference_path_by_base[base] = reference
        matrix_reference[base]++
      }
    }

    BEGIN {
      numeric_counts = 1
      metadata_names[1] = "Matrix ID"
      metadata_names[2] = "Git commit"
      metadata_names[3] = "FreeRDP commit"
      metadata_names[4] = "Candidate channel/codec set"
      metadata_names[5] = "Minimum OS under test"
      metadata_names[6] = "Agreed matrix scope / review reference"
      metadata_names[7] = "Reviewer"
      for (i = 1; i <= 7; i++) {
        expected_metadata[metadata_names[i]] = 1
      }
      count_names[1] = "agreed"
      count_names[2] = "rows"
      count_names[3] = "PASS"
      count_names[4] = "FAIL"
      count_names[5] = "BLOCKED"
      count_names[6] = "NOT RUN"
      count_names[7] = "missing"
      result_names[1] = "PASS"
      result_names[2] = "FAIL"
      result_names[3] = "BLOCKED"
      result_names[4] = "NOT RUN"
    }

    {
      sub(/\r$/, "")
    }

    $0 == "# Phase 0 matrix completion record" {
      title_count++
    }

    $0 == "## Candidate metadata" {
      metadata_heading_count++
      in_metadata = 1
      next
    }

    in_metadata && /^## / {
      in_metadata = 0
    }

    in_metadata && /^\|[[:space:]]*Field[[:space:]]*\|[[:space:]]*Value[[:space:]]*\|$/ {
      metadata_header_count++
      metadata_rows_started = 1
      next
    }

    in_metadata && metadata_rows_started && /^\|[[:space:]]*:?-+/ {
      next
    }

    in_metadata && metadata_rows_started && /^\|/ {
      column_count = split($0, columns, "|")
      if (column_count != 4) {
        report("Candidate metadata rows must contain exactly two cells")
        next
      }
      field = trim(columns[2])
      value = trim(columns[3])
      metadata_seen[field]++
      if (!(field in expected_metadata)) {
        report("unexpected Candidate metadata field " field)
      }
      if (!present(value)) {
        report("blank Candidate metadata value for " field)
      }
    }

    $0 == "## Agreed combinations" {
      in_combinations = 1
      combinations_heading_count++
      next
    }

    in_combinations && /^## / {
      in_combinations = 0
    }

    in_combinations && $0 == "| Combination ID | Device / OS build | Keyboard / transport | Pointer / transport | iPadOS settings profile | Windows target / build / layout | Input baseline record | Phase 0 test record(s) | Result | Notes |" {
      combinations_header_count++
      combinations_rows_started = 1
      next
    }

    in_combinations && combinations_rows_started && /^\|[[:space:]]*:?-+/ {
      next
    }

    in_combinations && combinations_rows_started && /^\|/ {
      column_count = split($0, columns, "|")
      if (column_count != 12) {
        report("combination rows must contain exactly ten cells and no pipe characters")
        next
      }

      id = exact_code_value(columns[2])
      result = exact_code_value(columns[10])
      if (id == "__MALFORMED_CODE_VALUE__" || id == "") {
        report("missing or malformed Combination ID")
        next
      }
      for (i = 3; i <= 9; i++) {
        if (!present(columns[i])) {
          report("blank required combination cell " (i - 1) " for " id)
        }
      }

      baseline_reference = plain_or_code_value(columns[8])
      if (baseline_reference == "__MALFORMED_CODE_VALUE__" ||
          baseline_reference !~ /^[A-Za-z0-9._\/-]+\.json$/ ||
          baseline_reference ~ /(^|\/)\.\.?($|\/)/) {
        report("invalid input-baseline reference for " id)
      }
      parse_references(columns[9])

      row_count++
      combination_seen[id]++
      if (combination_seen[id] > 1) {
        report("duplicate Combination ID " id)
      }
      if (result != "PASS" && result != "FAIL" && result != "BLOCKED" && result != "NOT RUN") {
        report("invalid result for combination " id ": " result)
      } else {
        actual[result]++
      }
    }

    $0 == "## Completeness review" {
      completeness_heading_count++
    }

    /^- Agreed combination count:[[:space:]]*/ {
      value = $0
      sub(/^- Agreed combination count:[[:space:]]*/, "", value)
      set_count("agreed", value)
    }
    /^- Rows present:[[:space:]]*/ {
      value = $0
      sub(/^- Rows present:[[:space:]]*/, "", value)
      set_count("rows", value)
    }
    /^- `PASS`:[[:space:]]*/ {
      value = $0
      sub(/^- `PASS`:[[:space:]]*/, "", value)
      set_count("PASS", value)
    }
    /^- `FAIL`:[[:space:]]*/ {
      value = $0
      sub(/^- `FAIL`:[[:space:]]*/, "", value)
      set_count("FAIL", value)
    }
    /^- `BLOCKED`:[[:space:]]*/ {
      value = $0
      sub(/^- `BLOCKED`:[[:space:]]*/, "", value)
      set_count("BLOCKED", value)
    }
    /^- `NOT RUN`:[[:space:]]*/ {
      value = $0
      sub(/^- `NOT RUN`:[[:space:]]*/, "", value)
      set_count("NOT RUN", value)
    }
    /^- Missing agreed combinations:[[:space:]]*/ {
      value = $0
      sub(/^- Missing agreed combinations:[[:space:]]*/, "", value)
      set_count("missing", value)
    }
    /^- Status:[[:space:]]*/ {
      status_count++
      status = $0
      sub(/^- Status:[[:space:]]*/, "", status)
      status = status_value(status)
    }
    /^- Review notes:[[:space:]]*/ {
      review_notes_count++
      review_notes = $0
      sub(/^- Review notes:[[:space:]]*/, "", review_notes)
    }

    END {
      if (title_count != 1) {
        report("expected exactly one matrix title")
      }
      if (metadata_heading_count != 1 || metadata_header_count != 1) {
        report("missing or duplicate Candidate metadata table")
      }
      for (i = 1; i <= 7; i++) {
        field = metadata_names[i]
        if (metadata_seen[field] != 1) {
          report("missing or duplicate Candidate metadata field " field)
        }
      }
      if (combinations_heading_count != 1 || combinations_header_count != 1) {
        report("missing or duplicate Agreed combinations table")
      }
      if (row_count == 0) {
        report("matrix must contain at least one combination row")
      }
      if (completeness_heading_count != 1) {
        report("missing or duplicate Completeness review section")
      }

      for (i = 1; i <= 7; i++) {
        name = count_names[i]
        if (count_seen[name] != 1) {
          report("missing or duplicate completeness count " name)
        } else if (declared[name] !~ /^(0|[1-9][0-9]*)$/) {
          report("completeness count " name " must be one exact non-negative integer")
          numeric_counts = 0
        }
      }

      if (numeric_counts != 0) {
        if ((declared["rows"] + 0) != row_count) {
          report("Rows present does not match the combination table")
        }
        declared_result_total = 0
        for (i = 1; i <= 4; i++) {
          name = result_names[i]
          declared_result_total += declared[name] + 0
          if ((declared[name] + 0) != (actual[name] + 0)) {
            report(name " count does not match the combination table")
          }
        }
        if (declared_result_total != row_count) {
          report("result counts do not add up to Rows present")
        }
        if ((declared["agreed"] + 0) != row_count + (declared["missing"] + 0)) {
          report("agreed count must equal rows present plus missing combinations")
        }
      }

      if (status_count != 1) {
        report("missing or duplicate completeness Status")
      } else if (status != "COMPLETE" && status != "INCOMPLETE") {
        report("invalid completeness Status: " status)
      } else if (status == "COMPLETE") {
        if (numeric_counts == 0 || row_count == 0 ||
            (declared["agreed"] + 0) != row_count ||
            (declared["missing"] + 0) != 0 ||
            (actual["PASS"] + 0) != row_count) {
          report("COMPLETE requires all agreed combinations to be present and PASS")
        }
      }
      if (review_notes_count != 1 || !present(review_notes)) {
        report("missing, duplicate, or blank Review notes")
      }
      if (!invalid) {
        print status
        for (reference in matrix_reference) {
          print reference
        }
      }
      exit invalid ? 65 : 0
    }
  ' "$record_path"
}

input_paths=()
test_paths=()
test_names=()
test_decisions=()
test_pass_states=()
matrix_count=0
input_count=0
test_count=0
matrix_path=""
matrix_status=""
matrix_references=""

for record_path in "$@"; do
  if [[ ! -f "$record_path" ]]; then
    echo "Phase 0 Markdown record does not exist: $record_path" >&2
    exit 66
  fi

  record_directory=$(cd "$(dirname "$record_path")" && pwd -P)
  normalized_path="$record_directory/$(basename "$record_path")"
  if [[ $input_count -gt 0 ]]; then
    for previous_path in "${input_paths[@]}"; do
      if [[ "$normalized_path" == "$previous_path" ]]; then
        fail "$record_path" "duplicate input path"
      fi
    done
  fi
  input_paths[$input_count]=$normalized_path
  input_count=$((input_count + 1))

  reject_unsupported_content "$record_path"

  if LC_ALL=C grep -Eq $'^# Phase 0 Core Adoption test record\r?$' -- "$record_path"; then
    test_metadata=$(validate_test_record "$record_path")
    test_decision=${test_metadata%%$'\t'*}
    test_pass_state=${test_metadata#*$'\t'}
    test_name=$(basename "$record_path")
    if [[ $test_count -gt 0 ]]; then
      for previous_name in "${test_names[@]}"; do
        if [[ "$test_name" == "$previous_name" ]]; then
          fail "$record_path" "test-record basenames must be unique in one validation"
        fi
      done
    fi
    test_paths[$test_count]=$record_path
    test_names[$test_count]=$test_name
    test_decisions[$test_count]=$test_decision
    test_pass_states[$test_count]=$test_pass_state
    test_count=$((test_count + 1))
  elif LC_ALL=C grep -Eq $'^# Phase 0 matrix completion record\r?$' -- "$record_path"; then
    matrix_count=$((matrix_count + 1))
    if [[ $matrix_count -gt 1 ]]; then
      fail "$record_path" "validate at most one candidate matrix at a time"
    fi
    matrix_metadata=$(validate_matrix "$record_path")
    matrix_status=${matrix_metadata%%$'\n'*}
    if [[ "$matrix_metadata" == *$'\n'* ]]; then
      matrix_references=${matrix_metadata#*$'\n'}
    else
      matrix_references=""
    fi
    matrix_path=$record_path
  else
    fail "$record_path" "unrecognized record type"
  fi
done

has_go=0
if [[ $test_count -gt 0 ]]; then
  for decision in "${test_decisions[@]}"; do
    if [[ "$decision" == "GO" ]]; then
      has_go=1
    fi
  done
fi

if [[ $matrix_count -eq 1 && "$matrix_status" == "COMPLETE" ]]; then
  if [[ $test_count -eq 0 ]]; then
    fail "$matrix_path" "COMPLETE requires every linked test record in the same validation command"
  fi

  for pass_state in "${test_pass_states[@]}"; do
    if [[ "$pass_state" != "PASS" ]]; then
      fail "$matrix_path" "COMPLETE requires every supplied test record Results row to be PASS"
    fi
  done

  reference_count=0
  while IFS= read -r reference_name; do
    [[ -n "$reference_name" ]] || continue
    reference_count=$((reference_count + 1))
    reference_found=0
    for test_name in "${test_names[@]}"; do
      if [[ "$reference_name" == "$test_name" ]]; then
        reference_found=1
      fi
    done
    if [[ $reference_found -eq 0 ]]; then
      fail "$matrix_path" "linked test record was not supplied: $reference_name"
    fi
  done <<< "$matrix_references"

  if [[ $reference_count -eq 0 ]]; then
    fail "$matrix_path" "COMPLETE matrix has no parseable test-record references"
  fi

  for test_name in "${test_names[@]}"; do
    test_is_linked=0
    while IFS= read -r reference_name; do
      if [[ "$test_name" == "$reference_name" ]]; then
        test_is_linked=1
      fi
    done <<< "$matrix_references"
    if [[ $test_is_linked -eq 0 ]]; then
      fail "$matrix_path" "supplied test record is not linked by the matrix: $test_name"
    fi
  done
fi

for record_path in "${input_paths[@]}"; do
  echo "structurally valid Phase 0 Markdown record: $record_path"
done

if [[ $matrix_count -eq 1 && "$matrix_status" == "COMPLETE" ]]; then
  echo "cross-file COMPLETE prerequisites are structurally consistent (evidence still requires review)"
fi
