#!/usr/bin/env python3
"""Keep App/Clew/Localizable.xcstrings in step with the strings the compiler extracts.

AGENTS.md rule 8: all UI text lives in the String Catalog. Xcode's IDE syncs the
catalog on build, but command-line builds do not, so this script does it from the
.stringsdata files a build leaves in DerivedData.

  scripts/sync-strings.py <derived-data>          add missing keys, mark unused ones stale
  scripts/sync-strings.py <derived-data> --check  exit 1 if any extracted key is missing
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "App" / "Clew" / "Localizable.xcstrings"


def extracted_keys(derived: pathlib.Path) -> dict:
    keys = {}
    pattern = "Build/Intermediates.noindex/Clew.build/*/Clew.build/Objects-normal/*/*.stringsdata"
    files = list(derived.glob(pattern))
    if not files:
        sys.exit(f"No .stringsdata under {derived}. Build the Clew scheme first.")
    for path in files:
        data = json.loads(path.read_text())
        for entry in data.get("tables", {}).get("Localizable", []):
            keys.setdefault(entry["key"], entry.get("comment", ""))
    return keys


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 1:
        sys.exit(__doc__)
    check = "--check" in sys.argv
    keys = extracted_keys(pathlib.Path(args[0]))
    catalog = json.loads(CATALOG.read_text())
    strings = catalog.setdefault("strings", {})

    missing = sorted(k for k in keys if k not in strings)
    if check:
        if missing:
            print("Missing from Localizable.xcstrings (run scripts/sync-strings.py):")
            for k in missing:
                print(f"  {k!r}")
            sys.exit(1)
        print(f"String Catalog covers all {len(keys)} extracted keys.")
        return

    for key in missing:
        strings[key] = {}
    for key, entry in strings.items():
        if key in keys:
            entry.pop("extractionState", None)
            if keys[key]:
                entry["comment"] = keys[key]
        else:
            entry["extractionState"] = "stale"
    catalog["strings"] = dict(sorted(strings.items()))
    CATALOG.write_text(json.dumps(catalog, indent=2, ensure_ascii=False, separators=(",", " : ")) + "\n")
    print(f"Added {len(missing)} keys; catalog has {len(strings)}.")


if __name__ == "__main__":
    main()
