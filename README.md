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
- **private area:** everything under `/private/` is behind the login. nginx adds the same bar to the top of every page there ([`nginx/private.conf`](nginx/private.conf), styled by [`private/bar.css`](private/bar.css)), with links to the areas and the logout, whichever tool generated the page. Each area keeps its own navigation below it.
- **bin/dashboard/update.sh:** optional. Every 15 minutes by cron, and right after each push through the webhook, it pulls the private repo named by `DASHBOARD_REPO` in `.env` with a read-only deploy key, runs that repo's `npm run dashboard -- --out <dir>` in the Node image, and nginx serves the result at `/private/dashboard/` behind the login. It passes the dependency status (`--status`) and the servers' cron job reports (`--reports`, read-only). `bin/dashboard/setup.sh` creates the deploy key and prints it for the repo's settings.
- **webhook:** GitHub calls `POST /webhook`. The login service checks the signature (`WEBHOOK_SECRET` in `.env`, generated like the other secrets) and drops a job file into `volumes/webhook/now` or `volumes/webhook/batched`. A systemd path unit on the host notices a job in `now` and runs [`bin/webhook/run.sh`](bin/webhook/run.sh) (log: `journalctl -u status-webhook`); jobs in `batched` wait for their cron job. Events during a run lead to one more run. Three jobs:
  - **update:** when CI passes on `main` of this repo (`UPDATE_REPO` in `.env`), the server runs `bin/update.sh`. Pull requests and forks never deploy. A failed update shows only in the journal; if it breaks a service, the checks alert.
  - **dashboard:** each push to the dashboard repo rebuilds the dashboard. Its cron job stays as a fallback for missed deliveries.
  - **dependency-status** (batched): a push or CI run on the default branch, a release, an issue or pull request opened or closed, or a repo created, renamed or archived, in any public repo of the organisation.
