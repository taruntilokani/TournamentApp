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
