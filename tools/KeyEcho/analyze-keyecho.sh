#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "usage: $0 KeyEcho.jsonl [expected-cycles, default: 100] [both|eisu|kana]" >&2
  exit 64
fi

keyecho_path=$1
expected_cycles=${2:-100}
target_mode=${3:-both}

if [[ ! -f "$keyecho_path" ]]; then
  echo "KeyEcho result does not exist: $keyecho_path" >&2
  exit 66
fi
if [[ ! "$expected_cycles" =~ ^[1-9][0-9]*$ ]]; then
  echo "expected-cycles must be a positive integer" >&2
  exit 64
fi
if (( ${#expected_cycles} > 7 )) || (( 10#$expected_cycles > 1000000 )); then
  echo "expected-cycles must be at most 1000000" >&2
  exit 64
fi
if [[ "$target_mode" != "both" && "$target_mode" != "eisu" && "$target_mode" != "kana" ]]; then
  echo "target mode must be both, eisu, or kana" >&2
  exit 64
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 69
fi

analysis_json=$(jq -s --argjson expected "$expected_cycles" --arg target "$target_mode" '
  def nonempty_string:
    type == "string" and length > 0;
  def hex_code:
    type == "string" and test("^0x[0-9A-F]{2,8}$");
  def valid_metadata:
    type == "object"
    and .type == "metadata"
    and (.keyecho_version | nonempty_string)
    and (.computer | nonempty_string)
    and (.windows | nonempty_string)
    and (.clock | nonempty_string);
  def valid_event:
    type == "object"
    and .type == "event"
    and (.sequence | type == "number" and . >= 1 and floor == .)
    and (.monotonic_ns | type == "number" and . >= 0 and floor == .)
    and (.action == "down" or .action == "up")
    and (.scan_code | hex_code)
    and (.extended | type == "boolean")
    and (.vk_code | hex_code)
    and (.vk_name | type == "string")
    and (.injected | type == "boolean")
    and (.alt_down | type == "boolean");
  def ordered_events:
    reduce .[] as $event
      ({ok: true, previous_sequence: null, previous_ns: null};
       .ok = (.ok
         and (.previous_sequence == null or $event.sequence == (.previous_sequence + 1))
         and (.previous_ns == null or $event.monotonic_ns >= .previous_ns))
       | .previous_sequence = $event.sequence
       | .previous_ns = $event.monotonic_ns)
    | .ok;
  def target($scan; $vk):
    reduce (.[] | select(.type == "event" and .scan_code == $scan)) as $event
      ({down: 0, up: 0, repeat: 0, orphan_up: 0, mismatch: 0, pressed: false};
       (if ($event.vk_code != $vk or $event.extended != false) then
          .mismatch += 1
        else . end)
       | if $event.action == "down" then
           if .pressed then .repeat += 1
           else .down += 1 | .pressed = true end
         elif $event.action == "up" then
           .up += 1
           | if .pressed then .pressed = false else .orphan_up += 1 end
         else .mismatch += 1 end);
  def clean_cycles($value; $count):
    $value.down == $count
    and $value.up == $count
    and $value.repeat == 0
    and $value.orphan_up == 0
    and $value.mismatch == 0
    and $value.pressed == false;

  if length == 0 or (.[0] | valid_metadata | not) then
    error("first JSON Lines object must be complete KeyEcho metadata")
  elif ([.[] | select(type == "object" and .type == "metadata")] | length) != 1 then
    error("KeyEcho JSON Lines must contain exactly one metadata object")
  elif (all(.[1:][]; valid_event) | not) then
    error("every row after metadata must be a complete KeyEcho event")
  elif (.[1:] | ordered_events | not) then
    error("event sequence must be contiguous and monotonic_ns must not decrease")
  else
    {
      keyecho_version: .[0].keyecho_version,
      expected_cycles: $expected,
      target_mode: $target,
      eisu: target("0x7B"; "0x1D"),
      kana: target("0x79"; "0x1C"),
      unexpected_events: ([.[]
        | select(.type == "event")
        | select(
            if $target == "eisu" then .scan_code != "0x7B"
            elif $target == "kana" then .scan_code != "0x79"
            else .scan_code != "0x7B" and .scan_code != "0x79"
            end
          )] | length)
    }
    | .pass = (
        if $target == "eisu" then
          clean_cycles(.eisu; $expected) and clean_cycles(.kana; 0)
        elif $target == "kana" then
          clean_cycles(.kana; $expected) and clean_cycles(.eisu; 0)
        else
          clean_cycles(.eisu; $expected) and clean_cycles(.kana; $expected)
        end
        and .unexpected_events == 0
      )
  end
' -- "$keyecho_path")

printf '%s\n' "$analysis_json"
jq -e '.pass == true' >/dev/null <<<"$analysis_json" || exit 1
