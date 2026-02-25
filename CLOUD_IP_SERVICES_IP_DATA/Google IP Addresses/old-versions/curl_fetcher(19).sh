#!/usr/bin/env bash
# curl_fetcher.sh — Download files with curl -O and rename per definitions.
# Compatible with macOS (Bash 3.x) and Linux (Bash 4+).
#
# VERSION
VERSION="2.8"

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
DF_ENABLED=false
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
  curl_fetcher.sh -f <targets.txt> [-p 1..5] [-dr <dir>] [-ts] [-df] [-rt 1..5] [-to 2..30] [-ck] [-d]
  curl_fetcher.sh -t <target> [-fn <name>] [-p 1..5] [-dr <dir>] [-ts] [-df] [-rt 1..5] [-to 2..30] [-ck] [-d]

Options:
  -f <file>     Path to target definition file (see rules below).
  -t, --tr <x>  Single target (URL or IP). If IP lacks a scheme, 'http://' is assumed (download mode).
  -fn <name>    Output filename for single-target download mode. Required unless -df is set.
  -p <N>        Parallel workers (1..5). Default: 1 (serial).
  -dr <dir>     Output directory (download mode). Relative paths anchored to your CURRENT dir.
  -ts           Append timestamp _<DD-MM-YYYY_HH-MM> to output filenames (before .txt if present).
  -df           Derive filenames automatically from each URL if a preceding 'filename:' is missing.
                Example: feeds/gcp/<region>/any/<ipv4|ipv6> -> <region>-<ipv4|ipv6>.txt
  -rt <N>       Retries per item on failure (1..5). Default: 1.
  -to <S>       Timeout seconds for connect and overall transfer (2..30). Default: 2.
  -ck           Check-only: confirm endpoint is up (HEAD/GET). Bare IPv4s: try http then https.
                Writes a report file: ck_results-<DD-MM-YYYY_HH-MM>.txt with lines '<url_or_ip> <up|down>'.
  -d            Debug mode. Print script transactions to stdout.
  -h/-v         Help / Print version.

Target file formatting rules (download mode):
  1) Lines starting with '#' are ignored (comments).
  2) 'filename:<name>' defines the output name for the next URL.
  3) 'https…' defines a URL to download using 'curl -O <url>'.
  4) With -df, missing 'filename:' will be derived from the URL.
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
    -df) DF_ENABLED=true; shift ;;
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

# Append one line to the check report: "<url_or_ip> up|down"
_ck_append() {
  printf "%s %s\n" "$1" "$2" >> "$CK_REPORT"
}

# Derive an output filename from a URL
_derive_name_from_url() {
  u="$1"
  # strip query
  path="${u%%\?*}"
  # remove scheme
  rest="${path#*://}"
  host="${rest%%/*}"
  p="${rest#${host}}"   # includes leading '/'
  p="${p#/}"            # drop leading '/'
  name=""
  # Match feeds/<cloud>/<region>/any/ipv4|ipv6
  if [[ "$p" =~ ^feeds/([^/]+)/([^/]+)/any/(ipv4|ipv6)$ ]]; then
    region="${BASH_REMATCH[2]}"
    ipver="${BASH_REMATCH[3]}"
    name="${region}-${ipver}.txt"
  else
    last="${p##*/}"
    if [[ -z "$last" ]]; then last="$host"; fi
    # sanitize
    name=$(printf "%s" "$last" | sed 's/[^A-Za-z0-9._-]/-/g')
    [[ "$name" != *.txt ]] && name="${name}.txt"
  fi
  echo "$name"
}

# Helper: write a portable download worker and run via bash -c
_spawn_download_worker() {
  url="$1"; dest="$2"
  bash -c '
    set -o pipefail
    url="$1"; dest="$2"; outdir="$3"; ts_enabled="$4"; ts_suffix="$5"; rt="$6"; to="$7"
    jobdir=$(mktemp -d "/tmp/curl_fetcher.job.XXXXXX") || exit 1
    cd "$jobdir" || exit 1
    # retry loop
    attempt=1
    while [ "$attempt" -le "$rt" ]; do
      curl -fsSLOJ -L --connect-timeout "$to" --max-time "$to" "$url" && break
      rc=$?
      attempt=$((attempt+1))
      [ "$attempt" -le "$rt" ] && sleep 1
    done
    # if not success, exit with last rc
    if [ "$attempt" -gt "$rt" ]; then
      echo "curl failed after $rt attempt(s): $url" 1>&2
      exit ${rc:-1}
    fi
    # find downloaded file
    guess=$(basename "${url%%\?*}")
    if [ -f "$guess" ]; then got="$guess"; else got=$(ls -t 2>/dev/null | head -n 1); fi
    if [ -z "$got" ] || [ ! -f "$got" ]; then
      echo "Downloaded file not found: $url" 1>&2; exit 1
    fi
    # apply timestamp suffix if requested
    final="$dest"
    if [ "$ts_enabled" = "true" ]; then
      case "$final" in
        *.txt) base="${final%.txt}"; final="${base}${ts_suffix}.txt" ;;
        *) final="${final}${ts_suffix}" ;;
      esac
    fi
    mv -f "$got" "$outdir/$final" || exit 1
    echo "Saved: $final (from $url)"
    rm -rf "$jobdir" 2>/dev/null || true
  ' _ "$url" "$dest" "$OUTPUT_DIR" "$TS_ENABLED" "$TS_SUFFIX" "$RT_COUNT" "$TO_SEC" &
}

