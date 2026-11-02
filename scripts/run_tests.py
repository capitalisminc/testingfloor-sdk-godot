#!/usr/bin/env python3
"""Run the Godot SDK's tests headless and fail on any failed test or script error.

    python3 scripts/run_tests.py --godot /path/to/godot

A GDScript runtime error stops the function it happens in but not the test run,
so this also fails when Godot prints an error, even if every check passed.
"""

import argparse
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ERROR_MARKERS = ("SCRIPT ERROR:", "ERROR:", "Parse Error:")


def run(godot, *arguments):
    result = subprocess.run([godot, "--headless", "--path", str(ROOT), *arguments],
                            capture_output=True, text=True, timeout=600)
    return result.returncode, result.stdout + result.stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--godot", default=os.environ.get("GODOT", "godot"), help="the Godot 4.4 or later executable")
    arguments = parser.parse_args()

    # Importing builds the class-name cache the tests resolve TestingFloorClient through.
    code, output = run(arguments.godot, "--import")
    errors = [line for line in output.splitlines() if any(marker in line for marker in ERROR_MARKERS)]
    code, output = run(arguments.godot, "--script", "res://tests/run_tests.gd")
    print(output)
    errors += [line for line in output.splitlines() if any(marker in line for marker in ERROR_MARKERS)]
    if errors:
        print(f"Godot reported {len(errors)} error lines, starting with: {errors[0]}", file=sys.stderr)
        return 1
    return code


if __name__ == "__main__":
    sys.exit(main())
