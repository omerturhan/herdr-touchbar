#!/usr/bin/env bash
# Installs a LaunchAgent so the Touch Bar badge comes back after a reboot,
# matching how the herdr server itself is kept alive.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="dev.herdr.touchbar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$ROOT/build/HerdrTouchBar.app"

# Note: the plist heredoc below is unquoted so $LABEL/$APP expand — keep backticks
# and stray $ out of it. Deliberately no KeepAlive: that would fight run.sh stop.
# If the app ever dies, the plugin's ensure event hook brings it back.
case "${1:-install}" in
  install)
    [ -x "$APP/Contents/MacOS/HerdrTouchBar" ] || bash "$ROOT/build.sh"
    mkdir -p "$(dirname "$PLIST")"
    cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP/Contents/MacOS/HerdrTouchBar</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/herdr-touchbar.log</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/herdr-touchbar.log</string>
</dict>
</plist>
PLISTEOF
    launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$UID" "$PLIST"
    echo "installed $LABEL (log: ~/Library/Logs/herdr-touchbar.log)"
    ;;
  uninstall)
    launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
    rm -f "$PLIST"
    echo "uninstalled $LABEL"
    ;;
  status)
    launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1 \
      && echo "$LABEL is loaded" || echo "$LABEL is not loaded"
    ;;
  *)
    echo "usage: launchagent.sh [install|uninstall|status]" >&2
    exit 2
    ;;
esac