- **bin/dependency-status/update.sh:** optional. The [dependency status](https://github.com/versatiles-org/dependency-graph) at `/private/dependency-status/`, with its page of issues and pull requests at `/private/dependency-status/issues/`, behind the login. Cron starts it every 10 minutes, and it runs when the webhook queued it or the last run is 6 hours old, so a burst of events leads to one run. It pulls the public dependency-graph repo, gets a read-only token from the GitHub App with [`github-app/token.mjs`](github-app/token.mjs), runs the collector (`npm run sync:deps`) and builds the page alone (`npm run build:status`). Then it rebuilds the dashboard, which takes its repo status from the same data.
- **bin/push/checks.sh:** the checks Gatus can't run, every 10 minutes by cron on the host. It reports with `GATUS_PUSH_TOKEN`, which `bin/setup.sh` and `bin/update.sh` generate into `.env`.
- **reports:** the servers' cron jobs report each run to `POST /report` ([`login/report.js`](login/report.js)), for the private dashboard. These reports never go to Gatus or the public page: some of them concern security. Each server has a token of its own (`REPORT_TOKEN_<SERVER>` in `.env`), which also says which server reports, so a token leaked from one server can't report for another. The latest report per server and job is kept in `volumes/reports/<server>/<job>.json`, with the time it arrived.

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

One webhook for the whole organisation (its settings → Webhooks), with payload URL `https://status.versatiles.org/webhook`, content type `application/json`, the secret from `WEBHOOK_SECRET` in `.env`, and the events Pushes, Releases, Issues, Pull requests, Repositories and Workflow runs. The receiver decides what each event triggers. GitHub's first delivery is a ping, which should get a green check under "Recent Deliveries".

For the dependency status, a GitHub App of the organisation, installed on all repositories, without webhook, with read-only access to Checks, Code scanning alerts, Commit statuses, Contents, Dependabot alerts, Issues, Metadata and Pull requests. The two alert permissions feed the security alerts behind the login; the token asks only for what the app was granted, so without them only the alerts are missing. Its Client ID goes into `.env` as `GITHUB_APP_CLIENT_ID`, its private key to `volumes/github-app/private-key.pem` (`chmod 600`). Keep a copy of the key with the `.env` copy.

For the reports, copy each other server's token from `.env` (`REPORT_TOKEN_TILES`, `REPORT_TOKEN_GEOCODE`) into that server's `.env` as `REPORT_TOKEN`. This server's own token is `REPORT_TOKEN` already; the login service gets it as `REPORT_TOKEN_STATUS`. The servers' cron jobs report through `bin/cron/run.sh`, the same script on every server; by hand, a report looks like this:

```sh
curl -sf --max-time 10 --retry 3 -X POST https://status.versatiles.org/report \
  -H "Authorization: Bearer $REPORT_TOKEN" -H 'Content-Type: application/json' \
  -d '{"job": "cert-renew", "exit_code": 0, "interval": 604800, "message": "renewed"}'
```

`job` is lower case letters, digits and `-`; `exit_code` the job's exit code; `interval` the seconds between runs, from which the dashboard sees that a job is overdue. `message` (up to 500 characters) and `details` (up to 20 flat values, such as a version) are optional. The answer is 204 when the report was stored, 400 with the reason when it is invalid, and 401 for a wrong token.

`.env` holds the secrets and is not committed. Keep a copy in the password manager, so a rebuilt server can be set up again.

The status server can't report its own outage. Add an external uptime monitor (for example a free one at UptimeRobot) that checks https://status.versatiles.org/.

## Usage

```sh
./bin/update.sh    # pull, apply new images and configs, verify (the webhook runs it after CI passes on main)
./bin/verify.sh    # check that this server serves the page with all endpoints
./bin/push/checks.sh  # run the push checks now and print their results
./bin/user.sh list    # users of the private area; also add <name>, passwd <name>, remove <name>
tests/login.sh     # test the login service, the webhook and the reports (needs docker)
tests/github-app.sh  # test the GitHub App token script (needs docker)
tests/private.sh   # test the private area through nginx: login and the shared bar on every area (needs docker)
tests/nginx-config.sh  # load the nginx config with nginx -t in the pinned image (needs docker)
tests/nginx-version.sh # test bin/nginx/check_version.sh
tests/cron-run.sh  # test bin/cron/run.sh (needs python3)
tests/config.sh    # start Gatus locally with the config, run the push checks against it, print the results (needs docker and jq)
```

To change a check, edit `gatus/config.yaml`, run `tests/config.sh`, commit and push. Once CI passes, the webhook updates the server; without the webhook, run `bin/update.sh` there.

## Keeping the images up to date

nginx faces the internet, and fixes for it reach the official image the day nginx releases them. So a daily cron job (4:30, set up by `bin/setup.sh` and `bin/update.sh`) runs `bin/nginx/update.sh`, the same procedure as on tiles.versatiles.org and geocode.versatiles.org. It pulls the nginx image and does nothing else unless a newer one arrived under the same tag. Then it checks that the config loads in the new image (`tests/nginx-config.sh`), recreates nginx (about 3 seconds of refused connections) and checks that it is healthy and answers HTTPS. If the config does not load, nginx keeps the previous image; if the new one does not work, nginx is recreated from the previous one. It never touches the other services, and it waits while `bin/update.sh` runs.

Afterwards `bin/nginx/check_version.sh` compares the running nginx with nginx's releases and fails when a newer release of the same line has been out for more than 2 days, or when the line is no longer one nginx.org maintains: then move the nginx tag in `compose.yaml` to a maintained line. The run is reported to the private dashboard (`bin/cron/run.sh`, with this server's `REPORT_TOKEN`); its log is `/var/log/nginx-update.log`.

The other images (Gatus, Node, certbot) are updated by pushes: Dependabot proposes new versions every week (`.github/dependabot.yml`), and `bin/update.sh` pulls them when it deploys. `.github/workflows/scan-images.yml` scans the images in `compose.yaml` for known vulnerabilities every Monday; the findings are under Security → Code scanning, not visible without a login.
