#!/usr/bin/env bash
# ping-multiple.sh — live terminal ping/port dashboard for multiple destinations.
#
# Usage:
#   ./ping-multiple.sh                          prompt for comma-separated destinations
#   ./ping-multiple.sh 8.8.8.8,1.1.1.1,...     pass destinations directly (ICMP)
#   ./ping-multiple.sh --guide                  interactive wizard (IPs + probe type)
#   ./ping-multiple.sh --csv FILE               import targets from CSV file
#
# CSV format (header line optional):
#   ip,label,probe
#   8.8.8.8,Google DNS,icmp
#   10.0.0.1,Web server,tcp:80
#   10.0.0.2,Database,tcp:5432
#   (label and probe are optional; defaults: label=ip  probe=icmp)
#
# Probe types: icmp | tcp:PORT | ssh (=tcp:22) | http (=tcp:80) | https (=tcp:443) | rdp | <port number>
#
# Hybrid probe model (ICMP):
#   Fast probe  : 1s cadence, 1s deadline — drives the rolling bar.
#   Slow probe  : 5s cadence, 5s deadline — drives the latest-RTT column.
# TCP probe: 10s cadence, 5s timeout — UP/DOWN + connect latency.
#
# Bar legend:  green=up/fast  yellow=slow(ICMP only)  red=down  gray=no sample
set -u

# ── runtime requirements check ────────────────────────────────────────────────
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf 'Error: bash 4+ required (you have %s).\n' "$BASH_VERSION" >&2
  printf 'On macOS: brew install bash\n' >&2
  exit 1
fi
for _cmd in ping awk mktemp nc; do
  if ! command -v "$_cmd" >/dev/null 2>&1; then
    printf 'Error: required command not found: %s\n' "$_cmd" >&2
    exit 1
  fi
done
unset _cmd

# ── config ────────────────────────────────────────────────────────────────────
FAST_INTERVAL=1
FAST_TIMEOUT=1
SLOW_INTERVAL=5
SLOW_TIMEOUT=5
SLOW_MS=200
HISTORY=60
COUNT=2
TCP_INTERVAL=10
TCP_TIMEOUT=5
TCP_STALE=$(( (TCP_INTERVAL * 3 + TCP_TIMEOUT) * 1000 ))

# ── colors (needed early for --guide prompts) ─────────────────────────────────
RESET=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
GREEN=$'\033[42m \033[0m'
YELLOW=$'\033[43m \033[0m'
RED=$'\033[41m \033[0m'
GRAY=$'\033[100m \033[0m'

# ── resolve timeout command (macOS nc ignores -w) ─────────────────────────────
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout"
fi

# ── helpers ───────────────────────────────────────────────────────────────────
now_ms() {
  local ts
  ts=$(date +%s%3N 2>/dev/null)
  if [[ "$ts" == *N ]]; then
    python3 -c 'import time;print(int(time.time()*1000))'
  else
    printf '%s' "$ts"
  fi
}

case "$(uname -s)" in
  Darwin) IS_MAC=1 ;;
  *)      IS_MAC=0 ;;
esac

ping_cmd() {
  local timeout="$1"
  if [ "$IS_MAC" = 1 ]; then
    printf 'ping -c %s -t %s -W %s' "$COUNT" "$timeout" "$((timeout * 1000))"
  else
    printf 'ping -c %s -w %s -W %s' "$COUNT" "$timeout" "$timeout"
  fi
}

run_ping() {
  local timeout="$1" ip="$2"
  local cmd; cmd=$(ping_cmd "$timeout")
  $cmd "$ip" 2>/dev/null | awk -F'time=' '
    /time=/ {
      split($2, a, " ")
      v = a[1] + 0
      if (min == "" || v < min) min = v
    }
    END { if (min != "") printf "%.0f", min; else print -1 }
  '
}

check_tcp() {
  local host="$1" port="$2" tout="$3"
  local t0 t1 rc
  t0=$(now_ms)
  if [ -n "$TIMEOUT_CMD" ]; then
    $TIMEOUT_CMD "$tout" nc -z "$host" "$port" 2>/dev/null
  else
    nc -z "$host" "$port" 2>/dev/null
  fi
  rc=$?
  t1=$(now_ms)
  if [ $rc -eq 0 ]; then printf '%d' $(( t1 - t0 ))
  else                    printf '%d' -1
  fi
}

