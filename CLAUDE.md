# status.versatiles.org

Public status page and alerts for the VersaTiles services. The README describes the setup.

- The checks are in `gatus/config.yaml`. Check config keys against the Gatus README of the version pinned in `compose.yaml`, not from memory.
- Gatus can't check response headers or compare dates. Content checks use the JSON body, `pat()` on HTML or `len([BODY])`. Anything beyond that goes in `bin/push/checks.sh`, which reports to an external endpoint. Its keys must match the names in the config; `tests/config.sh` fails if one doesn't.
- Alerts are for outages and for things that go stale unnoticed, like an old planet. Failing CI or security alerts don't belong here.
- Verify with `tests/config.sh` (starts Gatus in Docker and hits the live services) and `shellcheck -x bin/*.sh bin/cert/*.sh bin/push/*.sh tests/*.sh`, as CI does.
- Deployment follows `tiles.versatiles.org`: Docker Compose, nginx and certbot, `bin/update.sh`. Look there before inventing a new pattern.
