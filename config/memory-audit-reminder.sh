#!/usr/bin/env bash
# Sends a macOS notification reminding the user to run /memory-audit.

set -euo pipefail

osascript -e 'display notification "Monthly memory audit due — run /memory-audit in Claude Code" with title "Claude Code Reminder"'
