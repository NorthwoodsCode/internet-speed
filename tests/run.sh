#!/usr/bin/env bash
#
# Smoke tests for internet-speed.
#
# Exercises every subcommand against the committed sample CSV in a temp
# log dir, checks for expected output and exit codes, and reports
# pass/fail counts. No external test framework — just bash + grep.
#
# Run from anywhere:
#    ./tests/run.sh
#
# Set VERBOSE=1 to dump full output on every test (helpful when debugging).

set -uo pipefail   # NOT -e: we want to keep running after a failed test

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_DIR
readonly SPEEDTEST="$REPO_DIR/speedtest.sh"
readonly SAMPLE_CSV="$REPO_DIR/examples/speed-sample.csv"

TESTS_RUN=0
TESTS_FAILED=0
TMP_LOG_DIR=""
TMP_TEST_DIR=""

cleanup() { [[ -n "$TMP_LOG_DIR" ]] && rm -rf "$TMP_LOG_DIR" "$TMP_TEST_DIR"; }
trap cleanup EXIT

# ---------- assertion helpers ----------

# assert <name> <expected exit code> <expected substring in stdout|stderr> <command...>
assert() {
   local name="$1" expect_exit="$2" expect_match="$3"; shift 3
   TESTS_RUN=$((TESTS_RUN + 1))
   local out actual_exit
   out="$("$@" 2>&1)"; actual_exit=$?
   if [[ -n "${VERBOSE:-}" ]]; then
      echo "--- $name ---"
      echo "  cmd: $*"
      echo "  exit: $actual_exit (expected $expect_exit)"
      echo "  output:"; echo "$out" | sed 's/^/    /'
   fi
   if [[ "$actual_exit" != "$expect_exit" ]]; then
      printf "FAIL  %s — expected exit %s, got %s\n" "$name" "$expect_exit" "$actual_exit"
      [[ -z "${VERBOSE:-}" ]] && echo "$out" | head -5 | sed 's/^/    /'
      TESTS_FAILED=$((TESTS_FAILED + 1))
      return
   fi
   if [[ -n "$expect_match" ]] && ! echo "$out" | grep -qF "$expect_match"; then
      printf "FAIL  %s — output did not contain: %s\n" "$name" "$expect_match"
      [[ -z "${VERBOSE:-}" ]] && echo "$out" | head -5 | sed 's/^/    /'
      TESTS_FAILED=$((TESTS_FAILED + 1))
      return
   fi
   printf "PASS  %s\n" "$name"
}

# ---------- setup ----------

if [[ ! -x "$SPEEDTEST" ]]; then
   echo "tests/run.sh: $SPEEDTEST not found or not executable" >&2
   exit 1
fi
if [[ ! -f "$SAMPLE_CSV" ]]; then
   echo "tests/run.sh: sample CSV missing: $SAMPLE_CSV" >&2
   exit 1
fi

TMP_LOG_DIR="$(mktemp -d)"
TMP_TEST_DIR="$(mktemp -d)"
cp "$SAMPLE_CSV" "$TMP_LOG_DIR/"

export SPEED_LOG_DIR="$TMP_LOG_DIR"

# Stub directory prepended to PATH for tests that would otherwise need a
# real speedtest-cli or would modify the real crontab.
FAKE_BIN="$TMP_TEST_DIR/bin"
mkdir -p "$FAKE_BIN"

# ---------- meta / help ----------

assert "version prints expected format" 0 "speedtest.sh 1." \
   "$SPEEDTEST" --version
assert "help shows USAGE section"       0 "USAGE" \
   "$SPEEDTEST" --help
assert "unknown command rejected"       1 "unknown command" \
   "$SPEEDTEST" nonexistent-cmd

# ---------- run (speedtest-cli stubbed, no network) ----------

# The stub returns the first sample row. Its server name ("Charlotte, NC")
# contains a comma, which used to shift every column of the friendly
# output by one. SPEED_PREFLIGHT_HOST= disables the network probe.
cat > "$FAKE_BIN/speedtest-cli" <<'EOF'
#!/usr/bin/env bash
echo '18531,Spectrum,"Charlotte, NC",2026-05-20T12:00:00.000Z,96.7446,9.475,413250194,19075032,,73.176.45.182'
EOF
chmod +x "$FAKE_BIN/speedtest-cli"
RUN_DIR="$TMP_TEST_DIR/run"
assert "run prints the right numbers despite a comma in the server name" 0 \
   "ping=9.5ms down=413.3Mbps up=19.1Mbps ip=73.176.45.182" \
   env PATH="$FAKE_BIN:$PATH" SPEED_LOG_DIR="$RUN_DIR" SPEED_PREFLIGHT_HOST= "$SPEEDTEST" run
