import bcrypt from 'bcryptjs';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { IDatabaseConnectionManager } from '@/core/IDatabase';
import { createConnectionManager } from '@/core/PgConnectionManager';
import { checkConnections } from '@db/connection';
import { seed } from '@db/seed';

// Integration tests need live Postgres + Redis (docker compose up dbPostgres redis).
// When unreachable each test runtime-skips so `npm test` still passes without Docker.
let postgresUp = false;
let redisUp = false;
let db: IDatabaseConnectionManager;

beforeAll(async () => {
  const status = await checkConnections();
  postgresUp = status.postgres.ok;
  redisUp = status.redis.ok;
  if (!postgresUp) console.warn(`Postgres unreachable — ${status.postgres.detail}`);
  if (!redisUp) console.warn(`Redis unreachable — ${status.redis.detail}`);
  if (postgresUp) {
    db = createConnectionManager();
  }
});

afterAll(async () => {
  await db?.end();
});

describe('infrastructure connectivity', () => {
  it('connects to PostgreSQL', (ctx) => {
    if (!postgresUp) return ctx.skip();
    expect(postgresUp).toBe(true);
  });

  it('connects to Redis', (ctx) => {
    if (!redisUp) return ctx.skip();
    expect(redisUp).toBe(true);
  });
});

describe('schema + seeding', () => {
  it('seeds all tables with the expected row counts (read via replica)', async (ctx) => {
    if (!postgresUp) return ctx.skip();
    const counts = await seed(db);
    expect(counts).toEqual({ users: 2, userTags: 12, notices: 12, fakeList: 3 });

    const tables = ['users', 'user_tags', 'dashboard_notices', 'fake_list'] as const;
    const expected = [2, 12, 12, 3];
    for (let i = 0; i < tables.length; i += 1) {
      const { rows } = await db.read.query<{ count: number }>(
        `SELECT count(*)::int AS count FROM ${tables[i]}`,
      );
      expect(rows[0]?.count).toBe(expected[i]);
    }
  });

  it('is idempotent (re-seeding keeps counts stable)', async (ctx) => {
    if (!postgresUp) return ctx.skip();
    await seed(db);
    const second = await seed(db);
    expect(second).toEqual({ users: 2, userTags: 12, notices: 12, fakeList: 3 });
  });

  it('stores a bcrypt hash that verifies the admin password', async (ctx) => {
    if (!postgresUp) return ctx.skip();
    await seed(db);
    const { rows } = await db.read.query<{ password_hash: string; access: string }>(
      'SELECT password_hash, access FROM users WHERE username = $1',
      ['admin'],
    );
    const row = rows[0];
    expect(row?.access).toBe('admin');
    expect(row?.password_hash).not.toBe('ant.design');
    expect(await bcrypt.compare('ant.design', row?.password_hash ?? '')).toBe(true);
  });

  it('links tags to users via the foreign key', async (ctx) => {
    if (!postgresUp) return ctx.skip();
    await seed(db);
    const { rows } = await db.read.query(
      `SELECT t.label FROM user_tags t
         JOIN users u ON u.id = t.user_id
        WHERE u.username = $1
        ORDER BY t.tag_key`,
      ['admin'],
    );
    expect(rows.length).toBe(6);
  });
});

describe('read/write splitting (master vs. replica)', () => {
  it('exposes master for writes and replica for reads', (ctx) => {
    if (!postgresUp) return ctx.skip();
    expect(db.write.role).toBe('master');
    expect(db.read.role).toBe('replica');
  });

  it('INSERT on master is visible on a replica read', async (ctx) => {
    if (!postgresUp) return ctx.skip();
    await seed(db);
    await db.write.query(
      'INSERT INTO fake_list (item_key, name, age, address) VALUES ($1, $2, $3, $4)',
      ['rw-insert', 'RW Insert', 50, 'Master Park'],
    );
    const { rows } = await db.read.query<{ name: string }>(
      'SELECT name FROM fake_list WHERE item_key = $1',
      ['rw-insert'],
    );
    expect(rows[0]?.name).toBe('RW Insert');
  });

  it('UPDATE on master is reflected on a replica read', async (ctx) => {
    if (!postgresUp) return ctx.skip();
    await seed(db);
    const before = await db.read.query<{ read: boolean }>(
      'SELECT read FROM dashboard_notices WHERE id = $1',
      ['000000001'],
    );
    expect(before.rows[0]?.read).toBe(false);

    await db.write.query('UPDATE dashboard_notices SET read = true WHERE id = $1', ['000000001']);

    const after = await db.read.query<{ read: boolean }>(
      'SELECT read FROM dashboard_notices WHERE id = $1',
      ['000000001'],
    );
    expect(after.rows[0]?.read).toBe(true);
  });

  it('DELETE on master removes the row for replica reads', async (ctx) => {
    if (!postgresUp) return ctx.skip();
    await seed(db);
    await db.write.query('DELETE FROM fake_list WHERE item_key = $1', ['1']);
    const { rows } = await db.read.query('SELECT 1 FROM fake_list WHERE item_key = $1', ['1']);
    expect(rows.length).toBe(0);
  });
});
