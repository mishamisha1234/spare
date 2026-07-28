#!/usr/bin/env python3
"""Pick an available iOS simulator UDID from `xcrun simctl list devices`.

Hardcoding a device name in CI breaks whenever the runner image changes its
simulator set, and the resulting xcodebuild error is opaque. This resolves a
real UDID from the runner's own device list instead, preferring the newest
iPhone available.

Usage:
    xcrun simctl list devices available --json | pick_simulator.py

Prints the chosen UDID on stdout; a human-readable summary on stderr.
Exits non-zero when the runner has no available iOS simulator.
"""

import json
import re
import sys


def runtime_version(runtime: str) -> tuple:
    """Sort key from a runtime identifier like
    'com.apple.CoreSimulator.SimRuntime.iOS-18-2' -> (18, 2)."""
    numbers = re.findall(r"\d+", runtime.rsplit(".", 1)[-1])
    return tuple(int(n) for n in numbers) or (0,)


def model_number(name: str) -> tuple:
    """Sort key from a device name like 'iPhone 16 Pro' -> (16,)."""
    numbers = re.findall(r"\d+", name)
    return tuple(int(n) for n in numbers) or (0,)


def main() -> int:
    try:
        devices_by_runtime = json.load(sys.stdin)["devices"]
    except (json.JSONDecodeError, KeyError) as error:
        print(f"could not parse simctl output: {error}", file=sys.stderr)
        return 2

    candidates = []
    for runtime, devices in devices_by_runtime.items():
        if "iOS" not in runtime:
            continue
        for device in devices:
            if not device.get("isAvailable", False):
                continue
            if not device.get("udid"):
                continue
            name = device.get("name", "")
            candidates.append((runtime, name, device["udid"]))

    if not candidates:
        print("no available iOS simulator on this runner", file=sys.stderr)
        return 1

    # Prefer a plain iPhone over iPad or a Pro/Max variant, then the newest
    # runtime, then the highest model number.
    def rank(candidate: tuple) -> tuple:
        runtime, name, _ = candidate
        is_iphone = name.startswith("iPhone")
        is_plain = " Pro" not in name and " Max" not in name and " mini" not in name
        return (
            0 if is_iphone else 1,
            0 if is_plain else 1,
            [-part for part in runtime_version(runtime)],
            [-part for part in model_number(name)],
            name,
        )

    runtime, name, udid = min(candidates, key=rank)
    print(f"selected {name} on {runtime} ({udid})", file=sys.stderr)
    print(udid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
