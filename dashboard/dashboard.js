// internet-speed dashboard
//
// CSV loading priority:
//   1. ?csv=URL query param  → fetch that
//   2. ./speed.csv next to index.html  → fetch
//   3. ../examples/speed-sample.csv  → fetch (so GitHub Pages demo works)
//   4. Drag/drop or file picker
//
// Promised baseline:
//   - ?down=400&up=20  → URL params override
//   - Otherwise read from the input fields (persisted to localStorage)

const CSV_COLS = {
   timestamp: 3,
   ping: 5,
   download: 6,
   upload: 7,
   ip: 9,
};

const state = {
   rows: [],          // [{ts: Date, ping, down, up}, ...]
   filtered: [],
   range: "all",
   promised: { down: null, up: null },
   charts: {},
};

// Outage thresholds (same defaults as the bash script).
// Override via URL params: ?outage_down=200&outage_ping=50
const URL_PARAMS = new URLSearchParams(location.search);

// Numeric URL param with a fallback. Unlike `parseFloat(x) || fallback`
// this lets an explicit 0 through (e.g. ?outage_down=0 to disable the
// download-based outage rule).
function numParam(name, fallback) {
   const raw = URL_PARAMS.get(name);
   if (raw === null || raw.trim() === "") return fallback;
   const v = parseFloat(raw);
   return Number.isFinite(v) ? v : fallback;
}

const OUTAGE_DOWN_BELOW = numParam("outage_down", 25);
const OUTAGE_PING_ABOVE = numParam("outage_ping", 250);

// localStorage can throw (private browsing, blocked storage). Treat it as
// a best-effort convenience rather than a hard dependency.
function storageGet(key) {
   try { return localStorage.getItem(key); } catch (e) { return null; }
}
function storageSet(key, value) {
   try { localStorage.setItem(key, value); } catch (e) { /* ignore */ }
}
function storageRemove(key) {
   try { localStorage.removeItem(key); } catch (e) { /* ignore */ }
}

// Rebuilding four Chart.js instances on every keystroke in the promised
// inputs is wasteful; coalesce rapid edits into a single render.
let renderTimer = null;
function scheduleRender(delayMs = 150) {
   clearTimeout(renderTimer);
   renderTimer = setTimeout(render, delayMs);
}

// ---------- bootstrap ----------

document.addEventListener("DOMContentLoaded", async () => {
   restorePromisedInputs();
   wireConfigInputs();
   wireRangeButtons();
   wireFileDrop();

   const csvFromUrl = await tryLoadInitialCSV();
   if (!csvFromUrl) {
      showDropZone();
   }
});

async function tryLoadInitialCSV() {
   const params = new URLSearchParams(location.search);
   const urlCsv = params.get("csv");
   const candidates = [
      urlCsv,
      "./speed.csv",
      "../examples/speed-sample.csv",
   ].filter(Boolean);

   for (const url of candidates) {
      try {
         const res = await fetch(url);
         if (!res.ok) continue;
         const text = await res.text();
         const rows = parseCSV(text);
         if (rows.length) {
            state.rows = rows;
            applyRange(state.range);
            render();
            return true;
         }
      } catch (e) {
         // try next candidate
      }
   }
   return false;
}

// ---------- CSV parsing ----------

function parseCSV(text) {
   const lines = text.split(/\r?\n/).filter(l => l.length > 0);
   const out = [];
   for (let i = 0; i < lines.length; i++) {
      const cols = splitCsvLine(lines[i]);
      if (i === 0 && cols[0] === "Server ID") continue;
      if (cols.length < 10) continue;
      const ts = parseTimestamp(cols[CSV_COLS.timestamp]);
      const ping = parseFloat(cols[CSV_COLS.ping]);
      const down = parseFloat(cols[CSV_COLS.download]) / 1e6;
      const up = parseFloat(cols[CSV_COLS.upload]) / 1e6;
      if (isNaN(ts.getTime()) || isNaN(ping) || isNaN(down) || isNaN(up)) continue;
      out.push({ ts, ping, down, up });
   }
   out.sort((a, b) => a.ts - b.ts);
   return out;
}

function splitCsvLine(line) {
   // Minimal CSV splitter; handles quoted fields with commas inside.
   const cols = [];
   let cur = "";
   let inQuote = false;
   for (let i = 0; i < line.length; i++) {
      const ch = line[i];
      if (inQuote) {
         if (ch === '"' && line[i + 1] === '"') { cur += '"'; i++; }
         else if (ch === '"') inQuote = false;
         else cur += ch;
      } else {
         if (ch === ',') { cols.push(cur); cur = ""; }
         else if (ch === '"') inQuote = true;
         else cur += ch;
      }
   }
   cols.push(cur);
   return cols;
}

