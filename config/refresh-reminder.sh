#!/usr/bin/env bash
# Sends a macOS notification reminding the user to run /refresh.

set -euo pipefail

osascript -e 'display notification "Monthly memory refresh due — run /refresh in Claude Code" with title "Claude Code Reminder"'
