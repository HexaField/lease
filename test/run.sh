#!/bin/bash
# Test suite for lease. macOS only (it uses date -r, ps -o lstart and pgrep -g as macOS ships them).
# Runs against ./lease in a scratch HOME, so it never touches your real ~/.leases.
# One lease "hour" lasts LEASE_UNIT_SECONDS seconds in the expiry tests. Takes about 2 minutes.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
lease="$here/lease"
export HOME; HOME=$(mktemp -d)
trap 'pkill -f "lease-test-marker" 2>/dev/null; rm -rf "$HOME"' EXIT
pass=0 fail=0
ok()  { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
alive() { kill -0 "$1" 2>/dev/null; }
field() { (. "$HOME/.leases/$1.lease"; eval "echo \$$2"); }

# Input checks
check "rejects 0 hours"   '! "$lease" 0 a true 2>/dev/null'
check "rejects 25 hours"  '! "$lease" 25 a true 2>/dev/null'
check "rejects ../ name"  '! "$lease" 1 ../x true 2>/dev/null'
check "rejects / in name" '! "$lease" 1 a/b true 2>/dev/null'
check "rejects no command" '! "$lease" 1 a 2>/dev/null'
check "accepts 08 hours"  '"$lease" 08 t-octal bash -c "sleep 300; :" lease-test-marker >/dev/null 2>&1 && "$lease" end t-octal >/dev/null'

# Start failures leave nothing behind
"$lease" 1 t-missing /nonexistent/cmd >/dev/null 2>&1; r=$?
check "missing command fails"         '[ "$r" -ne 0 ] && [ ! -e "$HOME/.leases/t-missing.lease" ]'
"$lease" 1 t-quick true >/dev/null 2>&1; r=$?
check "command that exits at once fails" '[ "$r" -ne 0 ] && [ ! -e "$HOME/.leases/t-quick.lease" ]'

# Duplicate names and list
"$lease" 1 t-dup bash -c 'sleep 300; :' lease-test-marker >/dev/null
check "refuses a running duplicate" '! "$lease" 1 t-dup sleep 300 2>/dev/null'
check "list shows it"               '"$lease" list | grep -q "^t-dup "'
"$lease" end t-dup >/dev/null
check "list says when nothing runs" '"$lease" list | grep -q "no active leases"'

# end stops the group and the watchdog
"$lease" 1 t-end bash -c 'sleep 300 & wait' lease-test-marker >/dev/null
pid=$(field t-end pid); wd=$(field t-end wd)
"$lease" end t-end >/dev/null; sleep 1
check "end stops the service group" '! pgrep -g "$pid" >/dev/null'
check "end stops the watchdog"      '! alive "$wd"'

# A reused PID is never signalled
perl -e 'setpgrp(0,0); sleep 600' & victim=$!
sleep 600 & victim_wd=$!; sleep 1
mkdir -p "$HOME/.leases"
printf 'name=stale\npid=%s\nstart=%q\nend=%s\ncmd=old\nwd=%s\n' "$victim" "Mon Jan 1 00:00:00 2026" \
  $(( $(date +%s) + 3600 )) "$victim_wd" > "$HOME/.leases/stale.lease"
"$lease" end stale >/dev/null
check "end leaves a reused PID alone"           'alive "$victim"'
check "end leaves a reused watchdog PID alone" 'alive "$victim_wd"'
printf 'name=stale2\npid=%s\nstart=%q\nend=%s\ncmd=old\nwd=\n' "$victim" "Mon Jan 1 00:00:00 2026" \
  $(( $(date +%s) + 3600 )) > "$HOME/.leases/stale2.lease"
"$lease" list >/dev/null
check "list clears a stale lease without signalling" '[ ! -e "$HOME/.leases/stale2.lease" ] && alive "$victim"'
kill "$victim" "$victim_wd" 2>/dev/null

# Expiry (1 lease hour = 5 s): a TERM-ignoring child is killed after the grace
LEASE_UNIT_SECONDS=5 "$lease" 1 t-exp bash -c 'trap "" TERM; sleep 600 & wait' lease-test-marker >/dev/null
pid=$(field t-exp pid)
sleep 45
check "expiry ends a TERM-ignoring group" '! pgrep -g "$pid" >/dev/null'
check "expiry removes the lease file"     '[ ! -e "$HOME/.leases/t-exp.lease" ]'

# Expiry still holds if the lease file is deleted by hand
LEASE_UNIT_SECONDS=5 "$lease" 1 t-del bash -c 'sleep 600; :' lease-test-marker >/dev/null
pid=$(field t-del pid); rm -f "$HOME/.leases/t-del.lease"; sleep 8
check "expiry holds without the lease file" '! alive "$pid"'

# A service that exits on its own: the watchdog cleans up within a minute
LEASE_UNIT_SECONDS=300 "$lease" 1 t-self sleep 3 >/dev/null
wd=$(field t-self wd); sleep 65
check "watchdog exits after its service" '! alive "$wd" && [ ! -e "$HOME/.leases/t-self.lease" ]'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
