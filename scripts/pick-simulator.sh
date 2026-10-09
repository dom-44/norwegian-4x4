#!/bin/sh
# Prints the UDID of an available iPhone simulator on the newest installed iOS runtime.
set -e
xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)["devices"]
ios = sorted((k for k in data if "iOS" in k), key=lambda k: [int(p) for p in k.rsplit("iOS-", 1)[-1].split("-") if p.isdigit()])
for runtime in reversed(ios):
    phones = [d for d in data[runtime] if d.get("isAvailable") and d["name"].startswith("iPhone")]
    if phones:
        print(phones[0]["udid"])
        sys.exit(0)
sys.exit("No available iPhone simulator found")
'
