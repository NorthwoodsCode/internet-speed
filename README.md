# internet-speed

[![ci](https://github.com/NorthwoodsCode/internet-speed/actions/workflows/ci.yml/badge.svg)](https://github.com/NorthwoodsCode/internet-speed/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Track what your ISP actually delivers vs. what they promised.**

Cron a `speedtest-cli` run every 15–30 minutes, accumulate a CSV log over weeks
or months, then visualize it. Built originally to prove that Spectrum (Charter)
wasn't delivering the speeds we paid for. Works with any ISP.

---

## Quick start

Five minutes from clone to first data point. If anything fails, see
[Troubleshooting](#troubleshooting) at the bottom.

```bash
# 1. Install speedtest-cli (the Python one — see Requirements below)
sudo apt install speedtest-cli           # Debian/Ubuntu/Mint
# brew install speedtest-cli             # macOS
# pip install --user speedtest-cli       # anywhere with Python (may need --break-system-packages on Debian 12+)

# 2. Clone + make executable
git clone https://github.com/NorthwoodsCode/internet-speed.git
cd internet-speed
chmod +x speedtest.sh

# 3. Tell it what you're paying for (optional but recommended)
export SPECTRUM_PROMISED_DOWN=500        # your plan's down Mbps
export SPECTRUM_PROMISED_UP=20           # your plan's up Mbps

# 4. Run one test — should append a row to ~/speed_logs/speed-<ip>.csv
./speedtest.sh

# 5. See what you've got — try all three:
./speedtest.sh summary
./speedtest.sh hours
./speedtest.sh outages

# Then schedule it (pick one — see "Schedule it" below):
./speedtest.sh install-cron --interval 30m       # cron, easiest
# ./speedtest.sh install-systemd                 # or systemd --user timer

# Open the dashboard against your own data:
python3 -m http.server 8000
# visit http://localhost:8000/dashboard/ and drop your CSV onto the page
```

That's it for the bash side. For PNG charts or PDF reports, see
[View your data](#view-your-data) below — they need `matplotlib`.

- **Bash collector** — appends one row per run to a per-IP CSV log
- **HTML dashboard** — interactive Chart.js with time-series, hour-of-day
  bars, outage shading, and color-coded stat cards  
  → **[live demo](https://NorthwoodsCode.github.io/internet-speed/dashboard/)** (loads `examples/speed-sample.csv`)
- **Static PNG export** — `python3 plot.py` for screenshot-style charts
- **Monthly PDF report** — `python3 report.py` for a one-page summary you
  can attach to a complaint email
- **Promised-speed baseline** — set `SPECTRUM_PROMISED_DOWN=400` and every
  chart shows a reference line + "% of samples below promised" stat
- **Outage detection** — contiguous bad samples are grouped into events,
  shaded red on charts, listed by `./speedtest.sh outages`
- **Hour-of-day analysis** — `./speedtest.sh hours` shows you exactly when
  your ISP is failing you

---

## What it does

```text
$ ./speedtest.sh
[2026-05-27 12:00:15] ping=11.7ms down=405.3Mbps up=20.1Mbps ip=73.176.45.182
```

```text
$ SPECTRUM_PROMISED_DOWN=400 SPECTRUM_PROMISED_UP=20 ./speedtest.sh summary
internet-speed summary
  log dir:  /home/you/speed_logs
  samples:  337
  range:    2026-05-20T12:00:00.000Z  →  2026-05-27T12:00:00.000Z

  metric          min   median     mean      max
  ping (ms)       7.0     11.7     14.4     58.9
  down (Mbps)    124.0    402.1    384.0    431.7
  up (Mbps)       13.0     20.5     20.1     22.0

  below promised down (400 Mbps):  157 / 337 samples  (46.6%)
  below promised up   (20 Mbps):   123 / 337 samples  (36.5%)

  outages:  0 (thresholds: down < 25 Mbps or ping > 250 ms)

  worst hours (by mean download):
    08:00 → 09:00    286.0 Mbps mean down  (14 samples)
    07:00 → 08:00    307.2 Mbps mean down  (14 samples)
    06:00 → 07:00    312.5 Mbps mean down  (14 samples)
```

The "46.6% below promised" and "08:00-09:00 is the worst hour" lines are
the whole point — that's the ammo for a complaint email.

---

## Requirements

| Tier         | What                                       | Where                                                                                       |
| ------------ | ------------------------------------------ | ------------------------------------------------------------------------------------------- |
| **Required** | `bash` 3.2+                                | preinstalled on Linux/macOS                                                                 |
| **Required** | `speedtest-cli` (the Python one by sivel)  | `apt install speedtest-cli` / `brew install speedtest-cli` / `pip install speedtest-cli`    |
| Optional     | `python3` + `matplotlib`                   | only for `plot.py` (PNG export) and `report.py` (monthly PDF). See install notes below.     |
| Optional     | `cron` or `systemd`                        | only if you want scheduled runs (`install-cron` / `install-systemd`)                        |
| Optional     | `timeout` (GNU coreutils)                  | 3-second network preflight before each run. Preinstalled on Linux; on macOS `brew install coreutils` provides `gtimeout`. Skipped if absent. |

> ⚠️ There are two unrelated tools called "speedtest" — Ookla's official binary and
> [sivel's Python `speedtest-cli`](https://github.com/sivel/speedtest-cli). This repo
> uses the Python one; they produce different CSV columns.

**Installing matplotlib (only needed for `plot.py` and `report.py`):**

```bash
# Debian/Ubuntu/Mint — preferred, uses the system package
sudo apt install python3-matplotlib

# macOS or anywhere with pipx
pipx install matplotlib   # if matplotlib were a CLI app; for libs use a venv:
python3 -m venv .venv && source .venv/bin/activate && pip install matplotlib

# Older systems or if you don't mind breaking system Python
pip install --user matplotlib
# Debian 12+ / Ubuntu 24.04+ / Mint 22+ block this (PEP 668). Either use
# the apt package above, a venv, or add --break-system-packages.
```

---

## Install

```bash
git clone https://github.com/NorthwoodsCode/internet-speed.git
cd internet-speed
chmod +x speedtest.sh
./speedtest.sh --help
```

Optional — put it on PATH:

```bash
ln -s "$(pwd)/speedtest.sh" ~/.local/bin/internet-speed
```

---

## Set your promised speed

Tell the tool what your ISP promised so it can compute "% below promised" stats and
draw baseline lines on the charts:

```bash
# Add to ~/.bashrc or ~/.zshrc
export SPECTRUM_PROMISED_DOWN=400   # Mbps
export SPECTRUM_PROMISED_UP=20      # Mbps
```

Optional. Without them the tool still collects and graphs data, just without the
"vs promised" comparison.

---

## Schedule it

Pick one — they all do the same thing.

### Option A — easiest, one command

```bash
./speedtest.sh install-cron --interval 30m
```

Adds an idempotent line tagged `# internet-speed` to your crontab.
Re-run with `--uninstall` to remove. If `SPEED_LOG_DIR` is set in your
shell when you run this, it is baked into the entry (cron does not read
`~/.bashrc`, so the job would otherwise log somewhere `summary` doesn't look).

### Option B — manual cron

Print the exact line for your install with:

```bash
echo "*/30 * * * * \"$(pwd)/speedtest.sh\" >/dev/null 2>&1"
```

Then `crontab -e` and paste. Replace `*/30` with `*/15` for 15-min intervals,
or `0 */2` for every 2 hours.

### Option C — systemd `--user` timer

```bash
./speedtest.sh install-systemd
systemctl --user list-timers | grep internet-speed
```

The timer fires 5 minutes after boot and every 30 minutes thereafter, with
`Persistent=true` to catch up after laptop sleep. As with cron, a
`systemctl --user` service does not see `~/.bashrc` exports; `install-systemd`
bakes `SPEED_LOG_DIR` into the generated unit if it is set at install time.

---

## View your data

### Interactive dashboard (recommended)

From the repo root:

```bash
python3 -m http.server 8000
# open http://localhost:8000/dashboard/
```

Drop your `~/speed_logs/speed-<ip>.csv` into the page (or copy it next to
`dashboard/index.html` as `speed.csv` and refresh). Try the live demo to see
what it looks like: <https://NorthwoodsCode.github.io/internet-speed/dashboard/>

Features:

- 6+ stat cards with color coding (green/orange/red vs. your promised speed)
- 3 time-series charts with promised-speed baseline + red outage shading
- Hour-of-day bar chart (4th panel) — see when your ISP is failing you
- Time-range filter (24h / 7d / 30d / all)
- Loads CSV via `?csv=URL`, `./speed.csv`, or drag-and-drop
- URL param overrides: `?down=400&up=20&outage_down=200&outage_ping=50`

### Static PNG (for sharing or embedding)

Requires matplotlib — see [Requirements](#requirements) for install options.

```bash
SPECTRUM_PROMISED_DOWN=400 SPECTRUM_PROMISED_UP=20 python3 plot.py
# writes speed-chart.png
```

Four-panel chart: download / upload / ping time series (with promised baseline +
red outage shading) and a mean-download-by-hour-of-day bar chart at the bottom.
Use `--days 7` to limit to recent data, `--csv PATH` for a specific log file.

### Monthly PDF report (for emailing your ISP)

Requires matplotlib — see [Requirements](#requirements) for install options.

```bash
SPECTRUM_PROMISED_DOWN=400 SPECTRUM_PROMISED_UP=20 python3 report.py
# writes report-2026-04.pdf for the previous complete month
```

One-page A4 PDF with stats summary table, time-series charts, hour-of-day
breakdown, and outage event list. Attach to a complaint email. Override the
month with `--month 2026-03` or output path with `-o`.

### Quick CLI summary + drill-downs

```bash
./speedtest.sh summary    # high-level stats + worst 3 hours + outage count
./speedtest.sh hours      # full 24-hour breakdown with ASCII bar chart
./speedtest.sh outages    # list each detected outage event
```

The `hours` output uses ASCII bars so you can see when your ISP is failing
you directly in a terminal — no graphical viewer needed.

---

## Output format

One CSV per public IP (so a move/ISP change starts a fresh log). Standard
`speedtest-cli --csv` columns:

```csv
Server ID,Sponsor,Server Name,Timestamp,Distance,Ping,Download,Upload,Share,IP Address
18531,Spectrum,"Charlotte, NC",2026-05-27T12:00:00.000Z,96.74,9.47,413250194,19075032,,73.176.45.182
```

Download and Upload are in **bits/sec** (divide by 1,000,000 for Mbps).

---

## Configuration

| Env var                  | Default          | Purpose                                          |
| ------------------------ | ---------------- | ------------------------------------------------ |
| `SPEED_LOG_DIR`     | `~/speed_logs/`  | Where CSV logs go                                |
| `SPEED_PREFLIGHT_HOST` | `8.8.8.8:53`  | `host:port` probed before each run so an "internet is out" condition fails fast. Set to an empty string to skip the probe. |
| `SPECTRUM_PROMISED_DOWN` | _(unset)_        | Your plan's promised down in Mbps                |
| `SPECTRUM_PROMISED_UP`   | _(unset)_        | Your plan's promised up in Mbps                  |
| `OUTAGE_DOWN_BELOW` | `25`             | Outage threshold: download < N Mbps              |
| `OUTAGE_PING_ABOVE` | `250`            | Outage threshold: ping > N ms                    |

Dashboard accepts URL params too:
`?down=400&up=20&outage_down=200&outage_ping=50&csv=https://example.com/log.csv`.

---

## Subcommand reference

```text
speedtest.sh [run]                Run a speed test and append to CSV log
speedtest.sh summary              Min/median/mean/max + outage count + worst hours
speedtest.sh outages              List each detected outage event
speedtest.sh hours                24-hour ASCII bar chart of mean download
speedtest.sh migrate [--dry-run]  Convert legacy ;-separated logs to new format
speedtest.sh install-cron [--interval 30m] [--uninstall]
speedtest.sh install-systemd [--uninstall]
speedtest.sh --help | --version
```

### Migrating from pre-1.0 logs

If you have logs from the original (pre-1.0) script — semicolon-separated
lines like `2021-08-26;14:52:50;4.55;320.40;12.10` — run:

```bash
./speedtest.sh migrate --dry-run   # see what would change
./speedtest.sh migrate             # actually convert
```

Each affected file is backed up to `<file>.bak` before being rewritten in
the new `speedtest-cli --csv` format. The migration is idempotent — running
it again on already-converted files is a no-op. Files containing a mix of
old and new rows (which can happen if v1.0+ appended to a legacy file) are
handled correctly: new rows pass through unchanged, old rows are converted.

---

## Troubleshooting

**`speedtest.sh: required command not found: speedtest-cli`**  
Install it (see [Quick start](#quick-start) step 1). Double-check you got
the [sivel Python one](https://github.com/sivel/speedtest-cli) and not
Ookla's official binary — the CSV columns differ.

**`error: externally-managed-environment` when running `pip install`**  
That's [PEP 668](https://peps.python.org/pep-0668/), enforced by Debian 12+,
Ubuntu 24.04+, Mint 22+. Use `apt install python3-matplotlib` instead, or
create a venv (`python3 -m venv .venv && source .venv/bin/activate && pip
install matplotlib`), or — if you understand the risk — add
`--break-system-packages`.

**Dashboard shows a file picker instead of charts**  
The dashboard tried to fetch `./speed.csv` / `../examples/speed-sample.csv`
and got 404s. Make sure you're serving from the **repo root**
(`python3 -m http.server 8000` from where `speedtest.sh` lives) and visiting
`http://localhost:8000/dashboard/`, not from inside `dashboard/`. Or just
drag your CSV onto the page.

**`summary` says "no logs found"**  
You haven't run `./speedtest.sh` yet, or you set `SPEED_LOG_DIR` to
the wrong place. Check `~/speed_logs/` for files named `speed-<ip>.csv`.

**No "network is down" message on macOS even when offline**  
The 3-second preflight needs GNU `timeout`, which stock macOS lacks, so the
script skips the probe and lets `speedtest-cli` fail on its own (slower, same
result). `brew install coreutils` provides `gtimeout`, which is picked up
automatically.

**`network is down (couldn't reach 8.8.8.8:53)` but the internet works**  
Your network blocks outbound DNS to Google. Point the probe somewhere else
with `SPEED_PREFLIGHT_HOST=1.1.1.1:53`, or set it to an empty string to skip
the probe entirely.

**Cron or systemd job runs but no rows appear in the log**  
Cron and `systemctl --user` both have a minimal environment — exports from
`~/.bashrc` aren't visible. `SPECTRUM_PROMISED_*` only affect summary/charts,
not collection, so the data still gets logged. `SPEED_LOG_DIR` *does* affect
collection: `install-cron` and `install-systemd` bake it in if it is set when
you run them, otherwise the job logs to `~/speed_logs/`. Re-run the install
command with the variable set to fix an existing entry. For cron, set
`MAILTO=you@example.com` in your crontab to see the actual output of runs.

**`./speedtest.sh hours` shows different worst-hour than the dashboard**  
The bash `summary` and `hours` subcommands bucket by **UTC** hour
(extracted from the ISO timestamp via substring, since there is no portable
way to convert timezones in bash/awk). The HTML dashboard, `plot.py`, and
`report.py` convert each timestamp to your **local** timezone first, so
their time axes, hour-of-day buckets, and `24h`/`7d`/`--days`/`--month`
windows are all in local time. If your timezone is offset from UTC, the
bash output will differ from the others by exactly that offset; it is
labeled "(UTC)" to make this obvious. The dashboard/plot/report numbers
are what you usually want.

---

## Tests

Smoke tests for every subcommand, exercising the committed sample CSV
plus synthetic legacy data for migration:

```bash
./tests/run.sh           # 40+ tests, ~2 seconds
VERBOSE=1 ./tests/run.sh # dump full output of every command
```

`speedtest-cli` and `crontab` are stubbed with tiny scripts on `PATH`, so the
`run` and `install-cron` paths are exercised without a network connection or
touching your real crontab. CI runs the suite on Ubuntu and macOS plus
`shellcheck` on every push and PR (see `.github/workflows/ci.yml`).

---

## License

MIT — see [LICENSE](LICENSE).
