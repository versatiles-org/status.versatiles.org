[![CI status](https://img.shields.io/github/actions/workflow/status/versatiles-org/status.versatiles.org/ci.yml)](https://github.com/versatiles-org/status.versatiles.org/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

# status.versatiles.org

Checks the health of the VersaTiles services every minute, shows their state and uptime at **status.versatiles.org**, and alerts the maintainer through Pushover when one fails.

## What is checked

All checks are in [`gatus/config.yaml`](gatus/config.yaml), run by [Gatus](https://github.com/TwiN/gatus). The page groups them by importance: **Availability** (is each service up), **Content** (does it serve the right thing), **DNS and domains**, and **Map data age**. By service:

- **Tiles:** the map frontend, a vector tile and its content type, the tile metadata, a style and `version.json` on tiles.versatiles.org, and whether it serves the newest planet (7 days after a release at the latest).
- **Satellite:** a tile from the tile server's local copy (zoom 5) and one it takes from the CDN (zoom 17), their content type, and the metadata.
- **Download:** the download page, the planet file and the CDN behind it, and whether the newest planet is at most 180 days old.
- **Geocoding:** a search on geocode.versatiles.org.
- **Websites:** versatiles.org and docs.versatiles.org.
- **Status page:** this page itself, through its public address, mainly for its certificate: the only one renewed on this server.
- **DNS:** the A records of the servers, the CNAMEs of download and docs, the name servers and the expiry of the domains.

Besides the status code and response time, the checks look at the content (a tile of the expected size, a style with its layers, a search that finds Berlin) and at TLS certificates that are less than 14 days from expiry.

Gatus can't read response headers or compare dates, so the content types and the planet dates are checked by [`bin/push/checks.sh`](bin/push/checks.sh). Cron runs it every 10 minutes, and it reports each result to Gatus. If it stops reporting for 30 minutes, those checks fail.

An alert is sent after three failed checks in a row, and again when the check has passed twice. Gatus doesn't group alerts, so only the checks that matter most for each service send them: the vector tile and the style, both satellite tiles, the content types and planet dates, the download page and the CDN, geocoding, the websites, the status page, DNS and domains. The map frontend, the tile metadata, the satellite metadata, `version.json` and the planet file show on the page only. If tiles.versatiles.org goes down completely, that's four messages, one per alerting tile check; the push checks skip a source that doesn't answer.

## Architecture

- **gatus:** runs the checks, keeps the uptime history in SQLite (`volumes/gatus-data`) and serves the page.
- **nginx:** TLS in front of Gatus, and the certbot challenge.
- **certbot:** Let's Encrypt certificate, renewed weekly by cron.
- **login:** the login for the private area at `/private/`, a small Node service without dependencies ([`login/`](login/)). nginx asks it about every request there (`auth_request`). Passwords are stored as scrypt hashes in `volumes/login/users`, sessions are signed cookies that last 7 days. Removing a user or changing their password ends their sessions at once. Logins are limited to 10 per minute per address.
- **bin/dashboard/update.sh:** optional. Every 15 minutes by cron, and right after each push through the webhook, it pulls the private repo named by `DASHBOARD_REPO` in `.env` with a read-only deploy key, runs that repo's `npm run dashboard -- --out <dir>` in the Node image, and nginx serves the result at `/private/dashboard/` behind the login. `bin/dashboard/setup.sh` creates the deploy key and prints it for the repo's settings.
- **webhook:** GitHub calls `POST /webhook`. The login service checks the signature (`WEBHOOK_SECRET` in `.env`, generated like the other secrets) and drops a job file into `volumes/webhook`. A systemd path unit on the host notices it and runs [`bin/webhook/run.sh`](bin/webhook/run.sh) (log: `journalctl -u status-webhook`). Events during a run lead to one more run. Two jobs:
  - **update:** when CI passes on `main` of this repo (`UPDATE_REPO` in `.env`), the server runs `bin/update.sh`. Pull requests and forks never deploy. A failed update shows only in the journal; if it breaks a service, the checks alert.
  - **dashboard:** each push to the dashboard repo rebuilds the dashboard. Its cron job stays as a fallback for missed deliveries.
- **bin/push/checks.sh:** the checks Gatus can't run, every 10 minutes by cron on the host. It reports with `GATUS_PUSH_TOKEN`, which `bin/setup.sh` and `bin/update.sh` generate into `.env`.

The configuration of both Gatus and nginx reaches the containers through directory mounts, so `bin/update.sh` applies it without recreating them.

## Setup

1. Create the server with the [hetzner](https://github.com/versatiles-org/hetzner-scripts) scripts and the `install-status.sh` install script. Pick a location away from the servers it watches.
2. Point the DNS record of status.versatiles.org at the server.
3. On the server:

   ```sh
   cd /root/status.versatiles.org
   cp template.env .env   # then fill in EMAIL and the Pushover keys
   ./bin/setup.sh
   ./bin/user.sh add <name>   # a user for the private area
   ```

Webhooks, both with payload URL `https://status.versatiles.org/webhook`, content type `application/json` and the secret from `WEBHOOK_SECRET` in `.env`:

- In this repo's settings, with only "Workflow runs" selected, so the server updates itself after CI passes.
- For the dashboard, in the settings of the repo named by `DASHBOARD_REPO`, with only the push event.

GitHub's first delivery is a ping, which should get a green check under "Recent Deliveries".

`.env` holds the secrets and is not committed. Keep a copy in the password manager, so a rebuilt server can be set up again.

The status server can't report its own outage. Add an external uptime monitor (for example a free one at UptimeRobot) that checks https://status.versatiles.org/.

## Usage

```sh
./bin/update.sh    # pull, apply new images and configs, verify (the webhook runs it after CI passes on main)
./bin/verify.sh    # check that this server serves the page with all endpoints
./bin/push/checks.sh  # run the push checks now and print their results
./bin/user.sh list    # users of the private area; also add <name>, passwd <name>, remove <name>
tests/login.sh     # test the login service (needs docker)
tests/config.sh    # start Gatus locally with the config, run the push checks against it, print the results (needs docker and jq)
```

To change a check, edit `gatus/config.yaml`, run `tests/config.sh`, commit and push. Once CI passes, the webhook updates the server; without the webhook, run `bin/update.sh` there.
