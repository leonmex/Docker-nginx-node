// Tiny, dependency-free Prometheus exporter for the webapp dev container's
// existing Turbopack build-cache JSON endpoint (dashboard/plugins/
// cacheMonitorPlugin.ts, TURBOPACK_CACHE_ROUTE, default
// /dev/turbopack-cache-size). That endpoint already exists and is real —
// this exporter's only job is republishing it as Prometheus metrics so
// Grafana/alerting can use it like every other data source in this stack,
// since Prometheus can't scrape arbitrary JSON directly.
//
// Dev-only by design, same as the route it polls: this data only exists
// while `webapp`'s `npm run dev` is running (no such route in a production
// build) — turbopack_cache_scrape_success reports 0 rather than crashing
// when the target is unreachable, so this stays a normal Prometheus target
// with a visible-but-not-alarming "down" state outside of dev, not a
// crash-looping container.
import { createServer } from 'node:http';

const TARGET_URL = process.env.TURBOPACK_CACHE_URL ?? 'http://webapp:3000/dev/turbopack-cache-size';
const PORT = Number(process.env.PORT ?? 9300);

function metric(name, help, type, value) {
  return `# HELP ${name} ${help}\n# TYPE ${name} ${type}\n${name} ${value}\n`;
}

async function buildMetrics() {
  try {
    const res = await fetch(TARGET_URL, { signal: AbortSignal.timeout(5000) });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const body = await res.json();
    const d = body.data;
    return [
      metric(
        'turbopack_cache_scrape_success',
        'Whether the last scrape of the webapp turbopack-cache-size endpoint succeeded',
        'gauge',
        1,
      ),
      metric('turbopack_cache_size_bytes', 'Current Turbopack build cache size on disk', 'gauge', d.sizeBytes),
      metric(
        'turbopack_cache_ceiling_bytes',
        'Configured size ceiling (TURBOPACK_CACHE_CEILING_MB env var)',
        'gauge',
        d.ceilingBytes,
      ),
      metric(
        'turbopack_cache_stale_days',
        'Days the cache is behind the newest src/config source edit',
        'gauge',
        d.staleDays,
      ),
      metric(
        'turbopack_cache_stale_ceiling_days',
        'Configured staleness ceiling (TURBOPACK_CACHE_STALE_CEILING_DAYS env var)',
        'gauge',
        d.staleCeilingDays,
      ),
      metric(
        'turbopack_cache_percent_used',
        'max(size-vs-ceiling %, staleness-vs-ceiling %) - see dashboard/plugins/cacheMonitorPlugin.ts',
        'gauge',
        d.percentUsed,
      ),
    ].join('');
  } catch {
    // Target unreachable (webapp not running `npm run dev`, or mid-restart)
    // — report failure as a metric rather than crashing this exporter.
    return metric(
      'turbopack_cache_scrape_success',
      'Whether the last scrape of the webapp turbopack-cache-size endpoint succeeded',
      'gauge',
      0,
    );
  }
}

createServer(async (req, res) => {
  if (req.url !== '/metrics') {
    res.writeHead(404);
    res.end();
    return;
  }
  const body = await buildMetrics();
  res.writeHead(200, { 'Content-Type': 'text/plain; version=0.0.4' });
  res.end(body);
}).listen(PORT, () => {
  console.log(`turbopack-cache-exporter listening on :${PORT}, polling ${TARGET_URL}`);
});
