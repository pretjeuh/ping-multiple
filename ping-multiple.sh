#!/usr/bin/env bash
# ping-multiple.sh — live terminal ping/port dashboard for multiple destinations.
#
# Usage:
#   ./ping-multiple.sh                          prompt for comma-separated destinations
#   ./ping-multiple.sh 8.8.8.8,1.1.1.1,...     pass destinations directly (ICMP)
#   ./ping-multiple.sh --guide                  interactive wizard (IPs + probe type)
#   ./ping-multiple.sh --csv FILE               import targets from CSV file
#   ./ping-multiple.sh --log FILE               append state-change events to FILE
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
# Sparkline:   8-level block chars showing RTT trend (last 20 readings, ICMP only)
# On exit:     summary CSV written to ping-multiple-YYYY-MM-DD-HHmm.csv
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
SPARKLINE_HISTORY=10
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

check_udp() {
  local host="$1" port="$2" tout="$3"
  local t0 t1 rc
  t0=$(now_ms)
  if [ -n "$TIMEOUT_CMD" ]; then
    $TIMEOUT_CMD "$tout" nc -zu "$host" "$port" 2>/dev/null
  else
    nc -zu "$host" "$port" 2>/dev/null
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
    icmp)     printf 'ICMP'               ;;
    tcp:22)   printf 'SSH'                ;;
    tcp:80)   printf 'HTTP'               ;;
    tcp:443)  printf 'HTTPS'              ;;
    tcp:3389) printf 'RDP'                ;;
    tcp:*)    printf 'TCP:%s' "${1#tcp:}" ;;
    udp:53)   printf 'DNS'                ;;
    udp:123)  printf 'NTP'                ;;
    udp:161)  printf 'SNMP'               ;;
    udp:*)    printf 'UDP:%s' "${1#udp:}" ;;
    *)        printf '%s' "$1"            ;;
  esac
}

parse_probe() {
  local input="${1,,}"
  case "$input" in
    icmp|ping|"") printf 'icmp'            ;;
    tcp:*)        printf '%s' "$input"     ;;
    udp:*)        printf '%s' "$input"     ;;
    ssh)          printf 'tcp:22'          ;;
    http)         printf 'tcp:80'          ;;
    https)        printf 'tcp:443'         ;;
    rdp)          printf 'tcp:3389'        ;;
    dns)          printf 'udp:53'          ;;
    ntp)          printf 'udp:123'         ;;
    snmp)         printf 'udp:161'         ;;
    [0-9]*)       printf 'tcp:%s' "$input" ;;
    *)            printf 'icmp'            ;;
  esac
}

