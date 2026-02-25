#!/usr/bin/env bash
# curl_fetcher.sh — Download files with curl -O and rename per definitions.
# Compatible with macOS (Bash 3.x) and Linux (Bash 4+).
#
# VERSION
VERSION="2.6.1"

set -o pipefail

DEBUG=false
MAX_PARALLEL=1
TARGET_FILE=""
SINGLE_TARGET=""
SINGLE_NAME=""
OUTPUT_DIR=""
STOP_REQUESTED=false
TS_ENABLED=false
TS_SUFFIX=""
ORIGINAL_PWD="$(pwd)"  # Directory where the script is invoked
# Retries / timeout / check-only
RT_COUNT=1      # -rt 1..5, default 1
TO_SEC=2        # -to 2..30 seconds, default 2
CHECK_MODE=false  # -ck
CK_REPORT=""    # path to ck_results-<timestamp>.txt

# Safe debug helper
_debug() {
  if [ "$DEBUG" = true ]; then
    printf "[DEBUG] %s\n" "$*"
  fi
}

_info()  { printf "[INFO] %s\n"  "$*"; }
_err()   { printf "[ERROR] %s\n" "$*" 1>&2; }

_cleanup() {
  STOP_REQUESTED=true
  echo
  _info "Interrupt received. Stopping running jobs…"
  pids=$(jobs -p)
  if [[ -n "$pids" ]]; then
    kill $pids 2>/dev/null
    wait 2>/dev/null
  fi
  exit 130
}
trap _cleanup INT TERM

print_usage() {
  cat <<USAGE
curl_fetcher.sh v${VERSION}
Download files using 'curl -O' and rename each to a declared filename.

Usage:
  curl_fetcher.sh -f <targets.txt> [-p 1..5] [-dr <dir>] [-ts] [-rt 1..5] [-to 2..30] [-ck] [-d]
  curl_fetcher.sh -t <target> -fn <name> [-p 1..5] [-dr <dir>] [-ts] [-rt 1..5] [-to 2..30] [-ck] [-d]

Options:
  -f <file>     Path to target definition file (see rules below).
  -t, --tr <x>  Single target (URL or IP). If IP lacks a scheme, 'http://' is assumed.
  -fn <name>    Output filename for single-target mode. Required with -t/--tr (unless -ck).
  -p <N>        Parallel workers (1..5). Default: 1 (serial).
  -dr <dir>     Output directory (download mode). Relative paths anchored to your CURRENT dir.
  -ts           Append timestamp _<DD-MM-YYYY_HH-MM> to output filenames (before .txt if present).
  -rt <N>       Retries per item on failure (1..5). Default: 1.
  -to <S>       Timeout seconds for connect and overall transfer (2..30). Default: 2.
  -ck           Check-only: confirm endpoint is up (HEAD, fallback GET). No download/rename.
                Writes a report file: ck_results-<DD-MM-YYYY_HH-MM>.txt containing lines:
                "<url_or_ip> <up|down>"
  -d            Debug mode. Print script transactions to stdout.
  -h/-v         Help / Print version.

Target file formatting rules (download mode):
  1) Lines starting with '#' are ignored (comments).
  2) 'filename:<name>' defines the output name for the next URL.
  3) 'https…' defines a URL to download using 'curl -O <url>'.
  4) Other lines are ignored.

In -ck (check-only) mode, URLs are checked; 'filename:' lines are ignored.
USAGE
}

[[ $# -eq 0 ]] && { print_usage; exit 1; }

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h) print_usage; exit 0 ;;
    -v) echo "curl_fetcher.sh version ${VERSION}"; exit 0 ;;
    -d) DEBUG=true; shift ;;
    -p) MAX_PARALLEL="$2"; shift 2 ;;
    -f) TARGET_FILE="$2"; shift 2 ;;
    -t|--tr) SINGLE_TARGET="$2"; shift 2 ;;
    -fn) SINGLE_NAME="$2"; shift 2 ;;
    -dr) OUTPUT_DIR="$2"; shift 2 ;;
    -ts) TS_ENABLED=true; shift ;;
    -rt) RT_COUNT="$2"; shift 2 ;;
    -to) TO_SEC="$2"; shift 2 ;;
    -ck) CHECK_MODE=true; shift ;;
    --) shift; break ;;
    -*|*) _err "Unknown option or missing argument: $1"; print_usage; exit 1 ;;
  esac
