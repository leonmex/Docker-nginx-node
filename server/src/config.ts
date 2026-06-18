/**
 * Centralised, environment-driven configuration.
 *
 * This module reads ONLY from `process.env` — it never resolves a `.env` file by
 * path, so it behaves identically whether the variables are injected by
 * docker-compose (container) or by Node's `--env-file` flag (host tooling).
 *
 * Connection URLs are assembled from individual parts so the only difference
 * between host and container is the host name: docker-compose sets
 * `DB_HOST=dbPostgres` / `REDIS_HOST=redis`, while host runs default to
 * `localhost` (the containers are bound to 127.0.0.1).
 */

function required(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

const DB_HOST = process.env.DB_HOST ?? 'localhost';
const DB_PORT = process.env.DB_PORT ?? '5432';
// Read replica (slave). Defaults to the master host/port — i.e. single-node
// deployments transparently fall back to the master for reads.
const DB_REPLICA_HOST = process.env.DB_REPLICA_HOST ?? DB_HOST;
const DB_REPLICA_PORT = process.env.DB_REPLICA_PORT ?? DB_PORT;
const REDIS_HOST = process.env.REDIS_HOST ?? 'localhost';
const REDIS_PORT = process.env.REDIS_PORT ?? '6379';

const POSTGRES_USER = required('POSTGRES_USER');
const POSTGRES_PASSWORD = required('POSTGRES_PASSWORD');
const POSTGRES_DB = required('POSTGRES_DB');

const credentials = `${POSTGRES_USER}:${POSTGRES_PASSWORD}`;

export const config = {
  /** Master — all writes (INSERT/UPDATE/DELETE) and DDL. */
  databaseUrl: `postgresql://${credentials}@${DB_HOST}:${DB_PORT}/${POSTGRES_DB}`,
  /** Replica — reads (SELECT). Equals the master URL when no replica is set. */
  databaseReplicaUrl: `postgresql://${credentials}@${DB_REPLICA_HOST}:${DB_REPLICA_PORT}/${POSTGRES_DB}`,
  redisUrl: `redis://${REDIS_HOST}:${REDIS_PORT}`,
  useCache: (process.env.USE_CACHE ?? 'true') === 'true',
  cacheProvider: process.env.CACHE_PROVIDER ?? 'redis',
} as const;

export type AppConfig = typeof config;
