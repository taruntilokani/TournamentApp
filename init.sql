CREATE SCHEMA IF NOT EXISTS api;

CREATE TABLE IF NOT EXISTS api.app_storage (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS api.tournaments (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  type TEXT,
  fixture_type TEXT,
  match_type TEXT,
  playoff_format TEXT,
  teams_count INTEGER NOT NULL DEFAULT 0,
  groups_count INTEGER NOT NULL DEFAULT 0,
  teams_per_group INTEGER NOT NULL DEFAULT 0,
  final_winner_team TEXT,
  final_runner_up_team TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS api.tournament_players (
  tournament_id TEXT NOT NULL REFERENCES api.tournaments(id) ON DELETE CASCADE,
  player_name TEXT NOT NULL,
  player_order INTEGER NOT NULL,
  PRIMARY KEY (tournament_id, player_name)
);

CREATE TABLE IF NOT EXISTS api.teams (
  tournament_id TEXT NOT NULL REFERENCES api.tournaments(id) ON DELETE CASCADE,
  team_name TEXT NOT NULL,
  team_order INTEGER NOT NULL,
  PRIMARY KEY (tournament_id, team_name)
);

CREATE TABLE IF NOT EXISTS api.team_players (
  tournament_id TEXT NOT NULL,
  team_name TEXT NOT NULL,
  player_name TEXT NOT NULL,
  player_order INTEGER NOT NULL,
  PRIMARY KEY (tournament_id, team_name, player_order),
  FOREIGN KEY (tournament_id, team_name)
    REFERENCES api.teams(tournament_id, team_name)
    ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS api.matches (
  tournament_id TEXT NOT NULL REFERENCES api.tournaments(id) ON DELETE CASCADE,
  match_id TEXT NOT NULL,
  stage TEXT,
  group_index INTEGER,
  team1 TEXT,
  team2 TEXT,
  score1 INTEGER,
  score2 INTEGER,
  PRIMARY KEY (tournament_id, match_id)
);

CREATE TABLE IF NOT EXISTS api.player_lists (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS api.player_list_players (
  player_list_id TEXT NOT NULL REFERENCES api.player_lists(id) ON DELETE CASCADE,
  player_name TEXT NOT NULL,
  player_order INTEGER NOT NULL,
  PRIMARY KEY (player_list_id, player_name)
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

CREATE OR REPLACE FUNCTION api.sync_app_storage_row(storage_key TEXT, storage_value TEXT)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  payload JSONB;
  v_tournament_id TEXT;
  v_player_list_id TEXT;
BEGIN
  IF storage_key LIKE 'bt_tournament_v1_%' THEN
    payload := storage_value::JSONB;
    v_tournament_id := payload->>'id';

    IF v_tournament_id IS NULL OR v_tournament_id = '' THEN
      RETURN;
    END IF;

    INSERT INTO api.tournaments (
      id,
      name,
      type,
      fixture_type,
      match_type,
      playoff_format,
      teams_count,
      groups_count,
      teams_per_group,
      final_winner_team,
      final_runner_up_team,
      updated_at
    )
    VALUES (
      v_tournament_id,
      COALESCE(payload->>'name', v_tournament_id),
      payload->>'type',
      payload->>'fixtureType',
      payload->>'matchType',
      payload->>'playoffFormat',
      COALESCE((payload->>'teamsCount')::INTEGER, 0),
      COALESCE((payload->>'groupsCount')::INTEGER, 0),
      COALESCE((payload->>'teamsPerGroup')::INTEGER, 0),
      payload->'finalResult'->>'winner',
      payload->'finalResult'->>'runnerUp',
      NOW()
    )
    ON CONFLICT (id) DO UPDATE SET
      name = EXCLUDED.name,
      type = EXCLUDED.type,
      fixture_type = EXCLUDED.fixture_type,
      match_type = EXCLUDED.match_type,
      playoff_format = EXCLUDED.playoff_format,
      teams_count = EXCLUDED.teams_count,
      groups_count = EXCLUDED.groups_count,
      teams_per_group = EXCLUDED.teams_per_group,
      final_winner_team = EXCLUDED.final_winner_team,
      final_runner_up_team = EXCLUDED.final_runner_up_team,
      updated_at = NOW();

    DELETE FROM api.matches WHERE tournament_id = v_tournament_id;
    DELETE FROM api.team_players WHERE tournament_id = v_tournament_id;
    DELETE FROM api.teams WHERE tournament_id = v_tournament_id;
    DELETE FROM api.tournament_players WHERE tournament_id = v_tournament_id;

    INSERT INTO api.tournament_players (tournament_id, player_name, player_order)
    SELECT v_tournament_id, player_name, ordinality::INTEGER
    FROM jsonb_array_elements_text(COALESCE(payload->'players', '[]'::JSONB))
      WITH ORDINALITY AS players(player_name, ordinality)
    WHERE player_name <> '';

    INSERT INTO api.teams (tournament_id, team_name, team_order)
    SELECT v_tournament_id, team_name, ordinality::INTEGER
    FROM jsonb_array_elements_text(COALESCE(payload->'teams', '[]'::JSONB))
      WITH ORDINALITY AS team_values(team_name, ordinality)
    WHERE team_name <> '';

    INSERT INTO api.team_players (tournament_id, team_name, player_name, player_order)
    SELECT v_tournament_id, team_name, player_name, player_ordinality::INTEGER
    FROM jsonb_each(COALESCE(payload->'teamPlayers', '{}'::JSONB)) AS team_map(team_name, players)
    CROSS JOIN LATERAL jsonb_array_elements_text(team_map.players)
      WITH ORDINALITY AS player_values(player_name, player_ordinality)
    WHERE team_name <> '' AND player_name <> '';

    INSERT INTO api.matches (
      tournament_id,
      match_id,
      stage,
      group_index,
      team1,
      team2,
      score1,
      score2
    )
    SELECT
      v_tournament_id,
      match_item->>'id',
      match_item->>'stage',
      CASE
        WHEN match_item ? 'groupIndex' AND match_item->>'groupIndex' <> ''
          THEN (match_item->>'groupIndex')::INTEGER
        ELSE NULL
      END,
      match_item->>'team1',
      match_item->>'team2',
      CASE
        WHEN match_item ? 'score1' AND match_item->>'score1' <> ''
          THEN (match_item->>'score1')::INTEGER
        ELSE NULL
      END,
      CASE
        WHEN match_item ? 'score2' AND match_item->>'score2' <> ''
          THEN (match_item->>'score2')::INTEGER
        ELSE NULL
      END
    FROM jsonb_array_elements(COALESCE(payload->'matches', '[]'::JSONB)) AS matches(match_item)
    WHERE match_item->>'id' IS NOT NULL;

    RETURN;
  END IF;

  IF storage_key LIKE 'bt_playerlist_v1_%' THEN
    payload := storage_value::JSONB;
    v_player_list_id := replace(storage_key, 'bt_playerlist_v1_', '');

    IF v_player_list_id IS NULL OR v_player_list_id = '' THEN
      RETURN;
    END IF;

    INSERT INTO api.player_lists (id, name, updated_at)
    VALUES (v_player_list_id, COALESCE(payload->>'name', v_player_list_id), NOW())
    ON CONFLICT (id) DO UPDATE SET
      name = EXCLUDED.name,
      updated_at = NOW();

    DELETE FROM api.player_list_players
    WHERE player_list_id = v_player_list_id;

    INSERT INTO api.player_list_players (player_list_id, player_name, player_order)
    SELECT v_player_list_id, player_name, ordinality::INTEGER
    FROM jsonb_array_elements_text(COALESCE(payload->'players', '[]'::JSONB))
      WITH ORDINALITY AS players(player_name, ordinality)
    WHERE player_name <> '';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION api.sync_app_storage_to_tables()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM api.sync_app_storage_row(NEW.key, NEW.value);
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION api.cleanup_app_storage_tables()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  storage_id TEXT;
BEGIN
  IF OLD.key LIKE 'bt_tournament_v1_%' THEN
    storage_id := OLD.value::JSONB->>'id';
    IF storage_id IS NOT NULL AND storage_id <> '' THEN
      DELETE FROM api.tournaments WHERE id = storage_id;
    END IF;
  ELSIF OLD.key LIKE 'bt_playerlist_v1_%' THEN
    storage_id := replace(OLD.key, 'bt_playerlist_v1_', '');
    DELETE FROM api.player_lists WHERE id = storage_id;
  END IF;

  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS app_storage_sync_to_tables ON api.app_storage;
CREATE TRIGGER app_storage_sync_to_tables
AFTER INSERT OR UPDATE ON api.app_storage
FOR EACH ROW
EXECUTE FUNCTION api.sync_app_storage_to_tables();

DROP TRIGGER IF EXISTS app_storage_cleanup_tables ON api.app_storage;
CREATE TRIGGER app_storage_cleanup_tables
AFTER DELETE ON api.app_storage
FOR EACH ROW
EXECUTE FUNCTION api.cleanup_app_storage_tables();

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
GRANT SELECT, INSERT, UPDATE, DELETE ON
  api.tournaments,
  api.tournament_players,
  api.teams,
  api.team_players,
  api.matches,
  api.player_lists,
  api.player_list_players
TO web_anon;
GRANT web_anon TO authenticator;

SELECT api.sync_app_storage_row(key, value)
FROM api.app_storage
WHERE key LIKE 'bt_tournament_v1_%'
   OR key LIKE 'bt_playerlist_v1_%';