done

# Validate numeric ranges
if ! [[ "$MAX_PARALLEL" =~ ^[0-9]+$ ]] || (( MAX_PARALLEL < 1 || MAX_PARALLEL > 5 )); then
  _err "-p must be an integer in the range 1..5"; exit 1
fi
if ! [[ "$RT_COUNT" =~ ^[0-9]+$ ]] || (( RT_COUNT < 1 || RT_COUNT > 5 )); then
  _err "-rt must be an integer in the range 1..5"; exit 1
fi
if ! [[ "$TO_SEC" =~ ^[0-9]+$ ]] || (( TO_SEC < 2 || TO_SEC > 30 )); then
  _err "-to must be an integer in the range 2..30 seconds"; exit 1
fi

MODE=""
[[ -n "$TARGET_FILE" ]] && MODE="file"
if [[ -n "$SINGLE_TARGET" ]]; then
  [[ -n "$MODE" ]] && { _err "Use either -f or -t/--tr, not both"; exit 1; }
  MODE="single"
fi
[[ -z "$MODE" ]] && { _err "You must specify -f <file> or -t/--tr <target>"; print_usage; exit 1; }

command -v curl >/dev/null 2>&1 || { _err "curl not found in PATH"; exit 1; }

# Resolve and validate output directory (download mode only)
if [[ "$CHECK_MODE" != true ]]; then
  if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$ORIGINAL_PWD"
  fi
  case "$OUTPUT_DIR" in
    /*) ;;  # absolute
    *) OUTPUT_DIR="$ORIGINAL_PWD/$OUTPUT_DIR" ;;
  esac
  mkdir -p "$OUTPUT_DIR" 2>/dev/null || { _err "Failed to create output directory: $OUTPUT_DIR"; exit 1; }
  if [[ ! -d "$OUTPUT_DIR" ]]; then
    _err "Output path is not a directory: $OUTPUT_DIR"; exit 1
  fi
  if ! touch "$OUTPUT_DIR/.curl_fetcher.touch" 2>/dev/null; then
    _err "Directory not writable: $OUTPUT_DIR"; exit 1
  fi
  rm -f "$OUTPUT_DIR/.curl_fetcher.touch" 2>/dev/null
fi

# Prepare timestamp suffix if requested (DD-MM-YYYY_HH-MM)
if [[ "$TS_ENABLED" = true ]]; then
  TS_SUFFIX="_$(date +'%d-%m-%Y_%H-%M')"
  _debug "Timestamp suffix: $TS_SUFFIX"
fi

# Prepare check-only results file when -ck is set
_init_ck_report() {
  CK_REPORT="$ORIGINAL_PWD/ck_results-$(date +'%d-%m-%Y_%H-%M').txt"
  : > "$CK_REPORT" || { _err "Unable to create check report: $CK_REPORT"; exit 1; }
  _debug "Check results file: $CK_REPORT"
}

# Append one line to the check report: "<url> up|down"
_ck_append() {
  printf "%s %s\n" "$1" "$2" >> "$CK_REPORT"
}

# Apply timestamp to a filename per rules
_apply_ts() {
  name="$1"
  if [[ "$TS_ENABLED" != true ]]; then echo "$name"; return; fi
  case "$name" in
    *.txt)
      base="${name%.txt}"
      echo "${base}${TS_SUFFIX}.txt"
      ;;
    *)
      echo "${name}${TS_SUFFIX}"
      ;;
  esac
}

_resolve_url() {
  t="$1"
  if [[ "$t" =~ :// ]]; then echo "$t"; else echo "http://$t"; fi
}

_find_download_name() {
  url="$1"
  guess=$(basename "${url%%\?*}")
  if [[ -f "$guess" ]]; then echo "$guess"; return; fi
  recent=$(ls -t 2>/dev/null | head -n 1)
  [[ -n "$recent" ]] && echo "$recent"
}

# Curl attempt wrapper with retries and timeout
_curl_with_retry() {
  cmd="$1"
  attempt=1
  while (( attempt <= RT_COUNT )); do
    _debug "Attempt ${attempt}/${RT_COUNT}: $cmd"
    bash -c "$cmd"
    rc=$?
    if (( rc == 0 )); then
      return 0
    fi
    _err "Attempt ${attempt} failed (exit ${rc})."
    (( attempt++ ))
    if (( attempt <= RT_COUNT )); then sleep 1; fi
  done
  return $rc
}

_download_one() {
  url="$1"; dest="$2"; got=""; jobdir=""; final_name=""
  jobdir=$(mktemp -d "/tmp/curl_fetcher.job.XXXXXX")
  (
    set -e
    cd "$jobdir"
    curl_cmd="curl -fsSLOJ -L --connect-timeout ${TO_SEC} --max-time ${TO_SEC} \"$url\""
    _debug "$curl_cmd"
    if ! _curl_with_retry "$curl_cmd"; then
      rc=$?
      _err "curl failed after ${RT_COUNT} attempt(s): $url"
      exit $rc
    fi
    got=$(_find_download_name "$url")
    if [[ -z "$got" || ! -f "$got" ]]; then
      _err "Downloaded file not found for $url"
      exit 1
    fi
    final_name="$(_apply_ts "$dest")"
    _debug "mv \"$got\" \"$OUTPUT_DIR/$final_name\""
    mv -f "$got" "$OUTPUT_DIR/$final_name"
    _info "Saved: $final_name (from $url)"
  )
  rc=$?
  rm -rf "$jobdir" 2>/dev/null || true
  return $rc
}

# Check-only (HEAD, fallback GET) and write to report
_check_one() {
  url="$1"
  head_cmd="curl -fsSLI --connect-timeout ${TO_SEC} --max-time ${TO_SEC} \"$url\" >/dev/null"
  get_cmd="curl -fsSL --connect-timeout ${TO_SEC} --max-time ${TO_SEC} \"$url\" -o /dev/null"
  if _curl_with_retry "$head_cmd"; then
    _info "UP: $url (HEAD)"
    _ck_append "$url" "up"
    return 0
  fi
  if _curl_with_retry "$get_cmd"; then
    _info "UP: $url (GET)"
    _ck_append "$url" "up"
    return 0
  fi
  _err "DOWN: $url"
  _ck_append "$url" "down"
  return 1
}

# Parse target file into arrays (download mode)
_read_pairs_into_arrays() {
  tf="$1"; current_name=""; raw_line=""; line=""; url=""
  URLS=(); NAMES=()
  while IFS= read -r raw_line; do
    line="${raw_line%%$'\r'}"
    line="${line## }"; line="${line%% }"
    [[ -z "$line" ]] && continue
    case "$line" in
      \#*) continue ;;
      filename:*) current_name="${line#filename:}"; current_name="${current_name## }"; current_name="${current_name%% }" ;;
      https*)
        if [[ -z "$current_name" ]]; then _err "URL without preceding filename: $line"; continue; fi
        url="$line"
        URLS+=("$url")
        NAMES+=("$current_name")
        current_name=""
        ;;
      *) ;; # ignore others
    esac
  done < "$tf"
  PAIR_COUNT=${#URLS[@]}
}

# Parse target file into URLs only (for -ck)
_read_urls_for_check() {
  tf="$1"; raw_line=""; line=""; url=""
  URLS=()
  while IFS= read -r raw_line; do
    line="${raw_line%%$'\r'}"
    line="${line## }"; line="${line%% }"
    [[ -z "$line" ]] && continue
    case "$line" in
      \#*) continue ;;
      https*) url="$line"; URLS+=("$url") ;;
      *) ;; # ignore others
    esac
  done < "$tf"
  URL_COUNT=${#URLS[@]}
}

# Parallel runner: arrays + PID throttle (download mode)
_run_parallel_arrays() {
  pids=()
  i=0; active=0; total=${#URLS[@]}
  while (( i < total )); do
    while true; do
      active=0
      still=()
      for pid in "${pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then still+=("$pid"); ((active++)); fi
      done
      pids=("${still[@]}")
      (( active < MAX_PARALLEL )) && break
      [[ "$STOP_REQUESTED" == true ]] && break
      if [[ -n "${pids[0]}" ]]; then wait "${pids[0]}" 2>/dev/null || true; else sleep 0.1; fi
    done
    [[ "$STOP_REQUESTED" == true ]] && break
    _download_one "${URLS[i]}" "${NAMES[i]}" &
    pids+=($!)
    ((i++))
  done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
}

# Parallel runner for check mode (FIXED syntax)
_run_parallel_check() {
  pids=()
  i=0; active=0; total=${#URLS[@]}
  while (( i < total )); do
    while true; do
      active=0
      still=()
      for pid in "${pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then still+=("$pid"); ((active++)); fi
      done
      pids=("${still[@]}")
      (( active < MAX_PARALLEL )) && break
      [[ "$STOP_REQUESTED" == true ]] && break
      if [[ -n "${pids[0]}" ]]; then wait "${pids[0]}" 2>/dev/null || true; else sleep 0.1; fi
    done
    [[ "$STOP_REQUESTED" == true ]] && break
    _check_one "${URLS[i]}" &
    pids+=($!)
    ((i++))
  done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
}

# Main execution
if [[ "$MODE" == "single" ]]; then
  url=$(_resolve_url "$SINGLE_TARGET")
  if [[ "$CHECK_MODE" = true ]]; then
    _init_ck_report
    _check_one "$url"
    _info "Check report: $CK_REPORT"
  else
    if [[ -z "$SINGLE_NAME" ]]; then _err "-fn <name> is required with -t/--tr (download mode)"; exit 1; fi
    _download_one "$url" "$SINGLE_NAME"
  fi
elif [[ "$MODE" == "file" ]]; then
  if [[ "$CHECK_MODE" = true ]]; then
    [[ ! -r "$TARGET_FILE" ]] && { _err "Target file '$TARGET_FILE' not found or unreadable"; exit 1; }
    _read_urls_for_check "$TARGET_FILE"
    if (( URL_COUNT == 0 )); then _err "No 'https…' URLs found in $TARGET_FILE"; exit 1; fi
    _init_ck_report
    if (( MAX_PARALLEL == 1 )); then
      i=0
      while (( i < URL_COUNT )); do
        _check_one "${URLS[i]}"
        ((i++))
      done
    else
      _run_parallel_check
    fi
    _info "Check report: $CK_REPORT"
  else
    [[ ! -r "$TARGET_FILE" ]] && { _err "Target file '$TARGET_FILE' not found or unreadable"; exit 1; }
    _read_pairs_into_arrays "$TARGET_FILE"
    if (( PAIR_COUNT == 0 )); then _err "No valid 'filename:<name>' + 'https…' pairs found in $TARGET_FILE"; exit 1; fi
    if (( MAX_PARALLEL == 1 )); then
      i=0
      while (( i < PAIR_COUNT )); do
        _download_one "${URLS[i]}" "${NAMES[i]}"
        ((i++))
      done
    else
      _run_parallel_arrays
    fi
  fi
fi

exit 0

# ===== VERSION HISTORY =====
# Version 1.0 — Initial creation.
# Version 1.1 — Removed 'bash -c' from concurrency.
# Version 1.2 — Removed 'eval'; TSV queue with direct function calls.
# Version 1.3 — Per-job temp dirs; PID-throttle; consistent regardless of -d.
# Version 1.4 — Serial path when -p 1; clear 'no pairs found' message.
# Version 1.5 — Explicit queue handoff (path:count) and guards.
# Version 1.6 — Removed temp queue; arrays for serial/parallel.
# Version 1.7 — Fix: _debug conditional avoids set -e abort on DEBUG=false.
# Version 1.8 — Fix: removed 'local' in main scope; serial loop uses plain vars.
# Version 1.9 — Removed ALL 'local' keywords to avoid scope issues entirely.
# Version 2.0 — Added -dr <dir> and -ts (timestamp suffix).
# Version 2.1 — Changed -ts to _<DD-MM-YYYY_HH-MM>.
# Version 2.2 — -dr resolves relative paths against invocation directory.
# Version 2.5 — Added -rt (retries), -to (timeout), and -ck (check-only).
# Version 2.6 — In -ck mode, report 'ck_results-<DD-MM-YYYY_HH-MM>.txt' with '<url> up|down'.
# Version 2.6.1 — Fix: corrected for-loop syntax in -ck parallel runner (removed stray parenthesis).
