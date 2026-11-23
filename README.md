[![CI status](https://img.shields.io/github/actions/workflow/status/versatiles-org/status.versatiles.org/ci.yml)](https://github.com/versatiles-org/status.versatiles.org/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

# status.versatiles.org

Checks the health of the VersaTiles services every minute, shows their state and uptime at **status.versatiles.org**, and alerts the maintainer through Pushover when one fails.

## What is checked

All checks are in [`gatus/config.yaml`](gatus/config.yaml), run by [Gatus](https://github.com/TwiN/gatus):

- **Tiles:** the map frontend, a vector tile, the tile metadata, a style and `version.json` on tiles.versatiles.org.
- **Download:** the download page, the planet file and the CDN behind it.
- **Geocoding:** a search on geocode.versatiles.org.
- **Websites:** versatiles.org and docs.versatiles.org.
- **DNS:** the A records of the servers, the CNAMEs of download and docs, the name servers and the expiry of the domains.

Besides the status code and response time, the checks look at the content (a tile of the expected size, a style with its layers, a search that finds Berlin) and at TLS certificates that are less than 14 days from expiry.

An alert is sent after three failed checks in a row, and again when the check has passed twice. Gatus doesn't group alerts, so only the checks that matter most for each service send them: the vector tile and the style, the download page and the CDN, geocoding, the websites, DNS and domains. The map frontend, the tile metadata, `version.json` and the planet file show on the page only, so a server going down sends two messages, not five.

## Architecture

- **gatus:** runs the checks, keeps the uptime history in SQLite (`volumes/gatus-data`) and serves the page.
- **nginx:** TLS in front of Gatus, and the certbot challenge.
- **certbot:** Let's Encrypt certificate, renewed weekly by cron.

The configuration of both Gatus and nginx reaches the containers through directory mounts, so `bin/update.sh` applies it without recreating them.

## Setup

1. Create the server with the [hetzner](https://github.com/versatiles-org/hetzner-scripts) scripts and the `install-status.sh` install script. Pick a location away from the servers it watches.
2. Point the DNS record of status.versatiles.org at the server.
3. On the server:

   ```sh
   cd /root/status.versatiles.org
   cp template.env .env   # then fill in EMAIL and the Pushover keys
   ./bin/setup.sh
   ```

`.env` holds the secrets and is not committed. Keep a copy in the password manager, so a rebuilt server can be set up again.

The status server can't report its own outage. Add an external uptime monitor (for example a free one at UptimeRobot) that checks https://status.versatiles.org/.

## Usage

```sh
./bin/update.sh    # pull, apply new images and configs, verify
./bin/verify.sh    # check that this server serves the page with all endpoints
tests/config.sh    # start Gatus locally with the config and print the results (needs docker and jq)
```

To change a check, edit `gatus/config.yaml`, run `tests/config.sh`, commit and run `bin/update.sh` on the server.
