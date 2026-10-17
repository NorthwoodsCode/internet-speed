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

readonly REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

# ---------- meta / help ----------

assert "version prints expected format" 0 "speedtest.sh 1." \
   "$SPEEDTEST" --version
assert "help shows USAGE section"       0 "USAGE" \
   "$SPEEDTEST" --help
assert "unknown command rejected"       1 "unknown command" \
   "$SPEEDTEST" nonexistent-cmd

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

# ---------- missing-logs edge cases ----------

assert "summary on missing log dir exits 1" 1 "no logs found" \
   env SPEED_LOG_DIR="/tmp/never-exists-$$" "$SPEEDTEST" summary
assert "outages on missing log dir exits 1" 1 "no logs found" \
   env SPEED_LOG_DIR="/tmp/never-exists-$$" "$SPEEDTEST" outages
assert "hours on missing log dir exits 1" 1 "no logs found" \
   env SPEED_LOG_DIR="/tmp/never-exists-$$" "$SPEEDTEST" hours
assert "migrate on missing log dir exits 1" 1 "no logs found" \
   env SPEED_LOG_DIR="/tmp/never-exists-$$" "$SPEEDTEST" migrate

# ---------- Python tools: --help works without matplotlib ----------

assert "plot.py --help works without matplotlib" 0 "Render" \
   python3 "$REPO_DIR/plot.py" --help
assert "report.py --help works without matplotlib" 0 "monthly performance" \
   python3 "$REPO_DIR/report.py" --help

# ---------- summary ----------

echo
if (( TESTS_FAILED > 0 )); then
   printf "FAILED: %d/%d tests\n" "$TESTS_FAILED" "$TESTS_RUN"
   exit 1
fi
printf "OK: %d/%d tests passed\n" "$TESTS_RUN" "$TESTS_RUN"
