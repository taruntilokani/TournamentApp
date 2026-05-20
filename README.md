# Badminton Tournament Manager

Container-based setup for the tournament app.

## What Runs

- `web`: Nginx web server hosting `tournament.html` on port `8080`.
- `api`: PostgREST API exposing the storage table at `/api/app_storage`.
- `db`: PostgreSQL database container with a persistent Docker volume.
- `ngrok`: optional container that exposes the web app online.

The frontend hydrates its saved app keys from PostgreSQL before the app starts and mirrors future saves/deletes back to the database.

## Start Locally

Because Docker Snap may not be able to access `/data/badminton`, the currently running copy is in:

```bash
/home/devops/badminton-runtime
```

Start it with:

```bash
cd /home/devops/badminton-runtime
sudo -n docker compose up -d
```

Open:

```text
http://localhost:8080
```

Validate API/database access:

```bash
curl http://localhost:8080/api/app_storage
```



## Login / Admin Access

The app now uses Postgres-backed user accounts and sessions. The login page is served by the app; the old Nginx Basic Auth gate is no longer used.

Seeded admin account for this machine:

```text
Username: admin
Password: TournamentApp2026
```

Admins can create users from the in-app **Users** section. New users receive a temporary password and are forced to reset it on their first login before they can access the tournament screens.

Auth-related RPCs exposed through PostgREST:

```bash
# Login
curl -X POST http://localhost:8080/api/rpc/login_user \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"TournamentApp2026"}'

# List users with an admin session token
curl -X POST http://localhost:8080/api/rpc/list_users \
  -H 'Content-Type: application/json' \
  -d '{"auth_token":"TOKEN"}'

# Create a user with first-login password reset required
curl -X POST http://localhost:8080/api/rpc/create_user \
  -H 'Content-Type: application/json' \
  -d '{"auth_token":"TOKEN","username":"scorer1","display_name":"Court Scorer","temporary_password":"TempPass2026","is_admin":false}'
```

Direct table endpoints are not granted to anonymous users; app data flows through token-protected RPCs.

## Normalized Database Tables

The frontend still uses the original browser-friendly storage keys, but PostgreSQL now decomposes tournament and player-list JSON into real relational tables through triggers on `api.app_storage`. This keeps the current UI stable while making reporting and future API work much cleaner.

Normalized tables exposed through PostgREST:

- `api.tournaments`
- `api.tournament_players`
- `api.teams`
- `api.team_players`
- `api.matches`
- `api.player_lists`
- `api.player_list_players`

Useful API examples:

```bash
# direct table endpoints are blocked without RPC/session access
curl -X POST http://localhost:8080/api/rpc/export_app_state -H 'Content-Type: application/json' -d '{"auth_token":"TOKEN"}'
```

The compatibility table remains available at `api.app_storage` for small UI-only keys such as active tab or local draft state. Tournament and player-list reads/writes now use normalized RPC endpoints.

Normalized write/read RPCs:

```bash
# Rebuild browser app state from normalized tables
curl -X POST http://localhost:8080/api/rpc/export_app_state -H 'Content-Type: application/json' -d '{"auth_token":"TOKEN"}'

# Save a tournament payload into normalized tables
curl -X POST http://localhost:8080/api/rpc/save_tournament \
  -H 'Content-Type: application/json' \
  -d '{"auth_token":"TOKEN","payload": {"id": "example", "name": "Example Tournament"}}'

# Delete a tournament
curl -X POST http://localhost:8080/api/rpc/delete_tournament \
  -H 'Content-Type: application/json' \
  -d '{"auth_token":"TOKEN","tournament_id": "example"}'
```

## Expose Online With ngrok

Create `.env` in `/home/devops/badminton-runtime` and set your ngrok token:

```bash
cp .env.example .env
# edit .env and set NGROK_AUTHTOKEN
```

Start the app plus ngrok:

```bash
sudo -n docker compose --profile online up -d
```

Find the public URL:

```bash
sudo -n docker logs badminton-ngrok
```

Look for the `https://...ngrok-free.app` forwarding URL.

## Stop

```bash
sudo -n docker compose down
```

This keeps the database volume. To delete all saved data too:

```bash
sudo -n docker compose down -v
```

