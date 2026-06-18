import pg from 'pg';
import { config } from '@/config';
import type {
  DbRole,
  IDatabaseClient,
  IDatabaseConnectionManager,
  QueryParams,
  QueryResult,
} from '@/core/IDatabase';

const { Pool } = pg;

/** Wraps a pg Pool (or pooled connection) behind the IDatabaseClient interface. */
class PgClient implements IDatabaseClient {
  readonly role: DbRole;
  private readonly executor: Pick<pg.Pool, 'query'> | Pick<pg.PoolClient, 'query'>;

  constructor(executor: Pick<pg.Pool, 'query'> | Pick<pg.PoolClient, 'query'>, role: DbRole) {
    this.executor = executor;
    this.role = role;
  }

  async query<R = Record<string, unknown>>(
    text: string,
    params?: QueryParams,
  ): Promise<QueryResult<R>> {
    const result = await this.executor.query(text, params ? [...params] : undefined);
    return { rows: result.rows as R[], rowCount: result.rowCount ?? 0 };
  }
}

export interface PgConnectionOptions {
  writeUrl: string;
  /** Replica URL. When omitted or equal to writeUrl, reads share the master pool. */
  readUrl?: string;
}

export class PgConnectionManager implements IDatabaseConnectionManager {
  private readonly writePool: pg.Pool;
  private readonly readPool: pg.Pool;
  readonly write: IDatabaseClient;
  readonly read: IDatabaseClient;

  constructor(options: PgConnectionOptions) {
    this.writePool = new Pool({ connectionString: options.writeUrl });
    const singleNode = !options.readUrl || options.readUrl === options.writeUrl;
    this.readPool = singleNode ? this.writePool : new Pool({ connectionString: options.readUrl });
    this.write = new PgClient(this.writePool, 'master');
    // Logical replica: routes reads through a separate pool when configured,
    // otherwise reuses the master pool (single-node fallback).
    this.read = new PgClient(this.readPool, 'replica');
  }

  async withTransaction<T>(fn: (tx: IDatabaseClient) => Promise<T>): Promise<T> {
    const client = await this.writePool.connect();
    const tx = new PgClient(client, 'master');
    try {
      await client.query('BEGIN');
      const result = await fn(tx);
      await client.query('COMMIT');
      return result;
    } catch (err) {
      await client.query('ROLLBACK');
      throw err;
    } finally {
      client.release();
    }
  }

  async withoutTransaction<T>(fn: (client: IDatabaseClient) => Promise<T>): Promise<T> {
    // Dedicated master connection, autocommit per statement — no BEGIN/COMMIT.
    const client = await this.writePool.connect();
    const handle = new PgClient(client, 'master');
    try {
      return await fn(handle);
    } finally {
      client.release();
    }
  }

  async end(): Promise<void> {
    await this.writePool.end();
    if (this.readPool !== this.writePool) {
      await this.readPool.end();
    }
  }
}

/** Builds a connection manager from environment configuration. */
export function createConnectionManager(): PgConnectionManager {
  return new PgConnectionManager({
    writeUrl: config.databaseUrl,
    readUrl: config.databaseReplicaUrl,
  });
}
