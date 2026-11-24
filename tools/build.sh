#!/bin/zsh
# Builds Hovr (Release), installs it in /Applications, relaunches it and checks its resource use.
# Usage: tools/build.sh            build, install, check
#        tools/build.sh --draft    build and run from the build folder (no install), check
#        tools/build.sh --zip      also write build/release/Hovr.zip for a GitHub release
set -euo pipefail
cd "$(dirname "$0")/.."

# Build outside the project folder: ~/Documents syncs with iCloud Drive, which tags bundle
# folders with attributes that break code signing.
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/Hovr-cli"

python3 tools/gen_project.py >/dev/null
LOG="$DERIVED/build.log"
mkdir -p "$DERIVED"
if ! xcodebuild -project Hovr.xcodeproj -scheme Hovr -configuration Release -destination 'generic/platform=macOS' \
     -derivedDataPath "$DERIVED" -allowProvisioningUpdates build > "$LOG" 2>&1; then
  grep -E "error:" "$LOG" || tail -30 "$LOG"
  echo "✗ Build failed (full log: $LOG)"
  exit 1
fi
BUILT="$DERIVED/Build/Products/Release/Hovr.app"
xattr -cr "$BUILT"
codesign --verify --deep --strict "$BUILT"
echo "Built and verified $(defaults read "$BUILT/Contents/Info" CFBundleShortVersionString)"

if [[ "${1:-}" == "--draft" ]]; then
  pkill -x Hovr || true
  sleep 1
  open -g "$BUILT"
  echo "Running draft from $BUILT"
  sleep 12
  exec tools/check_resources.sh "$BUILT"
fi

# Replace the installed copy and keep only /Applications registered.
pkill -x Hovr || true
sleep 1
rm -rf /Applications/Hovr.app
ditto "$BUILT" /Applications/Hovr.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$BUILT" || true
open -g /Applications/Hovr.app
echo "Installed /Applications/Hovr.app"

if [[ "${1:-}" == "--zip" ]]; then
  mkdir -p build/release
  rm -f build/release/Hovr.zip
  ditto -c -k --keepParent "$BUILT" build/release/Hovr.zip
  echo "Wrote build/release/Hovr.zip"
fi

sleep 12  # restored cards and notes need a moment to settle
tools/check_resources.sh /Applications/Hovr.app
