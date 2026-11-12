import json
import pathlib
import plistlib
import re
import subprocess
import sys

generated = pathlib.Path(sys.argv[1])
keys = set()
for source in generated.glob("*.stringsdata"):
    records = json.loads(source.read_text())["tables"].get("Localizable", [])
    keys.update(record["key"] for record in records)
if not keys:
    sys.exit("Swift did not extract any localization keys.")

spec = re.compile(r"%(?:lld|@)")
for language in ("en", "ru"):
    path = pathlib.Path("Resources") / f"{language}.lproj" / "Localizable.strings"
    translations = plistlib.loads(subprocess.check_output(["plutil", "-convert", "xml1", "-o", "-", str(path)]))
    missing = keys - translations.keys()
    stale = translations.keys() - keys
    if missing or stale:
        sys.exit(f"{language}: missing {sorted(missing)}, stale {sorted(stale)}")
    for key, translation in translations.items():
        if spec.findall(key) != spec.findall(translation):
            sys.exit(f"{language}: format arguments changed for {key!r}")
print(f"PASS · all {len(keys)} interface strings available in English and Russian")
