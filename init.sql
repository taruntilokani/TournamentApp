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

CREATE TABLE IF NOT EXISTS api.knockout_matches (
  tournament_id TEXT NOT NULL REFERENCES api.tournaments(id) ON DELETE CASCADE,
  match_id TEXT NOT NULL,
  stage TEXT,
  team1 TEXT,
  team2 TEXT,
  score1 INTEGER,
  score2 INTEGER,
  PRIMARY KEY (tournament_id, match_id)
);

ALTER TABLE api.tournaments
  ADD COLUMN IF NOT EXISTS final_team1 TEXT,
  ADD COLUMN IF NOT EXISTS final_team2 TEXT,
  ADD COLUMN IF NOT EXISTS final_score1 INTEGER,
  ADD COLUMN IF NOT EXISTS final_score2 INTEGER,
  ADD COLUMN IF NOT EXISTS group_assignments JSONB NOT NULL DEFAULT '[]'::JSONB;

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
      final_team1,
      final_team2,
      final_score1,
      final_score2,
      group_assignments,
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
      payload->'finalMatch'->>'team1',
      payload->'finalMatch'->>'team2',
      CASE WHEN payload->'finalMatch' ? 'score1' AND payload->'finalMatch'->>'score1' <> '' THEN (payload->'finalMatch'->>'score1')::INTEGER ELSE NULL END,
      CASE WHEN payload->'finalMatch' ? 'score2' AND payload->'finalMatch'->>'score2' <> '' THEN (payload->'finalMatch'->>'score2')::INTEGER ELSE NULL END,
      COALESCE(payload->'groupAssignments', '[]'::JSONB),
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
      final_team1 = EXCLUDED.final_team1,
      final_team2 = EXCLUDED.final_team2,
      final_score1 = EXCLUDED.final_score1,
      final_score2 = EXCLUDED.final_score2,
      group_assignments = EXCLUDED.group_assignments,
      updated_at = NOW();

    DELETE FROM api.knockout_matches WHERE tournament_id = v_tournament_id;
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

    INSERT INTO api.matches (tournament_id, match_id, stage, group_index, team1, team2, score1, score2)
    SELECT
      v_tournament_id,
      match_item->>'id',
      match_item->>'stage',
      CASE WHEN match_item ? 'groupIndex' AND match_item->>'groupIndex' <> '' THEN (match_item->>'groupIndex')::INTEGER ELSE NULL END,
      match_item->>'team1',
      match_item->>'team2',
      CASE WHEN match_item ? 'score1' AND match_item->>'score1' <> '' THEN (match_item->>'score1')::INTEGER ELSE NULL END,
      CASE WHEN match_item ? 'score2' AND match_item->>'score2' <> '' THEN (match_item->>'score2')::INTEGER ELSE NULL END
    FROM jsonb_array_elements(COALESCE(payload->'matches', '[]'::JSONB)) AS matches(match_item)
    WHERE match_item->>'id' IS NOT NULL;

    INSERT INTO api.knockout_matches (tournament_id, match_id, stage, team1, team2, score1, score2)
    SELECT
      v_tournament_id,
      knockout_item->>'id',
      knockout_item->>'stage',
      knockout_item->>'team1',
      knockout_item->>'team2',
      CASE WHEN knockout_item ? 'score1' AND knockout_item->>'score1' <> '' THEN (knockout_item->>'score1')::INTEGER ELSE NULL END,
      CASE WHEN knockout_item ? 'score2' AND knockout_item->>'score2' <> '' THEN (knockout_item->>'score2')::INTEGER ELSE NULL END
    FROM jsonb_each(COALESCE(payload->'knockout', '{}'::JSONB)) AS knockout_map(knockout_key, knockout_item)
    WHERE knockout_item->>'id' IS NOT NULL;

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

    DELETE FROM api.player_list_players WHERE player_list_id = v_player_list_id;

    INSERT INTO api.player_list_players (player_list_id, player_name, player_order)
    SELECT v_player_list_id, player_name, ordinality::INTEGER
    FROM jsonb_array_elements_text(COALESCE(payload->'players', '[]'::JSONB))
      WITH ORDINALITY AS players(player_name, ordinality)
    WHERE player_name <> '';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION api.save_tournament(payload JSONB)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM api.sync_app_storage_row('bt_tournament_v1_' || (payload->>'id'), payload::TEXT);
END;
$$;

CREATE OR REPLACE FUNCTION api.delete_tournament(tournament_id TEXT)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  DELETE FROM api.tournaments WHERE id = tournament_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.save_player_list(storage_key TEXT, payload JSONB)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM api.sync_app_storage_row(storage_key, payload::TEXT);
END;
$$;

