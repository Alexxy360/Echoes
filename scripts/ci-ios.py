"""Compile Release, then run demo UI tests on an available iOS 26.1+ simulator."""
from pathlib import Path
import json
import re
import subprocess

root = Path(__file__).resolve().parents[1]
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
candidates = []
for runtime, entries in devices["devices"].items():
    version = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not version or tuple(map(int, version.groups())) < (26, 1):
        continue
    candidates.extend(device for device in entries if device["isAvailable"] and "iPhone" in device["name"])
if not candidates:
    raise SystemExit("An iOS 26.1+ iPhone Simulator runtime is required.")
device = next((item for item in candidates if item["state"] == "Booted"), candidates[0])
if device["state"] != "Booted":
    subprocess.run(["xcrun", "simctl", "boot", device["udid"]], check=True)
subprocess.run(["xcrun", "simctl", "bootstatus", device["udid"], "-b"], check=True)
base = ["xcodebuild", "-project", str(root / "Echoes.xcodeproj"), "-scheme", "Echoes",
        "-derivedDataPath", str(root / ".ci-deriveddata"),
        "CODE_SIGNING_ALLOWED=NO", "COMPILATION_CACHE_ENABLE_CACHING=NO"]
subprocess.run(base + ["-configuration", "Release", "-destination", "generic/platform=iOS", "build"], check=True)
subprocess.run(base + ["-configuration", "Debug", "-destination", "platform=iOS Simulator,id=" + device["udid"],
                      "-parallel-testing-enabled", "NO", "test"], check=True)
