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
curl http://localhost:8080/api/tournaments
curl http://localhost:8080/api/team_players
curl http://localhost:8080/api/matches
```

The compatibility table remains available at `api.app_storage` so the existing frontend can continue to save and load without a full rewrite.

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

