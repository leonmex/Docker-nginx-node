import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import bcrypt from 'bcryptjs';
import type { IDatabaseConnectionManager } from '@/core/IDatabase';
import { createConnectionManager } from '@/core/PgConnectionManager';
import { fakeListSeeds, noticeSeeds, userSeeds } from '@db/fixtures';

const SALT_ROUNDS = 10;

// schema.sql is shipped alongside this module; resolve it relative to the file
// so the seed works regardless of the process working directory.
const schemaPath = fileURLToPath(new URL('./schema.sql', import.meta.url));

export interface SeedCounts {
  users: number;
  userTags: number;
  notices: number;
  fakeList: number;
}

/** Applies the schema (DDL, no transaction) then replaces all seed data atomically. */
export async function seed(db: IDatabaseConnectionManager): Promise<SeedCounts> {
  const schema = await readFile(schemaPath, 'utf8');

  // DDL on the master, outside any transaction.
  await db.withoutTransaction((client) => client.query(schema));

  // Data load in a single transaction on the master.
  return db.withTransaction(async (tx) => {
    await tx.query('TRUNCATE users, user_tags, dashboard_notices, fake_list RESTART IDENTITY CASCADE');

    let userTagCount = 0;
    for (const u of userSeeds) {
      const passwordHash = await bcrypt.hash(u.password, SALT_ROUNDS);
      const { rows } = await tx.query<{ id: number }>(
        `INSERT INTO users
           (userid, username, password_hash, access, name, avatar, email, signature,
            title, group_name, notify_count, unread_count, country, geographic, address, phone)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)
         RETURNING id`,
        [
          u.userid,
          u.username,
          passwordHash,
          u.access,
          u.name,
          u.avatar,
          u.email,
          u.signature,
          u.title,
          u.group,
          u.notifyCount,
          u.unreadCount,
          u.country,
          JSON.stringify(u.geographic),
          u.address,
          u.phone,
        ],
      );
      const userId = rows[0]?.id;
      if (userId === undefined) {
        throw new Error(`Failed to insert user ${u.username}`);
      }
      for (const tag of u.tags) {
        await tx.query('INSERT INTO user_tags (user_id, tag_key, label) VALUES ($1, $2, $3)', [
          userId,
          tag.key,
          tag.label,
        ]);
        userTagCount += 1;
      }
    }

    let position = 0;
    for (const n of noticeSeeds) {
      await tx.query(
        `INSERT INTO dashboard_notices
           (id, type, title, description, avatar, datetime, status, extra, read, click_close, position)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,
        [
          n.id,
          n.type,
          n.title,
          n.description ?? null,
          n.avatar ?? null,
          n.datetime ?? null,
          n.status ?? null,
          n.extra ?? null,
          n.read ?? false,
          n.clickClose ?? false,
          position,
        ],
      );
      position += 1;
    }

    for (const f of fakeListSeeds) {
      await tx.query('INSERT INTO fake_list (item_key, name, age, address) VALUES ($1, $2, $3, $4)', [
        f.key,
        f.name,
        f.age,
        f.address,
      ]);
    }

    return {
      users: userSeeds.length,
      userTags: userTagCount,
      notices: noticeSeeds.length,
      fakeList: fakeListSeeds.length,
    };
  });
}

// Run as a script: `npm run db:seed`.
const isMain = process.argv[1] === fileURLToPath(import.meta.url);
if (isMain) {
  const db = createConnectionManager();
  try {
    const counts = await seed(db);
    console.log('Seed complete:', counts);
  } catch (err) {
    console.error('Seed failed:', (err as Error).message);
    process.exitCode = 1;
  } finally {
    await db.end();
  }
}