CREATE OR REPLACE FUNCTION api.delete_player_list(player_list_id TEXT)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  DELETE FROM api.player_lists WHERE id = player_list_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.export_app_state()
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
WITH tournament_payloads AS (
  SELECT
    'bt_tournament_v1_' || t.id AS key,
    jsonb_build_object(
      'id', t.id,
      'name', t.name,
      'type', COALESCE(t.type, ''),
      'fixtureType', COALESCE(t.fixture_type, ''),
      'matchType', COALESCE(t.match_type, ''),
      'playoffFormat', COALESCE(t.playoff_format, 'Semifinals'),
      'teamsCount', t.teams_count,
      'groupsCount', t.groups_count,
      'teamsPerGroup', t.teams_per_group,
      'players', COALESCE((SELECT jsonb_agg(tp.player_name ORDER BY tp.player_order) FROM api.tournament_players tp WHERE tp.tournament_id = t.id), '[]'::JSONB),
      'teams', COALESCE((SELECT jsonb_agg(tm.team_name ORDER BY tm.team_order) FROM api.teams tm WHERE tm.tournament_id = t.id), '[]'::JSONB),
      'teamPlayers', COALESCE((
        SELECT jsonb_object_agg(team_name, players ORDER BY team_order)
        FROM (
          SELECT tm.team_name, tm.team_order, COALESCE(jsonb_agg(tp.player_name ORDER BY tp.player_order) FILTER (WHERE tp.player_name IS NOT NULL), '[]'::JSONB) AS players
          FROM api.teams tm
          LEFT JOIN api.team_players tp ON tp.tournament_id = tm.tournament_id AND tp.team_name = tm.team_name
          WHERE tm.tournament_id = t.id
          GROUP BY tm.team_name, tm.team_order
        ) team_payload
      ), '{}'::JSONB),
      'groupAssignments', COALESCE(t.group_assignments, '[]'::JSONB),
      'matches', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', CASE WHEN m.match_id ~ '^\d+$' THEN to_jsonb(m.match_id::INTEGER) ELSE to_jsonb(m.match_id) END,
          'team1', m.team1,
          'team2', m.team2,
          'score1', m.score1,
          'score2', m.score2,
          'stage', m.stage,
          'groupIndex', m.group_index
        ) ORDER BY CASE WHEN m.match_id ~ '^\d+$' THEN m.match_id::INTEGER ELSE 2147483647 END, m.match_id)
        FROM api.matches m
        WHERE m.tournament_id = t.id
      ), '[]'::JSONB),
      'knockout', jsonb_build_object(
        'semifinal1', COALESCE((SELECT jsonb_build_object('id', km.match_id, 'stage', km.stage, 'team1', km.team1, 'team2', km.team2, 'score1', km.score1, 'score2', km.score2) FROM api.knockout_matches km WHERE km.tournament_id = t.id AND km.match_id = 'SEMIFINAL-1'), jsonb_build_object('id', 'SEMIFINAL-1', 'stage', 'Semifinal 1', 'team1', '', 'team2', '', 'score1', NULL, 'score2', NULL)),
        'semifinal2', COALESCE((SELECT jsonb_build_object('id', km.match_id, 'stage', km.stage, 'team1', km.team1, 'team2', km.team2, 'score1', km.score1, 'score2', km.score2) FROM api.knockout_matches km WHERE km.tournament_id = t.id AND km.match_id = 'SEMIFINAL-2'), jsonb_build_object('id', 'SEMIFINAL-2', 'stage', 'Semifinal 2', 'team1', '', 'team2', '', 'score1', NULL, 'score2', NULL)),
        'qualifier1', COALESCE((SELECT jsonb_build_object('id', km.match_id, 'stage', km.stage, 'team1', km.team1, 'team2', km.team2, 'score1', km.score1, 'score2', km.score2) FROM api.knockout_matches km WHERE km.tournament_id = t.id AND km.match_id = 'QUALIFIER-1'), jsonb_build_object('id', 'QUALIFIER-1', 'stage', 'Qualifier 1', 'team1', '', 'team2', '', 'score1', NULL, 'score2', NULL)),
        'eliminator', COALESCE((SELECT jsonb_build_object('id', km.match_id, 'stage', km.stage, 'team1', km.team1, 'team2', km.team2, 'score1', km.score1, 'score2', km.score2) FROM api.knockout_matches km WHERE km.tournament_id = t.id AND km.match_id = 'ELIMINATOR'), jsonb_build_object('id', 'ELIMINATOR', 'stage', 'Eliminator', 'team1', '', 'team2', '', 'score1', NULL, 'score2', NULL)),
        'qualifier2', COALESCE((SELECT jsonb_build_object('id', km.match_id, 'stage', km.stage, 'team1', km.team1, 'team2', km.team2, 'score1', km.score1, 'score2', km.score2) FROM api.knockout_matches km WHERE km.tournament_id = t.id AND km.match_id = 'QUALIFIER-2'), jsonb_build_object('id', 'QUALIFIER-2', 'stage', 'Qualifier 2', 'team1', '', 'team2', '', 'score1', NULL, 'score2', NULL)),
        'final', COALESCE((SELECT jsonb_build_object('id', km.match_id, 'stage', km.stage, 'team1', km.team1, 'team2', km.team2, 'score1', km.score1, 'score2', km.score2) FROM api.knockout_matches km WHERE km.tournament_id = t.id AND km.match_id = 'FINAL'), jsonb_build_object('id', 'FINAL', 'stage', 'Final', 'team1', COALESCE(t.final_team1, ''), 'team2', COALESCE(t.final_team2, ''), 'score1', t.final_score1, 'score2', t.final_score2))
      ),
      'finalMatch', CASE WHEN t.final_team1 IS NULL AND t.final_team2 IS NULL THEN NULL ELSE jsonb_build_object('id', 'FINAL', 'team1', t.final_team1, 'team2', t.final_team2, 'score1', t.final_score1, 'score2', t.final_score2, 'stage', 'Final', 'groupIndex', NULL) END,
      'finalResult', CASE WHEN t.final_winner_team IS NULL THEN NULL ELSE jsonb_build_object('winner', t.final_winner_team, 'runnerUp', t.final_runner_up_team) END
    )::TEXT AS value
  FROM api.tournaments t
),
player_list_payloads AS (
  SELECT
    'bt_playerlist_v1_' || pl.id AS key,
    jsonb_build_object(
      'name', pl.name,
      'players', COALESCE((SELECT jsonb_agg(plp.player_name ORDER BY plp.player_order) FROM api.player_list_players plp WHERE plp.player_list_id = pl.id), '[]'::JSONB)
    )::TEXT AS value
  FROM api.player_lists pl
),
index_payloads AS (
  SELECT 'bt_tournaments_index_v1' AS key,
    COALESCE(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'createdAt', EXTRACT(EPOCH FROM t.updated_at)::BIGINT * 1000, 'updatedAt', EXTRACT(EPOCH FROM t.updated_at)::BIGINT * 1000) ORDER BY t.updated_at DESC), '[]'::JSONB)::TEXT AS value
  FROM api.tournaments t
  UNION ALL
  SELECT 'bt_playerlists_index_v1' AS key,
    COALESCE(jsonb_agg(pl.id ORDER BY pl.id), '[]'::JSONB)::TEXT AS value
  FROM api.player_lists pl
),
compat_payloads AS (
  SELECT key, value
  FROM api.app_storage
  WHERE key NOT LIKE 'bt_tournament_v1_%'
    AND key NOT LIKE 'bt_playerlist_v1_%'
    AND key NOT IN ('bt_tournaments_index_v1', 'bt_playerlists_index_v1')
),
all_payloads AS (
  SELECT * FROM tournament_payloads
  UNION ALL SELECT * FROM player_list_payloads
  UNION ALL SELECT * FROM index_payloads
  UNION ALL SELECT * FROM compat_payloads
)
SELECT jsonb_object_agg(key, value) FROM all_payloads;
$$;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.knockout_matches TO web_anon;
GRANT EXECUTE ON FUNCTION
  api.save_tournament(JSONB),
  api.delete_tournament(TEXT),
  api.save_player_list(TEXT, JSONB),
  api.delete_player_list(TEXT),
  api.export_app_state()