assert "run creates a per-IP log with the CSV header" 0 "Server ID,Sponsor" \
   head -1 "$RUN_DIR/speed-73.176.45.182.csv"
assert "run appends the raw row unchanged" 0 '"Charlotte, NC"' \
   tail -1 "$RUN_DIR/speed-73.176.45.182.csv"
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
   assert "run exits 2 when the preflight target is unreachable" 2 "network is down" \
      env PATH="$FAKE_BIN:$PATH" SPEED_LOG_DIR="$RUN_DIR" SPEED_PREFLIGHT_HOST=127.0.0.1:9 "$SPEEDTEST" run
fi

# ---------- summary ----------

assert "summary reports 337 samples" 0 "samples:  337" \
   "$SPEEDTEST" summary
assert "summary with baselines: 46.6% below" 0 "(46.6%)" \
   env SPECTRUM_PROMISED_DOWN=400 SPECTRUM_PROMISED_UP=20 "$SPEEDTEST" summary
assert "summary rejects unknown args" 1 "takes no arguments" \
   "$SPEEDTEST" summary --bogus

# ---------- outages ----------

assert "outages with default threshold finds none" 0 "(no outages detected)" \
   "$SPEEDTEST" outages
assert "outages with 200 Mbps threshold finds 2 events" 0 "2 outage event(s)" \
   env OUTAGE_DOWN_BELOW=200 "$SPEEDTEST" outages
assert "outages rejects unknown args" 1 "takes no arguments" \
   "$SPEEDTEST" outages --bogus

# ---------- hours ----------

assert "hours prints 24-line UTC breakdown" 0 "hour-of-day breakdown (UTC)" \
   "$SPEEDTEST" hours
assert "hours rejects unknown args" 1 "takes no arguments" \
   "$SPEEDTEST" hours --bogus

# ---------- migrate ----------

assert "migrate detects sample as already-new" 0 "[already]" \
   "$SPEEDTEST" migrate --dry-run

# legacy-format conversion path
LEGACY_DIR="$TMP_TEST_DIR/legacy"
mkdir -p "$LEGACY_DIR"
cat > "$LEGACY_DIR/speed-10.0.0.1.csv" <<'EOF'
2021-08-11;08:03:00;5.3;350.00;18.01
2021-08-12;09:06:00;5.6;360.00;19.00
EOF
assert "migrate converts legacy lines" 0 "[migrated]" \
   env SPEED_LOG_DIR="$LEGACY_DIR" "$SPEEDTEST" migrate
assert "migrate is idempotent (re-run skips)" 0 "[already]" \
   env SPEED_LOG_DIR="$LEGACY_DIR" "$SPEEDTEST" migrate
assert "migrate left a .bak backup" 0 "" \
   test -f "$LEGACY_DIR/speed-10.0.0.1.csv.bak"
assert "migrated file has the new CSV header" 0 "Server ID,Sponsor" \
   head -1 "$LEGACY_DIR/speed-10.0.0.1.csv"

# empty-file edge case (regression test for the (( var++ )) bug)
EMPTY_DIR="$TMP_TEST_DIR/empty"
mkdir -p "$EMPTY_DIR"
touch "$EMPTY_DIR/speed-0.0.0.0.csv"
assert "migrate on empty file exits 0" 0 "[empty]" \
   env SPEED_LOG_DIR="$EMPTY_DIR" "$SPEEDTEST" migrate

# ---------- install-cron arg validation (no actual crontab modification) ----------

assert "install-cron rejects out-of-range minutes" 1 "minute interval must be 1-59" \
   "$SPEEDTEST" install-cron --interval 99m
assert "install-cron rejects junk interval"        1 "invalid interval"            \
   "$SPEEDTEST" install-cron --interval foo
assert "install-cron rejects unknown flag"         1 "unknown install-cron arg"    \
   "$SPEEDTEST" install-cron --bogus
assert "install-cron rejects non-numeric interval cleanly" 1 "invalid interval" \
   "$SPEEDTEST" install-cron --interval abcm

# ---------- install-cron happy path (crontab stubbed) ----------

# Fake crontab: `-l` prints the saved table, `-` replaces it from stdin.
CRON_STATE="$TMP_TEST_DIR/crontab.txt"
cat > "$FAKE_BIN/crontab" <<EOF
#!/usr/bin/env bash
state="$CRON_STATE"
case "\$1" in
   -l) if [[ -f "\$state" ]]; then cat "\$state"; fi ;;
   -)  cat > "\$state" ;;
