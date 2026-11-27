# status.versatiles.org

Public status page and alerts for the VersaTiles services. The README describes the setup.

- The checks are in `gatus/config.yaml`. Check config keys against the Gatus README of the version pinned in `compose.yaml`, not from memory.
- Gatus can't check response headers or compare dates. Content checks use the JSON body, `pat()` on HTML or `len([BODY])`. Anything beyond that goes in `bin/push/checks.sh`, which reports to an external endpoint. Its keys must match the names in the config; `tests/config.sh` fails if one doesn't.
- Alerts are for outages and for things that go stale unnoticed, like an old planet. Failing CI or security alerts don't belong here.
- Security problems never appear on the public page or in Gatus, whose API is public too: they go to the private dashboard. That's why the servers' cron job reports go to `POST /report` (`login/report.js`), not to a Gatus external endpoint.
- This repo is public. The dashboard's content comes from a private repo at run time (`DASHBOARD_REPO`); never commit anything of it here, and don't name that repo in code or docs.
- The login service in `login/` and the token script in `github-app/` use only Node's standard library, on purpose: no npm dependencies, no build, no package-lock. Keep it that way.
- Verify with `tests/config.sh` (starts Gatus in Docker and hits the live services), `tests/login.sh`, `tests/github-app.sh`, `tests/private.sh`, `tests/nginx-config.sh`, `tests/nginx-version.sh`, `tests/cron-run.sh` and `shellcheck -x bin/*.sh bin/cert/*.sh bin/push/*.sh bin/dashboard/*.sh bin/webhook/*.sh bin/dependency-status/*.sh bin/nginx/*.sh bin/cron/*.sh tests/*.sh`, as CI does.
- `bin/cron/run.sh` and `bin/nginx/check_version.sh` are the same scripts as in tiles.versatiles.org and photon-stack; keep all three copies alike.
- Pushing to `main` deploys: once CI passes, the webhook runs `bin/update.sh` on the server (see `bin/webhook/`). So `tests/config.sh` and `tests/login.sh` must pass before a push.
- Every area under `/private/` is a nginx location that sets `$private_section` and includes `nginx/private.conf`: the login, the headers and the shared bar at the top of each page come from there. Don't give an area its own login check or navigation to other areas; `tests/private.sh` fails if a location doesn't include the file.
- Deployment follows `tiles.versatiles.org`: Docker Compose, nginx and certbot, `bin/update.sh`. Look there before inventing a new pattern.