// speedtest-cli writes ISO 8601 UTC timestamps with a trailing "Z". Keep
// the Z (or any explicit offset) so the browser treats the value as the
// instant it is and renders it in local time. A bare date-time with no
// zone designator is parsed as *local* per ECMA-262, which used to shift
// every point, axis label and range filter by the UTC offset.
function parseTimestamp(raw) {
   const s = String(raw).trim();
   const hasZone = /(?:[Zz]|[+-]\d{2}:?\d{2})$/.test(s);
   return new Date(hasZone ? s : s + "Z");
}

// ---------- config / inputs ----------

function restorePromisedInputs() {
   const params = new URLSearchParams(location.search);
   const downInput = document.getElementById("promised-down");
   const upInput = document.getElementById("promised-up");
   const urlDown = params.get("down");
   const urlUp = params.get("up");
   const storedDown = storageGet("promised-down");
   const storedUp = storageGet("promised-up");

   downInput.value = urlDown || storedDown || "";
   upInput.value = urlUp || storedUp || "";
   state.promised.down = parseFloat(downInput.value) || null;
   state.promised.up = parseFloat(upInput.value) || null;
}

function wireConfigInputs() {
   for (const id of ["promised-down", "promised-up"]) {
      const input = document.getElementById(id);
      input.addEventListener("input", () => {
         const v = parseFloat(input.value) || null;
         const key = id === "promised-down" ? "down" : "up";
         state.promised[key] = v;
         if (v) storageSet(id, input.value);
         else storageRemove(id);
         scheduleRender();
      });
   }
}

function wireRangeButtons() {
   document.querySelectorAll(".range-buttons button").forEach(btn => {
      btn.addEventListener("click", () => {
         document.querySelectorAll(".range-buttons button").forEach(b => b.classList.remove("active"));
         btn.classList.add("active");
         state.range = btn.dataset.range;
         applyRange(state.range);
         render();
      });
   });
}

function applyRange(range) {
   if (!state.rows.length || range === "all") {
      state.filtered = state.rows;
      return;
   }
   const days = { "24h": 1, "7d": 7, "30d": 30 }[range];
   const cutoff = new Date(Date.now() - days * 24 * 60 * 60 * 1000);
   state.filtered = state.rows.filter(r => r.ts >= cutoff);
}

// ---------- file drop / picker ----------

function showDropZone() {
   document.getElementById("load-area").hidden = false;
   document.getElementById("charts").style.display = "none";
   document.getElementById("stats").style.display = "none";
}

function hideDropZone() {
   document.getElementById("load-area").hidden = true;
   document.getElementById("charts").style.display = "";
   document.getElementById("stats").style.display = "";
}

function wireFileDrop() {
   const drop = document.getElementById("drop-zone");
   const fileInput = document.getElementById("file-input");

   if (drop) {
      drop.addEventListener("dragover", (e) => { e.preventDefault(); drop.classList.add("drag-over"); });
      drop.addEventListener("dragleave", () => drop.classList.remove("drag-over"));
      drop.addEventListener("drop", (e) => {
         e.preventDefault();
         drop.classList.remove("drag-over");
         const file = e.dataTransfer.files[0];
         if (file) loadFile(file);
      });
   }

   fileInput.addEventListener("change", (e) => {
      const file = e.target.files[0];
      if (file) loadFile(file);
   });
}

function loadFile(file) {
   const reader = new FileReader();
   reader.onload = (e) => {
      const rows = parseCSV(e.target.result);
      if (!rows.length) {
         alert("No valid rows found in that CSV. Expected speedtest-cli --csv format.");
         return;
      }
      state.rows = rows;
      applyRange(state.range);
      hideDropZone();
      render();
   };
   reader.readAsText(file);
}

// ---------- stats ----------

function pctBelow(values, threshold) {
   if (!values.length || threshold == null) return null;
   const below = values.filter(v => v < threshold).length;
   return (below / values.length) * 100;
}

function mean(values) {
   if (!values.length) return 0;
   return values.reduce((s, v) => s + v, 0) / values.length;
}

