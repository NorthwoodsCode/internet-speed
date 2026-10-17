#!/usr/bin/env bash
#
# internet-speed — track what your ISP actually delivers vs. what
# they promised. Runs speedtest-cli, appends a CSV row, and gives you
# tools to summarize and schedule it.
#
# https://github.com/NorthwoodsCode/internet-speed

set -euo pipefail
IFS=$'\n\t'

readonly VERSION="1.3.0"
# Assign first, then mark readonly: `readonly X="$(cmd)"` would mask a
# failing $(cmd) (shellcheck SC2155), and set -e could never catch it.
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
# Resolve script path without depending on `realpath` (GNU coreutils,
# not on macOS by default). `cd` + `pwd` gives an absolute path that
# works on every POSIX shell.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME SCRIPT_DIR SCRIPT_PATH
readonly LOG_DIR="${SPEED_LOG_DIR:-$HOME/speed_logs}"
# Every run appends to this one file. The public IP is recorded in each
# row's last column, so an ISP or address change shows up in the data
# rather than as a separate file. Versions before 1.3 wrote one file per
# IP (speed-<ip>.csv); _log_files still reads those alongside it.
readonly LOG_FILE="$LOG_DIR/internet-speed.csv"
readonly CRON_TAG="# internet-speed"
readonly CSV_HEADER='Server ID,Sponsor,Server Name,Timestamp,Distance,Ping,Download,Upload,Share,IP Address'

trap 'echo "$SCRIPT_NAME: failed at line $LINENO (exit $?)" >&2' ERR

usage() {
   cat <<EOF
$SCRIPT_NAME v$VERSION — track ISP delivered vs. promised speed

USAGE
   $SCRIPT_NAME [run]                  Run a speed test and append to CSV log
   $SCRIPT_NAME summary                Print min/median/mean/max stats + outage count
                                       + worst 3 hours of day
   $SCRIPT_NAME outages                List each detected outage event
   $SCRIPT_NAME hours                  24-hour breakdown with ASCII bar chart
   $SCRIPT_NAME migrate [--dry-run]    Convert legacy ;-separated logs to the
                                       new speedtest-cli --csv format
   $SCRIPT_NAME install-cron [--interval 30m] [--uninstall]
                                       Install/remove a crontab entry
   $SCRIPT_NAME install-systemd [--uninstall]
                                       Install/remove a systemd --user timer
   $SCRIPT_NAME --help | -h            Show this help
   $SCRIPT_NAME --version              Print version

ENVIRONMENT
   SPEED_LOG_DIR       Directory for the CSV log, internet-speed.csv
                       (default: ~/speed_logs)
   SPEED_PREFLIGHT_HOST host:port probed before each run so an "internet
                       is out" condition fails fast (default: 8.8.8.8:53;
                       set to an empty string to skip the probe)
   SPECTRUM_PROMISED_DOWN   Your plan's promised download speed in Mbps
                            (e.g. 400). Enables "% below promised" stats.
   SPECTRUM_PROMISED_UP     Your plan's promised upload speed in Mbps.
   OUTAGE_DOWN_BELOW   Outage threshold: download < N Mbps (default 25)
   OUTAGE_PING_ABOVE   Outage threshold: ping > N ms (default 250)

EXAMPLES
   $SCRIPT_NAME                                    # run a single test now
   SPECTRUM_PROMISED_DOWN=400 $SCRIPT_NAME summary # stats with baseline
   $SCRIPT_NAME install-cron --interval 15m        # every 15 min via cron
   $SCRIPT_NAME install-systemd                    # every 30 min via systemd
EOF
}

require_cmd() {
   local cmd="$1"
   if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "$SCRIPT_NAME: required command not found: $cmd" >&2
      case "$cmd" in
         speedtest-cli)
            cat >&2 <<EOF

Install it with one of:
   apt install speedtest-cli       # Debian/Ubuntu/Mint
   brew install speedtest-cli      # macOS
   pip install --user speedtest-cli