# -- CHECK-ONLY helpers --
_is_ipv4() {
  s="$1"
  [[ "$s" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

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

_check_url_once() {
  url="$1"
  head_cmd="curl -fsSLI --connect-timeout ${TO_SEC} --max-time ${TO_SEC} \"$url\" >/dev/null"
  get_cmd="curl -fsSL --connect-timeout ${TO_SEC} --max-time ${TO_SEC} \"$url\" -o /dev/null"
  if _curl_with_retry "$head_cmd"; then return 0; fi
  if _curl_with_retry "$get_cmd"; then return 0; fi
  return 1
}

_check_one() {
  original="$1"
  if [[ "$original" =~ :// ]]; then
    if _check_url_once "$original"; then _info "UP: $original"; _ck_append "$original" "up"; return 0; fi
    _err "DOWN: $original"; _ck_append "$original" "down"; return 1
  else
    if _is_ipv4 "$original"; then
      http_u="http://$original"; https_u="https://$original"
      if _check_url_once "$http_u"; then _info "UP: $original (http)"; _ck_append "$original" "up"; return 0; fi
      if _check_url_once "$https_u"; then _info "UP: $original (https)"; _ck_append "$original" "up"; return 0; fi
      _err "DOWN: $original"; _ck_append "$original" "down"; return 1
    else
      _err "Ignoring non-URL/non-IPv4 entry: $original"; return 1
    fi
  fi
}

# Parse target file into arrays (download mode) — with -df support
_read_pairs_into_arrays() {
  tf="$1"; current_name=""; raw_line=""; line=""; url=""
  URLS=(); NAMES=()
  while IFS= read -r raw_line; do
    line="${raw_line%%$'\r'}"   # strip CR
    line="${line## }"; line="${line%% }"  # trim spaces
    [[ -z "$line" ]] && continue
    case "$line" in
      \#*) continue ;;
      filename:*) current_name="${line#filename:}"; current_name="${current_name## }"; current_name="${current_name%% }" ;;
      https*)
        url="$line"
        if [[ -z "$current_name" ]]; then
          if [[ "$DF_ENABLED" = true ]]; then
            derived=$(_derive_name_from_url "$url")
            _debug "Derived filename: $derived for $url"
            current_name="$derived"
          else
            _err "URL without preceding filename: $line"
            continue
          fi
        fi
        URLS+=("$url")
        NAMES+=("$current_name")
        current_name=""
        ;;
      *) ;; # ignore others
    esac
  done < "$tf"
  PAIR_COUNT=${#URLS[@]}
}

# Parse target file into entries for -ck (URLs and bare IPv4s)
_read_entries_for_check() {
  tf="$1"; raw_line=""; line=""; entry=""
  URLS=()
  while IFS= read -r raw_line; do
    line="${raw_line%%$'\r'}"
    line="${line## }"; line="${line%% }"
    [[ -z "$line" ]] && continue
    case "$line" in
      \#*) continue ;;
      https*|http*) entry="$line"; URLS+=("$entry") ;;
      filename:*) continue ;;  # ignore filename lines in check mode
      *)
        if [[ "$line" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then URLS+=("$line"); fi
        ;;
    esac
  done < "$tf"
  URL_COUNT=${#URLS[@]}
}

# Parallel runner: spawn workers without relying on in-scope functions
_run_parallel_download() {
  pids=()
  i=0; active=0; total=${#URLS[@]}
  while (( i < total )); do
    # throttle
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
    _spawn_download_worker "${URLS[i]}" "${NAMES[i]}"
    pids+=($!)
    ((i++))
  done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
}

# Parallel runner for check mode
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
  if [[ "$CHECK_MODE" = true ]]; then
    _init_ck_report
    _check_one "$SINGLE_TARGET"
    _info "Check report: $CK_REPORT"
  else
    url="$SINGLE_TARGET"; [[ "$url" =~ :// ]] || url="http://$url"
    if [[ -z "$SINGLE_NAME" ]]; then
      if [[ "$DF_ENABLED" = true ]]; then
        SINGLE_NAME=$(_derive_name_from_url "$url")
        _debug "Derived filename (single): $SINGLE_NAME"
      else
        _err "-fn <name> is required with -t/--tr (download mode), or use -df to derive"
        exit 1
      fi
    fi
    # serial worker
    _spawn_download_worker "$url" "$SINGLE_NAME"
    wait
  fi
elif [[ "$MODE" == "file" ]]; then
  if [[ "$CHECK_MODE" = true ]]; then
    [[ ! -r "$TARGET_FILE" ]] && { _err "Target file '$TARGET_FILE' not found or unreadable"; exit 1; }
    _read_entries_for_check "$TARGET_FILE"
    if (( URL_COUNT == 0 )); then _err "No 'http(s)…' URLs or IPv4 addresses found in $TARGET_FILE"; exit 1; fi
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
    if (( PAIR_COUNT == 0 )); then _err "No valid or derivable ('-df') 'filename:<name>' + 'https…' pairs found in $TARGET_FILE"; exit 1; fi
    if (( MAX_PARALLEL == 1 )); then
      i=0
      while (( i < PAIR_COUNT )); do
        _spawn_download_worker "${URLS[i]}" "${NAMES[i]}"
        wait $!
        ((i++))
      done
    else
      _run_parallel_download
    fi
  fi
fi

exit 0

# ===== VERSION HISTORY =====
# Version 2.6 — Report 'ck_results-<DD-MM-YYYY_HH-MM>.txt' with '<url> up|down'.
# Version 2.6.1 — Fix: corrected for-loop syntax in -ck parallel runner.
# Version 2.7 — -ck supports bare IPv4 entries.
# Version 2.7.2 — Robust parallel download workers via dedicated bash processes.
# Version 2.8 — Added -df (derive filenames). In download mode, if a URL lacks
#               a preceding filename, derive one from the URL. Single-target
#               download mode can omit -fn when -df is set.
