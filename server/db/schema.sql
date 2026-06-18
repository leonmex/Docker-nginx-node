-- ---------------------------------------------------------------------------
-- Phase 1 schema — maps the legacy dashboard mock data into relational tables.
-- Idempotent: safe to run repeatedly (CREATE TABLE IF NOT EXISTS).
-- Source mocks: dashboard/mock/{utils.ts,user.ts,notices.ts}
-- ---------------------------------------------------------------------------

-- users: authentication + profile.
-- Backs POST /api/login/account and GET /api/currentUser.
-- Profile columns come from `defaultUser` (dashboard/mock/utils.ts).
CREATE TABLE IF NOT EXISTS users (
  id            SERIAL PRIMARY KEY,
  userid        VARCHAR(64)  NOT NULL UNIQUE,            -- mock `userid`
  username      VARCHAR(64)  NOT NULL UNIQUE,            -- login name (admin/user)
  password_hash TEXT         NOT NULL,
  access        VARCHAR(32)  NOT NULL DEFAULT 'user',    -- admin | user
  name          VARCHAR(128) NOT NULL,
  avatar        TEXT,
  email         VARCHAR(255),
  signature     TEXT,
  title         VARCHAR(128),
  group_name    VARCHAR(255),                            -- mock `group`
  notify_count  INTEGER      NOT NULL DEFAULT 0,
  unread_count  INTEGER      NOT NULL DEFAULT 0,
  country       VARCHAR(64),
  geographic    JSONB,                                   -- { province, city }
  address       TEXT,
  phone         VARCHAR(64),
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- user_tags: tags belonging to a user (defaultUser.tags).
CREATE TABLE IF NOT EXISTS user_tags (
  id      SERIAL PRIMARY KEY,
  user_id INTEGER     NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  tag_key VARCHAR(32) NOT NULL,                          -- mock tag `key`
  label   VARCHAR(128) NOT NULL,
  UNIQUE (user_id, tag_key)
);

-- dashboard_notices: notifications / messages / events (notices.ts).
-- Backs GET /api/notices.
CREATE TABLE IF NOT EXISTS dashboard_notices (
  id          VARCHAR(32) PRIMARY KEY,                   -- mock `id` (e.g. 000000001)
  type        VARCHAR(32) NOT NULL,                      -- notification | message | event
  title       TEXT        NOT NULL,
  description TEXT,
  avatar      TEXT,
  datetime    VARCHAR(32),
  status      VARCHAR(32),                               -- todo | urgent | doing | processing
  extra       VARCHAR(64),
  read        BOOLEAN     NOT NULL DEFAULT false,
  click_close BOOLEAN     NOT NULL DEFAULT false,
  position    INTEGER     NOT NULL DEFAULT 0,            -- preserve mock ordering
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- fake_list: the simple dashboard table list returned by GET /api/users
-- (raw array in dashboard/mock/user.ts).
CREATE TABLE IF NOT EXISTS fake_list (
  id      SERIAL PRIMARY KEY,
  item_key VARCHAR(32) NOT NULL UNIQUE,                  -- mock `key`
  name    VARCHAR(128) NOT NULL,
  age     INTEGER,
  address TEXT
);

CREATE INDEX IF NOT EXISTS idx_users_username ON users (username);
CREATE INDEX IF NOT EXISTS idx_user_tags_user_id ON user_tags (user_id);
CREATE INDEX IF NOT EXISTS idx_dashboard_notices_type ON dashboard_notices (type);
