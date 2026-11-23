# status.versatiles.org

Public status page and alerts for the VersaTiles services. The README describes the setup.

- The checks are in `gatus/config.yaml`. Check config keys against the Gatus README of the version pinned in `compose.yaml`, not from memory.
- Gatus can't check response headers. Content checks use the JSON body, `pat()` on HTML or `len([BODY])`.
- Alerts are for outages only. Failing CI or security alerts don't belong here.
- Verify with `tests/config.sh` (starts Gatus in Docker and hits the live services) and `shellcheck -x bin/*.sh bin/cert/*.sh tests/*.sh`, as CI does.
- Deployment follows `tiles.versatiles.org`: Docker Compose, nginx and certbot, `bin/update.sh`. Look there before inventing a new pattern.
