# lease

Run a test service on macOS that stops itself when its lease runs out.

![How lease works: a service starts in its own process group with a lease file; a watchdog checks the wall clock every minute; at expiry the group gets SIGTERM, then SIGKILL; before any signal, the group leader's start time is checked so a reused PID is never touched.](lease.svg)

## What

`lease` starts a command in the background with a time limit of 1 to 24 hours. When the limit passes, it stops the command and everything the command started. You can list what is running and stop a lease early.

```sh
lease 6 my-test ollama serve      # run for 6 hours, log to ~/.leases/my-test.log
lease list                        # what runs, and when each lease ends
lease end my-test                 # stop it now
```

## Why

Test services outlive the work they were started for. A server started to check a pull request keeps running after the pull request merges, and nobody remembers it. One such leftover once ran a CPU core at 100 % for six days.

A lease makes the cleanup automatic. You decide how long a test needs when you start it, and the machine forgets it for you.

## How

```
lease 6 my-test ollama serve
  │
  ├─ service ─ own process group (perl setpgrp, then exec)
  │            output → ~/.leases/my-test.log
  │
  ├─ lease file ~/.leases/my-test.lease
  │            name · pid · leader start time · end (epoch) · command · watchdog pid
  │
  └─ watchdog ─ own process group, wakes every minute
               ├─ group gone?            → remove the lease file, exit
               ├─ leader's start time
               │  differs from the lease? → a different process holds the PID: exit, signal nothing
               └─ now ≥ end?             → SIGTERM the group, wait up to 30 s, SIGKILL what is left
```

**Process group.** The command runs as the leader of a new process group, so one signal reaches its children too: an executor and the Holochain conductor it spawned, a shell script and its jobs.

**Wall clock.** The watchdog compares `date +%s` with the end time once a minute. A single long `sleep` would not do: on macOS it stops counting while the machine sleeps, so a 24-hour lease on a laptop could last days.

**Identity check.** macOS reuses process IDs. After a service exits, or after a reboot leaves a stale lease file behind, its PID can belong to a different process. Before every signal, `lease` compares the group leader's start time (`ps -o lstart`) with the one recorded at launch. If the leader is gone but members of its group remain, the group is still ours: a PID cannot be reused while a process group with that ID has members. `lease end` checks the watchdog's PID the same way before it stops it.

### Commands

| Command | Does |
|---|---|
| `lease <hours> <name> <command> [args…]` | Starts `<command>` with a lease of 1–24 hours. Fails, and leaves no lease, if the command exits within its first second. |
| `lease list` | Shows each running lease: name, PID, end time, hours left, command. Removes leases whose service has gone. |
| `lease end <name>` | Stops the service's group (SIGTERM, then SIGKILL after 30 s) and its watchdog, and removes the lease. |

Names may hold letters, digits, `.`, `_` and `-` (64 at most). A running lease blocks a new one with the same name.

### Choosing the hours

- 6 hours for a quick check.
- 24 hours at most. If a test needs longer, start a new lease when this one ends. The limit forces a decision each day.

### Limits

- **Commands that daemonise themselves.** A command that forks into a new session and exits (`brew services start`, many `--daemon` flags) leaves the process group. `lease` sees its leader exit at once and reports a failure. Run the foreground form instead: `ollama serve`, not `brew services start ollama`.
- **Reboots.** A reboot ends the service and the watchdog together. The lease file stays behind until `lease list` or `lease end` clears it.
- **macOS only.** It relies on `date -r <epoch>`, `ps -o lstart=` and `pgrep -g` as macOS ships them. On Linux, use `systemd-run --user -p RuntimeMaxSec=6h …` instead.

## Install

```sh
cp lease ~/.local/bin/lease && chmod +x ~/.local/bin/lease   # any directory on your PATH
```

It needs only what macOS ships: bash, perl, ps, pgrep.

## Tests

```sh
test/run.sh
```

The suite runs `./lease` with `HOME` set to a scratch directory, so it never touches your real leases. Expiry tests set `LEASE_UNIT_SECONDS=5`, which makes one lease hour last five seconds. It covers input checks, start failures, `list` and `end`, a reused PID and a reused watchdog PID (both left alone), expiry of a group that ignores SIGTERM, expiry after the lease file is deleted, and a service that exits on its own. It takes about two minutes.