function buildStats() {
   const rows = state.filtered;
   if (!rows.length) return [];

   const downs = rows.map(r => r.down);
   const ups = rows.map(r => r.up);
   const pings = rows.map(r => r.ping);
   const latest = rows[rows.length - 1];

   const cards = [
      { label: "Latest down", value: latest.down.toFixed(1), unit: "Mbps", class: classify(latest.down, state.promised.down) },
      { label: "Avg down", value: mean(downs).toFixed(1), unit: "Mbps", class: classify(mean(downs), state.promised.down) },
      { label: "Latest up", value: latest.up.toFixed(1), unit: "Mbps", class: classify(latest.up, state.promised.up) },
      { label: "Avg up", value: mean(ups).toFixed(1), unit: "Mbps", class: classify(mean(ups), state.promised.up) },
      { label: "Latest ping", value: latest.ping.toFixed(0), unit: "ms" },
      { label: "Avg ping", value: mean(pings).toFixed(0), unit: "ms" },
   ];

   if (state.promised.down != null) {
      const pct = pctBelow(downs, state.promised.down);
      cards.push({
         label: `Below promised ${state.promised.down} down`,
         value: pct.toFixed(1) + "%",
         unit: `${rows.filter(r => r.down < state.promised.down).length}/${rows.length}`,
         class: pct > 10 ? "bad" : pct > 1 ? "warn" : "good",
      });
   }
   if (state.promised.up != null) {
      const pct = pctBelow(ups, state.promised.up);
      cards.push({
         label: `Below promised ${state.promised.up} up`,
         value: pct.toFixed(1) + "%",
         unit: `${rows.filter(r => r.up < state.promised.up).length}/${rows.length}`,
         class: pct > 10 ? "bad" : pct > 1 ? "warn" : "good",
      });
   }
   return cards;
}

function classify(value, promised) {
   if (promised == null) return "";
   if (value < promised * 0.7) return "bad";
   if (value < promised) return "warn";
   return "good";
}

// Group rows into contiguous outage windows.
// Returns [{start: Date, end: Date}, ...]
function detectOutages(rows) {
   const events = [];
   let run = null;
   for (const r of rows) {
      const bad = r.down < OUTAGE_DOWN_BELOW || r.ping > OUTAGE_PING_ABOVE;
      if (bad) {
         if (!run) run = { start: r.ts, end: r.ts };
         else run.end = r.ts;
      } else if (run) {
         events.push(run);
         run = null;
      }
   }
   if (run) events.push(run);
   return events;
}

// Mean download/ping per hour-of-day (0-23).
function hourOfDayStats(rows) {
   const buckets = Array.from({ length: 24 }, () => ({ down: 0, ping: 0, n: 0 }));
   for (const r of rows) {
      const h = r.ts.getHours();
      buckets[h].down += r.down;
      buckets[h].ping += r.ping;
      buckets[h].n++;
   }
   return buckets.map(b => ({
      down: b.n ? b.down / b.n : null,
      ping: b.n ? b.ping / b.n : null,
      n: b.n,
   }));
}

// Median gap between consecutive samples in ms (30 min if it can't be told).
function sampleInterval(rows) {
   const gaps = [];
   for (let i = 1; i < rows.length; i++) {
      const g = rows[i].ts - rows[i - 1].ts;
      if (g > 0) gaps.push(g);
   }
   if (!gaps.length) return 30 * 60 * 1000;
   gaps.sort((a, b) => a - b);
   return gaps[Math.floor(gaps.length / 2)];
}

// Widen each outage window by half a sampling interval on both sides so a
// single bad sample still draws as a visible band. Without this a
// one-sample outage has start === end and renders as a zero-width line.
function padOutages(events, intervalMs) {
   const half = intervalMs / 2;
   return events.map(o => ({ start: new Date(o.start - half), end: new Date(o.end + half) }));
}

// ---------- rendering ----------

function render() {
   renderStats();
   const outages = padOutages(detectOutages(state.filtered), sampleInterval(state.filtered));
   renderChart("chart-down", "Download (Mbps)", state.filtered.map(r => ({ x: r.ts, y: r.down })), "#58a6ff", state.promised.down, outages);
   renderChart("chart-up", "Upload (Mbps)", state.filtered.map(r => ({ x: r.ts, y: r.up })), "#3fb950", state.promised.up, outages);
   renderChart("chart-ping", "Ping (ms)", state.filtered.map(r => ({ x: r.ts, y: r.ping })), "#d29922", null, outages);
   renderHourChart();
}