TO web_anon;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS api.app_users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  username TEXT NOT NULL UNIQUE CHECK (username = lower(username)),
  display_name TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  is_admin BOOLEAN NOT NULL DEFAULT FALSE,
  must_reset_password BOOLEAN NOT NULL DEFAULT TRUE,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS api.app_sessions (
  token TEXT PRIMARY KEY DEFAULT encode(gen_random_bytes(32), 'hex'),
  user_id UUID NOT NULL REFERENCES api.app_users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '2 minutes'
);

ALTER TABLE api.app_sessions
  ALTER COLUMN expires_at SET DEFAULT NOW() + INTERVAL '2 minutes';

DROP TRIGGER IF EXISTS app_users_touch_updated_at ON api.app_users;
CREATE TRIGGER app_users_touch_updated_at
BEFORE UPDATE ON api.app_users
FOR EACH ROW
EXECUTE FUNCTION api.touch_updated_at();

INSERT INTO api.app_users (username, display_name, password_hash, is_admin, must_reset_password, is_active)
VALUES ('admin', 'Administrator', crypt('TournamentApp2026', gen_salt('bf')), TRUE, FALSE, TRUE)
ON CONFLICT (username) DO NOTHING;

CREATE OR REPLACE FUNCTION api.current_user_from_token(auth_token TEXT)
RETURNS api.app_users
LANGUAGE sql
STABLE
AS $$
  SELECT u.*
  FROM api.app_sessions s
  JOIN api.app_users u ON u.id = s.user_id
  WHERE s.token = auth_token
    AND s.expires_at > NOW()
    AND u.is_active = TRUE
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION api.require_active_user(auth_token TEXT)
RETURNS api.app_users
LANGUAGE plpgsql
AS $$
DECLARE
  current_user_row api.app_users;
