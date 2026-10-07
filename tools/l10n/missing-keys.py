#!/usr/bin/env python3
"""Lists strings the app uses that App/Localizable.xcstrings lacks or has
not translated, from the .stringsdata files a build leaves behind.

Xcode adds new keys to the catalog when it builds in the IDE; a build from
the command line does not, so run this after one:

    tools/l10n/missing-keys.py <DerivedData>/Build/Intermediates.noindex

Exits 1 when anything is missing, for use in a check.
"""
import glob
import json
import os
import re
import sys

root = sys.argv[1] if len(sys.argv) > 1 else "."
catalog_path = os.path.join(os.path.dirname(__file__), "..", "..", "App", "Localizable.xcstrings")
catalog = json.load(open(catalog_path))["strings"]
japanese = re.compile(r"[ぁ-んァ-ヶ一-龠]")

used = {}
for path in glob.glob(os.path.join(root, "**", "mRemote.build", "**", "*.stringsdata"), recursive=True):
    data = json.load(open(path))
    for entries in data["tables"].values():
        for entry in entries:
            used.setdefault(entry["key"], os.path.basename(data["source"]))

problems = 0
for key, source in sorted(used.items()):
    entry = catalog.get(key)
    if entry is None:
        print(f"missing      {source}: {key!r}")
        problems += 1
    elif japanese.search(key) and "en" not in entry.get("localizations", {}):
        print(f"untranslated {source}: {key!r}")
        problems += 1
print(f"{len(used)} keys used, {problems} to fix")
sys.exit(1 if problems else 0)