latest_rtt() {
  local base="$1"
  local f="$base.fast" s="$base.slow"
  local f_ts=0 s_ts=0 f_rtt="-1" s_rtt="-1"
  if [ -s "$f" ]; then IFS='|' read -r f_ts f_rtt _ < "$f"; fi
  if [ -s "$s" ]; then IFS='|' read -r s_ts s_rtt _ < "$s"; fi
  local s_valid=0 f_valid=0
  [ "${s_rtt:-"-1"}" != "-1" ] && [ "${s_ts:-0}" -gt 0 ] && s_valid=1
  [ "${f_rtt:-"-1"}" != "-1" ] && [ "${f_ts:-0}" -gt 0 ] && f_valid=1
  if [ "$s_valid" = 1 ] && [ "$f_valid" = 1 ]; then
    if [ "$s_ts" -ge "$f_ts" ]; then printf '%s|%s' "$s_rtt" "S"
    else                              printf '%s|%s' "$f_rtt" "F"
    fi
  elif [ "$s_valid" = 1 ]; then printf '%s|%s' "$s_rtt" "S"
  elif [ "$f_valid" = 1 ]; then printf '%s|%s' "$f_rtt" "F"
  else                          printf '%s|%s' "-1" "?"
  fi
}

probe_label() {
  case "$1" in
    icmp)    printf 'ICMP'               ;;
    tcp:22)  printf 'SSH'                ;;
    tcp:80)  printf 'HTTP'               ;;
    tcp:443) printf 'HTTPS'              ;;
    tcp:*)   printf 'TCP:%s' "${1#tcp:}" ;;
    *)       printf '%s' "$1"            ;;
  esac
}

parse_probe() {
  local input="${1,,}"
  case "$input" in
    icmp|ping|"") printf 'icmp'            ;;
    tcp:*)        printf '%s' "$input"     ;;
    ssh)          printf 'tcp:22'          ;;
    http)         printf 'tcp:80'          ;;
    https)        printf 'tcp:443'         ;;
    rdp)          printf 'tcp:3389'        ;;
    [0-9]*)       printf 'tcp:%s' "$input" ;;
    *)            printf 'icmp'            ;;
  esac
}

# ── argument parsing ──────────────────────────────────────────────────────────
usage() {
  printf '%bUsage:%b\n' "$BOLD" "$RESET"
  printf '  %s                              prompt for destinations (ICMP)\n' "$0"
  printf '  %s 8.8.8.8,1.1.1.1,...         pass destinations directly (ICMP)\n' "$0"
  printf '  %s --guide                      interactive wizard\n' "$0"
  printf '  %s --csv FILE                   import targets from CSV\n' "$0"
  printf '\n%bCSV format%b (ip,label,probe — label/probe optional):\n' "$BOLD" "$RESET"
  printf '  8.8.8.8,Google DNS,icmp\n'
  printf '  10.0.0.1,Web server,tcp:80\n'
  printf '  10.0.0.2,Database,tcp:5432\n'
  printf '\n%bProbe types:%b  icmp  tcp:PORT  ssh  http  https  rdp  <port number>\n' "$BOLD" "$RESET"
  exit 1
}

TARGETS=()
MODE="default"

load_csv() {
  local file="$1"
  [ ! -f "$file" ] && { printf 'CSV file not found: %s\n' "$file" >&2; exit 1; }
  while IFS=',' read -r ip label probe _rest; do
    [[ "$ip" =~ ^[[:space:]]*(ip|host|#|$) ]] && continue
    ip="${ip// /}"
    [ -z "$ip" ] && continue
    label="${label// /}"; [ -z "$label" ] && label="$ip"
    probe=$(parse_probe "${probe// /}")
    TARGETS+=("${ip}|${label}|${probe}")
  done < "$file"
  [ "${#TARGETS[@]}" -eq 0 ] && { printf 'No valid targets in CSV: %s\n' "$file" >&2; exit 1; }
}

run_guide() {
  printf '\n%bping-multiple — interactive setup%b\n\n' "$BOLD" "$RESET"
  printf 'Enter IPs or hostnames (comma-separated):\n> '
  read -r raw_ips
  [ -z "$raw_ips" ] && { printf 'No IPs provided.\n' >&2; exit 1; }

  IFS=',' read -ra ip_list <<< "$raw_ips"
  local cleaned=()
  for h in "${ip_list[@]}"; do
    h="${h// /}"; [ -n "$h" ] && cleaned+=("$h")
  done
  [ "${#cleaned[@]}" -eq 0 ] && { printf 'No valid IPs.\n' >&2; exit 1; }

  printf '\n%bProbe types:%b  icmp  tcp:PORT  ssh  http  https  rdp  <port number>\n' "$BOLD" "$RESET"
  printf '\nApply one probe type to ALL hosts, or configure per-host?\n'
  printf '  [1] Same probe for all  (default)\n'
  printf '  [2] Configure per host\n'
  printf '> '
  read -r choice

  if [ "${choice:-1}" = "2" ]; then
    for h in "${cleaned[@]}"; do
      printf 'Host %b%s%b — probe type [icmp]: ' "$BOLD" "$h" "$RESET"
      read -r probe_input
      local probe; probe=$(parse_probe "$probe_input")
      TARGETS+=("${h}|${h}|${probe}")
    done
  else
    printf 'Probe type for all hosts [icmp]: '
    read -r probe_input
    local probe; probe=$(parse_probe "$probe_input")
    for h in "${cleaned[@]}"; do
      TARGETS+=("${h}|${h}|${probe}")
    done
  fi
}

case "${1:-}" in
  --guide)
    MODE="guide"
    run_guide
    ;;
  --csv)
    MODE="csv"
    [ -z "${2:-}" ] && { printf 'Usage: %s --csv FILE\n' "$0" >&2; exit 1; }
    load_csv "$2"
    ;;
  --help|-h)
    usage
    ;;
  *)
    raw="${1:-}"
    if [ -z "$raw" ]; then
      printf 'Enter destinations (comma-separated IPs or hostnames): '
      read -r raw
    fi
    [ -z "$raw" ] && { printf 'No destinations provided.\n' >&2; exit 1; }
    IFS=',' read -ra parts <<< "$raw"
    for dest in "${parts[@]}"; do
      dest="${dest// /}"
      [ -n "$dest" ] && TARGETS+=("${dest}|${dest}|icmp")
    done
    ;;
