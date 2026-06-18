/**
 * Database access abstractions (Section 3B — connection & read/write splitting).
 *
 * Business code depends on these interfaces, never on `pg` directly, so the
 * physical topology (single node vs. master + read-replicas) can change without
 * touching queries.
 */

export type QueryParams = readonly unknown[];

export interface QueryResult<R> {
  rows: R[];
  rowCount: number;
}

export type DbRole = 'master' | 'replica';

export interface IDatabaseClient {
  /** Logical role of this client — 'master' for writes, 'replica' for reads. */
  readonly role: DbRole;
  query<R = Record<string, unknown>>(text: string, params?: QueryParams): Promise<QueryResult<R>>;
}

export interface IDatabaseConnectionManager {
  /** Master pool — INSERT / UPDATE / DELETE / DDL. */
  readonly write: IDatabaseClient;
  /** Replica pool — SELECT. Falls back to the master when no replica is configured. */
  readonly read: IDatabaseClient;
  /** Runs `fn` inside a single transaction on the master (BEGIN / COMMIT / ROLLBACK). */
  withTransaction<T>(fn: (tx: IDatabaseClient) => Promise<T>): Promise<T>;
  /**
   * Runs `fn` on a dedicated master connection WITHOUT a transaction
   * (autocommit per statement) — e.g. DDL or fire-and-forget statements that
   * must not run inside a transaction block.
   */
  withoutTransaction<T>(fn: (client: IDatabaseClient) => Promise<T>): Promise<T>;
  end(): Promise<void>;
}
