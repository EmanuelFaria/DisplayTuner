#!/opt/homebrew/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

trap 'echo "Build failed."; exit 1' ERR

echo "Building DisplayTuner..."
swiftc -O \
    "$PROJECT_DIR/Sources/DisplayTunerV3.swift" \
    -o "$PROJECT_DIR/DisplayTuner" \
    -framework AppKit \
    -framework CoreImage \
    -framework QuartzCore \
    2>&1

echo "Build successful: $PROJECT_DIR/DisplayTuner"
ls -lh "$PROJECT_DIR/DisplayTuner"
