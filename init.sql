CREATE SCHEMA IF NOT EXISTS api;

CREATE TABLE IF NOT EXISTS api.app_storage (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION api.touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS app_storage_touch_updated_at ON api.app_storage;
CREATE TRIGGER app_storage_touch_updated_at
BEFORE UPDATE ON api.app_storage
FOR EACH ROW
EXECUTE FUNCTION api.touch_updated_at();

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'web_anon') THEN
    CREATE ROLE web_anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticator') THEN
    CREATE ROLE authenticator LOGIN PASSWORD 'authenticator_password';
  END IF;
END
$$;

GRANT USAGE ON SCHEMA api TO web_anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.app_storage TO web_anon;
GRANT web_anon TO authenticator;
