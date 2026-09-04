#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 INPUT_BASELINE.json" >&2
  exit 64
fi

record_path=$1
if [[ ! -f "$record_path" ]]; then
  echo "input baseline does not exist: $record_path" >&2
  exit 66
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to validate input baseline records" >&2
  exit 69
fi

jq -e '
  def present:
    if type != "string" then false
    else
      (gsub("^\\s+|\\s+$"; "")) as $value
      | ($value | length) > 0
        and (($value | startswith("__REQUIRED")) | not)
    end;
  def only_keys($allowed):
    type == "object" and ((keys_unsorted - $allowed) | length == 0);
  def rfc3339:
    present and test(
      "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"
    );
  def mapping:
    only_keys(["label", "hid_usage", "set1_scan_code", "windows_virtual_key"])
    and (.label | present)
    and (.hid_usage | type == "string" and test("^0x[0-9A-F]{2}$"))
    and (.set1_scan_code | type == "string" and test("^0x[0-9A-F]{2}$"))
    and (.windows_virtual_key | type == "string" and test("^0x[0-9A-F]{2}$"));
  def required_mapping($usage; $scan; $vk):
    any(.expected_mappings[];
      .hid_usage == $usage and .set1_scan_code == $scan and .windows_virtual_key == $vk);

  only_keys([
    "schema_version", "record_id", "captured_at", "operator", "device", "os",
    "keyboard", "pointer", "ipados_settings", "harness", "windows_target",
    "connection", "expected_mappings", "notes"
  ])
  and .schema_version == 1
  and (.record_id | present)
  and (.captured_at | rfc3339)
  and (.operator | present)
  and (.device | only_keys(["model_name", "model_identifier", "soc"]))
  and (.device.model_name | present)
  and (.device.model_identifier | present)
  and (.device.soc | present)
  and (.os | only_keys(["product_version", "build"]))
  and (.os.product_version | present)
  and (.os.build | present)
  and (.keyboard | only_keys(["manufacturer", "model", "layout", "transport", "firmware"]))
  and (.keyboard.manufacturer | present)
  and (.keyboard.model | present)
  and (.keyboard.layout | IN("jis", "us", "other"))
  and (.keyboard.transport | IN("smart_connector", "usb", "bluetooth"))
  and (.keyboard.firmware | present)
  and (.pointer | only_keys(["manufacturer", "model", "kind", "transport", "firmware"]))
  and (.pointer.manufacturer | present)
  and (.pointer.model | present)
  and (.pointer.kind | IN("mouse", "trackpad", "none"))
  and (.pointer.transport | IN("integrated", "smart_connector", "usb", "bluetooth", "none"))
  and (.pointer.firmware | present)
  and (.ipados_settings | only_keys([
    "hardware_keyboard_layout", "full_keyboard_access", "stage_manager", "window_mode",
    "caps_lock_switches_language", "globe_key_action", "modifier_remapping",
    "active_input_sources", "other_accessibility_keyboard_features"
  ]))
  and (.ipados_settings.hardware_keyboard_layout | present)
  and (.ipados_settings.full_keyboard_access | type == "boolean")
  and (.ipados_settings.stage_manager | type == "boolean")
  and (.ipados_settings.window_mode | IN("full_screen", "split_view", "stage_manager"))
  and (.ipados_settings.caps_lock_switches_language | type == "boolean")
  and (.ipados_settings.globe_key_action | present)
  and (.ipados_settings.modifier_remapping
    | only_keys(["caps_lock", "control", "option", "command", "globe"])
      and length == 5
      and all(.[]; present))
  and (.ipados_settings.active_input_sources | type == "array" and length > 0)
  and (all(.ipados_settings.active_input_sources[]; present))
  and (.ipados_settings.other_accessibility_keyboard_features | present)
  and (.harness | only_keys([
    "git_commit", "build_configuration", "call_super", "keyboard_source_policy"
  ]))
  and (.harness.git_commit | present)
  and (.harness.build_configuration | IN("Debug", "Release"))
  and (.harness.call_super | type == "boolean")
  and (.harness.keyboard_source_policy | only_keys(["0x90", "0x91"]) and length == 2)
  and (.harness.keyboard_source_policy["0x90"] | IN("uikit", "game_controller", "unsupported"))
  and (.harness.keyboard_source_policy["0x91"] | IN("uikit", "game_controller", "unsupported"))
  and (.windows_target | only_keys([
    "edition", "version", "build", "keyboard_layout", "keyboard_type", "ime",
    "ime_key_assignments", "keyecho_version"
  ]))
  and (.windows_target.edition | present)
  and (.windows_target.version | present)
  and (.windows_target.build | present)
  and .windows_target.keyboard_layout == "0x00000411"
  and .windows_target.keyboard_type == 7
  and (.windows_target.ime | present)
  and (.windows_target.ime_key_assignments | present)
  and (.windows_target.keyecho_version | present)
  and (.connection | only_keys(["transport", "rdp_server_kind", "network_notes"]))
  and (.connection.transport | IN("wifi", "ethernet", "other"))
  and (.connection.rdp_server_kind | IN("physical", "virtual_machine", "cloud"))
  and (.connection.network_notes | present)
  and (.expected_mappings | type == "array" and length >= 2 and all(.[]; mapping))
  and required_mapping("0x91"; "0x7B"; "0x1D")
  and required_mapping("0x90"; "0x79"; "0x1C")
  and (.notes | type == "string")
  and ([.. | strings | select(gsub("^\\s+"; "") | startswith("__REQUIRED"))] | length == 0)
' -- "$record_path" >/dev/null || {
  echo "invalid or incomplete input baseline: $record_path" >&2
  exit 65
}

echo "valid input baseline: $record_path"