BEGIN
  DELETE FROM api.app_sessions WHERE expires_at <= NOW();

  WITH refreshed_session AS (
    UPDATE api.app_sessions s
    SET expires_at = NOW() + INTERVAL '2 minutes'
    FROM api.app_users u
    WHERE s.token = auth_token
      AND s.user_id = u.id
      AND s.expires_at > NOW()
      AND u.is_active = TRUE
    RETURNING
      u.id,
      u.username,
      u.display_name,
      u.password_hash,
      u.is_admin,
      u.must_reset_password,
      u.is_active,
      u.created_at,
      u.updated_at
  )
  SELECT * INTO current_user_row
  FROM refreshed_session
  LIMIT 1;

  IF current_user_row.id IS NULL THEN
    RAISE EXCEPTION 'Invalid or expired session' USING ERRCODE = '28000';
  END IF;
  RETURN current_user_row;
END;
$$;

CREATE OR REPLACE FUNCTION api.require_admin_user(auth_token TEXT)
RETURNS api.app_users
LANGUAGE plpgsql
AS $$
DECLARE
  current_user_row api.app_users;
BEGIN
  current_user_row := api.require_active_user(auth_token);
  IF current_user_row.is_admin IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501';
  END IF;
  RETURN current_user_row;
END;
$$;

