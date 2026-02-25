#!/usr/bin/env bash
# curl_fetcher.sh — Download files with curl -O and rename per definitions.
# Compatible with macOS (Bash 3.x) and Linux (Bash 4+).
#
# VERSION
VERSION="2.1"

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

# Safe debug helper: use conditional, not a failing command.
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
  curl_fetcher.sh -f <targets.txt> [-p 1..5] [-dr <dir>] [-ts] [-d]
  curl_fetcher.sh -t <target> -fn <name> [-p 1..5] [-dr <dir>] [-ts] [-d]

Options:
  -f <file>     Path to target definition file (see rules below).
  -t, --tr <x>  Single target (URL or IP). If IP lacks a scheme, 'http://' is assumed.
  -fn <name>    Output filename for single-target mode. Required with -t/--tr.
  -p <N>        Parallel workers (1..5). Default: 1 (serial).
  -dr <dir>     Output directory. Will be created if it doesn't exist; results
                are saved inside this directory.
  -ts           Append timestamp _<DD-MM-YYYY_HH-MM> to each output filename.
                Inserted before .txt if present; otherwise appended at the end
                of the filename.
  -d            Debug mode. Print script transactions to stdout.
  -h            Help. Show this text and exit.
  -v            Version. Print version and exit.

Target file formatting rules:
  1) Lines starting with '#' are ignored (comments).
  2) A line starting with 'filename:<name>' defines the output name for the next URL.
  3) A line starting with 'https' defines a URL to download using 'curl -O <url>'.
  4) Any line that does not start with 'filename' or 'https' is ignored.
USAGE
}

[[ $# -eq 0 ]] && { print_usage; exit 1; }

# Parse arguments (long/short flags)
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
    --) shift; break ;;
    -*|*) _err "Unknown option or missing argument: $1"; print_usage; exit 1 ;;
  esac
done

if ! [[ "$MAX_PARALLEL" =~ ^[0-9]+$ ]] || (( MAX_PARALLEL < 1 || MAX_PARALLEL > 5 )); then
  _err "-p must be an integer in the range 1..5"; exit 1
fi

MODE=""
[[ -n "$TARGET_FILE" ]] && MODE="file"
if [[ -n "$SINGLE_TARGET" ]]; then
  [[ -n "$MODE" ]] && { _err "Use either -f or -t/--tr, not both"; exit 1; }
  MODE="single"
fi
[[ -z "$MODE" ]] && { _err "You must specify -f <file> or -t/--tr <target>"; print_usage; exit 1; }

command -v curl >/dev/null 2>&1 || { _err "curl not found in PATH"; exit 1; }

# Resolve output directory
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$PWD"
fi
# Create and validate directory
mkdir -p "$OUTPUT_DIR" 2>/dev/null || { _err "Failed to create output directory: $OUTPUT_DIR"; exit 1; }
if [[ ! -d "$OUTPUT_DIR" ]]; then
  _err "Output path is not a directory: $OUTPUT_DIR"; exit 1
fi
if ! touch "$OUTPUT_DIR/.curl_fetcher.touch" 2>/dev/null; then
  _err "Directory not writable: $OUTPUT_DIR"; exit 1
fi
rm -f "$OUTPUT_DIR/.curl_fetcher.touch" 2>/dev/null

# Prepare timestamp suffix if requested (DD-MM-YYYY_HH-MM)
if [[ "$TS_ENABLED" = true ]]; then
  TS_SUFFIX="_$(date +'%d-%m-%Y_%H-%M')"
  _debug "Timestamp suffix: $TS_SUFFIX"
fi

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

_download_one() {
  url="$1"; dest="$2"; rc=0; got=""; jobdir=""
  jobdir=$(mktemp -d "/tmp/curl_fetcher.job.XXXXXX")
  (
    set -e
    cd "$jobdir"
    _debug "curl -fsSLOJ -L \"$url\""
    if ! curl -fsSLOJ -L "$url"; then rc=$?; _err "curl failed ($rc): $url"; exit $rc; fi
    got=$(_find_download_name "$url")
    if [[ -z "$got" || ! -f "$got" ]]; then
      _err "Downloaded file not found for $url"; exit 1
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

# Parse target file into arrays (globals: URLS[], NAMES[], PAIR_COUNT)
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

# Parallel runner: arrays + PID throttle
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

if [[ "$MODE" == "single" ]]; then
  [[ -z "$SINGLE_NAME" ]] && { _err "-fn <name> is required with -t/--tr"; exit 1; }
  url=$(_resolve_url "$SINGLE_TARGET")
  _download_one "$url" "$SINGLE_NAME"
elif [[ "$MODE" == "file" ]]; then
  [[ ! -r "$TARGET_FILE" ]] && { _err "Target file '$TARGET_FILE' not found or unreadable"; exit 1; }
  _read_pairs_into_arrays "$TARGET_FILE"
  if (( PAIR_COUNT == 0 )); then
    _err "No valid 'filename:<name>' + 'https…' pairs found in $TARGET_FILE"; exit 1
  fi
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
# Version 2.0 — Added -dr <dir> to create/use output directory; added -ts to append
#               timestamp _<dd-ww-yy_hh-mm> (ISO week) before .txt or at the end.
# Version 2.1 — Changed -ts format to _<DD-MM-YYYY_HH-MM>; unchanged placement rules.
