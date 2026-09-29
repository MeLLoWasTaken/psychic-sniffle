#!/usr/bin/env bash
# M0-03 check: the Godot project imports, boots as client and as server, and logs no
# errors or warnings.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$(mktemp)"
fail=0

godot --headless --path "$REPO/game" --import >"$LOG" 2>&1 || true

for role in client server; do
  args=()
  [[ $role == server ]] && args=(-- --server)
  if ! godot --headless --path "$REPO/game" --quit-after 120 "${args[@]}" >"$LOG.$role" 2>&1; then
    echo "$role: godot exited with an error"; fail=1
  fi
  if grep -E "ERROR|WARNING|SCRIPT ERROR|Parse Error" "$LOG.$role" | grep -v "^WARNING: .*--quit-after" ; then
    echo "$role: errors or warnings in the log (above)"; fail=1
  fi
  grep -q "\[$role\]" "$LOG.$role" || { echo "$role: role marker missing from log"; fail=1; }
done
grep -q "server: listening" "$LOG.server" || { echo "server scene did not start"; fail=1; }
grep -q "client: main menu ready" "$LOG.client" || { echo "client scene did not start"; fail=1; }
rm -f "$LOG" "$LOG.client" "$LOG.server"
exit $fail
