#!/usr/bin/env python3
"""Structural checks that can run without macOS/Xcode."""
from pathlib import Path
import json
import plistlib
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
errors: list[str] = []

sources = sorted((root / "GreenSight").glob("*.swift"))
pbx = (root / "GreenSight.xcodeproj/project.pbxproj").read_text()
for source in sources:
    if source.name not in pbx:
        errors.append(f"source absent from pbxproj: {source.name}")

for path in root.glob("GreenSight/Assets.xcassets/**/Contents.json"):
    try:
        json.loads(path.read_text())
    except Exception as exc:
        errors.append(f"invalid JSON {path}: {exc}")

try:
    with (root / "GreenSight/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if "NSCameraUsageDescription" not in info:
        errors.append("missing NSCameraUsageDescription")
    if "arkit" not in info.get("UIRequiredDeviceCapabilities", []):
        errors.append("missing ARKit device capability")
except Exception as exc:
    errors.append(f"invalid Info.plist: {exc}")

for source in sources:
    text = source.read_text()
    # Coarse delimiter balance after removing strings/comments; Xcode remains authoritative.
    scrubbed = re.sub(r'//.*|"(?:\\.|[^"\\])*"', '', text)
    for left, right in (("{", "}"), ("(", ")"), ("[", "]")):
        if scrubbed.count(left) != scrubbed.count(right):
            errors.append(f"unbalanced {left}{right} in {source.name}")

icon = root / "GreenSight/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
if not icon.exists() or icon.stat().st_size < 10_000:
    errors.append("missing or implausibly small 1024px app icon")

result = subprocess.run([sys.executable, str(root / "Scripts/reference_validation.py")], capture_output=True, text=True)
if result.returncode:
    errors.append(result.stdout + result.stderr)
else:
    print(result.stdout.strip())

if errors:
    print("project validation failed:")
    for error in errors: print(" -", error)
    raise SystemExit(1)
print(f"project validation: {len(sources)} Swift sources, plist/assets/pbxproj checks passed")
