#!/usr/bin/env bash
# ping-multiple.sh — live terminal ping dashboard for multiple destinations.
#
# Usage:
#   ./ping-multiple.sh                          prompt for comma-separated destinations
#   ./ping-multiple.sh 8.8.8.8,1.1.1.1,...     pass destinations directly
#
# Hybrid probe model:
#   Fast probe  : 1s cadence, 1s deadline — drives the rolling bar.
#   Slow probe  : 5s cadence, 5s deadline — drives the latest-RTT column.
#
# Bar legend:  green = fast reply (<SLOW_MS), yellow = slow reply, red = no reply,
#              gray = no sample yet. Newest sample on the right.
set -u

# ── runtime requirements check ────────────────────────────────────────────────
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf 'Error: bash 4+ required (you have %s).\n' "$BASH_VERSION" >&2
  printf 'On macOS: brew install bash\n' >&2
  exit 1
fi
for _cmd in ping awk mktemp; do
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

# ── argument parsing ──────────────────────────────────────────────────────────
usage() {
  printf 'Usage:\n'
  printf '  %s                              prompt for comma-separated destinations\n' "$0"
  printf '  %s 8.8.8.8,1.1.1.1,...         pass destinations directly\n' "$0"
  exit 1
}

TARGETS=()

raw="${1:-}"
if [ -z "$raw" ]; then
  printf 'Enter destinations (comma-separated IPs or hostnames): '
  read -r raw
fi
if [ -z "$raw" ]; then
  printf 'No destinations provided.\n' >&2
  exit 1
fi
IFS=',' read -ra parts <<< "$raw"
for dest in "${parts[@]}"; do
  dest="${dest// /}"   # strip spaces
  [ -n "$dest" ] && TARGETS+=("${dest}|${dest}")
done

if [ "${#TARGETS[@]}" -eq 0 ]; then
  printf 'No targets to ping.\n' >&2
  exit 1
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

latest_rtt() {
  local base="$1"
  local f="$base.fast" s="$base.slow"
  local f_ts=0 s_ts=0 f_rtt="-1" s_rtt="-1" f_src="?" s_src="?"
  if [ -s "$f" ]; then IFS='|' read -r f_ts f_rtt f_src < "$f"; fi
  if [ -s "$s" ]; then IFS='|' read -r s_ts s_rtt s_src < "$s"; fi
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

# ── colors ────────────────────────────────────────────────────────────────────
GREEN=$'\033[42m \033[0m'
YELLOW=$'\033[43m \033[0m'
RED=$'\033[41m \033[0m'
GRAY=$'\033[100m \033[0m'
RESET=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'

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
  ip="${entry%%|*}"; label="${entry#*|}"
  combined="${ip}  ${label}"
  (( ${#combined} > maxlabel )) && maxlabel=${#combined}
done

# ── spawn workers ─────────────────────────────────────────────────────────────
i=0
for entry in "${TARGETS[@]}"; do
  ip="${entry%%|*}"
  bar_file="$WORK_DIR/$i.bar"
  rtt_file="$WORK_DIR/$i.rtt"
  : > "$bar_file"
  : > "$rtt_file"

  (
    while :; do
      rtt=$(run_ping "$FAST_TIMEOUT" "$ip")
      ts=$(now_ms)
      if [ "$rtt" -lt 0 ] 2>/dev/null; then
        slow_rtt="-1"
        if [ -s "$rtt_file.slow" ]; then
          IFS='|' read -r slow_ts slow_rtt _ < "$rtt_file.slow"
          cur_ms=$(now_ms)
          age=$(( cur_ms - slow_ts ))
          if [ "$age" -gt $(( (SLOW_INTERVAL * 3 + SLOW_TIMEOUT) * 1000 )) ]; then
            slow_rtt="-1"
          fi
        fi
        if [ "$slow_rtt" -gt 0 ] 2>/dev/null; then bucket="Y"
        else                                        bucket="R"
        fi
      elif [ "$rtt" -gt "$SLOW_MS" ]; then bucket="Y"
      else                                 bucket="G"
      fi
      printf '%s' "$bucket" >> "$bar_file"
      printf '%s|%s|F\n' "$ts" "$rtt" > "$rtt_file.fast"
      contents=$(cat "$bar_file")
      if (( ${#contents} > HISTORY )); then
        printf '%s' "${contents: -HISTORY}" > "$bar_file"
      fi
      sleep "$FAST_INTERVAL"
    done
  ) &

  (
    while :; do
      rtt=$(run_ping "$SLOW_TIMEOUT" "$ip")
      ts=$(now_ms)
      printf '%s|%s|S\n' "$ts" "$rtt" > "$rtt_file.slow"
      sleep "$SLOW_INTERVAL"
    done
  ) &

  i=$(( i + 1 ))
done

# ── display loop ──────────────────────────────────────────────────────────────
title="Ping Dashboard"

clear
printf '%b%s%b  %b(Ctrl-C to quit | green<%dms yellow=slow red=timeout)%b\n' \
  "$BOLD" "$title" "$RESET" "$DIM" "$SLOW_MS" "$RESET"
echo

while :; do
  printf '\033[3;1H'
  i=0
  for entry in "${TARGETS[@]}"; do
    ip="${entry%%|*}"; label="${entry#*|}"
    bar_file="$WORK_DIR/$i.bar"
    rtt_base="$WORK_DIR/$i.rtt"

    samples=""
    [ -s "$bar_file" ] && samples=$(cat "$bar_file")

    bar=""
    last_bucket=""
    if [ -n "$samples" ]; then
      pad=$(( HISTORY - ${#samples} ))
      for ((p=0; p<pad; p++)); do bar+="$GRAY"; done
      for ((c=0; c<${#samples}; c++)); do
        case "${samples:c:1}" in
          G) bar+="$GREEN" ;;
          Y) bar+="$YELLOW" ;;
          R) bar+="$RED" ;;
          *) bar+="$GRAY" ;;
        esac
      done
      last_bucket="${samples: -1}"
    else
      for ((p=0; p<HISTORY; p++)); do bar+="$GRAY"; done
    fi

    rtt_pair=$(latest_rtt "$rtt_base")
    last_rtt="${rtt_pair%%|*}"
    last_src="${rtt_pair#*|}"

    if [ "$last_rtt" = "-1" ] || [ -z "$last_rtt" ] || [ "$last_bucket" = "R" -a "$last_src" = "?" ]; then
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

    combined="${ip}  ${label}"
    printf "  %b  %b  %-${maxlabel}s  [%s]\033[K\n" "$status" "$rtt_str" "$combined" "$bar"
    i=$(( i + 1 ))
  done

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