Note: this is sivel/speedtest-cli (the Python one), NOT Ookla's
official "speedtest" binary. They produce different CSV columns.
EOF
            ;;
         crontab)
            echo "Install cron with: apt install cron" >&2
            ;;
         systemctl)
            echo "systemd is not available on this system." >&2
            ;;
      esac
      exit 1
   fi
}

# Strip double-quoted CSV fields (e.g. "Charlotte, NC") so an embedded
# comma can't shift awk's -F, columns. The quotes and their contents go;
# the commas around them stay, so column positions are preserved.
_strip_quoted() {
   sed 's/"[^"]*"//g'
}

# Network preflight: speedtest-cli takes ~30s to fail if the network is
# down. A 3-second TCP probe catches the "internet is out" case fast so
# cron mail explains it clearly instead of dumping a wall of
# speedtest-cli traceback.
#
# Target is SPEED_PREFLIGHT_HOST (host:port, default 8.8.8.8:53); set it
# to an empty string to skip the probe, e.g. on networks that block
# outbound DNS to Google. Needs `timeout` (GNU coreutils) or `gtimeout`
# (macOS: brew install coreutils); without either the probe is skipped
# rather than risk hanging on a blocked connect().
_preflight() {
   local target="${SPEED_PREFLIGHT_HOST-8.8.8.8:53}"
   if [[ -z "$target" ]]; then
      return 0
   fi
   local host="${target%%:*}" port="53"
   if [[ "$target" == *:* ]]; then
      port="${target##*:}"
   fi
   local timeout_cmd
   if command -v timeout >/dev/null 2>&1; then
      timeout_cmd="timeout"
   elif command -v gtimeout >/dev/null 2>&1; then
      timeout_cmd="gtimeout"
   else
      return 0
   fi
   if ! "$timeout_cmd" 3 bash -c ": > /dev/tcp/$host/$port" 2>/dev/null; then
      echo "$SCRIPT_NAME: network is down (couldn't reach $target)" >&2
      echo "Skipping speed test. Run again when connectivity returns." >&2
      exit 2
   fi
}

cmd_run() {
   require_cmd speedtest-cli
   _preflight
   mkdir -p "$LOG_DIR"

   local row ip log_file
   row="$(speedtest-cli --csv --secure)"

   # IP Address is the 10th (last) column. Pull it out for the stdout line.
   ip="$(echo "$row" | awk -F, '{print $NF}' | tr -d '"')"
   if [[ -z "$ip" ]]; then
      ip="unknown"
   fi

   log_file="$LOG_FILE"
   if [[ ! -f "$log_file" ]]; then
      echo "$CSV_HEADER" > "$log_file"
   fi
   echo "$row" >> "$log_file"

   # Friendly stdout for cron mail / manual runs. The raw row is what got
   # logged above; for the numbers we split a copy with quoted fields
   # removed, otherwise a server name like "Charlotte, NC" shifts every
   # column by one and ping/down/up come out wrong.
   local fields ping_ms down_mbps up_mbps
   fields="$(echo "$row" | _strip_quoted)"
   ping_ms="$(echo "$fields" | awk -F, '{printf "%.1f", $6}')"
   down_mbps="$(echo "$fields" | awk -F, '{printf "%.1f", $7/1000000}')"
   up_mbps="$(echo "$fields" | awk -F, '{printf "%.1f", $8/1000000}')"
   echo "[$(date '+%Y-%m-%d %H:%M:%S')] ping=${ping_ms}ms down=${down_mbps}Mbps up=${up_mbps}Mbps ip=$ip"
}

