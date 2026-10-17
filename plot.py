#!/usr/bin/env python3
"""Render a 4-panel PNG chart from internet-speed CSV logs.

Panels (top to bottom):
  1. Download (Mbps) over time
  2. Upload (Mbps) over time
  3. Ping (ms) over time
  4. Mean download by hour-of-day (bar chart)

When SPECTRUM_PROMISED_DOWN / SPECTRUM_PROMISED_UP env vars are set,
draws dashed reference lines, reports "% below promised" in the title,
and color-codes the hour-of-day bars red/orange/green.

Outage windows (down < OUTAGE_DOWN_BELOW or ping >
OUTAGE_PING_ABOVE; defaults 25 Mbps / 250 ms) are shaded red
across the time-series panels and counted in the title.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import os
import sys
from pathlib import Path

DEFAULT_LOG_DIR = Path(os.environ.get("SPEED_LOG_DIR", Path.home() / "speed_logs"))
OUTAGE_DOWN_BELOW = float(os.environ.get("OUTAGE_DOWN_BELOW", "25"))
OUTAGE_PING_ABOVE = float(os.environ.get("OUTAGE_PING_ABOVE", "250"))


def _import_matplotlib():
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.dates as mdates
        import matplotlib.pyplot as plt
        return plt, mdates
    except ImportError:
        sys.exit(
            "plot.py: matplotlib is required.\n"
            "Install with: pip install --user matplotlib"
        )


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument(
        "--csv",
        type=Path,
        help="CSV file to plot (default: all speed-*.csv in SPEED_LOG_DIR)",
    )
    p.add_argument(
        "--output",
        "-o",
        type=Path,
        default=Path("speed-chart.png"),
        help="Output PNG path (default: speed-chart.png)",
    )
    p.add_argument(
        "--days",
        type=int,
        help="Only plot the last N days of data",
    )
    return p.parse_args()


def find_csvs(csv_arg: Path | None) -> list[Path]:
    if csv_arg:
        if not csv_arg.exists():
            sys.exit(f"plot.py: {csv_arg} not found")
        return [csv_arg]
    if not DEFAULT_LOG_DIR.exists():
        sys.exit(f"plot.py: log dir {DEFAULT_LOG_DIR} does not exist. Run speedtest.sh first.")
    paths = sorted(DEFAULT_LOG_DIR.glob("speed-*.csv"))
    if not paths:
        sys.exit(f"plot.py: no speed-*.csv files in {DEFAULT_LOG_DIR}. Run speedtest.sh first.")
    return paths


def load_rows(paths: list[Path]) -> tuple[list[dt.datetime], list[float], list[float], list[float]]:
    times, pings, downs, ups = [], [], [], []
    for path in paths:
        with path.open() as f:
            reader = csv.reader(f)
            for i, row in enumerate(reader):
                if i == 0 and row and row[0] == "Server ID":
                    continue  # header
                if len(row) < 10:
                    continue
                try:
                    ts = dt.datetime.fromisoformat(row[3].rstrip("Z"))
                    ping = float(row[5])
                    down = float(row[6]) / 1_000_000  # bits -> Mbps
                    up = float(row[7]) / 1_000_000
                except (ValueError, IndexError):
                    continue
                times.append(ts)
                pings.append(ping)
                downs.append(down)
                ups.append(up)
    paired = sorted(zip(times, pings, downs, ups))
    return [list(c) for c in zip(*paired)] if paired else ([], [], [], [])


def filter_days(times, pings, downs, ups, days: int):
    cutoff = dt.datetime.now() - dt.timedelta(days=days)
    keep = [i for i, t in enumerate(times) if t >= cutoff]
    return ([times[i] for i in keep], [pings[i] for i in keep],
            [downs[i] for i in keep], [ups[i] for i in keep])


def pct_below(values: list[float], threshold: float) -> float:
    if not values:
        return 0.0
    return 100.0 * sum(1 for v in values if v < threshold) / len(values)


def detect_outages(times, pings, downs):
    """Return list of (start_idx, end_idx) for each contiguous outage run."""
    events = []
    run_start = None
    for i, (p, d) in enumerate(zip(pings, downs)):
        bad = d < OUTAGE_DOWN_BELOW or p > OUTAGE_PING_ABOVE
        if bad and run_start is None:
            run_start = i
        elif not bad and run_start is not None:
            events.append((run_start, i - 1))
            run_start = None
    if run_start is not None:
        events.append((run_start, len(times) - 1))
    return events


def hour_means(times, downs):
    """Return [(hour, mean_down, count)] for hours 0-23 with samples."""
    by_hour = [(0.0, 0)] * 24
    for t, d in zip(times, downs):
        h = t.hour
        s, n = by_hour[h]
        by_hour[h] = (s + d, n + 1)
    return [(h, s / n if n else None, n) for h, (s, n) in enumerate(by_hour)]


def main() -> int:
    args = parse_args()
    paths = find_csvs(args.csv)
    times, pings, downs, ups = load_rows(paths)
    if not times:
        sys.exit("plot.py: no data rows found")
    if args.days:
        times, pings, downs, ups = filter_days(times, pings, downs, ups, args.days)
        if not times:
            sys.exit(f"plot.py: no data in the last {args.days} days")

    promised_down = float(os.environ.get("SPECTRUM_PROMISED_DOWN", "0")) or None
    promised_up = float(os.environ.get("SPECTRUM_PROMISED_UP", "0")) or None
    outages = detect_outages(times, pings, downs)

    plt, mdates = _import_matplotlib()
    fig = plt.figure(figsize=(12, 12), constrained_layout=True)
    gs = fig.add_gridspec(4, 1, height_ratios=[1, 1, 1, 0.8])
    ax_down = fig.add_subplot(gs[0])
    ax_up = fig.add_subplot(gs[1], sharex=ax_down)
    ax_ping = fig.add_subplot(gs[2], sharex=ax_down)
    ax_hours = fig.add_subplot(gs[3])
    fig.suptitle(_make_title(times, downs, ups, promised_down, promised_up, outages), fontsize=13)

    _plot_metric(ax_down, times, downs, "Download (Mbps)", "tab:blue", promised_down, outages)
    _plot_metric(ax_up, times, ups, "Upload (Mbps)", "tab:green", promised_up, outages)
    _plot_metric(ax_ping, times, pings, "Ping (ms)", "tab:orange", None, outages)
    _plot_hours(ax_hours, hour_means(times, downs), promised_down)

    ax_ping.xaxis.set_major_formatter(mdates.DateFormatter("%Y-%m-%d %H:%M"))
    fig.autofmt_xdate()

    fig.savefig(args.output, dpi=120)
    print(f"wrote {args.output} ({len(times)} samples, {len(outages)} outage(s))")
    return 0


def _plot_metric(ax, times, values, label, color, baseline, outages):
    ax.plot(times, values, color=color, linewidth=1.2, marker=".", markersize=3)
    ax.set_ylabel(label)
    ax.grid(True, alpha=0.3)
    if baseline is not None:
        ax.axhline(baseline, color="red", linestyle="--", linewidth=1, label=f"promised: {baseline:g}")
        ax.fill_between(times, 0, baseline, where=[v < baseline for v in values],
                        color="red", alpha=0.1, interpolate=False)
        ax.legend(loc="lower right", fontsize=9)
    # Outage shading: vertical span per event.
    for start, end in outages:
        ax.axvspan(times[start], times[end], color="red", alpha=0.18, zorder=0)


def _plot_hours(ax, hour_data, baseline):
    hours = [h for h, _, _ in hour_data]
    means = [m if m is not None else 0 for _, m, _ in hour_data]
    counts = [n for _, _, n in hour_data]
    colors = []
    for m, n in zip(means, counts):
        if n == 0:
            colors.append("#cccccc")
        elif baseline is None:
            colors.append("tab:blue")
        elif m < baseline * 0.7:
            colors.append("tab:red")
        elif m < baseline:
            colors.append("tab:orange")
        else:
            colors.append("tab:green")
    ax.bar(hours, means, color=colors, width=0.85)
    if baseline is not None:
        ax.axhline(baseline, color="red", linestyle="--", linewidth=1, label=f"promised: {baseline:g}")
        ax.legend(loc="lower right", fontsize=9)
    ax.set_xticks(range(24))
    ax.set_xticklabels([f"{h:02d}" for h in range(24)], fontsize=8)
    ax.set_xlabel("hour of day")
    ax.set_ylabel("Mean download (Mbps)")
    ax.set_title("Mean download by hour-of-day", loc="left", fontsize=11)
    ax.grid(True, alpha=0.3, axis="y")


def _make_title(times, downs, ups, promised_down, promised_up, outages) -> str:
    span = f"{times[0]:%Y-%m-%d} → {times[-1]:%Y-%m-%d}  ({len(times)} samples)"
    bits = []
    if promised_down:
        bits.append(f"{pct_below(downs, promised_down):.0f}% below promised {promised_down:g} Mbps down")
    if promised_up:
        bits.append(f"{pct_below(ups, promised_up):.0f}% below promised {promised_up:g} Mbps up")
    if outages:
        bits.append(f"{len(outages)} outage event(s)")
    if bits:
        return f"internet-speed  —  {span}\n" + "  |  ".join(bits)
    return f"internet-speed  —  {span}"


if __name__ == "__main__":
    sys.exit(main())
