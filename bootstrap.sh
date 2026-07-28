#!/usr/bin/env bash
# Spare — one-shot project bootstrap (macOS only).
# Installs XcodeGen if missing, generates the Xcode project, opens it.
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen not found — installing via Homebrew..."
  if ! command -v brew >/dev/null 2>&1; then
    echo "error: Homebrew is required (https://brew.sh)" >&2
    exit 1
  fi
  brew install xcodegen
fi

xcodegen generate
echo "Generated Spare.xcodeproj"
open Spare.xcodeproj
