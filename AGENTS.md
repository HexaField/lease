# AGENTS.md — lease

A single bash script (`lease`) that runs a test service on macOS under a 1–24 hour lease. README.md explains what it does and why; this file holds what you need to change it safely.

## Layout

| Path | Holds |
|---|---|
| `lease` | The whole tool: start, `list`, `end`, and the watchdog (an inline `bash -c` script). |
| `test/run.sh` | The test suite. Runs `./lease` in a scratch `HOME`. |
| `lease.svg` | The README diagram (940 px wide, safe fonts, inline attributes; GitHub renders it as an `<img>`). |

## Run the tests

```sh
test/run.sh        # macOS only, about 2 minutes, exit 0 when all pass
```

Run them on macOS after every change to `lease`. They set `LEASE_UNIT_SECONDS=5` so a lease "hour" lasts five seconds; that variable exists only for tests.

## Rules the code depends on

- **Never signal a PID without the identity check.** Every `kill` of a service group goes through `ours <pgid> <start>`: the leader's `ps -o lstart=` must equal the start time recorded at launch, or the leader must be gone while members of its group remain. A PID cannot be reused while a group with that ID has members, so that second case is still ours. Before stopping the watchdog, `lease end` checks that the watchdog's command line names the lease file. Removing either check can kill an unrelated process after PID reuse.
- **Expiry follows the wall clock.** The watchdog sleeps at most 60 s, then compares `date +%s` with `end`. Do not replace this with one long `sleep`: macOS does not count system sleep in `sleep`.
- **The service and the watchdog each get their own process group** (`perl -e 'setpgrp(0,0); exec …'`; macOS has no `setsid`). The service's group is what expiry signals; the watchdog's own group keeps a terminal's Ctrl-C or hang-up away from it.
- **Write the lease file before starting the watchdog**, then append `wd=`. The watchdog reads nothing from the file, but `lease end` and `list` must never see a running service without a lease file.
- **Lease files are bash, written with `printf %q`** and read with `.`. Keep every value quoted that way. Names are checked against `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$` before they become paths.
- **The watchdog does not depend on the lease file.** It enforces expiry even if the file is deleted, and removes the file when its service ends.

## Gotchas

- `bash` reads `08` as octal. Hours go through `$((10#$hours))`.
- `ps -o lstart=` pads with double spaces; `starttime` collapses them so stored and live values compare equal.
- `date -r <epoch>` is macOS syntax (on Linux, `-r` takes a file). The tool is macOS only on purpose; Linux has `systemd-run -p RuntimeMaxSec=`.
- A self-daemonising command leaves the group and looks like an instant exit. That is the intended report, not a bug.
