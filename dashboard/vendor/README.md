# Vendored libraries

These files are checked in so the dashboard works offline and doesn't depend
on a CDN being reachable.

| File | Version | Source | License |
| ---- | ------- | ------ | ------- |
| `chart.umd.min.js` | Chart.js v4.4.1 | <https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js> | MIT |
| `chartjs-adapter-date-fns.bundle.min.js` | chartjs-adapter-date-fns v3.0.0 | <https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns@3.0.0/dist/chartjs-adapter-date-fns.bundle.min.js> | MIT |

To update, re-fetch from the URLs above and replace the files. No build step.