function renderHourChart() {
   const ctx = document.getElementById("chart-hours");
   if (state.charts["chart-hours"]) state.charts["chart-hours"].destroy();
   const stats = hourOfDayStats(state.filtered);
   const labels = stats.map((_, h) => String(h).padStart(2, "0"));
   const baseline = state.promised.down;
   const colors = stats.map(s => {
      if (s.down == null) return "#2a3441";
      if (baseline == null) return "#58a6ff";
      if (s.down < baseline * 0.7) return "#f85149";
      if (s.down < baseline) return "#d29922";
      return "#3fb950";
   });
   const datasets = [{
      label: "Mean download (Mbps) by hour-of-day",
      data: stats.map(s => s.down),
      backgroundColor: colors,
      borderWidth: 0,
   }];
   if (baseline != null) {
      datasets.push({
         type: "line",
         label: `promised: ${baseline}`,
         data: Array(24).fill(baseline),
         borderColor: "#f85149",
         borderDash: [6, 4],
         borderWidth: 1.5,
         pointRadius: 0,
         fill: false,
      });
   }
   state.charts["chart-hours"] = new Chart(ctx, {
      type: "bar",
      data: { labels, datasets },
      options: {
         responsive: true,
         maintainAspectRatio: false,
         scales: {
            x: {
               title: { display: true, text: "hour of day", color: "#8b949e" },
               grid: { display: false },
               ticks: { color: "#8b949e" },
            },
            y: {
               beginAtZero: true,
               grid: { color: "#2a3441" },
               ticks: { color: "#8b949e" },
            },
         },
         plugins: {
            legend: { display: false },
            tooltip: {
               backgroundColor: "#1f2730", borderColor: "#2a3441", borderWidth: 1,
               callbacks: {
                  label: (ctx) => {
                     const s = stats[ctx.dataIndex];
                     if (s.n === 0) return "no samples";
                     return `${s.down.toFixed(1)} Mbps  ·  ping ${s.ping.toFixed(0)} ms  ·  ${s.n} samples`;
                  },
               },
            },
            title: { display: true, text: "Mean download by hour-of-day", color: "#e6edf3", font: { size: 13, weight: "500" }, align: "start" },
         },
      },
   });
}

function renderStats() {
   const container = document.getElementById("stats");
   container.innerHTML = "";
   for (const card of buildStats()) {
      const div = document.createElement("div");
      div.className = "stat-card " + (card.class || "");
      div.innerHTML = `
         <div class="label">${escapeHtml(card.label)}</div>
         <div class="value">${escapeHtml(card.value)}<span class="unit">${escapeHtml(card.unit)}</span></div>
      `;
      container.appendChild(div);
   }
}

function renderChart(canvasId, label, data, color, baseline, outages) {
   const ctx = document.getElementById(canvasId);
   if (state.charts[canvasId]) state.charts[canvasId].destroy();

   const datasets = [{
      label: label,
      data: data,
      borderColor: color,
      backgroundColor: color + "33",
      borderWidth: 1.5,
      pointRadius: 1.5,
      pointHoverRadius: 5,
      tension: 0.15,
      fill: false,
   }];

   if (baseline != null && data.length) {
      datasets.push({
         label: `promised: ${baseline}`,
         data: [{ x: data[0].x, y: baseline }, { x: data[data.length - 1].x, y: baseline }],
         borderColor: "#f85149",
         borderDash: [6, 4],
         borderWidth: 1.5,
         pointRadius: 0,
         fill: false,
      });
   }

   // Outage shading: stepped line at a very high Y, filled to origin, only
   // present during outage windows. Renders as a translucent red vertical
   // band per event.
   if (outages && outages.length && data.length) {
      const dataMax = Math.max(...data.map(d => d.y || 0), baseline || 0) * 1.1 || 100;
      const overlay = [];
      for (const o of outages) {
         overlay.push({ x: o.start, y: null });
         overlay.push({ x: o.start, y: dataMax });
         overlay.push({ x: o.end, y: dataMax });
         overlay.push({ x: o.end, y: null });
      }
      datasets.push({
         label: "outage",
         data: overlay,
         borderColor: "transparent",
         backgroundColor: "rgba(248, 81, 73, 0.18)",
         borderWidth: 0,
         pointRadius: 0,
         fill: { target: "origin" },
         spanGaps: false,
         order: 10,
      });
   }

   state.charts[canvasId] = new Chart(ctx, {
      type: "line",
      data: { datasets },
      options: {
         responsive: true,
         maintainAspectRatio: false,
         interaction: { mode: "index", intersect: false },
         scales: {
            x: {
               type: "time",
               time: { tooltipFormat: "PPp" },
               grid: { color: "#2a3441" },
               ticks: { color: "#8b949e" },
            },
            y: {
               beginAtZero: true,
               grid: { color: "#2a3441" },
               ticks: { color: "#8b949e" },
            },
         },
         plugins: {
            legend: { display: false },
            tooltip: { backgroundColor: "#1f2730", borderColor: "#2a3441", borderWidth: 1 },
            title: { display: true, text: label, color: "#e6edf3", font: { size: 13, weight: "500" }, align: "start" },
         },
      },
   });
}

function escapeHtml(s) {
   return String(s).replace(/[&<>"']/g, c => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
   }[c]));
}
