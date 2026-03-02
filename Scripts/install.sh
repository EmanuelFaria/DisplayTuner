#!/opt/homebrew/bin/bash
# Install DisplayTuner binary
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BINARY="$PROJECT_DIR/DisplayTuner"
INSTALL_DIR="${1:-$HOME/.claude/bin}"

if [[ ! -f "$BINARY" ]]; then
    echo "Binary not found. Run build.sh first."
    exit 1
fi

mkdir -p "$INSTALL_DIR"
cp "$BINARY" "$INSTALL_DIR/DisplayTuner"
chmod +x "$INSTALL_DIR/DisplayTuner"
echo "Installed to $INSTALL_DIR/DisplayTuner"

# Also install the raw passthrough ICC profile
PROFILE_SRC="$PROJECT_DIR/Resources/raw_passthrough.icc"
PROFILE_DST="$HOME/Library/ColorSync/Profiles/Raw_Passthrough.icc"
if [[ -f "$PROFILE_SRC" ]]; then
    mkdir -p "$(dirname "$PROFILE_DST")"
    cp "$PROFILE_SRC" "$PROFILE_DST"
    echo "Installed Raw Passthrough ICC profile to $PROFILE_DST"
fi
