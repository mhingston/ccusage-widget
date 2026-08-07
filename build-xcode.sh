#!/bin/zsh
set -e

ROOT="${0:A:h}"
DERIVED="$ROOT/.xcode-build"
if [[ -w /Applications ]]; then
  APP="/Applications/ccusage Widget.app"
else
  APP="$HOME/Applications/ccusage Widget.app"
fi
LAUNCH_AGENT="$HOME/Library/LaunchAgents/local.ccusage.widget.collector.plist"
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
mkdir -p "${APP:h}" "$HOME/Library/LaunchAgents"
pkill -f "$APP/Contents/MacOS/ccusage-widget" 2>/dev/null || true
rm -rf "$APP"
cp -R "$BUILT" "$APP"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
for DEVELOPMENT_COPY in "$HOME/Applications/ccusage Widget.app" "$BUILT"; do
  if [[ "$DEVELOPMENT_COPY" != "$APP" && -d "$DEVELOPMENT_COPY" ]]; then
    pluginkit -r "$DEVELOPMENT_COPY/Contents/PlugIns/ClaudeUsageWidget.appex" 2>/dev/null || true
    "$LSREGISTER" -u "$DEVELOPMENT_COPY" 2>/dev/null || true
  fi
done
"$LSREGISTER" -f -R -trusted "$APP"
pluginkit -a "$APP/Contents/PlugIns/ClaudeUsageWidget.appex"
killall chronod 2>/dev/null || true

cp "$ROOT/local.ccusage.widget.collector.plist" "$LAUNCH_AGENT"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:2 $APP" "$LAUNCH_AGENT"
launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENT" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT"
launchctl enable "gui/$(id -u)/local.ccusage.widget.collector"

open "$APP"
echo "Installed $APP and enabled background refresh at login"
