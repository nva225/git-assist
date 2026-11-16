#!/bin/bash
# Rebuilds Git Assist, installs it to ~/Applications (a stable path for launch-at-login), and (re)launches it.
# Pass --show to open the main window on launch.
set -euo pipefail
cd "$(dirname "$0")"

INSTALLED="$HOME/Applications/GitAssist.app"

./build.sh

# Ask the running copy to quit (it saves its cache on the way out), then wait for that exact process.
PID=$(pgrep -x GitAssist || true)
if [ -n "$PID" ]; then
    osascript -e 'tell application id "com.nickva.gitassist" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 50); do
        kill -0 "$PID" 2>/dev/null || break
        sleep 0.1
    done
fi

mkdir -p "$HOME/Applications"
rm -rf "$INSTALLED"
cp -R build/GitAssist.app "$INSTALLED"
open "$INSTALLED" --args "$@"
echo "Installed and launched $INSTALLED"
