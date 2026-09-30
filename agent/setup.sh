#!/bin/zsh
# Notch Agent — background agent setup.
#
# Installs opencode (the agent harness) if needed, creates the agent workspace in
# ~/NotchAgent/workspace, and registers a login service that keeps `opencode serve`
# running on 127.0.0.1:4096 for the Notch Agent app. Safe to run again.
#
#   curl -fsSL https://raw.githubusercontent.com/MoMia7/boring.notch/main/agent/setup.sh | zsh
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/MoMia7/boring.notch/main/agent"
WORKSPACE="$HOME/NotchAgent/workspace"
LOGS="$HOME/NotchAgent/logs"
LABEL="io.otron.notch.opencode"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PORT=4096

say() { print -P "%F{cyan}==>%f $*"; }

# 1. opencode
OPENCODE="$(command -v opencode || true)"
if [[ -z "$OPENCODE" && -x "$HOME/.opencode/bin/opencode" ]]; then OPENCODE="$HOME/.opencode/bin/opencode"; fi
if [[ -z "$OPENCODE" ]]; then
  say "Installing opencode…"
  curl -fsSL https://opencode.ai/install | bash
  OPENCODE="$HOME/.opencode/bin/opencode"
fi
say "Using opencode at $OPENCODE ($("$OPENCODE" --version 2>/dev/null || echo unknown))"

# 2. Workspace (keeps an existing opencode.json / prompt you've customised)
mkdir -p "$WORKSPACE" "$LOGS"
for f in opencode.json notch-prompt.md; do
  if [[ ! -f "$WORKSPACE/$f" ]]; then
    say "Writing $WORKSPACE/$f"
    curl -fsSL "$REPO_RAW/workspace/$f" -o "$WORKSPACE/$f"
  fi
done

# 3. Login service
say "Registering background service ($LABEL)…"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$OPENCODE</string>
    <string>serve</string>
    <string>--hostname</string><string>127.0.0.1</string>
    <string>--port</string><string>$PORT</string>
  </array>
  <key>WorkingDirectory</key><string>$WORKSPACE</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$(dirname "$OPENCODE"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key><string>$HOME</string>
    <key>OPENCODE_DISABLE_CLAUDE_CODE</key><string>1</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOGS/opencode.log</string>
  <key>StandardErrorPath</key><string>$LOGS/opencode.log</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

for _ in {1..30}; do
  curl -sf "http://127.0.0.1:$PORT/global/health" >/dev/null && break
  sleep 1
done
if curl -sf "http://127.0.0.1:$PORT/global/health" >/dev/null; then
  say "Agent is running on http://127.0.0.1:$PORT"
  print "\nNext: open Notch Agent → Settings → Models and log in with ChatGPT or add an API key."
else
  print -u2 "The agent didn't start. See $LOGS/opencode.log"
  exit 1
fi
