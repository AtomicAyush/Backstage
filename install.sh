#!/bin/bash
# Build Backstage and install it:
#   ~/.local/bin/backstage       the CLI and MCP server that agents launch
#   /Applications/Backstage.app  the menu-bar app for watching and taking over agent screens
# then connect it to the agents on this Mac (Claude Code, the Claude app, Codex).
#
#   ./install.sh               build, install, connect
#   ./install.sh --no-setup    build and install, but leave agent configuration alone
#   ./install.sh --build-only  just assemble build/Backstage.app and build/backstage
#
# The app is signed with a real Apple Development certificate rather than ad-hoc. That matters:
# macOS records Screen Recording permission against the code signature, and an ad-hoc signature
# gets a fresh hash on every build, so each rebuild would look like a brand-new app and lose it.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

MODE="${1:-}"
APP="build/Backstage.app"
CONTENTS="$APP/Contents"
BIN_DIR="$HOME/.local/bin"

echo "Building (release)…"
swift build -c release
BUILT="$(swift build -c release --show-bin-path)"

echo "Assembling $APP…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BUILT/BackstageViewer" "$CONTENTS/MacOS/BackstageViewer"
cp scripts/Viewer-Info.plist "$CONTENTS/Info.plist"
if [ -f scripts/AppIcon.icns ]; then cp scripts/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"; fi
cp "$BUILT/backstage" build/backstage

# Prefer a real identity; fall back to ad-hoc so the script still works without one.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Apple Development" | head -1 | awk '{print $2}' || true)
if [ -z "$IDENTITY" ]; then
    echo "No Apple Development certificate found — signing ad-hoc."
    echo "macOS will ask for Screen Recording again after each rebuild of the app."
    IDENTITY="-"
fi
echo "Signing with ${IDENTITY}…"
codesign --force --sign "$IDENTITY" --timestamp=none -i com.ayush.Backstage.cli build/backstage
codesign --force --options runtime --sign "$IDENTITY" --timestamp=none "$APP"

if [ "$MODE" = "--build-only" ]; then
    echo
    echo "Built $APP and build/backstage."
    exit 0
fi

echo "Installing…"
mkdir -p "$BIN_DIR"
cp build/backstage "$BIN_DIR/backstage"
pkill -x BackstageViewer 2>/dev/null || true
rm -rf /Applications/Backstage.app
cp -R "$APP" /Applications/

echo
"$BIN_DIR/backstage" doctor || true
echo

if [ "$MODE" != "--no-setup" ]; then
    "$BIN_DIR/backstage" setup
fi

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo; echo "Note: $BIN_DIR is not on your PATH. Add it to run \`backstage\` by name." ;;
esac
echo
echo "Installed. Try it with:  backstage try"
