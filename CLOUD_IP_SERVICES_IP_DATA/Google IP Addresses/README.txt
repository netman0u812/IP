curl_fetcher.sh v2.8 — README
=================================

Overview
--------
`curl_fetcher.sh` is a Bash script for downloading or checking multiple URLs/IPs with advanced features:
- Parallel execution (1–5 workers)
- Retries and timeouts
- Timestamped filenames
- Output directory control
- Check-only mode (HEAD/GET)
- Automatic filename derivation (-df)

Usage
-----
Download mode:
  curl_fetcher.sh -f <targets.txt> [-p 1..5] [-dr <dir>] [-ts] [-df] [-rt 1..5] [-to 2..30] [-d]
  curl_fetcher.sh -t <target> [-fn <name>] [-dr <dir>] [-ts] [-df] [-rt 1..5] [-to 2..30] [-d]

Check-only mode:
  curl_fetcher.sh -f <targets.txt> -ck [-p 1..5] [-rt 1..5] [-to 2..30]
  curl_fetcher.sh -t <target> -ck [-rt 1..5] [-to 2..30]

Options
-------
-f <file>     Target definition file.
-t, --tr <x>  Single target (URL or IP). If IP lacks scheme, 'http://' assumed in download mode.
-fn <name>    Output filename for single-target download mode. Required unless -df is set.
-p <N>        Parallel workers (1..5). Default: 1.
-dr <dir>     Output directory. Created if missing.
-ts           Append timestamp _<DD-MM-YYYY_HH-MM> to filenames.
-df           Derive filenames from URL if missing. Example: feeds/gcp/<region>/any/ipv4 -> <region>-ipv4.txt.
-rt <N>       Retries per item (1..5). Default: 1.
-to <S>       Timeout seconds (2..30). Default: 2.
-ck           Check-only: confirm endpoint is up. Bare IPs: try http then https.
-d            Debug mode.
-h/-v         Help / Version.

Target File Rules
-----------------
Download mode:
- Lines starting with '#' ignored.
- 'filename:<name>' sets next output name.
- 'https…' lines are downloaded.
- With -df, missing 'filename:' is derived automatically.

Check-only mode:
- Accepts URLs and bare IPv4 addresses.
- Ignores 'filename:' lines.

Examples
--------
1) Download from file, derive names, timestamp, output dir:
   ./curl_fetcher.sh -f EDL-Google-Geo-List.txt -df -ts -dr google_edl -p 3 -rt 3 -to 5

2) Single target, derive name:
   ./curl_fetcher.sh -t "https://saasedl.paloaltonetworks.com/feeds/gcp/europe/any/ipv4" -df -ts -dr google_edl

3) Check-only mode:
   ./curl_fetcher.sh -f EDL-Google-Geo-List.txt -ck -p 5 -rt 2 -to 4

Output:
- Download mode: files saved under -dr directory.
- Check-only mode: report file ck_results-<DD-MM-YYYY_HH-MM>.txt in current directory.

Version History
---------------
- v2.8 — Added -df (derive filenames). If URL lacks preceding filename, derive from URL. Single-target can omit -fn with -df.
- v2.7.2 — Robust parallel download workers via dedicated bash processes.
- v2.7 — Check-only supports bare IPv4 entries.
- v2.6 — Check-only report file with up|down status.
- v2.5 — Added -rt (retries), -to (timeout), and -ck (check-only).
- v2.2 — Output directory resolves relative paths.
- v2.1 — Timestamp format changed to DD-MM-YYYY_HH-MM.
- v2.0 — Added -dr and -ts.