CREATE OR REPLACE FUNCTION api.login_user(username TEXT, password TEXT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  user_row api.app_users;
  session_token TEXT;
  session_expires_at TIMESTAMPTZ;
  active_session_count INTEGER;
BEGIN
  SELECT * INTO user_row
  FROM api.app_users u
  WHERE u.username = lower(login_user.username)
    AND u.is_active = TRUE;

  IF user_row.id IS NULL OR user_row.password_hash <> crypt(password, user_row.password_hash) THEN
    RAISE EXCEPTION 'Invalid username or password' USING ERRCODE = '28000';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(user_row.id::text));

  DELETE FROM api.app_sessions WHERE expires_at <= NOW();

  SELECT COUNT(*) INTO active_session_count
  FROM api.app_sessions s
  WHERE s.user_id = user_row.id
    AND s.expires_at > NOW();

  IF active_session_count >= 3 THEN
    RAISE EXCEPTION 'Login session limit exceeded. Please logout from another device before logging in again.' USING ERRCODE = '28000';
  END IF;

  INSERT INTO api.app_sessions (user_id, expires_at)
  VALUES (user_row.id, NOW() + INTERVAL '2 minutes')
  RETURNING token, expires_at INTO session_token, session_expires_at;

  RETURN jsonb_build_object(
    'token', session_token,
    'expiresAt', session_expires_at,
    'username', user_row.username,
    'displayName', user_row.display_name,
    'isAdmin', user_row.is_admin,
    'mustResetPassword', user_row.must_reset_password
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.logout_user(auth_token TEXT)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  DELETE FROM api.app_sessions WHERE token = auth_token;
END;
$$;

CREATE OR REPLACE FUNCTION api.refresh_session(auth_token TEXT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  user_row api.app_users;
  session_expires_at TIMESTAMPTZ;
BEGIN
  user_row := api.require_active_user(auth_token);

  SELECT s.expires_at INTO session_expires_at
  FROM api.app_sessions s
  WHERE s.token = auth_token;

  RETURN jsonb_build_object(
    'ok', TRUE,
    'expiresAt', session_expires_at,
    'username', user_row.username
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.change_my_password(auth_token TEXT, current_password TEXT, new_password TEXT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  user_row api.app_users;
BEGIN
  user_row := api.require_active_user(auth_token);

  IF length(COALESCE(new_password, '')) < 8 THEN
    RAISE EXCEPTION 'New password must be at least 8 characters' USING ERRCODE = '22023';
  END IF;

  IF user_row.password_hash <> crypt(current_password, user_row.password_hash) THEN
    RAISE EXCEPTION 'Current password is incorrect' USING ERRCODE = '28000';
  END IF;

  UPDATE api.app_users
  SET password_hash = crypt(new_password, gen_salt('bf')),
      must_reset_password = FALSE
  WHERE id = user_row.id;

  RETURN jsonb_build_object('ok', TRUE);
END;
$$;

CREATE OR REPLACE FUNCTION api.list_users(auth_token TEXT)
RETURNS TABLE (
  username TEXT,
  display_name TEXT,
  is_admin BOOLEAN,
  must_reset_password BOOLEAN,
  is_active BOOLEAN,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM api.require_admin_user(auth_token);

  RETURN QUERY
  SELECT u.username, u.display_name, u.is_admin, u.must_reset_password, u.is_active, u.created_at, u.updated_at
  FROM api.app_users u
  ORDER BY u.username;
END;
$$;

CREATE OR REPLACE FUNCTION api.create_user(auth_token TEXT, username TEXT, display_name TEXT, temporary_password TEXT, is_admin BOOLEAN DEFAULT FALSE)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  normalized_username TEXT;
BEGIN
  PERFORM api.require_admin_user(auth_token);

  normalized_username := lower(trim(username));
  IF normalized_username = '' OR normalized_username IS NULL THEN
    RAISE EXCEPTION 'Username is required' USING ERRCODE = '22023';
  END IF;
  IF length(COALESCE(temporary_password, '')) < 8 THEN
    RAISE EXCEPTION 'Temporary password must be at least 8 characters' USING ERRCODE = '22023';
  END IF;

  INSERT INTO api.app_users (username, display_name, password_hash, is_admin, must_reset_password, is_active)
  VALUES (
    normalized_username,
    COALESCE(NULLIF(trim(display_name), ''), normalized_username),
    crypt(temporary_password, gen_salt('bf')),
    COALESCE(is_admin, FALSE),
    TRUE,
    TRUE
  );

  RETURN jsonb_build_object('ok', TRUE, 'username', normalized_username);
END;
$$;

CREATE OR REPLACE FUNCTION api.reset_user_password(auth_token TEXT, username TEXT, temporary_password TEXT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  normalized_username TEXT;
BEGIN
  PERFORM api.require_admin_user(auth_token);

  normalized_username := lower(trim(username));
  IF length(COALESCE(temporary_password, '')) < 8 THEN
    RAISE EXCEPTION 'Temporary password must be at least 8 characters' USING ERRCODE = '22023';
  END IF;

  UPDATE api.app_users
  SET password_hash = crypt(temporary_password, gen_salt('bf')),
      must_reset_password = TRUE
  WHERE app_users.username = normalized_username;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'User not found' USING ERRCODE = '02000';
  END IF;

  RETURN jsonb_build_object('ok', TRUE, 'username', normalized_username);
END;
$$;

CREATE OR REPLACE FUNCTION api.set_user_active(auth_token TEXT, username TEXT, is_active BOOLEAN)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  admin_row api.app_users;
  normalized_username TEXT;
BEGIN
  admin_row := api.require_admin_user(auth_token);
  normalized_username := lower(trim(username));

  IF normalized_username = admin_row.username AND is_active IS FALSE THEN
    RAISE EXCEPTION 'You cannot disable your own account' USING ERRCODE = '42501';
  END IF;

  UPDATE api.app_users u
  SET is_active = set_user_active.is_active
  WHERE u.username = normalized_username;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'User not found' USING ERRCODE = '02000';
  END IF;

  RETURN jsonb_build_object('ok', TRUE, 'username', normalized_username, 'isActive', is_active);
END;
$$;

DROP FUNCTION IF EXISTS api.save_tournament(JSONB);
CREATE OR REPLACE FUNCTION api.save_tournament(auth_token TEXT, payload JSONB)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM api.require_active_user(auth_token);
  PERFORM api.sync_app_storage_row('bt_tournament_v1_' || (payload->>'id'), payload::TEXT);
END;
$$;

DROP FUNCTION IF EXISTS api.delete_tournament(TEXT);
CREATE OR REPLACE FUNCTION api.delete_tournament(auth_token TEXT, tournament_id TEXT)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM api.require_active_user(auth_token);
  DELETE FROM api.tournaments WHERE id = tournament_id;
END;
$$;

DROP FUNCTION IF EXISTS api.save_player_list(TEXT, JSONB);
CREATE OR REPLACE FUNCTION api.save_player_list(auth_token TEXT, storage_key TEXT, payload JSONB)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM api.require_active_user(auth_token);
  PERFORM api.sync_app_storage_row(storage_key, payload::TEXT);
END;
$$;

DROP FUNCTION IF EXISTS api.delete_player_list(TEXT);
CREATE OR REPLACE FUNCTION api.delete_player_list(auth_token TEXT, player_list_id TEXT)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM api.require_active_user(auth_token);
  DELETE FROM api.player_lists WHERE id = player_list_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.export_app_state(auth_token TEXT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  result JSONB;
BEGIN
  PERFORM api.require_active_user(auth_token);

  WITH tournament_payloads AS (
    SELECT
      'bt_tournament_v1_' || t.id AS key,
      jsonb_build_object(
        'id', t.id,
        'name', t.name,
        'type', COALESCE(t.type, ''),
        'fixtureType', COALESCE(t.fixture_type, ''),
        'matchType', COALESCE(t.match_type, ''),
        'playoffFormat', COALESCE(t.playoff_format, 'Semifinals'),
        'teamsCount', t.teams_count,
        'groupsCount', t.groups_count,
        'teamsPerGroup', t.teams_per_group,
        'players', COALESCE((SELECT jsonb_agg(tp.player_name ORDER BY tp.player_order) FROM api.tournament_players tp WHERE tp.tournament_id = t.id), '[]'::JSONB),
        'teams', COALESCE((SELECT jsonb_agg(tm.team_name ORDER BY tm.team_order) FROM api.teams tm WHERE tm.tournament_id = t.id), '[]'::JSONB),
        'teamPlayers', COALESCE((
          SELECT jsonb_object_agg(team_name, players ORDER BY team_order)
          FROM (
            SELECT tm.team_name, tm.team_order, COALESCE(jsonb_agg(tp.player_name ORDER BY tp.player_order) FILTER (WHERE tp.player_name IS NOT NULL), '[]'::JSONB) AS players
            FROM api.teams tm
            LEFT JOIN api.team_players tp ON tp.tournament_id = tm.tournament_id AND tp.team_name = tm.team_name
            WHERE tm.tournament_id = t.id
            GROUP BY tm.team_name, tm.team_order
          ) team_payload
        ), '{}'::JSONB),
        'groupAssignments', COALESCE(t.group_assignments, '[]'::JSONB),
        'matches', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'id', CASE WHEN m.match_id ~ '^\d+$' THEN to_jsonb(m.match_id::INTEGER) ELSE to_jsonb(m.match_id) END,
            'team1', m.team1,
            'team2', m.team2,
            'score1', m.score1,
            'score2', m.score2,
            'stage', m.stage,
            'groupIndex', m.group_index
          ) ORDER BY CASE WHEN m.match_id ~ '^\d+$' THEN m.match_id::INTEGER ELSE 2147483647 END, m.match_id)
          FROM api.matches m
          WHERE m.tournament_id = t.id
        ), '[]'::JSONB),
        'knockout', jsonb_build_object(
          'semifinal1', COALESCE((SELECT jsonb_build_object('id', km.match_id, 'stage', km.stage, 'team1', km.team1, 'team2', km.team2, 'score1', km.score1, 'score2', km.score2) FROM api.knockout_matches km WHERE km.tournament_id = t.id AND km.match_id = 'SEMIFINAL-1'), jsonb_build_object('id', 'SEMIFINAL-1', 'stage', 'Semifinal 1', 'team1', '', 'team2', '', 'score1', NULL, 'score2', NULL)),
          'semifinal2', COALESCE((SELECT jsonb_build_object('id', km.match_id, 'stage', km.stage, 'team1', km.team1, 'team2', km.team2, 'score1', km.score1, 'score2', km.score2) FROM api.knockout_matches km WHERE km.tournament_id = t.id AND km.match_id = 'SEMIFINAL-2'), jsonb_build_object('id', 'SEMIFINAL-2', 'stage', 'Semifinal 2', 'team1', '', 'team2', '', 'score1', NULL, 'score2', NULL)),
          'qualifier1', COALESCE((SELECT jsonb_build_object('id', km.match_id, 'stage', km.stage, 'team1', km.team1, 'team2', km.team2, 'score1', km.score1, 'score2', km.score2) FROM api.knockout_matches km WHERE km.tournament_id = t.id AND km.match_id = 'QUALIFIER-1'), jsonb_build_object('id', 'QUALIFIER-1', 'stage', 'Qualifier 1', 'team1', '', 'team2', '', 'score1', NULL, 'score2', NULL)),
          'eliminator', COALESCE((SELECT jsonb_build_object('id', km.match_id, 'stage', km.stage, 'team1', km.team1, 'team2', km.team2, 'score1', km.score1, 'score2', km.score2) FROM api.knockout_matches km WHERE km.tournament_id = t.id AND km.match_id = 'ELIMINATOR'), jsonb_build_object('id', 'ELIMINATOR', 'stage', 'Eliminator', 'team1', '', 'team2', '', 'score1', NULL, 'score2', NULL)),
          'qualifier2', COALESCE((SELECT jsonb_build_object('id', km.match_id, 'stage', km.stage, 'team1', km.team1, 'team2', km.team2, 'score1', km.score1, 'score2', km.score2) FROM api.knockout_matches km WHERE km.tournament_id = t.id AND km.match_id = 'QUALIFIER-2'), jsonb_build_object('id', 'QUALIFIER-2', 'stage', 'Qualifier 2', 'team1', '', 'team2', '', 'score1', NULL, 'score2', NULL)),
          'final', COALESCE((SELECT jsonb_build_object('id', km.match_id, 'stage', km.stage, 'team1', km.team1, 'team2', km.team2, 'score1', km.score1, 'score2', km.score2) FROM api.knockout_matches km WHERE km.tournament_id = t.id AND km.match_id = 'FINAL'), jsonb_build_object('id', 'FINAL', 'stage', 'Final', 'team1', COALESCE(t.final_team1, ''), 'team2', COALESCE(t.final_team2, ''), 'score1', t.final_score1, 'score2', t.final_score2))
        ),
        'finalMatch', CASE WHEN t.final_team1 IS NULL AND t.final_team2 IS NULL THEN NULL ELSE jsonb_build_object('id', 'FINAL', 'team1', t.final_team1, 'team2', t.final_team2, 'score1', t.final_score1, 'score2', t.final_score2, 'stage', 'Final', 'groupIndex', NULL) END,
        'finalResult', CASE WHEN t.final_winner_team IS NULL THEN NULL ELSE jsonb_build_object('winner', t.final_winner_team, 'runnerUp', t.final_runner_up_team) END
      )::TEXT AS value
    FROM api.tournaments t
  ),
  player_list_payloads AS (
    SELECT
      'bt_playerlist_v1_' || pl.id AS key,
      jsonb_build_object(
        'name', pl.name,
        'players', COALESCE((SELECT jsonb_agg(plp.player_name ORDER BY plp.player_order) FROM api.player_list_players plp WHERE plp.player_list_id = pl.id), '[]'::JSONB)
      )::TEXT AS value
    FROM api.player_lists pl
  ),
  index_payloads AS (
    SELECT 'bt_tournaments_index_v1' AS key,
      COALESCE(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'createdAt', EXTRACT(EPOCH FROM t.updated_at)::BIGINT * 1000, 'updatedAt', EXTRACT(EPOCH FROM t.updated_at)::BIGINT * 1000) ORDER BY t.updated_at DESC), '[]'::JSONB)::TEXT AS value
    FROM api.tournaments t
    UNION ALL
    SELECT 'bt_playerlists_index_v1' AS key,
      COALESCE(jsonb_agg(pl.id ORDER BY pl.id), '[]'::JSONB)::TEXT AS value
    FROM api.player_lists pl
  ),
  compat_payloads AS (
    SELECT key, value
    FROM api.app_storage
    WHERE key NOT LIKE 'bt_tournament_v1_%'
      AND key NOT LIKE 'bt_playerlist_v1_%'
      AND key NOT IN ('bt_tournaments_index_v1', 'bt_playerlists_index_v1')
  ),
  all_payloads AS (
    SELECT * FROM tournament_payloads
    UNION ALL SELECT * FROM player_list_payloads
    UNION ALL SELECT * FROM index_payloads
    UNION ALL SELECT * FROM compat_payloads
  )
  SELECT jsonb_object_agg(key, value) INTO result FROM all_payloads;

  RETURN COALESCE(result, '{}'::JSONB);
END;
$$;

GRANT SELECT ON api.app_users TO web_anon;
GRANT EXECUTE ON FUNCTION
  api.login_user(TEXT, TEXT),
  api.logout_user(TEXT),
  api.refresh_session(TEXT),
  api.change_my_password(TEXT, TEXT, TEXT),
  api.list_users(TEXT),
  api.create_user(TEXT, TEXT, TEXT, TEXT, BOOLEAN),
  api.reset_user_password(TEXT, TEXT, TEXT),
  api.set_user_active(TEXT, TEXT, BOOLEAN),
  api.save_tournament(TEXT, JSONB),
  api.delete_tournament(TEXT, TEXT),
  api.save_player_list(TEXT, TEXT, JSONB),
  api.delete_player_list(TEXT, TEXT),
  api.export_app_state(TEXT)
TO web_anon;

CREATE OR REPLACE FUNCTION api.save_app_setting(auth_token TEXT, storage_key TEXT, storage_value TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, public
AS $$
BEGIN
  PERFORM api.require_active_user(auth_token);
  INSERT INTO api.app_storage (key, value, updated_at)
  VALUES (storage_key, storage_value, NOW())
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
END;
$$;

CREATE OR REPLACE FUNCTION api.delete_app_setting(auth_token TEXT, storage_key TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, public
AS $$
BEGIN
  PERFORM api.require_active_user(auth_token);
  DELETE FROM api.app_storage WHERE key = storage_key;
END;
$$;

ALTER FUNCTION api.current_user_from_token(TEXT) SECURITY DEFINER SET search_path = api, public;
ALTER FUNCTION api.require_active_user(TEXT) SECURITY DEFINER SET search_path = api, public;
ALTER FUNCTION api.require_admin_user(TEXT) SECURITY DEFINER SET search_path = api, public;
ALTER FUNCTION api.login_user(TEXT, TEXT) SECURITY DEFINER SET search_path = api, public;
ALTER FUNCTION api.logout_user(TEXT) SECURITY DEFINER SET search_path = api, public;
ALTER FUNCTION api.refresh_session(TEXT) SECURITY DEFINER SET search_path = api, public;
ALTER FUNCTION api.change_my_password(TEXT, TEXT, TEXT) SECURITY DEFINER SET search_path = api, public;
ALTER FUNCTION api.list_users(TEXT) SECURITY DEFINER SET search_path = api, public;
ALTER FUNCTION api.create_user(TEXT, TEXT, TEXT, TEXT, BOOLEAN) SECURITY DEFINER SET search_path = api, public;
ALTER FUNCTION api.reset_user_password(TEXT, TEXT, TEXT) SECURITY DEFINER SET search_path = api, public;
ALTER FUNCTION api.set_user_active(TEXT, TEXT, BOOLEAN) SECURITY DEFINER SET search_path = api, public;
ALTER FUNCTION api.sync_app_storage_row(TEXT, TEXT) SECURITY DEFINER SET search_path = api, public;
ALTER FUNCTION api.sync_app_storage_to_tables() SECURITY DEFINER SET search_path = api, public;
ALTER FUNCTION api.cleanup_app_storage_tables() SECURITY DEFINER SET search_path = api, public;
ALTER FUNCTION api.save_tournament(TEXT, JSONB) SECURITY DEFINER SET search_path = api, public;
ALTER FUNCTION api.delete_tournament(TEXT, TEXT) SECURITY DEFINER SET search_path = api, public;
ALTER FUNCTION api.save_player_list(TEXT, TEXT, JSONB) SECURITY DEFINER SET search_path = api, public;
ALTER FUNCTION api.delete_player_list(TEXT, TEXT) SECURITY DEFINER SET search_path = api, public;
ALTER FUNCTION api.export_app_state(TEXT) SECURITY DEFINER SET search_path = api, public;

REVOKE ALL ON
  api.app_storage,
  api.tournaments,
  api.tournament_players,
  api.teams,
  api.team_players,
  api.matches,
  api.knockout_matches,
  api.player_lists,
  api.player_list_players,
  api.app_users,
  api.app_sessions
FROM web_anon;

GRANT EXECUTE ON FUNCTION
  api.login_user(TEXT, TEXT),
  api.logout_user(TEXT),
  api.refresh_session(TEXT),
  api.change_my_password(TEXT, TEXT, TEXT),
  api.list_users(TEXT),
  api.create_user(TEXT, TEXT, TEXT, TEXT, BOOLEAN),
  api.reset_user_password(TEXT, TEXT, TEXT),
  api.set_user_active(TEXT, TEXT, BOOLEAN),
  api.save_tournament(TEXT, JSONB),
  api.delete_tournament(TEXT, TEXT),
  api.save_player_list(TEXT, TEXT, JSONB),
  api.delete_player_list(TEXT, TEXT),
  api.export_app_state(TEXT),
  api.save_app_setting(TEXT, TEXT, TEXT),
  api.delete_app_setting(TEXT, TEXT)
TO web_anon;

DROP FUNCTION IF EXISTS api.export_app_state();

CREATE OR REPLACE FUNCTION api.delete_user(auth_token TEXT, username TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, public
AS $$
DECLARE
  admin_row api.app_users;
  target_row api.app_users;
  normalized_username TEXT;
  active_admin_count INTEGER;
BEGIN
  admin_row := api.require_admin_user(auth_token);
  normalized_username := lower(trim(username));

  SELECT * INTO target_row
  FROM api.app_users u
  WHERE u.username = normalized_username;

  IF target_row.id IS NULL THEN
    RAISE EXCEPTION 'User not found' USING ERRCODE = '02000';
  END IF;

  IF target_row.username = admin_row.username THEN
    RAISE EXCEPTION 'You cannot delete your own account' USING ERRCODE = '42501';
  END IF;

  IF target_row.is_admin THEN
    SELECT COUNT(*) INTO active_admin_count
    FROM api.app_users u
    WHERE u.is_admin = TRUE AND u.is_active = TRUE;

    IF active_admin_count <= 1 THEN
      RAISE EXCEPTION 'You cannot delete the last active admin account' USING ERRCODE = '42501';
    END IF;
  END IF;

  DELETE FROM api.app_users u
  WHERE u.id = target_row.id;

  RETURN jsonb_build_object('ok', TRUE, 'username', normalized_username);
END;
$$;

GRANT EXECUTE ON FUNCTION api.delete_user(TEXT, TEXT) TO web_anon;