# render a sparkline string from a file of space-separated RTT values (newest last)
# outputs SPARKLINE_HISTORY block characters; -1 entries render as a space
render_sparkline() {
  local rtts_file="$1"
  [ ! -s "$rtts_file" ] && printf '%*s' "$SPARKLINE_HISTORY" '' && return
  local vals
  read -ra vals < "$rtts_file"

  local min_v=999999 max_v=0
  for v in "${vals[@]}"; do
    [ "$v" = "-1" ] && continue
    (( v < min_v )) && min_v=$v
    (( v > max_v )) && max_v=$v
  done

  local blocks=('▁' '▂' '▃' '▄' '▅' '▆' '▇' '█')
  local range=$(( max_v - min_v ))
  local out=""
  local pad=$(( SPARKLINE_HISTORY - ${#vals[@]} ))
  for ((p=0; p<pad; p++)); do out+=" "; done
  for v in "${vals[@]}"; do
    if [ "$v" = "-1" ]; then
      out+=" "
    elif [ "$range" -eq 0 ]; then
      out+="${blocks[3]}"
    else
      local idx=$(( (v - min_v) * 7 / range ))
      out+="${blocks[$idx]}"
    fi
  done
  printf '%s' "$out"
}

# ── argument parsing ──────────────────────────────────────────────────────────
usage() {
  printf '%bUsage:%b\n' "$BOLD" "$RESET"
  printf '  %s                              prompt for destinations (ICMP)\n' "$0"
  printf '  %s 8.8.8.8,1.1.1.1,...         pass destinations directly (ICMP)\n' "$0"
  printf '  %s --guide                      interactive wizard\n' "$0"
  printf '  %s --csv FILE                   import targets from CSV\n' "$0"
  printf '  %s --log FILE                   append state-change events to FILE\n' "$0"
  printf '\n%bCSV format%b (ip,label,probe — label/probe optional):\n' "$BOLD" "$RESET"
  printf '  8.8.8.8,Google DNS,icmp\n'
  printf '  10.0.0.1,Web server,tcp:80\n'
  printf '  10.0.0.2,Database,tcp:5432\n'
  printf '\n%bProbe types:%b  icmp  tcp:PORT  udp:PORT  ssh  http  https  rdp  dns  ntp  snmp  <port number>\n' "$BOLD" "$RESET"
  exit 1
}

TARGETS=()
MODE="default"
EVENT_LOG=""

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

  printf '\n%bProbe types:%b  icmp  tcp:PORT  udp:PORT  ssh  http  https  rdp  dns  ntp  snmp  <port number>\n' "$BOLD" "$RESET"
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

# consume args left-to-right so --log can appear in any position
_args=("$@")
_idx=0
while [ $_idx -lt ${#_args[@]} ]; do
  case "${_args[$_idx]}" in
    --guide) MODE="guide" ;;
    --csv)
      MODE="csv"
      _idx=$(( _idx + 1 ))
      [ $_idx -ge ${#_args[@]} ] && { printf 'Usage: %s --csv FILE\n' "$0" >&2; exit 1; }
      load_csv "${_args[$_idx]}"
      ;;
    --log)
      _idx=$(( _idx + 1 ))
      [ $_idx -ge ${#_args[@]} ] && { printf 'Usage: %s --log FILE\n' "$0" >&2; exit 1; }
      EVENT_LOG="${_args[$_idx]}"
      ;;
    --help|-h) usage ;;
    *)
      if [ "$MODE" = "default" ] && [ -z "${_INLINE_IPS:-}" ]; then
        _INLINE_IPS="${_args[$_idx]}"
      fi
      ;;
  esac
  _idx=$(( _idx + 1 ))
done

if [ "$MODE" = "guide" ]; then
  run_guide
elif [ "$MODE" = "default" ]; then
  raw="${_INLINE_IPS:-}"
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
fi

[ "${#TARGETS[@]}" -eq 0 ] && { printf 'No targets.\n' >&2; exit 1; }

# ── setup ─────────────────────────────────────────────────────────────────────
WORK_DIR=$(mktemp -d -t ping-multiple.XXXXXX)
EXPORT_CSV="ping-multiple-$(date +%Y-%m-%d-%H%M).csv"

export_csv() {
  printf 'host,label,probe,samples,good,slow,timeout,loss_pct,min_ms,avg_ms,max_ms\n' > "$EXPORT_CSV"
  local idx=0
  for entry in "${TARGETS[@]}"; do
    IFS='|' read -r host label probe <<< "$entry"
    local bar_file="$WORK_DIR/$idx.bar"
    local rtt_file="$WORK_DIR/$idx.rtt"
    local spark_file="$WORK_DIR/$idx.rtts"
    local s=""; [ -s "$bar_file" ] && s=$(cat "$bar_file")
    local total=${#s} tmp
    tmp="${s//G/}"; local good=$(( total - ${#tmp} ))
    tmp="${s//Y/}"; local slow=$(( total - ${#tmp} ))
    tmp="${s//R/}"; local tout=$(( total - ${#tmp} ))
    local loss=0; (( total > 0 )) && loss=$(( tout * 100 / total ))

    local min_ms="-" avg_ms="-" max_ms="-"
    if [ -s "$spark_file" ]; then
      local rtt_vals; read -ra rtt_vals < "$spark_file"
      local sum=0 cnt=0 mn=999999 mx=0
      for v in "${rtt_vals[@]}"; do
        [ "$v" = "-1" ] && continue
        sum=$(( sum + v )); cnt=$(( cnt + 1 ))
        (( v < mn )) && mn=$v
        (( v > mx )) && mx=$v
      done
      if (( cnt > 0 )); then
        min_ms=$mn; avg_ms=$(( sum / cnt )); max_ms=$mx
      fi
    elif [ -s "$rtt_file.tcp" ]; then
      local tcp_lat; IFS='|' read -r _ tcp_lat < "$rtt_file.tcp"
      [ "$tcp_lat" != "-1" ] && min_ms=$tcp_lat && avg_ms=$tcp_lat && max_ms=$tcp_lat
    fi

    printf '%s,%s,%s,%d,%d,%d,%d,%d,%s,%s,%s\n' \
      "$host" "$label" "$(probe_label "$probe")" \
      "$total" "$good" "$slow" "$tout" "$loss" \
      "$min_ms" "$avg_ms" "$max_ms" >> "$EXPORT_CSV"
    idx=$(( idx + 1 ))
  done
}

cleanup() {
  trap - EXIT INT TERM
  for pid in $(jobs -p); do kill "$pid" 2>/dev/null || true; done
  export_csv
  rm -rf "$WORK_DIR"
  printf '\033[?25h'
  printf '\nSession summary written to %s\n' "$EXPORT_CSV"
}
trap cleanup EXIT INT TERM
printf '\033[?25l'

maxlabel=0
for entry in "${TARGETS[@]}"; do
  IFS='|' read -r _h _l probe <<< "$entry"
  [ "$_h" = "$_l" ] && combined="${_h}  [$(probe_label "$probe")]" \
                    || combined="${_h}  ${_l}  [$(probe_label "$probe")]"
  (( ${#combined} > maxlabel )) && maxlabel=${#combined}
done

# BAR_WIDTH: how many blocks to display (separate from HISTORY ring buffer size)
_term_cols=$(tput cols 2>/dev/null || printf '120')
_fixed=$(( 2 + 4 + 2 + 6 + 2 + maxlabel + 3 + 2 + SPARKLINE_HISTORY ))
_avail=$(( _term_cols - _fixed ))
(( _avail < 20 )) && _avail=20
BAR_WIDTH=$(( _avail < HISTORY ? _avail : HISTORY ))

# ── spawn workers ─────────────────────────────────────────────────────────────
i=0
for entry in "${TARGETS[@]}"; do
  IFS='|' read -r host _label probe <<< "$entry"
  bar_file="$WORK_DIR/$i.bar"
  rtt_file="$WORK_DIR/$i.rtt"
  spark_file="$WORK_DIR/$i.rtts"
  : > "$bar_file"

  if [ "$probe" = "icmp" ]; then
    # fast probe — 1s cadence, drives bar + sparkline ring buffer
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

        # update sparkline ring buffer (space-separated ints, newest last)
        existing=""; [ -s "$spark_file" ] && read -r existing < "$spark_file"
        read -ra spark_vals <<< "$existing"
        spark_vals+=("$rtt")
        (( ${#spark_vals[@]} > SPARKLINE_HISTORY )) && \
          spark_vals=("${spark_vals[@]: -${SPARKLINE_HISTORY}}")
        printf '%s\n' "${spark_vals[*]}" > "$spark_file"

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
  elif [[ "$probe" == tcp:* ]]; then
    # TCP probe — 10s cadence
    port="${probe#tcp:}"
    _bar="$bar_file"
    _rtt="$rtt_file"
    _spark="$spark_file"
    _host="$host"
    _port="$port"
    (
      while :; do
        lat=$(check_tcp "$_host" "$_port" "$TCP_TIMEOUT")
        ts=$(now_ms)
        printf '%s|%s\n' "$ts" "$lat" > "$_rtt.tcp"
        if [ "$lat" = "-1" ]; then bucket="R"; else bucket="G"; fi
        printf '%s' "$bucket" >> "$_bar"
        contents=$(cat "$_bar")
        (( ${#contents} > HISTORY )) && printf '%s' "${contents: -HISTORY}" > "$_bar"
        existing=""; [ -s "$_spark" ] && read -r existing < "$_spark"
        read -ra spark_vals <<< "$existing"
        spark_vals+=("$lat")
        (( ${#spark_vals[@]} > SPARKLINE_HISTORY )) && \
          spark_vals=("${spark_vals[@]: -${SPARKLINE_HISTORY}}")
        printf '%s\n' "${spark_vals[*]}" > "$_spark"
        sleep "$TCP_INTERVAL"
      done
    ) &
  else
    # UDP probe — 10s cadence
    port="${probe#udp:}"
    _bar="$bar_file"
    _rtt="$rtt_file"
    _spark="$spark_file"
    _host="$host"
    _port="$port"
    (
      while :; do
        lat=$(check_udp "$_host" "$_port" "$TCP_TIMEOUT")
        ts=$(now_ms)
        printf '%s|%s\n' "$ts" "$lat" > "$_rtt.tcp"
        if [ "$lat" = "-1" ]; then bucket="R"; else bucket="G"; fi
        printf '%s' "$bucket" >> "$_bar"
        contents=$(cat "$_bar")
        (( ${#contents} > HISTORY )) && printf '%s' "${contents: -HISTORY}" > "$_bar"
        existing=""; [ -s "$_spark" ] && read -r existing < "$_spark"
        read -ra spark_vals <<< "$existing"
        spark_vals+=("$lat")
        (( ${#spark_vals[@]} > SPARKLINE_HISTORY )) && \
          spark_vals=("${spark_vals[@]: -${SPARKLINE_HISTORY}}")
        printf '%s\n' "${spark_vals[*]}" > "$_spark"
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
printf '%b%s%b  %b(Ctrl-C to quit | icmp: green<%dms yellow=slow | tcp/udp: every %ds | red=down)%b\n' \
  "$BOLD" "$title" "$RESET" "$DIM" "$SLOW_MS" "$TCP_INTERVAL" "$RESET"
echo

# per-host previous-status tracking for state-change alerts
declare -a PREV_STATUS
for (( k=0; k<${#TARGETS[@]}; k++ )); do PREV_STATUS[$k]="?"; done

emit_event() {
  local ts="$1" host="$2" label="$3" prev="$4" next="$5"
  local when
  when=$(date -d "@$(( ts / 1000 ))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
         date -r  "$(( ts / 1000 ))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
         printf '%s' "$ts")
  local line="${when} | ${host} (${label}) | ${prev} -> ${next}"
  printf '\a'
  [ -n "$EVENT_LOG" ] && printf '%s\n' "$line" >> "$EVENT_LOG"
}

while :; do
  printf '\033[3;1H'
  cur_ms=$(now_ms)
  i=0
  for entry in "${TARGETS[@]}"; do
    IFS='|' read -r host label probe <<< "$entry"
    bar_file="$WORK_DIR/$i.bar"
    rtt_file="$WORK_DIR/$i.rtt"
    spark_file="$WORK_DIR/$i.rtts"
    plabel=$(probe_label "$probe")

    # build colour bar (display BAR_WIDTH newest samples from the ring buffer)
    samples=""; [ -s "$bar_file" ] && samples=$(cat "$bar_file")
    # expand TCP samples so each probe result fills TCP_INTERVAL display blocks
    if [ "$probe" != "icmp" ] && [ -n "$samples" ]; then
      expanded=""
      for ((c=0; c<${#samples}; c++)); do
        ch="${samples:c:1}"
        for ((e=0; e<TCP_INTERVAL; e++)); do expanded+="$ch"; done
      done
      samples="$expanded"
    fi
    # take only the newest BAR_WIDTH chars for display
    (( ${#samples} > BAR_WIDTH )) && samples="${samples: -${BAR_WIDTH}}"
    bar=""; last_bucket=""
    if [ -n "$samples" ]; then
      pad=$(( BAR_WIDTH - ${#samples} ))
      for ((p=0; p<pad; p++)); do bar+="$GRAY"; done
      for ((c=0; c<${#samples}; c++)); do
        case "${samples:c:1}" in
          G) bar+="$GREEN" ;; Y) bar+="$YELLOW" ;;
          R) bar+="$RED"   ;; *) bar+="$GRAY"   ;;
        esac
      done
      last_bucket="${samples: -1}"
    else
      for ((p=0; p<BAR_WIDTH; p++)); do bar+="$GRAY"; done
    fi

    # determine status (plain word, coloured separately)
    if [ "$probe" = "icmp" ]; then
      rtt_pair=$(latest_rtt "$rtt_file")
      last_rtt="${rtt_pair%%|*}"; last_src="${rtt_pair#*|}"

      if [ "$last_rtt" = "-1" ] || [ -z "$last_rtt" ] || \
         { [ "$last_bucket" = "R" ] && [ "$last_src" = "?" ]; }; then
        status="DOWN"
      elif [ "$last_rtt" -gt "$SLOW_MS" ] 2>/dev/null; then
        status="SLOW"
      elif [ "$last_rtt" -ge 0 ] 2>/dev/null; then
        status="UP"
      elif [ "$last_bucket" = "R" ]; then
        status="DOWN"
      else
        status="INIT"
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
        status="INIT"; rtt_str="     -"
      else
        stale=$(( cur_ms - tcp_ts ))
        if [ "$stale" -gt "$TCP_STALE" ]; then
          status="INIT"; rtt_str="     -"
        elif [ "$tcp_lat" = "-1" ]; then
          status="DOWN"; rtt_str=$'\033[31m   TO \033[0m'
        else
          status="UP";   rtt_str=$(printf '%4sms ' "$tcp_lat")
        fi
      fi
    fi

    # fire alert on UP<->DOWN/<->SLOW transitions (skip INIT / warm-up)
    prev="${PREV_STATUS[$i]}"
    if [ "$prev" != "?" ] && [ "$prev" != "$status" ] && \
       [ "$status" != "INIT" ] && [ "$prev" != "INIT" ]; then
      emit_event "$cur_ms" "$host" "$label" "$prev" "$status"
    fi
    PREV_STATUS[$i]="$status"

    # colour the status word
    case "$status" in
      UP)   status_disp=$'\033[1;32mUP  \033[0m' ;;
      SLOW) status_disp=$'\033[1;33mSLOW\033[0m' ;;
      DOWN) status_disp=$'\033[1;31mDOWN\033[0m' ;;
      *)    status_disp=$'\033[2m... \033[0m'     ;;
    esac

    # sparkline for all probe types
    spark=$(render_sparkline "$spark_file")

    [ "$host" = "$label" ] && combined="${host}  [${plabel}]" \
                           || combined="${host}  ${label}  [${plabel}]"
    printf "  %b  %b  %-${maxlabel}s  [%s] %b%s%b\033[K\n" \
      "$status_disp" "$rtt_str" "$combined" "$bar" "$DIM" "$spark" "$RESET"
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
