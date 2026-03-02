#!/opt/homebrew/bin/bash
# Build DisplayTuner from source
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "Building DisplayTuner..."
swiftc -O \
    "$PROJECT_DIR/Sources/DisplayTunerV3.swift" \
    -o "$PROJECT_DIR/DisplayTuner" \
    -framework AppKit \
    -framework CoreImage \
    -framework QuartzCore \
    -framework ScreenCaptureKit \
    2>&1

if [[ $? -eq 0 ]]; then
    echo "Build successful: $PROJECT_DIR/DisplayTuner"
    ls -lh "$PROJECT_DIR/DisplayTuner"
else
    echo "Build failed."
    exit 1
fi