esac

[ "${#TARGETS[@]}" -eq 0 ] && { printf 'No targets.\n' >&2; exit 1; }

# ── setup ─────────────────────────────────────────────────────────────────────
WORK_DIR=$(mktemp -d -t ping-multiple.XXXXXX)
cleanup() {
  trap - EXIT INT TERM
  for pid in $(jobs -p); do kill "$pid" 2>/dev/null || true; done
  rm -rf "$WORK_DIR"
  printf '\033[?25h'
}
trap cleanup EXIT INT TERM
printf '\033[?25l'

maxlabel=0
for entry in "${TARGETS[@]}"; do
  IFS='|' read -r _h _l probe <<< "$entry"
  combined="${_h}  ${_l}  [$(probe_label "$probe")]"
  (( ${#combined} > maxlabel )) && maxlabel=${#combined}
done

# ── spawn workers ─────────────────────────────────────────────────────────────
i=0
for entry in "${TARGETS[@]}"; do
  IFS='|' read -r host _label probe <<< "$entry"
  bar_file="$WORK_DIR/$i.bar"
  rtt_file="$WORK_DIR/$i.rtt"
  : > "$bar_file"

  if [ "$probe" = "icmp" ]; then
    # fast probe — 1s cadence, drives bar
    (
      while :; do
        rtt=$(run_ping "$FAST_TIMEOUT" "$host")
        ts=$(now_ms)
        if [ "$rtt" -lt 0 ] 2>/dev/null; then
          slow_rtt="-1"
          if [ -s "$rtt_file.slow" ]; then
            IFS='|' read -r slow_ts slow_rtt _ < "$rtt_file.slow"
            age=$(( $(now_ms) - slow_ts ))
            [ "$age" -gt $(( (SLOW_INTERVAL * 3 + SLOW_TIMEOUT) * 1000 )) ] && slow_rtt="-1"
          fi
          if [ "$slow_rtt" -gt 0 ] 2>/dev/null; then bucket="Y"; else bucket="R"; fi
        elif [ "$rtt" -gt "$SLOW_MS" ]; then bucket="Y"
        else                                  bucket="G"
        fi
        printf '%s' "$bucket" >> "$bar_file"
        printf '%s|%s|F\n' "$ts" "$rtt" > "$rtt_file.fast"
        contents=$(cat "$bar_file")
        (( ${#contents} > HISTORY )) && printf '%s' "${contents: -HISTORY}" > "$bar_file"
        sleep "$FAST_INTERVAL"
      done
    ) &
    # slow probe — 5s cadence, drives RTT column
    (
      while :; do
        rtt=$(run_ping "$SLOW_TIMEOUT" "$host")
        ts=$(now_ms)
        printf '%s|%s|S\n' "$ts" "$rtt" > "$rtt_file.slow"
        sleep "$SLOW_INTERVAL"
      done
    ) &
  else
    # TCP probe — 10s cadence
    port="${probe#tcp:}"
    (
      while :; do
        lat=$(check_tcp "$host" "$port" "$TCP_TIMEOUT")
        ts=$(now_ms)
        printf '%s|%s\n' "$ts" "$lat" > "$rtt_file.tcp"
        if [ "$lat" = "-1" ]; then bucket="R"; else bucket="G"; fi
        printf '%s' "$bucket" >> "$bar_file"
        contents=$(cat "$bar_file")
        (( ${#contents} > HISTORY )) && printf '%s' "${contents: -HISTORY}" > "$bar_file"
        sleep "$TCP_INTERVAL"
      done
    ) &
  fi

  i=$(( i + 1 ))
done

# ── display loop ──────────────────────────────────────────────────────────────
title="Ping Dashboard"
[ "$MODE" = "guide" ] && title="Custom Dashboard"
[ "$MODE" = "csv" ]   && title="Dashboard (CSV)"

clear
printf '%b%s%b  %b(Ctrl-C to quit | icmp: green<%dms yellow=slow | tcp: every %ds | red=down)%b\n' \
  "$BOLD" "$title" "$RESET" "$DIM" "$SLOW_MS" "$TCP_INTERVAL" "$RESET"
echo

while :; do
  printf '\033[3;1H'
  i=0
  for entry in "${TARGETS[@]}"; do
    IFS='|' read -r host label probe <<< "$entry"
    bar_file="$WORK_DIR/$i.bar"
    rtt_file="$WORK_DIR/$i.rtt"
    plabel=$(probe_label "$probe")

    # build bar
    samples=""; [ -s "$bar_file" ] && samples=$(cat "$bar_file")
    bar=""; last_bucket=""
    if [ -n "$samples" ]; then
      pad=$(( HISTORY - ${#samples} ))
      for ((p=0; p<pad; p++)); do bar+="$GRAY"; done
      for ((c=0; c<${#samples}; c++)); do
        case "${samples:c:1}" in
          G) bar+="$GREEN" ;; Y) bar+="$YELLOW" ;;
          R) bar+="$RED"   ;; *) bar+="$GRAY"   ;;
        esac
      done
      last_bucket="${samples: -1}"
    else
      for ((p=0; p<HISTORY; p++)); do bar+="$GRAY"; done
    fi

    # build status + rtt_str
    if [ "$probe" = "icmp" ]; then
      rtt_pair=$(latest_rtt "$rtt_file")
      last_rtt="${rtt_pair%%|*}"; last_src="${rtt_pair#*|}"

      if [ "$last_rtt" = "-1" ] || [ -z "$last_rtt" ] || \
         { [ "$last_bucket" = "R" ] && [ "$last_src" = "?" ]; }; then
        status=$'\033[1;31mDOWN\033[0m'
      elif [ "$last_rtt" -gt "$SLOW_MS" ] 2>/dev/null; then
        status=$'\033[1;33mSLOW\033[0m'
      elif [ "$last_rtt" -ge 0 ] 2>/dev/null; then
        status=$'\033[1;32mUP  \033[0m'
      elif [ "$last_bucket" = "R" ]; then
        status=$'\033[1;31mDOWN\033[0m'
      else
        status=$'\033[2m... \033[0m'
      fi

      if [ "$last_rtt" = "-1" ]; then
        rtt_str=$'\033[31m   TO \033[0m'
      elif [ -z "$last_rtt" ]; then
        rtt_str="     -"
      else
        tag=" "; [ "$last_src" = "S" ] && tag="s"
        rtt_str=$(printf '%4sms%s' "$last_rtt" "$tag")
      fi

    else
      tcp_ts=0; tcp_lat="-1"
      [ -s "$rtt_file.tcp" ] && IFS='|' read -r tcp_ts tcp_lat < "$rtt_file.tcp"

      if [ "$tcp_ts" -eq 0 ]; then
        status=$'\033[2m... \033[0m'; rtt_str="     -"
      else
        stale=$(( $(now_ms) - tcp_ts ))
        if [ "$stale" -gt "$TCP_STALE" ]; then
          status=$'\033[2m... \033[0m'; rtt_str="     -"
        elif [ "$tcp_lat" = "-1" ]; then
          status=$'\033[1;31mDOWN\033[0m'
          rtt_str=$'\033[31m   TO \033[0m'
        else
          status=$'\033[1;32mUP  \033[0m'
          rtt_str=$(printf '%4sms ' "$tcp_lat")
        fi
      fi
    fi

    combined="${host}  ${label}  [${plabel}]"
    printf "  %b  %b  %-${maxlabel}s  [%s]\033[K\n" "$status" "$rtt_str" "$combined" "$bar"
    i=$(( i + 1 ))
  done

  # summary line
  total=0; gcount=0; ycount=0; rcount=0
  for f in "$WORK_DIR"/*.bar; do
    [ -s "$f" ] || continue
    s=$(cat "$f")
    total=$(( total + ${#s} ))
    tmp="${s//G/}"; gcount=$(( gcount + ${#s} - ${#tmp} ))
    tmp="${s//Y/}"; ycount=$(( ycount + ${#s} - ${#tmp} ))
    tmp="${s//R/}"; rcount=$(( rcount + ${#s} - ${#tmp} ))
  done
  loss=0
  (( total > 0 )) && loss=$(( rcount * 100 / total ))
  printf "\n  %bsamples=%d good=%d slow=%d timeout=%d loss=%d%%%b\033[K\n" \
    "$DIM" "$total" "$gcount" "$ycount" "$rcount" "$loss" "$RESET"

  sleep 0.25
done