esac
EOF
chmod +x "$FAKE_BIN/crontab"
printf '0 0 * * * /bin/true # unrelated\n' > "$CRON_STATE"
assert "install-cron installs a quoted script path" 0 "\"$SPEEDTEST\" >/dev/null" \
   env PATH="$FAKE_BIN:$PATH" "$SPEEDTEST" install-cron --interval 08m
assert "install-cron reads 08m as 8 minutes, not octal" 0 "*/8 * * * *" \
   cat "$CRON_STATE"
assert "install-cron keeps unrelated entries" 0 "# unrelated" \
   cat "$CRON_STATE"
assert "install-cron bakes SPEED_LOG_DIR into the entry" 0 "SPEED_LOG_DIR=\"$TMP_LOG_DIR\"" \
   env PATH="$FAKE_BIN:$PATH" "$SPEEDTEST" install-cron --interval 15m
assert "install-cron is idempotent (one tagged line after two installs)" 0 "" \
   bash -c 'test "$(grep -c "# internet-speed" "$1")" -eq 1' _ "$CRON_STATE"
assert "install-cron --uninstall removes the entry" 0 "removed crontab entry" \
   env PATH="$FAKE_BIN:$PATH" "$SPEEDTEST" install-cron --uninstall
assert "uninstall leaves unrelated entries alone" 0 "# unrelated" \
   cat "$CRON_STATE"

# ---------- missing-logs edge cases ----------

assert "summary on missing log dir exits 1" 1 "no logs found" \
   env SPEED_LOG_DIR="/tmp/never-exists-$$" "$SPEEDTEST" summary
assert "outages on missing log dir exits 1" 1 "no logs found" \
   env SPEED_LOG_DIR="/tmp/never-exists-$$" "$SPEEDTEST" outages
assert "hours on missing log dir exits 1" 1 "no logs found" \
   env SPEED_LOG_DIR="/tmp/never-exists-$$" "$SPEEDTEST" hours
assert "migrate on missing log dir exits 1" 1 "no logs found" \
   env SPEED_LOG_DIR="/tmp/never-exists-$$" "$SPEEDTEST" migrate

# ---------- header-less log: first data row must not be dropped ----------

NOHDR_DIR="$TMP_TEST_DIR/nohdr"
mkdir -p "$NOHDR_DIR"
tail -n +2 "$SAMPLE_CSV" | head -3 > "$NOHDR_DIR/speed-1.1.1.1.csv"
assert "summary counts every row of a header-less log" 0 "samples:  3" \
   env SPEED_LOG_DIR="$NOHDR_DIR" "$SPEEDTEST" summary

# ---------- Python tools (none of these need matplotlib) ----------

assert "plot.py --help works without matplotlib" 0 "Render" \
   python3 "$REPO_DIR/plot.py" --help
assert "report.py --help works without matplotlib" 0 "monthly performance" \
   python3 "$REPO_DIR/report.py" --help
assert "report.py rejects --month 13 cleanly" 1 "bad --month" \
   python3 "$REPO_DIR/report.py" --csv "$SAMPLE_CSV" --month 2026-13
assert "plot.py rejects a non-numeric promised speed cleanly" 1 "must be a number" \
   env SPECTRUM_PROMISED_DOWN=abc python3 "$REPO_DIR/plot.py" --csv "$SAMPLE_CSV"
assert "plot.py converts UTC timestamps to local time" 0 "hour=21" \
   env TZ=Asia/Tokyo python3 -c '
import sys; sys.path.insert(0, sys.argv[1])
import plot
print("hour=%d" % plot.parse_timestamp("2026-05-20T12:00:00.000Z").hour)' "$REPO_DIR"
assert "plot.py pads a single-sample outage to a visible span" 0 "width_min=30" \
   python3 -c '
import sys, datetime as dt; sys.path.insert(0, sys.argv[1])
import plot
t0 = dt.datetime(2026, 1, 1)
times = [t0 + dt.timedelta(minutes=30 * i) for i in range(5)]
events = plot.detect_outages(times, [10, 10, 999, 10, 10], [400] * 5)
(a, b), = plot.outage_spans(times, events)
print("width_min=%d" % ((b - a).total_seconds() // 60))' "$REPO_DIR"

# ---------- summary ----------

echo
if (( TESTS_FAILED > 0 )); then
   printf "FAILED: %d/%d tests\n" "$TESTS_FAILED" "$TESTS_RUN"
   exit 1
fi
printf "OK: %d/%d tests passed\n" "$TESTS_RUN" "$TESTS_RUN"