cmd_summary() {
   if (( $# > 0 )); then
      echo "$SCRIPT_NAME: summary takes no arguments (got: $*)" >&2
      exit 1
   fi
   _require_logs

   local promised_down="${SPECTRUM_PROMISED_DOWN:-}"
   local promised_up="${SPECTRUM_PROMISED_UP:-}"
   local outage_down="${OUTAGE_DOWN_BELOW:-25}"
   local outage_ping="${OUTAGE_PING_ABOVE:-250}"

   # awk reads all rows across all CSV files, skips headers, computes
   # min/median/mean/max for ping (col 6), download (col 7), upload (col 8).
   # Download/upload are bits/sec from speedtest-cli; convert to Mbps.
   # _load_rows_sorted has already stripped quoted fields (e.g.
   # "Charlotte, NC") so embedded commas don't confuse awk's -F, splitter.
   # shellcheck disable=SC2016
   _load_rows_sorted | awk -F, \
      -v promised_down="$promised_down" \
      -v promised_up="$promised_up" \
      -v outage_down="$outage_down" \
      -v outage_ping="$outage_ping" \
      -v log_dir="$LOG_DIR" '
      function hsort(arr, n,    i, t) {
         # heapsort: O(n log n) and portable across awk/mawk/gawk/BSD awk.
         # (The previous insertion sort was O(n^2): ~40 s at 20k rows and
         # ~4 min at 40k rows, i.e. a year or two of 30-minute samples.)
         for (i = int(n / 2); i >= 1; i--) siftdown(arr, i, n)
         for (i = n; i > 1; i--) {
            t = arr[1]; arr[1] = arr[i]; arr[i] = t
            siftdown(arr, 1, i - 1)
         }
      }
      function siftdown(arr, root, end,    child, t) {
         while (2 * root <= end) {
            child = 2 * root
            if (child < end && arr[child] < arr[child + 1]) child++
            if (arr[root] >= arr[child]) return
            t = arr[root]; arr[root] = arr[child]; arr[child] = t
            root = child
         }
      }
      function median(arr, n,    m) {
         m = int(n/2)
         if (n % 2 == 1) return arr[m+1]
         return (arr[m] + arr[m+1]) / 2
      }
      function fmt(x) { return sprintf("%8.1f", x) }
      {
         n++
         ping[n] = $6 + 0
         down[n] = ($7 + 0) / 1000000
         up[n]   = ($8 + 0) / 1000000
         ts = $4
         if (n == 1 || ts < first_ts) first_ts = ts
         if (n == 1 || ts > last_ts)  last_ts  = ts
         if (promised_down != "" && down[n] < promised_down) below_down++
         if (promised_up   != "" && up[n]   < promised_up)   below_up++
         # Hour-of-day bucket: positions 12-13 of ISO timestamp.
         hour = substr(ts, 12, 2) + 0
         hour_count[hour]++
         hour_down_sum[hour] += down[n]
         # Outage tracking: contiguous runs where down < threshold or ping > threshold.
         is_out = (down[n] < outage_down || ping[n] > outage_ping)
         if (is_out) {
            in_run = 1
            run_samples++
         } else if (in_run) {
            outage_events++
            outage_total_samples += run_samples
            run_samples = 0
            in_run = 0
         }
      }
      END {
         if (n == 0) { print "No data rows."; exit 1 }
         if (in_run) { outage_events++; outage_total_samples += run_samples }
         hsort(ping, n); hsort(down, n); hsort(up, n)
         for (i = 1; i <= n; i++) {
            s_ping += ping[i]; s_down += down[i]; s_up += up[i]
         }
         printf "internet-speed summary\n"
         printf "  log dir:  %s\n", log_dir
         printf "  samples:  %d\n", n
         printf "  range:    %s  →  %s\n\n", first_ts, last_ts
         printf "  %-10s %8s %8s %8s %8s\n", "metric", "min", "median", "mean", "max"
         printf "  %-10s %s %s %s %s\n", "ping (ms)",  fmt(ping[1]), fmt(median(ping,n)), fmt(s_ping/n), fmt(ping[n])
         printf "  %-10s %s %s %s %s\n", "down (Mbps)", fmt(down[1]), fmt(median(down,n)), fmt(s_down/n), fmt(down[n])
         printf "  %-10s %s %s %s %s\n", "up (Mbps)",   fmt(up[1]),   fmt(median(up,n)),   fmt(s_up/n),   fmt(up[n])
         if (promised_down != "") {
            pct = (below_down / n) * 100
            printf "\n  below promised down (%s Mbps):  %d / %d samples  (%.1f%%)\n", promised_down, below_down+0, n, pct
         }
         if (promised_up != "") {
            pct = (below_up / n) * 100
            printf "  below promised up   (%s Mbps):  %d / %d samples  (%.1f%%)\n", promised_up, below_up+0, n, pct
         }
         if (outage_events > 0) {
            printf "\n  outages:  %d events covering %d samples (down < %s Mbps or ping > %s ms)\n", outage_events, outage_total_samples, outage_down, outage_ping
            printf "            run `'"$SCRIPT_NAME"' outages` for the detailed list\n"
         } else {
            printf "\n  outages:  0 (thresholds: down < %s Mbps or ping > %s ms)\n", outage_down, outage_ping
         }
         # Worst 3 hours by mean download.
         worst_n = 0
         for (h = 0; h < 24; h++) {
            if (hour_count[h] > 0) {
               worst_n++
               worst_hour[worst_n] = h
               worst_down[worst_n] = hour_down_sum[h] / hour_count[h]
            }
         }
         # Selection sort top 3 lowest down.
         printf "\n  worst hours (UTC, by mean download):\n"
         for (k = 1; k <= 3 && k <= worst_n; k++) {
            min_i = k
            for (j = k+1; j <= worst_n; j++) {
               if (worst_down[j] < worst_down[min_i]) min_i = j
            }
            tmp_h = worst_hour[k]; worst_hour[k] = worst_hour[min_i]; worst_hour[min_i] = tmp_h
            tmp_d = worst_down[k]; worst_down[k] = worst_down[min_i]; worst_down[min_i] = tmp_d
            printf "    %02d:00 → %02d:00   %6.1f Mbps mean down  (%d samples)\n", worst_hour[k], (worst_hour[k]+1)%24, worst_down[k], hour_count[worst_hour[k]]
         }
         printf "            run `'"$SCRIPT_NAME"' hours` for the full 24-hour breakdown\n"
      }
   '
}

# The log files to read, one path per line: internet-speed.csv (what
# current versions write) followed by any legacy per-IP speed-<ip>.csv
# files from versions before 1.3. Analysis concatenates them all, so
# upgrading needs no migration. Prints nothing if there are no logs.
_log_files() {
   local f
   for f in "$LOG_FILE" "$LOG_DIR"/speed-*.csv; do
      [[ -f "$f" ]] && printf '%s\n' "$f"
   done
   return 0
}

_require_logs() {
   if [[ -z "$(_log_files)" ]]; then
      echo "$SCRIPT_NAME: no logs found in $LOG_DIR" >&2
      echo "Run '$SCRIPT_NAME' first to collect some data." >&2
      exit 1
   fi
}

# Helper: emit the data portion of every log file as a single
# time-sorted stream with quoted fields stripped so awk -F, works.
# Used by cmd_summary, cmd_hours and cmd_outages.
_load_rows_sorted() {
   # Header lines are dropped by the $4 == "Timestamp" test, which works
   # for every file in the concatenation. (A bare `NR > 1` here used to
   # also throw away the first data row of a header-less first file.)
   # LC_ALL=C keeps the ISO-8601 timestamp sort byte-wise and
   # locale-independent.
   # shellcheck disable=SC2016
   local f
   _log_files | while IFS= read -r f; do cat "$f"; done \
      | _strip_quoted \
      | awk -F, '$4 != "" && $4 != "Timestamp"' \
      | LC_ALL=C sort -t, -k4,4
}

cmd_hours() {
   if (( $# > 0 )); then
      echo "$SCRIPT_NAME: hours takes no arguments (got: $*)" >&2
      exit 1
   fi
   _require_logs

   local promised_down="${SPECTRUM_PROMISED_DOWN:-}"

   # shellcheck disable=SC2016
   _load_rows_sorted | awk -F, \
      -v promised_down="$promised_down" '
      {
         hour = substr($4, 12, 2) + 0
         down = ($7 + 0) / 1000000
         ping_v = $6 + 0
         hour_count[hour]++
         hour_down_sum[hour] += down
         hour_ping_sum[hour] += ping_v
         if (down > max_down) max_down = down
         if (promised_down != "" && down < promised_down) hour_below[hour]++
      }
      END {
         # Bar width scales to max observed down (or promised, whichever is bigger).
         scale = (promised_down != "" && promised_down > max_down) ? promised_down : max_down
         bar_width = 30
         printf "hour-of-day breakdown (UTC) — bars show mean download (Mbps), scale %.0f Mbps\n\n", scale
         for (h = 0; h < 24; h++) {
            if (hour_count[h] == 0) {
               printf "  %02d  %-30s   (no samples)\n", h, ""
               continue
            }
            mean_d = hour_down_sum[h] / hour_count[h]
            mean_p = hour_ping_sum[h] / hour_count[h]
            n_full = int((mean_d / scale) * bar_width + 0.5)
            if (n_full > bar_width) n_full = bar_width
            bar = ""
            for (i = 0; i < n_full; i++) bar = bar "█"
            for (i = n_full; i < bar_width; i++) bar = bar "·"
            extra = ""
            if (promised_down != "" && hour_below[h] > 0) {
               extra = sprintf("   %d/%d below %s", hour_below[h], hour_count[h], promised_down)
            }
            printf "  %02d  %s   %6.1f Mbps  ping %3.0f ms%s\n", h, bar, mean_d, mean_p, extra
         }
      }
   '
}

cmd_outages() {
   if (( $# > 0 )); then
      echo "$SCRIPT_NAME: outages takes no arguments (got: $*)" >&2
      exit 1
   fi
   _require_logs

   local outage_down="${OUTAGE_DOWN_BELOW:-25}"
   local outage_ping="${OUTAGE_PING_ABOVE:-250}"

   echo "outages — down < $outage_down Mbps or ping > $outage_ping ms"
   echo

   # shellcheck disable=SC2016
   _load_rows_sorted | awk -F, \
      -v outage_down="$outage_down" \
      -v outage_ping="$outage_ping" '
      function finish_run() {
         if (run_start != "") {
            printf "  %s  →  %s   %4d samples   worst: down=%6.1f Mbps   ping=%5.0f ms\n", \
               run_start, run_end, run_samples, run_min_down, run_max_ping
            count++
         }
         run_start = ""; run_samples = 0
      }
      {
         ts = $4
         ping_v = $6 + 0
         down_v = ($7 + 0) / 1000000
         is_out = (down_v < outage_down || ping_v > outage_ping)
         if (is_out) {
            if (run_start == "") {
               run_start = ts
               run_min_down = down_v
               run_max_ping = ping_v
            } else {
               if (down_v < run_min_down) run_min_down = down_v
               if (ping_v > run_max_ping) run_max_ping = ping_v
            }
            run_end = ts
            run_samples++
         } else {
            finish_run()
         }
      }
      END {
         finish_run()
         if (count == 0) print "  (no outages detected)"
         else printf "\n  %d outage event(s) total\n", count
      }
   '
}

interval_to_cron() {
   # Convert "15m", "30m", "1h", "2h" into a cron schedule expression.
   local interval="$1"
   # Validate the shape up front: anything but digits+unit would otherwise
   # reach the (( )) arithmetic below and die with a confusing
   # "unbound variable" instead of this message.
   if [[ ! "$interval" =~ ^[0-9]+[mh]$ ]]; then
      echo "$SCRIPT_NAME: invalid interval: $interval (use e.g. 15m, 30m, 1h)" >&2
      exit 1
   fi
   # 10# forces decimal so "08m" isn't read as (invalid) octal.
   local n=$((10#${interval%[mh]}))
   case "$interval" in
      *m)
         if (( n < 1 || n > 59 )); then
            echo "$SCRIPT_NAME: minute interval must be 1-59, got: $interval" >&2
            exit 1
         fi
         echo "*/$n * * * *"
         ;;
      *h)
         if (( n < 1 || n > 23 )); then
            echo "$SCRIPT_NAME: hour interval must be 1-23, got: $interval" >&2
            exit 1
         fi
         echo "0 */$n * * *"
         ;;
   esac
}

cmd_install_cron() {
   require_cmd crontab

   local interval="30m"
   local uninstall=0
   while [[ $# -gt 0 ]]; do
      case "$1" in
         --interval) interval="$2"; shift 2 ;;
         --uninstall) uninstall=1; shift ;;
         *) echo "$SCRIPT_NAME: unknown install-cron arg: $1" >&2; exit 1 ;;
      esac
   done

   # Pull the current crontab (may not exist yet), strip any prior
   # internet-speed line, optionally add a new one, install.
   local current new_line
   current="$(crontab -l 2>/dev/null || true)"
   local filtered
   filtered="$(echo "$current" | grep -v -F "$CRON_TAG" || true)"

   if (( uninstall )); then
      echo "$filtered" | crontab -
      echo "$SCRIPT_NAME: removed crontab entry"
      return
   fi

   local schedule
   schedule="$(interval_to_cron "$interval")"
   # Quote the path so a checkout under a directory with spaces works.
   # If SPEED_LOG_DIR was set when installing, bake it into the entry:
   # cron doesn't read ~/.bashrc, so the job would otherwise log to the
   # default dir while `summary` (run from your shell) reads another.
   local env_prefix=""
   if [[ -n "${SPEED_LOG_DIR:-}" ]]; then
      env_prefix="SPEED_LOG_DIR=\"$SPEED_LOG_DIR\" "
   fi
   new_line="$schedule ${env_prefix}\"$SCRIPT_PATH\" >/dev/null 2>&1 $CRON_TAG"

   printf '%s\n%s\n' "$filtered" "$new_line" | grep -v '^$' | crontab -
   echo "$SCRIPT_NAME: installed crontab entry (every $interval)"
   echo "  $new_line"
}

cmd_install_systemd() {
   require_cmd systemctl

   local uninstall=0
   while [[ $# -gt 0 ]]; do
      case "$1" in
         --uninstall) uninstall=1; shift ;;
         *) echo "$SCRIPT_NAME: unknown install-systemd arg: $1" >&2; exit 1 ;;
      esac
   done

   local unit_dir="$HOME/.config/systemd/user"
   local service_dst="$unit_dir/internet-speed.service"
   local timer_dst="$unit_dir/internet-speed.timer"

   if (( uninstall )); then
      systemctl --user disable --now internet-speed.timer 2>/dev/null || true
      rm -f "$service_dst" "$timer_dst"
      systemctl --user daemon-reload
      echo "$SCRIPT_NAME: removed systemd timer"
      return
   fi

   local service_src="$SCRIPT_DIR/systemd/internet-speed.service"
   local timer_src="$SCRIPT_DIR/systemd/internet-speed.timer"
   if [[ ! -f "$service_src" || ! -f "$timer_src" ]]; then
      echo "$SCRIPT_NAME: systemd unit templates not found in $SCRIPT_DIR/systemd/" >&2
      exit 1
   fi

   mkdir -p "$unit_dir"
   # Pure-bash substitution: unlike sed there's no delimiter or escaping
   # to trip over if the path contains |, &, or \.
   local unit
   unit="$(<"$service_src")"
   unit="${unit//@SCRIPT_PATH@/"$SCRIPT_PATH"}"
   # A `systemctl --user` service doesn't see ~/.bashrc exports, so bake
   # SPEED_LOG_DIR into the unit if it is set right now (same reasoning
   # as install-cron).
   if [[ -n "${SPEED_LOG_DIR:-}" ]]; then
      unit="$unit"$'\n'"Environment=\"SPEED_LOG_DIR=$SPEED_LOG_DIR\""
   fi
   printf '%s\n' "$unit" > "$service_dst"
   cp "$timer_src" "$timer_dst"

   systemctl --user daemon-reload
   systemctl --user enable --now internet-speed.timer
   echo "$SCRIPT_NAME: installed systemd timer (every 30 min)"
   if [[ -n "${SPEED_LOG_DIR:-}" ]]; then
      echo "  log dir baked into the unit: $SPEED_LOG_DIR"
   fi
   echo "  see: systemctl --user list-timers | grep internet-speed"
}

cmd_migrate() {
   # Convert legacy semicolon-separated log files (date;time;ping;down;up)
   # produced by the pre-1.0 script into the new speedtest-cli --csv format.
   # Detects per-line, so files containing a mix of old and new rows
   # (which can happen if v1.0+ appended to an existing legacy file) work.
   # Backs up the original to <file>.bak before overwriting.
   local dry_run=0
   while [[ $# -gt 0 ]]; do
      case "$1" in
         --dry-run|-n) dry_run=1; shift ;;
         *) echo "$SCRIPT_NAME: unknown migrate arg: $1" >&2; exit 1 ;;
      esac
   done

   _require_logs

   local migrated=0 already=0 empty=0
   local f
   while IFS= read -r f; do
      local base ip first
      # Legacy semicolon rows carry no IP, so take it from a speed-<ip>.csv
      # filename when there is one; otherwise leave the column empty.
      base="${f##*/}"
      case "$base" in
         speed-*.csv) ip="${base#speed-}"; ip="${ip%.csv}" ;;
         *)           ip="" ;;
      esac
      first="$(grep -m1 -v '^$' "$f" 2>/dev/null || true)"

      if [[ -z "$first" ]]; then
         echo "  [empty]      $f"
         (( ++empty ))
         continue
      fi

      # Already new format? Header line OR data line with ≥10 comma-separated cols.
      if [[ "$first" == "$CSV_HEADER" ]] \
         || { [[ "$first" == *,*,*,*,*,*,*,*,*,* ]] && [[ "$first" != *";"* ]]; }; then
         echo "  [already]    $f"
         (( ++already ))
         continue
      fi

      local converted
      converted="$(
         awk -F';' -v ip="$ip" '
         {
            # Strip a trailing CR first: a legacy log with Windows line
            # endings otherwise matches no pattern below and migrates to a
            # header-only file while reporting success.
            sub(/\r$/, "")
            # If line has 10+ commas (new format), pass through unchanged.
            n_comma = gsub(/,/, ",", $0)
            if (n_comma >= 9) { print $0; next }
            # Otherwise treat as legacy semicolon format.
            # Field 1 = YYYY-MM-DD, field 2 = HH:MM:SS, then collect first
            # 3 numeric fields → ping, download Mbps, upload Mbps.
            if ($1 !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) next
            if ($2 !~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}$/) next
            n = 0
            for (i = 3; i <= NF; i++) {
               if ($i ~ /^[0-9]+(\.[0-9]+)?$/) {
                  n++; v[n] = $i + 0
                  if (n == 3) break
               }
            }
            if (n < 3) next
            ts = $1 "T" $2 "Z"
            printf ",,,%s,,%s,%d,%d,,%s\n", ts, v[1], v[2]*1000000, v[3]*1000000, ip
         }
         ' "$f"
      )"

      local converted_rows
      converted_rows="$(echo "$converted" | grep -c . || true)"
      local original_rows
      original_rows="$(grep -c -v '^$' "$f" || true)"

      if (( dry_run )); then
         echo "  [would-migrate] $f  ($original_rows rows → $converted_rows new-format rows)"
         (( ++migrated ))
         continue
      fi

      cp -p "$f" "$f.bak"
      { echo "$CSV_HEADER"; echo "$converted"; } > "$f.tmp"
      mv "$f.tmp" "$f"
      echo "  [migrated]   $f  ($original_rows → $converted_rows rows, backup: $f.bak)"
      (( ++migrated ))
   done < <(_log_files)

   echo
   if (( dry_run )); then
      echo "$SCRIPT_NAME: dry run — $migrated would migrate, $already already new, $empty empty"
   else
      echo "$SCRIPT_NAME: $migrated migrated, $already already new, $empty empty"
   fi
}

main() {
   local cmd="${1:-run}"
   case "$cmd" in
      run)              shift 2>/dev/null || true; cmd_run "$@" ;;
      summary)          shift; cmd_summary "$@" ;;
      outages)          shift; cmd_outages "$@" ;;
      hours)            shift; cmd_hours "$@" ;;
      migrate)          shift; cmd_migrate "$@" ;;
      install-cron)     shift; cmd_install_cron "$@" ;;
      install-systemd)  shift; cmd_install_systemd "$@" ;;
      -h|--help)        usage ;;
      --version)        echo "$SCRIPT_NAME $VERSION" ;;
      *)
         echo "$SCRIPT_NAME: unknown command: $cmd" >&2
         echo "Run '$SCRIPT_NAME --help' for usage." >&2
         exit 1
         ;;
   esac
}

main "$@"
