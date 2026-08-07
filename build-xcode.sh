#!/bin/zsh
set -e

ROOT="${0:A:h}"
DERIVED="$ROOT/.xcode-build"
APP="$HOME/Applications/ccusage Widget.app"
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export DEVELOPER_DIR

TEAM_ID="${DEVELOPMENT_TEAM:-$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null | awk '/teamID =/ { gsub(/[;\"]/, "", $3); print $3; exit }')}"
if [[ -z "$TEAM_ID" ]]; then
  echo "No Apple Development team found. Add your Apple ID in Xcode or set DEVELOPMENT_TEAM." >&2
  exit 1
fi

xcodebuild \
  -project "$ROOT/CCUsageWidget.xcodeproj" \
  -target CCUsageWidgetApp \
  -configuration Release \
  -allowProvisioningUpdates \
  SYMROOT="$DERIVED/Build/Products" \
  OBJROOT="$DERIVED/Build/Intermediates.noindex" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_IDENTITY="Apple Development" \
  CODE_SIGN_STYLE=Automatic \
  build

BUILT="$DERIVED/Build/Products/Release/ccusage Widget.app"
test -d "$BUILT"
pkill -f "$APP/Contents/MacOS/ccusage Widget" 2>/dev/null || true
rm -rf "$APP"
cp -R "$BUILT" "$APP"
open "$APP"
echo "Installed $APP"
