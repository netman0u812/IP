#!/usr/bin/env bash
# curl_fetcher.sh — Download files with curl -O and rename per definitions.
# Compatible with macOS (Bash 3.x) and Linux (Bash 4+).
#
# VERSION
VERSION="1.2"

set -o pipefail

DEBUG=false
MAX_PARALLEL=1
TARGET_FILE=""
SINGLE_TARGET=""
SINGLE_NAME=""
WORKDIR=""
OUTPUT_DIR=""
STOP_REQUESTED=false

_debug() { $DEBUG && printf "[DEBUG] %s\n" "$*"; }
_info()  { printf "[INFO] %s\n"  "$*"; }
_err()   { printf "[ERROR] %s\n" "$*" 1>&2; }

_cleanup() {
  STOP_REQUESTED=true
  echo
  _info "Interrupt received. Stopping running jobs…"
  local pids
  pids=$(jobs -p)
  if [[ -n "$pids" ]]; then
    kill $pids 2>/dev/null
    wait 2>/dev/null
  fi
  [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
  exit 130
}
trap _cleanup INT TERM

print_usage() {
  cat <<USAGE
curl_fetcher.sh v${VERSION}
Download files using 'curl -O' and rename each to a declared filename.

Usage:
  curl_fetcher.sh -f <targets.txt> [-p 1..5] [-d]
  curl_fetcher.sh -t <target> -fn <name> [-p 1..5] [-d]

Options:
  -f <file>     Path to target definition file (see rules below).
  -t, --tr <x>  Single target (URL or IP). If IP lacks a scheme, 'http://' is assumed.
  -fn <name>    Output filename for single-target mode. Required with -t/--tr.
  -p <N>        Parallel workers (1..5). Default: 1 (serial).
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h) print_usage; exit 0 ;;
    -v) echo "curl_fetcher.sh version ${VERSION}"; exit 0 ;;
    -d) DEBUG=true; shift ;;
    -p) MAX_PARALLEL="$2"; shift 2 ;;
    -f) TARGET_FILE="$2"; shift 2 ;;
    -t|--tr) SINGLE_TARGET="$2"; shift 2 ;;
    -fn) SINGLE_NAME="$2"; shift 2 ;;
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

OUTPUT_DIR="$PWD"
WORKDIR=$(mktemp -d "/tmp/curl_fetcher.XXXXXX")
_debug "Workdir: $WORKDIR | Output dir: $OUTPUT_DIR"

_resolve_url() {
  local t="$1"; [[ "$t" =~ :// ]] && { echo "$t"; return; } ; echo "http://$t"
}

_find_download_name() {
  local url="$1" guess recent
  guess=$(basename "${url%%\?*}")
  [[ -f "$guess" ]] && { echo "$guess"; return; }
  recent=$(ls -t 2>/dev/null | head -n 1)
  [[ -n "$recent" ]] && echo "$recent"
}

_download_one() {
  local url="$1" dest="$2" rc=0 got
  (
    set -e
    cd "$WORKDIR"
    _debug "curl -fsSLOJ -L \"$url\""
    if ! curl -fsSLOJ -L "$url"; then rc=$?; _err "curl failed ($rc): $url"; exit $rc; fi
    got=$(_find_download_name "$url")
    [[ -z "$got" || ! -f "$got" ]] && { _err "Downloaded file not found for $url"; exit 1; }
    _debug "mv \"$got\" \"$OUTPUT_DIR/$dest\""
    mv -f "$got" "$OUTPUT_DIR/$dest"
    _info "Saved: $dest (from $url)"
  )
  return $rc
}

# Concurrency: read TSV (url<tab>name) and call function directly in background
_run_queue_tsv() {
  local pids=()
  while IFS=$'\t' read -r url name; do
    [[ -z "$url" || -z "$name" ]] && continue
    # throttle
    while true; do
      local current; current=$(jobs -r | wc -l | tr -d ' ')
      (( current < MAX_PARALLEL )) && break
      [[ "$STOP_REQUESTED" == true ]] && break
      sleep 0.2
    done
    [[ "$STOP_REQUESTED" == true ]] && break
    _download_one "$url" "$name" &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
}

if [[ "$MODE" == "single" ]]; then
  [[ -z "$SINGLE_NAME" ]] && { _err "-fn <name> is required with -t/--tr"; exit 1; }
  url=$(_resolve_url "$SINGLE_TARGET")
  _download_one "$url" "$SINGLE_NAME"
elif [[ "$MODE" == "file" ]]; then
  [[ ! -r "$TARGET_FILE" ]] && { _err "Target file '$TARGET_FILE' not found or unreadable"; exit 1; }
  local_name=""
  queue_tmp=$(mktemp "/tmp/curl_fetcher.queue.XXXXXX")
  while IFS= read -r raw; do
    line="${raw%%$'\r'}"; [[ -z "$line" ]] && continue
    case "$line" in
      \#*) continue ;;
      filename:*) local_name="${line#filename:}"; local_name="${local_name## }"; local_name="${local_name%% }" ;;
      https*)
        if [[ -z "$local_name" ]]; then _err "URL without preceding filename: $line"; continue; fi
        printf '%s\t%s\n' "$line" "$local_name" >> "$queue_tmp"
        local_name=""
        ;;
      *) ;; # ignore others
    esac
  done < "$TARGET_FILE"
  _run_queue_tsv < "$queue_tmp"
  rm -f "$queue_tmp"
fi

[[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
exit 0

# ===== VERSION HISTORY =====
# Version 1.0 — Initial creation.
# Version 1.1 — Fixed function scope: removed 'bash -c' from concurrency.
# Version 1.2 — Removed 'eval'; concurrency now passes args via TSV queue and calls
# _download_one directly. Fixes intermittent behavior where quoting or subshells
# caused commands to work only under -d.
