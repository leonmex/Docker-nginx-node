import { fileURLToPath } from 'node:url';
import { Redis } from 'ioredis';
import pg from 'pg';
import { config } from '@/config';

const { Pool } = pg;

export interface CheckResult {
  ok: boolean;
  detail: string;
}

export async function checkPostgres(): Promise<CheckResult> {
  const pool = new Pool({
    connectionString: config.databaseUrl,
    connectionTimeoutMillis: 5000,
  });
  try {
    const { rows } = await pool.query<{ version: string }>('SELECT version()');
    return { ok: true, detail: rows[0]?.version ?? 'connected' };
  } catch (err) {
    return { ok: false, detail: (err as Error).message };
  } finally {
    await pool.end();
  }
}

export async function checkRedis(): Promise<CheckResult> {
  const redis = new Redis(config.redisUrl, {
    lazyConnect: true,
    connectTimeout: 5000,
    maxRetriesPerRequest: 1,
  });
  try {
    await redis.connect();
    const pong = await redis.ping();
    return { ok: pong === 'PONG', detail: pong };
  } catch (err) {
    return { ok: false, detail: (err as Error).message };
  } finally {
    redis.disconnect();
  }
}

export async function checkConnections(): Promise<{ postgres: CheckResult; redis: CheckResult }> {
  const [postgres, redis] = await Promise.all([checkPostgres(), checkRedis()]);
  return { postgres, redis };
}

// Run as a script: `npm run db:check`.
const isMain = process.argv[1] === fileURLToPath(import.meta.url);
if (isMain) {
  const { postgres, redis } = await checkConnections();
  console.log(`PostgreSQL: ${postgres.ok ? 'OK' : 'FAIL'} — ${postgres.detail}`);
  console.log(`Redis:      ${redis.ok ? 'OK' : 'FAIL'} — ${redis.detail}`);
  process.exit(postgres.ok && redis.ok ? 0 : 1);
}
