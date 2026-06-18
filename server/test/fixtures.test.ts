import { describe, expect, it } from 'vitest';
import { fakeListSeeds, noticeSeeds, userSeeds } from '@db/fixtures';

describe('seed fixtures', () => {
  it('provides admin and user logins with plaintext dev passwords', () => {
    const usernames = userSeeds.map((u) => u.username).sort();
    expect(usernames).toEqual(['admin', 'user']);
    const admin = userSeeds.find((u) => u.username === 'admin');
    expect(admin?.access).toBe('admin');
    expect(admin?.password).toBe('ant.design');
  });

  it('has unique userids and tags for every user', () => {
    const userids = new Set(userSeeds.map((u) => u.userid));
    expect(userids.size).toBe(userSeeds.length);
    for (const u of userSeeds) {
      expect(u.tags.length).toBeGreaterThan(0);
    }
  });

  it('mirrors the 12 mock notices with unique ids and known types', () => {
    expect(noticeSeeds).toHaveLength(12);
    const ids = new Set(noticeSeeds.map((n) => n.id));
    expect(ids.size).toBe(12);
    for (const n of noticeSeeds) {
      expect(['notification', 'message', 'event']).toContain(n.type);
    }
  });

  it('mirrors the 3 GET /api/users rows with unique keys', () => {
    expect(fakeListSeeds).toHaveLength(3);
    const keys = new Set(fakeListSeeds.map((f) => f.key));
    expect(keys.size).toBe(3);
  });
});
