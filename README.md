# ping-multiple.sh

A live terminal ping dashboard that monitors multiple hosts simultaneously and displays a rolling colour-coded history bar for each one.

## What it does

- Pings any number of IP addresses or hostnames in parallel
- Shows a scrolling 60-sample colour bar per host — green for fast replies, yellow for slow, red for timeout, gray for no data yet
- Reports the latest round-trip time and an aggregate packet-loss summary
- Uses two concurrent probe cadences per host:
  - **Fast probe** — every 1 s with a 1 s deadline, drives the rolling bar
  - **Slow probe** — every 5 s with a 5 s deadline, drives the RTT column when it has a fresher reading

## Requirements

- bash 4+ (macOS ships bash 3; install a newer version via Homebrew if needed: `brew install bash`)
- Standard `ping` available on PATH
- `awk`, `date`, `mktemp` (present on any POSIX system)
- `python3` only as a fallback if `date +%s%3N` is unavailable

## Usage

Prompt for destinations interactively:

```
./ping-multiple.sh
```

Pass destinations directly as a comma-separated list:

```
./ping-multiple.sh 8.8.8.8,1.1.1.1
./ping-multiple.sh google.com,cloudflare.com,example.com
```

Press **Ctrl-C** to quit. The terminal cursor and temp files are cleaned up automatically on exit.

## Display columns

```
UP    12ms   8.8.8.8  8.8.8.8  [████████████████████]
```

| Column | Meaning |
|--------|---------|
| Status | UP / SLOW / DOWN / ... (waiting for first sample) |
| RTT | Latest round-trip time; `TO` = timeout; trailing `s` = reading from slow probe |
| Host | IP or hostname as supplied |
| Bar | 60 most-recent fast-probe results, newest on the right |

A summary line at the bottom shows total sample counts and the overall loss percentage across all hosts.

## Configuration

The thresholds are plain variables near the top of the script:

| Variable | Default | Meaning |
|----------|---------|---------|
| `FAST_INTERVAL` | 1 | Seconds between fast probes |
| `FAST_TIMEOUT` | 1 | Deadline for each fast probe (seconds) |
| `SLOW_INTERVAL` | 5 | Seconds between slow probes |
| `SLOW_TIMEOUT` | 5 | Deadline for each slow probe (seconds) |
| `SLOW_MS` | 200 | RTT threshold (ms) above which a reply is yellow |
| `HISTORY` | 60 | Number of samples kept in the rolling bar |
| `COUNT` | 2 | ICMP packets sent per probe |

## Permissions

`ping` requires the ability to send raw ICMP packets. On most Linux systems this is granted via a capability on the binary (`cap_net_raw`). If you see permission errors, either run with `sudo` or check that `ping` has the required capability:

```
sudo setcap cap_net_raw+ep /usr/bin/ping
```

## License

MIT
